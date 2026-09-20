import Foundation
import GRDB
import NoopPush
import WhoopStore
import XCTest
#if !SCORING_INPUT_NATIVE_TESTS
@testable import Strand
#endif

actor ScoringInputTestGate {
    let entered = XCTestExpectation(description: "entered controlled boundary")
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered.fulfill()
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

final class ScoringInputTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var ownerCurrent = true
    private var enabled = false
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private var pending: [ScoringInputJournal.Pending] = []
    func current() -> Bool { lock.lock(); defer { lock.unlock() }; return ownerCurrent }
    func invalidate() { lock.lock(); defer { lock.unlock() }; ownerCurrent = false }
    func ready() -> Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    func setReady(_ value: Bool) { lock.lock(); defer { lock.unlock() }; enabled = value }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return clock }
    func advance() { lock.lock(); defer { lock.unlock() }; clock.addTimeInterval(10) }
    @discardableResult func record(_ value: ScoringInputJournal.Pending) -> Int {
        lock.lock(); defer { lock.unlock() }; pending.append(value); return pending.count
    }
    func sent() -> [ScoringInputJournal.Pending] { lock.lock(); defer { lock.unlock() }; return pending }
}

@MainActor
final class ScoringInputCoordinatorTests: XCTestCase {
    private func fixture() throws -> (URL, AccountStorageLayout, AccountSessionContext) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scope = try AccountScope(projectURL: "https://input-fixture.invalid", userID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        return (root, .init(baseDirectory: root, scope: scope), .init(scope: scope, generation: UUID()))
    }
    private func change(_ value: Int = 1) throws -> ScoringInputChange {
        try .init(device: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", kind: .profile, entity: "primary",
                  effectiveDay: "2026-09-18", payload: Data("{\"schemaVersion\":1,\"timezone\":\"UTC\",\"age\":\(value)}".utf8))
    }
    private func dependencies(_ state: ScoringInputTestState) -> ScoringInputCoordinator.Dependencies {
        .init(isCurrent: { _ in state.current() }, canUpload: { state.ready() }, head: {
            ScoringInputJournalTests.head($0, scope: $1.scope)
        }, send: { pending, _ in
            state.record(pending)
            return ScoringInputJournalTests.receipt(pending, revision: pending.expectedRevision + 1)
        }, now: { state.now() })
    }
    private func joined(_ count: Int, _ coordinator: ScoringInputCoordinator) async {
        let deadline = Date().addingTimeInterval(3)
        while coordinator.preparationWaiterCount != count && Date() < deadline { await Task.yield() }
        XCTAssertEqual(coordinator.preparationWaiterCount, count, "waiters must reach the actual shared preparation")
    }

    func testDeniedConsentDoesNotStartPreparationOrHTTP() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ScoringInputTestState()
        state.setReady(true)
        var deps = dependencies(state)
        deps.allowsChange = { $0.kind != .context }
        deps.openJournal = { _, _ in
            XCTFail("denied producer started journal preparation")
            throw ScoringInputJournal.Failure.storageLimit
        }
        deps.head = { _, _ in
            XCTFail("denied producer reached HTTP head lookup")
            throw ScoringInputRPC.Failure.unavailable
        }
        let coordinator = ScoringInputCoordinator(context: context, layout: layout, dependencies: deps)
        let sensitive = try ScoringInputChange(device: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", kind: .context,
            entity: "entry", effectiveDay: "2026-09-18", payload: Data("{\"schemaVersion\":1}".utf8))
        do { try await coordinator.enqueue(sensitive); XCTFail("denied producer admitted") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .held) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.directory.path))
        XCTAssertTrue(state.sent().isEmpty)
        XCTAssertEqual(coordinator.status, .init(pending: 0, conflicts: 0))
        coordinator.retire()
    }

    func testConsentRevokedWhileOpeningRefusesAdmissionAndProfileStillUploads() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ScoringInputTestState()
        state.setReady(true)
        let consent = ScoringInputTestState()
        consent.setReady(true)
        let gate = ScoringInputTestGate()
        var deps = dependencies(state)
        deps.allowsChange = { $0.kind != .context || consent.ready() }
        deps.openJournal = { layout, fence in
            await gate.wait()
            return try ScoringInputJournal(layout: layout, fence: fence)
        }
        deps.head = { change, context in
            XCTAssertEqual(change.kind, .profile, "unadmitted sensitive change reached HTTP")
            return ScoringInputJournalTests.head(change, scope: context.scope)
        }
        let sensitive = try ScoringInputChange(device: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", kind: .context,
            entity: "entry", effectiveDay: "2026-09-18", payload: Data("{\"schemaVersion\":1}".utf8))
        let coordinator = ScoringInputCoordinator(context: context, layout: layout, dependencies: deps)
        let held = Task { try await coordinator.enqueue(sensitive) }
        await fulfillment(of: [gate.entered], timeout: 3)
        consent.setReady(false)
        let profile = Task { try await coordinator.enqueue(change()) }
        await joined(2, coordinator)
        await gate.release()
        do { try await held.value; XCTFail("revoked producer admitted after opening") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .held) }
        try await profile.value
        await coordinator.reconcile()?.value
        XCTAssertEqual(state.sent().map(\.change.kind), [.profile])
        XCTAssertEqual(coordinator.status, .init(pending: 0, conflicts: 0))
        XCTAssertNil(coordinator.lastError)
        let inspector = try DatabaseQueue(path: layout.directory.appendingPathComponent("history-inputs.sqlite").path)
        let sensitiveRows = try await inspector.read { db in
            try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM input_change WHERE kind='context') + (SELECT COUNT(*) FROM input_head WHERE kind='context')")
        }
        XCTAssertEqual(sensitiveRows, 0)
        coordinator.retire()
    }

    func testRetiredPendingOpeningCannotWriteAfterSameAccountNewGenerationOpens() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ScoringInputTestState()
        let fence = StoreWriteFence()
        let gate = ScoringInputTestGate()
        var deps = dependencies(state)
        deps.openJournal = { layout, captured in
            XCTAssertTrue(captured === fence)
            await gate.wait()
            return try ScoringInputJournal(layout: layout, fence: captured)
        }
        let old = ScoringInputCoordinator(context: context, layout: layout, dependencies: deps, fence: fence)
        let stale = Task { try await old.enqueue(change(1)) }
        await fulfillment(of: [gate.entered], timeout: 3)
        old.retire()
        XCTAssertFalse(fence.isValid, "retirement must invalidate before the actor cleanup can run")
        let nextContext = AccountSessionContext(scope: context.scope, generation: UUID())
        let next = ScoringInputCoordinator(context: nextContext, layout: layout, dependencies: dependencies(state))
        try await next.enqueue(change(2))
        await gate.release()
        do { try await stale.value; XCTFail("old opening wrote after new runtime opened") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retired) }
        await next.reconcile()?.value
        let inspector = try ScoringInputJournal(layout: layout)
        let pending = try await inspector.next()
        let status = try await inspector.status()
        XCTAssertEqual(pending?.change, try change(2))
        XCTAssertEqual(status, .init(pending: 1, conflicts: 0))
        XCTAssertTrue(state.sent().isEmpty)
        next.retire()
    }

    func testCoordinatorRetirementRollsBackActualSQLInsertBeforeCommit() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ScoringInputTestState()
        let fence = StoreWriteFence()
        let journal = try ScoringInputJournal(layout: layout, fence: fence)
        var deps = dependencies(state)
        deps.openJournal = { _, captured in
            XCTAssertTrue(captured === fence)
            return journal
        }
        let coordinator = ScoringInputCoordinator(context: context, layout: layout, dependencies: deps, fence: fence)
        await coordinator.reconcile()?.value
        let inserted = expectation(description: "actual input INSERT has executed before COMMIT")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let input = try change()
        let writing = Task.detached {
            try await journal.enqueue(input, beforeCommit: {
                inserted.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            })
        }
        await fulfillment(of: [inserted], timeout: 3)
        coordinator.retire()
        XCTAssertFalse(fence.isValid)
        release.signal()
        do { _ = try await writing.value; XCTFail("retired transaction committed") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retired) }
        let reopened = try ScoringInputJournal(layout: layout)
        let status = try await reopened.status()
        XCTAssertEqual(status, .init(pending: 0, conflicts: 0))
        _ = try await reopened.enqueue(change(2))
        let next = try await reopened.next()
        XCTAssertEqual(next?.change, try change(2), "new fence remains writable")
    }

    func testCancelledProducerWaiterDoesNotRetireOtherWaiterOrLaterAdmission() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ScoringInputTestGate()
        let state = ScoringInputTestState()
        var deps = dependencies(state)
        deps.openJournal = { layout, fence in await gate.wait(); return try ScoringInputJournal(layout: layout, fence: fence) }
        let coordinator = ScoringInputCoordinator(context: context, layout: layout, dependencies: deps)
        let cancelled = Task { try await coordinator.enqueue(change(1)) }
        await fulfillment(of: [gate.entered], timeout: 3)
        let survivor = Task { try await coordinator.enqueue(change(2)) }
        await joined(2, coordinator)
        cancelled.cancel()
        await gate.release()
        do { try await cancelled.value; XCTFail("cancelled producer admitted") } catch { XCTAssertTrue(error is CancellationError) }
        try await survivor.value
        try await coordinator.enqueue(change(3))
        await coordinator.reconcile()?.value
        XCTAssertEqual(coordinator.status.pending, 2)
        XCTAssertNil(coordinator.lastError)
        let journal = try ScoringInputJournal(layout: layout)
        let next = try await journal.next()
        XCTAssertEqual(next?.change, try change(2))
        coordinator.retire()
    }

    func testPolicyOffOnDuringPreparationKeepsOneDrainAndLiveJournal() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fence = StoreWriteFence()
        let journal = try ScoringInputJournal(layout: layout, fence: fence)
        _ = try await journal.enqueue(change())
        let gate = ScoringInputTestGate()
        let state = ScoringInputTestState()
        state.setReady(true)
        var deps = dependencies(state)
        deps.openJournal = { _, _ in await gate.wait(); return journal }
        let coordinator = ScoringInputCoordinator(context: context, layout: layout, dependencies: deps, fence: fence)
        let cancelledDrain = coordinator.reconcile()
        await fulfillment(of: [gate.entered], timeout: 3)
        state.setReady(false); coordinator.policyChanged()
        state.setReady(true); coordinator.policyChanged()
        await gate.release()
        await cancelledDrain?.value
        await coordinator.reconcile()?.value
        XCTAssertEqual(state.sent().count, 1)
        XCTAssertEqual(coordinator.status.pending, 0)
        try await coordinator.enqueue(change(2))
        await coordinator.reconcile()?.value
        XCTAssertEqual(state.sent().count, 2)
        XCTAssertEqual(coordinator.status.pending, 0)
        XCTAssertNil(coordinator.lastError)
        coordinator.retire()
    }

    func testRealRetirementDuringOpenRejectsAdmissionAndRetainsExistingDebt() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fence = StoreWriteFence()
        let journal = try ScoringInputJournal(layout: layout, fence: fence)
        _ = try await journal.enqueue(change())
        let initial = try await journal.next()
        let gate = ScoringInputTestGate()
        let state = ScoringInputTestState()
        var deps = dependencies(state)
        deps.openJournal = { _, _ in await gate.wait(); return journal }
        let coordinator = ScoringInputCoordinator(context: context, layout: layout, dependencies: deps, fence: fence)
        let producer = Task { try await coordinator.enqueue(change(2)) }
        await fulfillment(of: [gate.entered], timeout: 3)
        coordinator.retire()
        await gate.release()
        do { try await producer.value; XCTFail("retired producer admitted") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retired) }
        do { _ = try await journal.next(); XCTFail("retired prepared resource remained active") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retired) }
        let reopened = try ScoringInputJournal(layout: layout)
        let retry = try await reopened.next()
        XCTAssertEqual(retry, initial)
        XCTAssertEqual(coordinator.status.pending, 0)
        XCTAssertTrue(state.sent().isEmpty)
    }

    func testFailedPreparationCanBeRetriedWithoutDroppingDebt() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ScoringInputTestState()
        var deps = dependencies(state)
        deps.openJournal = { layout, fence in
            if !state.ready() { throw ScoringInputJournal.Failure.storageLimit }
            return try ScoringInputJournal(layout: layout, fence: fence)
        }
        let coordinator = ScoringInputCoordinator(context: context, layout: layout, dependencies: deps)
        do { try await coordinator.enqueue(change()); XCTFail("failed open admitted") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .storageLimit) }
        state.setReady(true)
        try await coordinator.enqueue(change())
        await coordinator.reconcile()?.value
        XCTAssertEqual(state.sent().count, 1)
        XCTAssertEqual(coordinator.status.pending, 0)
        coordinator.retire()
    }

    func testLateReceiptAfterAccountGenerationChangeDoesNotSettleOrPublish() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ScoringInputTestState()
        state.setReady(true)
        let gate = ScoringInputTestGate()
        var deps = dependencies(state)
        deps.send = { pending, _ in
            state.record(pending); await gate.wait()
            return ScoringInputJournalTests.receipt(pending)
        }
        deps.didSettle = { _ in XCTFail("stale owner published invalidation") }
        let coordinator = ScoringInputCoordinator(context: context, layout: layout, dependencies: deps)
        try await coordinator.enqueue(change())
        let drain = coordinator.reconcile()
        await fulfillment(of: [gate.entered], timeout: 3)
        state.invalidate(); coordinator.retire()
        await gate.release(); await drain?.value
        let reopened = try ScoringInputJournal(layout: layout)
        let retry = try await reopened.next()
        XCTAssertEqual(retry, state.sent().first)
        XCTAssertEqual(coordinator.status.pending, 0)
        XCTAssertNil(coordinator.lastError)
    }

    func testRetryBackoffKeepsFrozenMutationAndRevision() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ScoringInputTestState()
        state.setReady(true)
        var deps = dependencies(state)
        deps.send = { pending, _ in
            if state.record(pending) == 1 { throw ScoringInputRPC.Failure.unavailable }
            return ScoringInputJournalTests.receipt(pending)
        }
        let coordinator = ScoringInputCoordinator(context: context, layout: layout, dependencies: deps)
        try await coordinator.enqueue(change())
        await coordinator.reconcile()?.value
        XCTAssertEqual(state.sent().count, 1)
        XCTAssertEqual(coordinator.status.pending, 1)
        XCTAssertNotNil(coordinator.lastError)
        state.advance()
        await coordinator.reconcile()?.value
        let sent = state.sent()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first?.id, sent.last?.id)
        XCTAssertEqual(sent.first?.clientID, sent.last?.clientID)
        XCTAssertEqual(sent.first?.clientRevision, sent.last?.clientRevision)
        XCTAssertEqual(sent.first?.expectedRevision, sent.last?.expectedRevision)
        XCTAssertEqual(sent.last?.failures, 1)
        XCTAssertEqual(coordinator.status.pending, 0)
        coordinator.retire()
    }

    func testRPCDoesNotSendAfterAuthorizationGenerationChanges() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ScoringInputJournal(layout: layout)
        _ = try await journal.enqueue(change())
        let loaded = try await journal.next()
        let pending = try XCTUnwrap(loaded)
        let state = ScoringInputTestState()
        let gate = ScoringInputTestGate()
        let deps = ScoringInputRPC.Dependencies(anonKey: { "synthetic" }, authorize: {
            await gate.wait(); return .init(context: context, accessToken: "synthetic")
        }, isCurrent: { _ in state.current() }, canUpload: { true }, request: { _ in
            XCTFail("stale authorization reached HTTP")
            throw ScoringInputRPC.Failure.unavailable
        })
        let sending = Task { try await ScoringInputRPC.send(pending, context: context, dependencies: deps) }
        await fulfillment(of: [gate.entered], timeout: 3)
        state.invalidate(); await gate.release()
        do { _ = try await sending.value; XCTFail("stale authorization accepted") }
        catch { XCTAssertEqual(error as? ScoringInputRPC.Failure, .staleOwner) }
        let retained = try await journal.next()
        XCTAssertEqual(retained, pending)
    }

    func testConsentRevokedDuringHeadLookupStaysUnpinnedWhileOtherEntityUploads() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ScoringInputTestState()
        let consent = ScoringInputTestState()
        consent.setReady(true)
        let gate = ScoringInputTestGate()
        var deps = dependencies(state)
        deps.allowsChange = { $0.kind != .context || consent.ready() }
        deps.head = { change, context in
            if change.kind == .context { await gate.wait() }
            return ScoringInputJournalTests.head(change, scope: context.scope)
        }
        let sensitive = try ScoringInputChange(device: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", kind: .context,
            entity: "entry", effectiveDay: "2026-09-18", payload: Data("{\"schemaVersion\":1}".utf8))
        let coordinator = ScoringInputCoordinator(context: context, layout: layout, dependencies: deps)
        try await coordinator.enqueue(sensitive)
        try await coordinator.enqueue(change())
        await coordinator.reconcile()?.value
        state.setReady(true)
        let drain = coordinator.reconcile()
        await fulfillment(of: [gate.entered], timeout: 3)
        consent.setReady(false)
        await gate.release(); await drain?.value
        XCTAssertEqual(state.sent().map(\.change.kind), [.profile])
        XCTAssertEqual(coordinator.status, .init(pending: 1, conflicts: 0))
        let inspector = try DatabaseQueue(path: layout.directory.appendingPathComponent("history-inputs.sqlite").path)
        let pinned = try await inspector.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM input_change WHERE expected_revision IS NOT NULL OR failures<>0 OR conflict<>0") }
        XCTAssertEqual(pinned, 0)
        coordinator.retire()
    }

    func testOwnerChangeDuringHeadLookupDoesNotFreezeOrSend() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ScoringInputTestState()
        state.setReady(true)
        let gate = ScoringInputTestGate()
        var deps = dependencies(state)
        deps.head = { change, context in await gate.wait(); return ScoringInputJournalTests.head(change, scope: context.scope, revision: 300) }
        let coordinator = ScoringInputCoordinator(context: context, layout: layout, dependencies: deps)
        try await coordinator.enqueue(change())
        let drain = coordinator.reconcile()
        await fulfillment(of: [gate.entered], timeout: 3)
        state.invalidate(); coordinator.retire()
        await gate.release(); await drain?.value
        let reopened = try ScoringInputJournal(layout: layout)
        let stillUnfrozen = try await reopened.initialHeadRequest()
        XCTAssertNotNil(stillUnfrozen)
        XCTAssertTrue(state.sent().isEmpty)
    }

    func testRPCConsentCheckedBeforeAndAfterAuthorization() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ScoringInputJournal(layout: layout)
        _ = try await journal.enqueue(change())
        let loaded = try await journal.next()
        let pending = try XCTUnwrap(loaded)
        let consent = ScoringInputTestState()
        let gate = ScoringInputTestGate()
        let deps = ScoringInputRPC.Dependencies(anonKey: { "synthetic" }, authorize: {
            await gate.wait(); return .init(context: context, accessToken: "synthetic")
        }, isCurrent: { $0 == context }, canUpload: { true }, request: { _ in
            XCTFail("held input reached delivery")
            throw ScoringInputRPC.Failure.unavailable
        }, allowsChange: { _ in consent.ready() })
        do { _ = try await ScoringInputRPC.send(pending, context: context, dependencies: deps); XCTFail("held input authorized") }
        catch { XCTAssertEqual(error as? ScoringInputRPC.Failure, .held) }
        consent.setReady(true)
        let sending = Task { try await ScoringInputRPC.send(pending, context: context, dependencies: deps) }
        await fulfillment(of: [gate.entered], timeout: 3)
        consent.setReady(false); await gate.release()
        do { _ = try await sending.value; XCTFail("revoked input sent") }
        catch { XCTAssertEqual(error as? ScoringInputRPC.Failure, .held) }
        let retained = try await journal.next()
        XCTAssertEqual(retained, pending)
    }

    func testPostgRESTSQLCodesClassifyIndependentlyOfHTTPStatus() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ScoringInputJournal(layout: layout)
        _ = try await journal.enqueue(change())
        let loaded = try await journal.next()
        let pending = try XCTUnwrap(loaded)
        let cases: [(Int, String, String, ScoringInputRPC.Failure)] = [
            (500, "40001", "history_revision_conflict", .conflict),
            (412, "40001", "client_revision_conflict", .conflict),
            (409, "PGRST001", "not a mutation conflict", .unavailable),
            (422, "23505", "idempotency_conflict", .conflict),
            (409, "22023", "invalid_history_input_payload", .rejected),
            (503, "53300", "too_many_connections", .unavailable)
        ]
        for (status, code, message, expected) in cases {
            let deps = ScoringInputRPC.Dependencies(anonKey: { "synthetic" }, authorize: {
                .init(context: context, accessToken: "synthetic")
            }, isCurrent: { $0 == context }, canUpload: { true }, request: { request in
                (try JSONSerialization.data(withJSONObject: ["code": code, "message": message]),
                 HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
            do { _ = try await ScoringInputRPC.send(pending, context: context, dependencies: deps); XCTFail("error receipt accepted") }
            catch { XCTAssertEqual(error as? ScoringInputRPC.Failure, expected, "HTTP \(status) SQLSTATE \(code)") }
        }
    }

    func testExplicitConflictReviewIsBoundToAccountGeneration() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ScoringInputJournal(layout: layout)
        _ = try await journal.enqueue(change())
        let loaded = try await journal.next()
        let pending = try XCTUnwrap(loaded)
        try await journal.retry(pending, conflict: true)
        let state = ScoringInputTestState()
        state.setReady(true)
        let coordinator = ScoringInputCoordinator(context: context, layout: layout, dependencies: dependencies(state))
        let review = try await coordinator.reviewConflict(id: pending.id)
        state.invalidate(); coordinator.retire()
        do { try await coordinator.resolveConflict(review, replacement: change(2)); XCTFail("old generation resolved debt") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retired) }
        let status = try await journal.status()
        XCTAssertEqual(status, .init(pending: 1, conflicts: 1))
    }

    func testExplicitConflictReplacementCannotBypassRevokedAdmissionConsent() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ScoringInputJournal(layout: layout)
        let sensitive = try ScoringInputChange(device: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", kind: .context,
            entity: "entry", effectiveDay: "2026-09-18", payload: Data("{\"schemaVersion\":1}".utf8))
        _ = try await journal.enqueue(sensitive)
        let loaded = try await journal.next()
        let pending = try XCTUnwrap(loaded)
        try await journal.retry(pending, conflict: true)
        let state = ScoringInputTestState()
        state.setReady(true)
        let consent = ScoringInputTestState()
        consent.setReady(true)
        var deps = dependencies(state)
        deps.allowsChange = { $0.kind != .context || consent.ready() }
        let coordinator = ScoringInputCoordinator(context: context, layout: layout, dependencies: deps)
        let review = try await coordinator.reviewConflict(id: pending.id)
        consent.setReady(false)
        do { try await coordinator.resolveConflict(review, replacement: sensitive); XCTFail("revoked rebase admitted") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .held) }
        // The journal also checks after an actor hop, independently of the coordinator guard.
        do {
            _ = try await journal.resolveConflict(review.conflict, head: review.head, replacement: sensitive,
                allowing: { _ in consent.ready() })
            XCTFail("direct journal replacement bypassed consent")
        } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .held) }
        let retained = try await journal.conflict(id: pending.id)
        XCTAssertEqual(retained, review.conflict)
        let inspector = try DatabaseQueue(path: layout.directory.appendingPathComponent("history-inputs.sqlite").path)
        let archives = try await inspector.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM input_resolution") }
        XCTAssertEqual(archives, 0)
        XCTAssertTrue(state.sent().isEmpty)
        coordinator.retire()
    }
}
