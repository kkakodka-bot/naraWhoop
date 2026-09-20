import Foundation
import GRDB
import NoopPush
import WhoopStore
import XCTest
@testable import Strand

/// Exercises the actual presentation handlers and SQLite journals, not SwiftUI clicks or rendering.
@MainActor
final class ScoringSyncControlTests: XCTestCase {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        private var upload = false
        private var sends = 0
        private var reads = 0
        func current() -> Bool { lock.lock(); defer { lock.unlock() }; return active }
        func retire() { lock.lock(); active = false; lock.unlock() }
        func online(_ value: Bool) { lock.lock(); upload = value; lock.unlock() }
        func canUpload() -> Bool { lock.lock(); defer { lock.unlock() }; return upload }
        func recordSend() { lock.lock(); sends += 1; lock.unlock() }
        func recordRead() { lock.lock(); reads += 1; lock.unlock() }
        var sendCount: Int { lock.lock(); defer { lock.unlock() }; return sends }
        var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    }

    private actor Boundary {
        let entered = XCTestExpectation(description: "first actual operation reached boundary")
        private var calls = 0
        private var opened = false
        private var waiter: CheckedContinuation<Void, Never>?
        func pauseFirst() async -> Int {
            calls += 1
            let ordinal = calls
            if ordinal == 1 {
                entered.fulfill()
                if !opened { await withCheckedContinuation { waiter = $0 } }
            }
            return ordinal
        }
        func release() { opened = true; waiter?.resume(); waiter = nil }
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let layout: AccountStorageLayout
        let context: AccountSessionContext
        let state = State()
        let consent: ScoringContextConsent
        let inputs: ScoringInputCoordinator
        let journal: ScoringInputJournal
        let owner: ScoringSyncControlOwner
        let sharing: ScoringContextSharingActions
        let actions: ScoringInputConflictActions

        init(root: URL, layout: AccountStorageLayout, context: AccountSessionContext,
             journal: ScoringInputJournal, headBoundary: Boundary?, openBoundary: Boundary?) {
            self.root = root; self.layout = layout; self.context = context; self.journal = journal
            consent = ScoringContextConsent(layout: layout)
            let state = state, gate = consent.gate
            owner = ScoringSyncControlOwner(context: context, isCurrent: { state.current() })
            inputs = ScoringInputCoordinator(context: context, layout: layout, dependencies: .init(
                isCurrent: { $0 == context && state.current() }, canUpload: { state.canUpload() },
                openJournal: { layout, fence in
                    if let openBoundary { _ = await openBoundary.pauseFirst() }
                    return try ScoringInputJournal(layout: layout, fence: fence)
                }, head: { change, captured in
                    let ordinal = if let headBoundary { await headBoundary.pauseFirst() } else { 0 }
                    return ScoringInputHead(schemaVersion: 1, userId: UUID(uuidString: captured.scope.userID)!,
                        sourceDeviceId: UUID(uuidString: change.device)!, kind: change.kind, entity: change.entity,
                        headRevision: 37 + Int64(ordinal))
                }, send: { _, _ in
                    state.recordSend()
                    throw ScoringInputRPC.Failure.unavailable
                }, allowsChange: { gate.allows($0) }))
            sharing = ScoringContextSharingActions(owner: owner, consent: consent)
            actions = ScoringInputConflictActions(owner: owner, coordinator: inputs)
        }

        func close() async throws {
            actions.suspend(); sharing.suspend(); state.retire(); consent.retire()
            try await inputs.waitForRetirement()
            try await journal.close()
            // Consent owns a separate actor/SQLite handle without a close API. Retain the synthetic
            // fixture until process teardown instead of unlinking a possibly live database.
        }
    }

    private func fixture(headBoundary: Boundary? = nil, openBoundary: Boundary? = nil) async throws -> Fixture {
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let root = temporary.appendingPathComponent("sync-controls-" + UUID().uuidString)
        let scope = try AccountScope(projectURL: "https://sync-controls.invalid", userID: UUID().uuidString)
        let context = AccountSessionContext(scope: scope, generation: UUID())
        let layout = AccountStorageLayout(baseDirectory: root, scope: scope)
        let journal = try await Task.detached { try ScoringInputJournal(layout: layout) }.value
        let f = Fixture(root: root, layout: layout, context: context, journal: journal,
                        headBoundary: headBoundary, openBoundary: openBoundary)
        addTeardownBlock {
            await headBoundary?.release(); await openBoundary?.release()
            try await f.close()
        }
        return f
    }

    private func change(_ value: Int = 30, day: String = "2026-09-18", entity: String = "primary") throws -> ScoringInputChange {
        try .init(device: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", kind: .profile, entity: entity,
            effectiveDay: day, payload: Data("{\"schemaVersion\":1,\"timezone\":\"UTC\",\"age\":\(value)}".utf8))
    }

    @discardableResult
    private func seed(_ f: Fixture, changes: [ScoringInputChange]) async throws -> ScoringInputJournal.Conflict {
        for value in changes { _ = try await f.journal.enqueue(value) }
        let next = try await f.journal.next()
        let pending = try XCTUnwrap(next)
        try await f.journal.retry(pending, conflict: true)
        let loaded = try await f.journal.conflict(id: pending.id)
        return try XCTUnwrap(loaded)
    }

    private func review(_ f: Fixture, with actions: ScoringInputConflictActions? = nil) async throws -> ScoringInputJournal.Conflict {
        let actions = actions ?? f.actions
        await actions.load()
        let conflict = try XCTUnwrap(actions.conflicts.first)
        actions.open(conflict.pending.id)
        f.state.online(true)
        await actions.checkHead()
        f.state.online(false)
        XCTAssertEqual(actions.reviewPhase, .ready)
        return try XCTUnwrap(actions.conflict)
    }

    private func inspector(_ f: Fixture) throws -> DatabaseQueue {
        try DatabaseQueue(path: f.layout.directory.appendingPathComponent("history-inputs.sqlite").path)
    }

    func testRealAppModelOwnerRejectsGuestAndInvalidatedGeneration() async throws {
        try XCTSkipUnless(AppRuntimeMode.isUnitTesting, "requires hermetic app construction")
        let f = try await fixture()
        let state = f.state, context = f.context
        let deps = ScoringInputCoordinator.Dependencies(isCurrent: { $0 == context && state.current() },
            canUpload: { false }, head: { _, _ in throw ScoringInputRPC.Failure.unavailable },
            send: { _, _ in throw ScoringInputRPC.Failure.unavailable })
        let model = AppModel(storageLayout: f.layout, context: context, presentationAllowed: false,
            captureAllowed: false, scoringInputDependencies: deps, nativePreferenceCurrent: { $0 == context && state.current() },
            preferenceScoringEnabled: { false }, isCurrent: { $0 == context && state.current() })
        let owner = try XCTUnwrap(ScoringSyncControlOwner(model: model))
        XCTAssertTrue(owner.isCurrent()); XCTAssertEqual(owner.context, context)
        state.retire()
        XCTAssertFalse(owner.isCurrent()); XCTAssertNil(ScoringSyncControlOwner(model: model))
        model.shutdownForAccountChange()
        await model.scoringPreferences?.waitForRetirement()
        try await model.scoringInputs?.waitForRetirement()
        let guestSuite = "sync-controls-guest-" + UUID().uuidString
        let guestDefaults = try XCTUnwrap(UserDefaults(suiteName: guestSuite))
        addTeardownBlock {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: guestSuite))
            defaults.removePersistentDomain(forName: guestSuite)
        }
        let guest = AppModel(storageLayout: .init(baseDirectory: f.root, scope: nil), context: nil,
            presentationAllowed: false, captureAllowed: false, guestPreferenceDefaults: guestDefaults,
            isCurrent: { $0 == nil })
        XCTAssertNil(ScoringSyncControlOwner(model: guest))
        guest.shutdownForAccountChange()
    }

    func testConsentLoadDefaultsOffAndDoesNotCreateDecisionIntents() async throws {
        let f = try await fixture()
        XCTAssertEqual(f.sharing.phase, .idle); XCTAssertTrue(f.sharing.disabled)
        await f.sharing.load()
        XCTAssertEqual(f.sharing.phase, .ready)
        XCTAssertFalse(f.consent.enabled(.journal)); XCTAssertFalse(f.consent.enabled(.cycle))
        let db = try DatabaseQueue(path: f.layout.directory.appendingPathComponent("scoring-context-consent.sqlite").path)
        defer { try? db.close() }
        let count = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM consent_intent") }
        XCTAssertEqual(count, 0); XCTAssertEqual(f.state.sendCount, 0)
    }

    func testLocalConsentSaveIsDurableWithoutClaimingServerReceipt() async throws {
        let f = try await fixture()
        await f.sharing.load()
        await f.sharing.save(true, purpose: .journal)
        let saved = try XCTUnwrap(f.consent.decisions[.journal])
        XCTAssertTrue(saved.enabled); XCTAssertEqual(f.sharing.phase, .ready)
        XCTAssertTrue(f.sharing.message?.contains("Server acceptance is not confirmed") == true)
        let reopened = ScoringContextConsent(layout: f.layout)
        await reopened.load()
        XCTAssertEqual(reopened.decisions[.journal], saved)
        reopened.retire()
        let pending = try await f.journal.status()
        XCTAssertEqual(pending.pending, 0); XCTAssertEqual(f.state.sendCount, 0)
    }

    func testFailedRevokeReloadAndFreshControllerRemainPausedWithoutOriginalRetry() async throws {
        let f = try await fixture()
        await f.sharing.load(); await f.sharing.save(true, purpose: .journal)
        let db = try DatabaseQueue(path: f.layout.directory.appendingPathComponent("scoring-context-consent.sqlite").path)
        defer { try? db.close() }
        try await db.write { database in
            try database.execute(sql: """
                CREATE TRIGGER deny_revocation BEFORE UPDATE ON consent_decision
                WHEN NEW.purpose='journal_context' AND NEW.enabled=0
                BEGIN SELECT RAISE(ABORT,'synthetic write failure'); END;
                """)
        }
        await f.sharing.save(false, purpose: .journal)
        XCTAssertEqual(f.sharing.phase, .failed); XCTAssertFalse(f.consent.enabled(.journal))
        let before = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM consent_intent") }
        f.consent.retire()
        let reopened = ScoringContextConsent(layout: f.layout)
        let actions = ScoringContextSharingActions(owner: f.owner, consent: reopened)
        await actions.load(); await actions.load()
        XCTAssertEqual(actions.phase, .failed); XCTAssertFalse(reopened.enabled(.journal))
        let after = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM consent_intent") }
        XCTAssertEqual(before, after, "reopening/reloading must not create another dated decision")
        reopened.retire()
    }

    func testConsentLoadFailureIsNotEmptyOrSaved() async throws {
        let f = try await fixture()
        let path = f.layout.directory.appendingPathComponent("scoring-context-consent.sqlite")
        try await Task.detached { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }.value
        await f.sharing.load()
        XCTAssertEqual(f.sharing.phase, .failed); XCTAssertFalse(f.consent.loaded)
        XCTAssertTrue(f.sharing.disabled); XCTAssertNotNil(f.sharing.message)
    }

    func testSuspendingConsentPresentationDoesNotInventRollbackOrLateSuccess() async throws {
        let f = try await fixture()
        await f.sharing.load()
        f.consent.willChange = { [weak actions = f.sharing] in actions?.suspend() }
        await f.sharing.save(true, purpose: .cycle)
        XCTAssertEqual(f.sharing.phase, .idle); XCTAssertNil(f.sharing.message)
        XCTAssertTrue(f.consent.enabled(.cycle), "the explicit durable choice still completes")
        await f.sharing.load()
        XCTAssertEqual(f.sharing.phase, .ready); XCTAssertNil(f.sharing.message)
    }

    func testRetirementDuringConsentChoiceSuppressesPublication() async throws {
        let f = try await fixture()
        await f.sharing.load()
        f.consent.willChange = { [state = f.state, weak consent = f.consent] in state.retire(); consent?.retire() }
        await f.sharing.save(true, purpose: .journal)
        XCTAssertEqual(f.sharing.phase, .retired); XCTAssertFalse(f.consent.enabled(.journal))
        XCTAssertTrue(f.sharing.disabled)
    }

    func testListLoadingIsDistinctFromVerifiedEmpty() async throws {
        let boundary = Boundary()
        let f = try await fixture(openBoundary: boundary)
        let loading = Task { await f.actions.load() }
        await fulfillment(of: [boundary.entered], timeout: 3)
        XCTAssertEqual(f.actions.loadPhase, .loading)
        await boundary.release(); await loading.value
        XCTAssertEqual(f.actions.loadPhase, .loaded); XCTAssertTrue(f.actions.conflicts.isEmpty)
        XCTAssertEqual(f.state.sendCount, 0)
    }

    func testListIsBoundedWithoutDiscardingLaterGroups() async throws {
        let f = try await fixture()
        for i in 0..<33 { try await seed(f, changes: [change(i, entity: "entity-\(i)")]) }
        await f.actions.load()
        XCTAssertEqual(f.actions.conflicts.count, ScoringInputConflictActions.listLimit)
        let status = try await f.journal.status()
        XCTAssertEqual(status.conflicts, 33); XCTAssertEqual(status.pending, 33)
        XCTAssertNil(f.actions.review); XCTAssertEqual(f.state.sendCount, 0)
    }

    func testHeadOnlyReviewNeverDefaultsSelectionOrAcknowledgement() async throws {
        let f = try await fixture()
        let original = try await seed(f, changes: [change(), change(31, day: "2026-09-19")])
        let reviewed = try await review(f)
        XCTAssertEqual(reviewed, original)
        XCTAssertEqual(f.actions.review?.head.headRevision, 37)
        XCTAssertNil(f.actions.selectedMutationID); XCTAssertFalse(f.actions.wholeQueueAcknowledged)
        await f.actions.confirm()
        let retained = try await f.journal.conflict(id: original.pending.id)
        XCTAssertEqual(retained, original); XCTAssertFalse(f.actions.canConfirm)
    }

    func testSelectionRequiresAcknowledgementAndChangingSelectionClearsIt() async throws {
        let f = try await fixture()
        try await seed(f, changes: [change(), change(31)])
        let value = try await review(f)
        f.actions.select(value.queuedMutationIDs[0])
        XCTAssertFalse(f.actions.canConfirm)
        f.actions.acknowledge(true); XCTAssertTrue(f.actions.canConfirm)
        f.actions.select(value.queuedMutationIDs[1])
        XCTAssertFalse(f.actions.wholeQueueAcknowledged); XCTAssertFalse(f.actions.canConfirm)
        await f.actions.confirm()
        let status = try await f.journal.status()
        XCTAssertEqual(status.pending, 2)
    }

    func testSelectedExactOlderVersionArchivesEntireMultiDayQueue() async throws {
        let f = try await fixture()
        let changes = try [change(30, day: "2026-09-18"), change(31, day: "2026-09-21"), change(32, day: "2026-09-19")]
        try await seed(f, changes: changes)
        let reviewed = try await review(f)
        XCTAssertEqual(f.actions.conflict?.queuedChanges, changes)
        f.actions.select(reviewed.queuedMutationIDs[0]); f.actions.acknowledge(true)
        await f.actions.confirm()
        XCTAssertEqual(f.actions.reviewPhase, .recorded); XCTAssertFalse(f.actions.canConfirm)
        let next = try await f.journal.next(requireKnownHead: true)
        let replacement = try XCTUnwrap(next)
        XCTAssertEqual(replacement.change, changes[0]); XCTAssertEqual(replacement.change.payload, changes[0].payload)
        XCTAssertEqual(replacement.expectedRevision, 37)
        XCTAssertFalse(reviewed.queuedMutationIDs.contains(replacement.id))
        let db = try inspector(f); defer { try? db.close() }
        let rows = try await db.read { try Row.fetchAll($0, sql: "SELECT id,day,payload,replacement_id FROM input_resolution ORDER BY original_sequence") }
        XCTAssertEqual(rows.map { $0["id"] as String }, reviewed.queuedMutationIDs)
        XCTAssertEqual(rows.map { $0["day"] as String }, changes.map(\.effectiveDay))
        XCTAssertEqual(rows.map { $0["payload"] as Data }, changes.map(\.payload))
        XCTAssertEqual(Set(rows.map { $0["replacement_id"] as String }), [replacement.id])
        XCTAssertEqual(f.state.sendCount, 0)
    }

    func testNewArrivalInvalidatesWholeReviewWithoutAutomaticReplacement() async throws {
        let f = try await fixture()
        try await seed(f, changes: [change(), change(31)])
        let reviewed = try await review(f)
        f.actions.select(reviewed.queuedMutationIDs[0]); f.actions.acknowledge(true)
        _ = try await f.journal.enqueue(change(32, day: "2026-09-20"))
        await f.actions.confirm()
        XCTAssertEqual(f.actions.reviewPhase, .failed); XCTAssertNil(f.actions.review)
        XCTAssertNil(f.actions.selectedMutationID); XCTAssertFalse(f.actions.wholeQueueAcknowledged)
        let retained = try await f.journal.conflict(id: reviewed.pending.id)
        XCTAssertEqual(retained?.queuedMutationIDs.count, 3)
        let db = try inspector(f); defer { try? db.close() }
        let count = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM input_resolution") }
        XCTAssertEqual(count, 0)
    }

    func testLateHeadCannotOverwriteNewerReviewRequest() async throws {
        let boundary = Boundary()
        let f = try await fixture(headBoundary: boundary)
        let original = try await seed(f, changes: [change()])
        await f.actions.load(); f.actions.open(original.pending.id); f.state.online(true)
        let old = Task { await f.actions.checkHead() }
        await fulfillment(of: [boundary.entered], timeout: 3)
        await f.actions.checkHead()
        XCTAssertEqual(f.actions.review?.head.headRevision, 39)
        await boundary.release(); await old.value
        XCTAssertEqual(f.actions.review?.head.headRevision, 39)
        XCTAssertNil(f.actions.selectedMutationID)
    }

    func testOwnerRetirementDuringHeadLookupHidesAllOldPresentation() async throws {
        let boundary = Boundary()
        let f = try await fixture(headBoundary: boundary)
        let original = try await seed(f, changes: [change()])
        await f.actions.load(); f.actions.open(original.pending.id); f.state.online(true)
        let lookup = Task { await f.actions.checkHead() }
        await fulfillment(of: [boundary.entered], timeout: 3)
        f.state.retire(); f.inputs.retire()
        await boundary.release(); await lookup.value
        XCTAssertEqual(f.actions.reviewPhase, .retired); XCTAssertNil(f.actions.review)
        XCTAssertNil(f.actions.conflict); XCTAssertTrue(f.actions.conflicts.isEmpty)
        let status = try await f.journal.status()
        XCTAssertEqual(status.pending, 1)
    }

    func testDismissedReviewCannotReappearFromLateHead() async throws {
        let boundary = Boundary()
        let f = try await fixture(headBoundary: boundary)
        let original = try await seed(f, changes: [change()])
        await f.actions.load(); f.actions.open(original.pending.id); f.state.online(true)
        let lookup = Task { await f.actions.checkHead() }
        await fulfillment(of: [boundary.entered], timeout: 3)
        f.actions.dismissReview()
        await boundary.release(); await lookup.value
        XCTAssertNil(f.actions.review); XCTAssertNil(f.actions.conflict)
        XCTAssertEqual(f.actions.reviewPhase, .local)
    }

    func testRevocationThenNewGrantCannotRecaptureOldSensitivePayload() async throws {
        let f = try await fixture()
        await f.sharing.load(); await f.sharing.save(true, purpose: .journal)
        let decision = try XCTUnwrap(f.consent.decisions[.journal])
        let sensitive = try ScoringContextInput.context(device: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            day: "2026-09-18", timezone: "UTC", flags: .init(alcohol: nil, stress: true, sauna: nil,
                hardOrLateWorkout: nil, travelPhaseJump: nil, alreadyUnwell: nil), decision: decision)
        try await seed(f, changes: [sensitive])
        let reviewed = try await review(f)
        f.actions.select(reviewed.pending.id); f.actions.acknowledge(true)
        await f.sharing.save(false, purpose: .journal)
        await f.actions.confirm()
        XCTAssertEqual(f.actions.reviewPhase, .failed)
        await f.sharing.save(true, purpose: .journal)
        XCTAssertNotEqual(f.consent.decisions[.journal]?.id, decision.id)
        f.state.online(true); await f.actions.checkHead()
        XCTAssertEqual(f.actions.reviewPhase, .failed); XCTAssertNil(f.actions.review)
        let retained = try await f.journal.conflict(id: reviewed.pending.id)
        XCTAssertEqual(retained?.queuedChanges, [sensitive])
        XCTAssertEqual(f.state.sendCount, 0)
    }

    func testPayloadIsDecodedOnlyOnDemandWithoutByteSubstitution() async throws {
        let f = try await fixture()
        let changes = try [change(), change(31)]
        let original = try await seed(f, changes: changes)
        let state = f.state
        let actions = ScoringInputConflictActions(owner: f.owner, coordinator: f.inputs, readPayload: { bytes in
            state.recordRead(); return try await ScoringInputConflictActions.decodePayload(bytes)
        })
        await actions.load(); actions.open(original.pending.id)
        XCTAssertEqual(state.readCount, 0); XCTAssertNil(actions.payloadText)
        await actions.inspect(original.queuedMutationIDs[1])
        XCTAssertEqual(state.readCount, 1)
        XCTAssertEqual(Data(try XCTUnwrap(actions.payloadText).utf8), changes[1].payload)
        actions.closePayload(); XCTAssertNil(actions.payloadID); XCTAssertNil(actions.payloadText)
        XCTAssertEqual(state.readCount, 1)
    }

    func testSlowPayloadCannotReplaceNewSelectionAndOnlyOneIsRetained() async throws {
        let f = try await fixture()
        let boundary = Boundary(), changes = try [change(), change(31)]
        let original = try await seed(f, changes: changes)
        let actions = ScoringInputConflictActions(owner: f.owner, coordinator: f.inputs, readPayload: { bytes in
            _ = await boundary.pauseFirst()
            return try await ScoringInputConflictActions.decodePayload(bytes)
        })
        addTeardownBlock { await boundary.release() }
        await actions.load(); actions.open(original.pending.id)
        let old = Task { await actions.inspect(original.queuedMutationIDs[0]) }
        await fulfillment(of: [boundary.entered], timeout: 3)
        XCTAssertTrue(actions.payloadLoading); XCTAssertNil(actions.payloadText)
        await actions.inspect(original.queuedMutationIDs[1])
        await boundary.release(); await old.value
        XCTAssertEqual(actions.payloadID, original.queuedMutationIDs[1])
        XCTAssertEqual(Data(try XCTUnwrap(actions.payloadText).utf8), changes[1].payload)
        actions.suspend(); XCTAssertNil(actions.payloadText); XCTAssertNil(actions.conflict)
    }

    func testPayloadReadAfterDismissalCannotPublish() async throws {
        let f = try await fixture()
        let boundary = Boundary()
        let original = try await seed(f, changes: [change()])
        let actions = ScoringInputConflictActions(owner: f.owner, coordinator: f.inputs, readPayload: { bytes in
            _ = await boundary.pauseFirst()
            return try await ScoringInputConflictActions.decodePayload(bytes)
        })
        addTeardownBlock { await boundary.release() }
        await actions.load(); actions.open(original.pending.id)
        let reading = Task { await actions.inspect(original.pending.id) }
        await fulfillment(of: [boundary.entered], timeout: 3)
        actions.dismissReview(); await boundary.release(); await reading.value
        XCTAssertNil(actions.payloadText); XCTAssertNil(actions.payloadID); XCTAssertNil(actions.conflict)
    }

    func testStorageFailureKeepsQueueAndRequiresExplicitNewReview() async throws {
        let f = try await fixture()
        let original = try await seed(f, changes: [change(), change(31)])
        let db = try inspector(f); defer { try? db.close() }
        try await db.write { try $0.execute(sql: "CREATE TRIGGER deny_archive BEFORE INSERT ON input_resolution BEGIN SELECT RAISE(ABORT,'synthetic archive failure'); END;") }
        let reviewed = try await review(f)
        f.actions.select(reviewed.pending.id); f.actions.acknowledge(true)
        await f.actions.confirm(); await f.actions.confirm()
        XCTAssertEqual(f.actions.reviewPhase, .failed); XCTAssertFalse(f.actions.canConfirm)
        let retained = try await f.journal.conflict(id: original.pending.id)
        XCTAssertEqual(retained, original)
        let count = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM input_resolution") }
        XCTAssertEqual(count, 0)
    }

    func testFailureAfterRealLocalCommitRefreshesWithoutResubmitting() async throws {
        let f = try await fixture()
        let original = try await seed(f, changes: [change(), change(31)])
        let actions = ScoringInputConflictActions(owner: f.owner, coordinator: f.inputs, resolve: { review, change in
            try await f.inputs.resolveConflict(review, replacement: change)
            // Actual SQLite resolution is already committed; simulate loss of its presentation result.
            throw ScoringInputJournal.Failure.storageLimit
        })
        let reviewed = try await review(f, with: actions)
        actions.select(reviewed.pending.id); actions.acknowledge(true)
        await actions.confirm()
        XCTAssertEqual(actions.reviewPhase, .failed); XCTAssertFalse(actions.canConfirm)
        let first = try await f.journal.next(requireKnownHead: true)
        let replacement = try XCTUnwrap(first)
        XCTAssertFalse(original.queuedMutationIDs.contains(replacement.id))
        await actions.confirm(); actions.dismissReview(); await actions.load()
        XCTAssertTrue(actions.conflicts.isEmpty)
        let second = try await f.journal.next(requireKnownHead: true)
        XCTAssertEqual(second?.id, replacement.id)
        let db = try inspector(f); defer { try? db.close() }
        let count = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM input_resolution") }
        XCTAssertEqual(count, 2)
    }

    func testDuplicateConfirmationWhileHeldDoesNotSubmitTwice() async throws {
        let f = try await fixture()
        let boundary = Boundary()
        try await seed(f, changes: [change(), change(31)])
        let actions = ScoringInputConflictActions(owner: f.owner, coordinator: f.inputs, resolve: { review, change in
            _ = await boundary.pauseFirst()
            try await f.inputs.resolveConflict(review, replacement: change)
        })
        addTeardownBlock { await boundary.release() }
        let reviewed = try await review(f, with: actions)
        actions.select(reviewed.pending.id); actions.acknowledge(true)
        let first = Task { await actions.confirm() }
        await fulfillment(of: [boundary.entered], timeout: 3)
        XCTAssertEqual(actions.reviewPhase, .recording); XCTAssertFalse(actions.canConfirm)
        await actions.confirm()
        await boundary.release(); await first.value
        XCTAssertEqual(actions.reviewPhase, .recorded)
        let status = try await f.journal.status()
        XCTAssertEqual(status.pending, 1)
        let db = try inspector(f); defer { try? db.close() }
        let count = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM input_resolution") }
        XCTAssertEqual(count, 2)
    }

    func testOfflineHeadLeavesLocalQueueInspectableButCannotAuthorizeReplacement() async throws {
        let f = try await fixture()
        let original = try await seed(f, changes: [change()])
        await f.actions.load(); f.actions.open(original.pending.id)
        await f.actions.checkHead()
        XCTAssertEqual(f.actions.reviewPhase, .failed); XCTAssertNil(f.actions.review)
        f.actions.select(original.pending.id); f.actions.acknowledge(true)
        await f.actions.confirm()
        XCTAssertNil(f.actions.selectedMutationID); XCTAssertFalse(f.actions.canConfirm)
        await f.actions.inspect(original.pending.id)
        XCTAssertEqual(Data(try XCTUnwrap(f.actions.payloadText).utf8), original.pending.change.payload)
        let retained = try await f.journal.conflict(id: original.pending.id)
        XCTAssertEqual(retained, original)
    }
}
