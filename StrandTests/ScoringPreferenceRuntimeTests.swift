import Combine
import Foundation
import GRDB
import NoopPush
import WhoopStore
import XCTest
#if !SCORING_INPUT_NATIVE_TESTS
@testable import Strand
#endif

final class PreferenceRuntimeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool = true) { self.value = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ next: Bool) { lock.lock(); value = next; lock.unlock() }
}

actor PreferenceRuntimeGate {
    let entered = XCTestExpectation(description: "preference async boundary")
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered.fulfill()
        if !open { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { open = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

final class PreferenceRuntimeCommitGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "preference native transaction boundary")
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let first = PreferenceRuntimeFlag()
    func waitOnce() {
        guard first.get() else { return }
        first.set(false); entered.fulfill()
        XCTAssertEqual(releaseSignal.wait(timeout: .now() + 8), .success, "native barrier was not released")
    }
    func release() { releaseSignal.signal() }
}

@MainActor
final class PreferenceRuntimeFixture {
    nonisolated static let device = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    nonisolated static let date = Date(timeIntervalSince1970: 1_794_122_999)
    let root: URL
    let context: AccountSessionContext
    let layout: AccountStorageLayout
    let domain: String
    let defaults: UserDefaults
    let current: PreferenceRuntimeFlag
    let inputs: ScoringInputCoordinator
    let runtime: ScoringPreferenceRuntime
    var path: String { layout.directory.appendingPathComponent("history-inputs.sqlite").path }

    init(root: URL? = nil, context: AccountSessionContext? = nil, domain: String? = nil,
         seed: [String: Any] = [:], current: PreferenceRuntimeFlag = .init(),
         maxActions: Int = 64, maxBytes: Int = 1_048_576,
         open: PreferenceRuntimeGate? = nil, hooks: ScoringPreferenceRuntime.Hooks = .init()) throws {
        let base = ProcessInfo.processInfo.environment["SCORING_PREFERENCE_SCRATCH"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        self.root = root ?? base.appendingPathComponent("preference-runtime-" + UUID().uuidString, isDirectory: true)
        let owner = try context ?? AccountSessionContext(scope: AccountScope(projectURL: "https://runtime-fixture.invalid",
            userID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"), generation: UUID())
        self.context = owner; self.current = current
        layout = AccountStorageLayout(baseDirectory: self.root, scope: owner.scope)
        self.domain = domain ?? "test.preference-runtime." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: self.domain))
        let deps = ScoringInputCoordinator.Dependencies(isCurrent: { $0 == owner && current.get() }, canUpload: { false },
            openJournal: { layout, fence in
                await open?.wait()
                return try ScoringInputJournal(layout: layout, fence: fence, preferenceContext: owner,
                    isPreferenceContextCurrent: { $0 == owner && current.get() })
            }, head: { _, _ in XCTFail("offline fixture attempted HTTP head"); throw ScoringInputRPC.Failure.unavailable },
            send: { _, _ in XCTFail("offline fixture attempted HTTP send"); throw ScoringInputRPC.Failure.unavailable })
        inputs = ScoringInputCoordinator(context: owner, layout: layout, dependencies: deps)
        runtime = try ScoringPreferenceRuntime(context: owner, inputs: inputs,
            seed: .seed(context: owner, domain: seed, now: Self.date), defaults: defaults,
            isCurrent: { $0 == owner && current.get() }, maxActions: maxActions, maxBytes: maxBytes, hooks: hooks)
    }
    func action(_ patch: [ScoringPreferenceIntent.Patch] = [.init(key: .weightKg, value: .number(71))],
                date: Date = PreferenceRuntimeFixture.date, zone: String = "America/Los_Angeles",
                source: String? = PreferenceRuntimeFixture.device, local: Bool = false,
                consent: ScoringPreferenceSnapshot.Consent? = .init(journalEnabled: false, cycleEnabled: false),
                permit: (@Sendable () -> Bool)? = { true }) -> ScoringPreferenceAction {
        .init(patch: patch, capture: .init(context: context, occurredAt: date, timezone: zone, sourceDeviceID: source,
            disposition: local ? .localOnly : .serverCoupled, consent: consent, allowing: permit))
    }
    func rows(_ table: String) throws -> [Row] {
        let db = try DatabaseQueue(path: path)
        defer { try? db.close() }
        return try db.read { try Row.fetchAll($0, sql: "SELECT * FROM \(table)") }
    }
    func intents() throws -> [ScoringPreferenceIntent] {
        try rows("preference_intent").map { try ScoringPreferenceIntent(encoded: $0["body"]) }
            .sorted { $0.position.sequence < $1.position.sequence }
    }
    func close() async throws { runtime.retire(); await runtime.waitForRetirement(); try await inputs.waitForRetirement() }
}

@MainActor
final class ScoringPreferenceRuntimeTests: XCTestCase {
    private func fixture(_ value: PreferenceRuntimeFixture? = nil,
                         _ body: (PreferenceRuntimeFixture) async throws -> Void) async throws {
        let f = try value ?? PreferenceRuntimeFixture()
        let failures = testRun?.failureCount ?? 0
        do {
            try await body(f); try await f.close()
            if testRun?.failureCount == failures {
                f.defaults.removePersistentDomain(forName: f.domain)
                if FileManager.default.fileExists(atPath: f.root.path) { try FileManager.default.removeItem(at: f.root) }
            } else { print("Preserved runtime fixture: \(f.root.path) suite=\(f.domain)") }
        } catch {
            try await f.close(); print("Preserved runtime fixture: \(f.root.path) suite=\(f.domain)"); throw error
        }
    }
    private func rejected(_ ticket: ScoringPreferenceTicket, _ expected: ScoringPreferenceTicket.Failure) async {
        do { _ = try await ticket.acceptance(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? ScoringPreferenceTicket.Failure, expected) }
    }

    func testHydrationDoesNotCreateCommandsOrAdoptFallback() async throws {
        try await fixture { f in
            f.defaults.register(defaults: ["profile.weightKg": 99, "noopBanisterEffort": true])
            XCTAssertNil(f.runtime.accepted)
            await rejected(f.runtime.complete(f.action()), .loading)
            try await f.runtime.hydrate()
            XCTAssertEqual(f.runtime.accepted?.weightKg, 75)
            XCTAssertFalse(f.runtime.accepted!.algorithmChoices.banisterEffortEnabled)
            XCTAssertTrue(f.runtime.isReady)
            XCTAssertEqual(try f.rows("input_change").count, 0)
            XCTAssertEqual(try f.intents().count, 0)
        }
    }

    func testOpenSuspensionLeavesMainActorAvailableAndRetirementBlocksHydration() async throws {
        let gate = PreferenceRuntimeGate()
        let f = try PreferenceRuntimeFixture(open: gate)
        try await fixture(f) { f in
            let loading = Task { try await f.runtime.hydrate() }
            await fulfillment(of: [gate.entered], timeout: 3)
            XCTAssertNil(f.runtime.accepted)
            await rejected(f.runtime.complete(f.action()), .loading)
            f.current.set(false); f.runtime.retire()
            await gate.release()
            do { try await loading.value; XCTFail("retired hydration published") }
            catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retired) }
            XCTAssertNil(f.runtime.accepted)
        }
    }

    func testAcceptedAndFacadeRemainUnchangedUntilRealCommit() async throws {
        let gate = PreferenceRuntimeCommitGate()
        let f = try PreferenceRuntimeFixture(hooks: .init(atCommit: { if $0 == .beforeCommit { gate.waitOnce() } }))
        try await fixture(f) { f in
            let profile = ProfileStore(defaults: f.defaults, domainName: f.domain)
            profile.bindScoringPreferences(f.runtime)
            try await f.runtime.hydrate()
            let ticket = f.runtime.complete(f.action())
            await fulfillment(of: [gate.entered], timeout: 3)
            XCTAssertEqual(profile.weightKg, 75)
            XCTAssertEqual(f.runtime.accepted?.position.sequence, 0)
            XCTAssertEqual(f.runtime.draft?.weightKg, 71)
            XCTAssertNil(f.defaults.persistentDomain(forName: f.domain)?["profile.weightKg"])
            XCTAssertEqual(f.runtime.pendingCount, 1)
            XCTAssertGreaterThan(f.runtime.pendingBytes, 4096)
            gate.release()
            let receipt = try await ticket.acceptance()
            XCTAssertEqual(receipt.position.sequence, 1)
            XCTAssertEqual(profile.weightKg, 71)
            XCTAssertEqual(f.runtime.pendingCount, 0)
            XCTAssertEqual(f.defaults.double(forKey: "profile.weightKg"), 71)
            XCTAssertEqual(try f.rows("input_change").count, 2)
        }
    }

    func testFIFOABAUsesCapturedPostActionStateAndExactDates() async throws {
        try await fixture { f in
            try await f.runtime.hydrate()
            let dates = (0..<3).map { PreferenceRuntimeFixture.date.addingTimeInterval(Double($0 * 86400)) }
            let values = [71.0, 82.0, 71.0]
            let tickets = zip(values, dates).map { f.runtime.complete(f.action([.init(key: .weightKg, value: .number($0.0))], date: $0.1)) }
            for ticket in tickets { _ = try await ticket.acceptance() }
            let intents = try f.intents()
            XCTAssertEqual(intents.count, 3)
            XCTAssertEqual(intents.map(\.occurredAt), dates)
            XCTAssertEqual(intents.map(\.id), tickets.map(\.id))
            XCTAssertEqual(intents.map(\.predecessor), [.initial, intents[0].position, intents[1].position])
            for (intent, value) in zip(intents, values) {
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.profile!.payload) as? [String: Any])
                XCTAssertEqual(payload["weightKg"] as? Double, value)
                XCTAssertEqual(intent.device, PreferenceRuntimeFixture.device)
                XCTAssertEqual(intent.timezone, "America/Los_Angeles")
            }
            XCTAssertEqual(f.runtime.accepted?.weightKg, 71)
            XCTAssertEqual(try f.rows("input_change").count, 6)
        }
    }

    func testHeldHeadRetainsIdenticalIntentPermitAndDependentFIFO() async throws {
        let permit = PreferenceRuntimeFlag(false)
        try await fixture { f in
            try await f.runtime.hydrate()
            let first = f.runtime.complete(f.action(permit: { permit.get() }))
            let second = f.runtime.complete(f.action([.init(key: .heightCm, value: .number(180))]))
            await rejected(first, .held)
            XCTAssertEqual(second.state, .queued)
            XCTAssertEqual(f.runtime.pendingCount, 2)
            XCTAssertEqual(try f.intents().count, 0)
            f.inputs.captureAdmission = { XCTFail("captured a replacement permit"); return { true } }
            f.inputs.prepareAdmission = { XCTAssertGreaterThan(try f.intents().count, 0, "relayed before frozen admission") }
            f.runtime.retry(first)
            await rejected(first, .held)
            // A transiently held *same* permit may become usable; no new permit is captured.
            permit.set(true)
            f.runtime.retry(first)
            _ = try await first.acceptance(); _ = try await second.acceptance()
            let intents = try f.intents()
            XCTAssertEqual(intents.map(\.id), [first.id, second.id])
            XCTAssertEqual(intents.map(\.occurredAt), Array(repeating: PreferenceRuntimeFixture.date, count: 2))
            XCTAssertEqual(f.runtime.accepted?.weightKg, 71)
            XCTAssertEqual(f.runtime.accepted?.heightCm, 180)
            f.inputs.prepareAdmission = nil
        }
    }

    func testMissingSourceAndPermitStayCapturedAbsentUntilExplicitDiscard() async throws {
        try await fixture { f in
            try await f.runtime.hydrate()
            let absent = f.runtime.complete(f.action(source: nil))
            await rejected(absent, .missingSource)
            f.runtime.retry(absent)
            XCTAssertEqual(absent.state, .held(.missingSource))
            await rejected(f.runtime.complete(f.action()), .dependent)
            XCTAssertTrue(f.runtime.discardUnacceptedChain(from: absent))
            let noPermit = f.runtime.complete(f.action(permit: nil))
            await rejected(noPermit, .missingPermit)
            f.inputs.captureAdmission = { return { true } }
            f.runtime.retry(noPermit)
            XCTAssertEqual(noPermit.state, .held(.missingPermit))
            XCTAssertEqual(try f.intents().count, 0)
            XCTAssertTrue(f.runtime.discardUnacceptedChain(from: noPermit))
            _ = try await f.runtime.complete(f.action()).acceptance()
            XCTAssertEqual(try f.intents().count, 1)
        }
    }

    func testLocalOnlyNeedsNoSourceOrConsentAndNeverPromotesOnHydration() async throws {
        try await fixture { f in
            try await f.runtime.hydrate()
            let ticket = f.runtime.complete(f.action(source: nil, local: true, consent: nil, permit: nil))
            let receipt = try await ticket.acceptance()
            XCTAssertNil(receipt.profileMutationID); XCTAssertNil(receipt.configMutationID)
            XCTAssertEqual(f.runtime.accepted?.provenance[.weightKg], .localOnly)
            XCTAssertEqual(try f.rows("input_change").count, 0)
            try await f.close()
            let context = AccountSessionContext(scope: f.context.scope, generation: UUID())
            let next = try PreferenceRuntimeFixture(root: f.root, context: context, domain: f.domain)
            try await next.runtime.hydrate()
            XCTAssertEqual(next.runtime.accepted?.weightKg, 71)
            XCTAssertEqual(next.runtime.accepted?.position, receipt.position)
            XCTAssertEqual(try next.intents().count, 1)
            XCTAssertEqual(try next.rows("input_change").count, 0)
            try await next.close()
        }
    }

    func testBoundedQueueCountsInFlightAndRejectsWithoutDroppingAcceptedWork() async throws {
        let gate = PreferenceRuntimeCommitGate()
        let f = try PreferenceRuntimeFixture(maxActions: 2, hooks: .init(atCommit: { if $0 == .beforeCommit { gate.waitOnce() } }))
        try await fixture(f) { f in
            try await f.runtime.hydrate()
            let first = f.runtime.complete(f.action())
            await fulfillment(of: [gate.entered], timeout: 3)
            let second = f.runtime.complete(f.action([.init(key: .heightCm, value: .number(182))]))
            let bytes = f.runtime.pendingBytes
            await rejected(f.runtime.complete(f.action()), .capacity)
            XCTAssertEqual(f.runtime.pendingCount, 2); XCTAssertEqual(f.runtime.pendingBytes, bytes)
            XCTAssertFalse(f.runtime.discardUnacceptedChain(from: first))
            gate.release()
            _ = try await first.acceptance(); _ = try await second.acceptance()
            XCTAssertEqual(try f.intents().count, 2)
            XCTAssertEqual(f.runtime.accepted?.heightCm, 182)
        }
    }

    func testByteLimitIncludesMetadataAndCapturedAbsence() async throws {
        let f = try PreferenceRuntimeFixture(maxBytes: 4096)
        try await fixture(f) { f in
            try await f.runtime.hydrate()
            await rejected(f.runtime.complete(f.action()), .capacity)
            await rejected(f.runtime.complete(f.action(source: nil)), .capacity)
            XCTAssertEqual(f.runtime.pendingCount, 0)
            XCTAssertEqual(try f.intents().count, 0)
        }
    }

    func testRetirementBeforeNativeCommitRollsBackPairAndProjection() async throws {
        let gate = PreferenceRuntimeCommitGate()
        let f = try PreferenceRuntimeFixture(hooks: .init(atCommit: { if $0 == .beforeCommit { gate.waitOnce() } }))
        try await fixture(f) { f in
            try await f.runtime.hydrate()
            let ticket = f.runtime.complete(f.action())
            await fulfillment(of: [gate.entered], timeout: 3)
            f.runtime.retire(); gate.release()
            await rejected(ticket, .retired)
            XCTAssertNil(f.runtime.accepted)
            XCTAssertEqual(try f.intents().count, 0)
            XCTAssertEqual(try f.rows("input_change").count, 0)
            XCTAssertEqual(try f.rows("preference_projection").count, 0)
        }
    }

    func testCommittedReceiptSurvivesRetirementWithoutOldPublication() async throws {
        let gate = PreferenceRuntimeGate()
        let f = try PreferenceRuntimeFixture(hooks: .init(beforePublication: { await gate.wait() }))
        try await fixture(f) { f in
            try await f.runtime.hydrate()
            var publications = 0
            f.runtime.onAccepted = { _, _ in publications += 1 }
            let ticket = f.runtime.complete(f.action())
            await fulfillment(of: [gate.entered], timeout: 3)
            XCTAssertEqual(try f.intents().count, 1)
            XCTAssertEqual(f.runtime.accepted?.weightKg, 75)
            f.runtime.retire(); await gate.release()
            let receipt = try await ticket.acceptance()
            XCTAssertEqual(receipt.position.id, ticket.id)
            XCTAssertNil(f.runtime.accepted); XCTAssertEqual(publications, 0)
            XCTAssertNil(f.defaults.persistentDomain(forName: f.domain)?["profile.weightKg"])
        }
    }

    func testGenerationInvalidationAndReentrantObserverCannotRestoreAcceptedState() async throws {
        try await fixture { f in
            try await f.runtime.hydrate()
            let observer = f.runtime.objectWillChange.sink { f.current.set(false) }
            f.runtime.retire()
            XCTAssertNil(f.runtime.accepted)
            observer.cancel()
        }
        let f = try PreferenceRuntimeFixture()
        try await fixture(f) { f in
            let observer = f.runtime.objectWillChange.sink { f.runtime.retire() }
            do { try await f.runtime.hydrate(); XCTFail("reentrant retirement reported successful hydration") }
            catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retired) }
            XCTAssertNil(f.runtime.accepted)
            XCTAssertFalse(f.runtime.isReady)
            observer.cancel()
        }
    }

    func testNativePermitRevocationHoldsSameTicketAndNoReplacementCapture() async throws {
        let gate = PreferenceRuntimeCommitGate(), permit = PreferenceRuntimeFlag()
        let f = try PreferenceRuntimeFixture(hooks: .init(atCommit: { if $0 == .beforeCommit { gate.waitOnce() } }))
        try await fixture(f) { f in
            try await f.runtime.hydrate()
            let ticket = f.runtime.complete(f.action(permit: { permit.get() }))
            await fulfillment(of: [gate.entered], timeout: 3)
            permit.set(false); gate.release()
            await rejected(ticket, .held)
            XCTAssertEqual(try f.intents().count, 0)
            XCTAssertEqual(f.runtime.accepted?.weightKg, 75)
            f.runtime.retry(ticket)
            await rejected(ticket, .held)
            XCTAssertEqual(try f.rows("input_change").count, 0)
        }
    }

    func testDiscardHeadDiscardsEntireDependentChainWithoutRebase() async throws {
        try await fixture { f in
            try await f.runtime.hydrate()
            let head = f.runtime.complete(f.action(permit: { false }))
            let tail = f.runtime.complete(f.action([.init(key: .heightCm, value: .number(188))]))
            await rejected(head, .held)
            XCTAssertTrue(f.runtime.discardUnacceptedChain(from: head))
            XCTAssertEqual(head.state, .discarded); XCTAssertEqual(tail.state, .discarded)
            XCTAssertEqual(f.runtime.draft?.heightCm, 178)
            let next = f.runtime.complete(f.action())
            _ = try await next.acceptance()
            XCTAssertEqual(try f.intents().first?.predecessor, .initial)
        }
    }

    func testDefault64AdmissionLimitCannotBeRaisedByConstructor() async throws {
        let f = try PreferenceRuntimeFixture(maxActions: 1000)
        try await fixture(f) { f in
            try await f.runtime.hydrate()
            let tickets = (0..<64).map { _ in f.runtime.complete(f.action(permit: { false })) }
            XCTAssertEqual(f.runtime.pendingCount, 64)
            XCTAssertLessThanOrEqual(f.runtime.pendingBytes, 1_048_576)
            await rejected(f.runtime.complete(f.action()), .capacity)
            await rejected(tickets[0], .held)
            XCTAssertTrue(f.runtime.discardUnacceptedChain(from: tickets[0]))
            XCTAssertTrue(tickets.allSatisfy { $0.state == .discarded })
            XCTAssertEqual(try f.intents().count, 0)
        }
    }

    func testOwnerSwitchDuringNativeCommitCannotWriteEitherSuccessorStore() async throws {
        let gate = PreferenceRuntimeCommitGate()
        let f = try PreferenceRuntimeFixture(hooks: .init(atCommit: { if $0 == .beforeCommit { gate.waitOnce() } }))
        try await fixture(f) { f in
            try await f.runtime.hydrate()
            let old = f.runtime.complete(f.action())
            await fulfillment(of: [gate.entered], timeout: 3)
            f.current.set(false)
            let b = try PreferenceRuntimeFixture(root: f.root, context: .init(scope: AccountScope(
                projectURL: f.context.scope.projectURL, userID: "cccccccc-cccc-cccc-cccc-cccccccccccc"), generation: UUID()))
            try await b.runtime.hydrate()
            gate.release()
            await rejected(old, .retired)
            XCTAssertNil(f.runtime.accepted)
            XCTAssertEqual(try f.intents().count, 0)
            XCTAssertEqual(try b.intents().count, 0)
            XCTAssertEqual(try b.rows("input_change").count, 0)
            _ = try await b.runtime.complete(b.action([.init(key: .weightKg, value: .number(83))])).acceptance()
            XCTAssertEqual(b.runtime.accepted?.weightKg, 83)
            XCTAssertEqual(try f.rows("input_change").count, 0)
            try await b.close()
            b.defaults.removePersistentDomain(forName: b.domain)
        }
    }

    func testSynchronousCommitObserverRetirementDoesNotRestoreSnapshotOrMirror() async throws {
        let gate = PreferenceRuntimeGate()
        let f = try PreferenceRuntimeFixture(hooks: .init(beforePublication: { await gate.wait() }))
        try await fixture(f) { f in
            try await f.runtime.hydrate()
            let ticket = f.runtime.complete(f.action())
            await fulfillment(of: [gate.entered], timeout: 3)
            let observer = f.runtime.objectWillChange.sink { f.runtime.retire() }
            await gate.release()
            let receipt = try await ticket.acceptance()
            observer.cancel()
            XCTAssertEqual(receipt.position.id, ticket.id)
            XCTAssertNil(f.runtime.accepted)
            XCTAssertNil(f.defaults.persistentDomain(forName: f.domain)?["profile.weightKg"])
            XCTAssertEqual(try f.intents().count, 1)
        }
    }

    func testDiscardCallbackCanRetireWithoutMutatingTheDiscardedQueue() async throws {
        try await fixture { f in
            try await f.runtime.hydrate()
            let head = f.runtime.complete(f.action(permit: { false }))
            let tail = f.runtime.complete(f.action())
            await rejected(head, .held)
            let observer = tail.$state.sink { if $0 == .discarded { f.runtime.retire() } }
            XCTAssertTrue(f.runtime.discardUnacceptedChain(from: tail))
            observer.cancel()
            XCTAssertEqual(tail.state, .discarded)
            XCTAssertEqual(head.state, .held(.retired))
            XCTAssertNil(f.runtime.accepted)
            XCTAssertEqual(f.runtime.pendingCount, 0)
            XCTAssertEqual(try f.intents().count, 0)
        }
    }

    func testReentrantCountAdmissionCannotBypassByteBudget() async throws {
        try await fixture(PreferenceRuntimeFixture(maxBytes: 9_000)) { f in
            try await f.runtime.hydrate()
            var nested: ScoringPreferenceTicket?
            let observer = f.runtime.$pendingCount.sink { count in
                if count == 1 && nested == nil {
                    nested = f.runtime.complete(f.action([.init(key: .heightCm, value: .number(183))]))
                }
            }
            let first = f.runtime.complete(f.action(permit: { false }))
            observer.cancel()
            XCTAssertEqual(nested?.state, .held(.capacity))
            XCTAssertEqual(f.runtime.pendingCount, 1)
            XCTAssertLessThanOrEqual(f.runtime.pendingBytes, 9_000)
            await rejected(first, .held)
        }
    }

    func testReentrantByteAdmissionPublishesFinalQueueCounts() async throws {
        try await fixture { f in
            try await f.runtime.hydrate()
            var fired = false
            var nested: ScoringPreferenceTicket?
            let observer = f.runtime.$pendingBytes.sink { bytes in
                if bytes > 0 && !fired {
                    fired = true
                    nested = f.runtime.complete(f.action([.init(key: .heightCm, value: .number(183))]))
                }
            }
            let first = f.runtime.complete(f.action(permit: { false }))
            observer.cancel()
            XCTAssertTrue(fired)
            XCTAssertEqual(f.runtime.pendingCount, 2)
            XCTAssertGreaterThan(f.runtime.pendingBytes, 9_000)
            XCTAssertEqual(nested?.state, .queued)
            await rejected(first, .held)
            f.runtime.retire()
            XCTAssertEqual(f.runtime.pendingCount, 0)
            XCTAssertEqual(f.runtime.pendingBytes, 0)
            XCTAssertEqual(nested?.state, .held(.retired))
        }
    }

    func testRetryObserverRetirementLeavesTerminalTicketAndNoWaiter() async throws {
        try await fixture { f in
            try await f.runtime.hydrate()
            let ticket = f.runtime.complete(f.action(permit: { false }))
            await rejected(ticket, .held)
            var fired = false
            let observer = ticket.$state.sink { state in
                if state == .queued && !fired { fired = true; f.runtime.retire() }
            }
            f.runtime.retry(ticket)
            observer.cancel()
            XCTAssertTrue(fired)
            XCTAssertEqual(ticket.state, .held(.retired))
            await rejected(ticket, .retired)
            XCTAssertNil(f.runtime.accepted)
            XCTAssertEqual(f.runtime.pendingCount, 0)
            XCTAssertEqual(try f.intents().count, 0)
        }
    }

    func testCountObserverRetirementCannotRestorePendingStatus() async throws {
        try await fixture { f in
            try await f.runtime.hydrate()
            let observer = f.runtime.$pendingCount.sink { if $0 == 1 { f.runtime.retire() } }
            let ticket = f.runtime.complete(f.action(source: nil))
            observer.cancel()
            XCTAssertEqual(ticket.state, .held(.retired))
            XCTAssertEqual(f.runtime.pendingCount, 0)
            XCTAssertEqual(f.runtime.pendingBytes, 0)
            XCTAssertNil(f.runtime.accepted)
            XCTAssertEqual(try f.intents().count, 0)
        }
    }

    func testLocalOnlyHistoryPassesCapacityWithBoundedCompactionAndRecovery() async throws {
        try await fixture { f in
            try await f.runtime.hydrate()
            var last: ScoringPreferenceAdmission?
            for index in 0..<4_097 {
                last = try await f.runtime.complete(f.action([
                    .init(key: .weightKg, value: .number(index % 2 == 0 ? 71 : 72))
                ], source: nil, local: true, consent: nil, permit: nil)).acceptance()
            }
            XCTAssertEqual(last?.position.sequence, 4_097)
            XCTAssertEqual(f.runtime.accepted?.position, last?.position)
            XCTAssertEqual(try f.intents().count, 4_097 - 128)
            XCTAssertEqual(try f.rows("input_change").count, 0)
            try await f.close()
            let reopened = try PreferenceRuntimeFixture(root: f.root, context: f.context, domain: f.domain)
            try await reopened.runtime.hydrate()
            XCTAssertEqual(reopened.runtime.accepted?.position, last?.position)
            XCTAssertEqual(reopened.runtime.accepted?.weightKg, 71)
            XCTAssertEqual(try reopened.rows("input_change").count, 0)
            try await reopened.close()
        }
    }

    private func maintenanceIntent(_ f: PreferenceRuntimeFixture, after head: ScoringPreferencePosition,
                                   server: Bool = false) throws -> ScoringPreferenceIntent {
        try .init(context: f.context, predecessor: head, occurredAt: PreferenceRuntimeFixture.date,
            timezone: "America/Los_Angeles", device: server ? PreferenceRuntimeFixture.device : nil,
            disposition: server ? .serverCoupled : .localOnly,
            patch: [.init(key: .weightKg, value: .number(head.sequence % 2 == 0 ? 71 : 72))],
            profilePayload: server ? Data(#"{"schemaVersion":1,"timezone":"America/Los_Angeles","weightKg":71}"#.utf8) : nil,
            configPayload: server ? Data(#"{"schemaVersion":1,"effortMethod":"EDWARDS"}"#.utf8) : nil)
    }

    private func fillHistory(_ f: PreferenceRuntimeFixture, journal: ScoringInputJournal,
                             after initial: ScoringPreferencePosition = .initial,
                             count: Int = 4_096, server: Bool = false) async throws -> ScoringPreferenceIntent {
        var head = initial
        var last: ScoringPreferenceIntent?
        for _ in 0..<count {
            let intent = try maintenanceIntent(f, after: head, server: server)
            _ = try await journal.admitPreferenceIntent(intent, allowing: { true })
            head = intent.position; last = intent
        }
        return try XCTUnwrap(last)
    }

    private func withMaintenanceFixture(_ body: (PreferenceRuntimeFixture, ScoringInputJournal) async throws -> Void) async throws {
        try await fixture { f in
            try await f.runtime.hydrate()
            let owner = f.context, current = f.current
            let journal = try ScoringInputJournal(layout: f.layout, preferenceContext: owner,
                isPreferenceContextCurrent: { $0 == owner && current.get() })
            do { try await body(f, journal); try await journal.close() }
            catch { try? await journal.close(); throw error }
        }
    }

    private func maintenanceReceipt(_ pending: ScoringInputJournal.Pending) -> ScoringInputReceipt {
        .init(schemaVersion: 1, userId: UUID(uuidString: pending.scope.userID)!,
            sourceDeviceId: UUID(uuidString: pending.change.device)!, kind: pending.change.kind,
            entity: pending.change.entity, revision: pending.expectedRevision + 1, clientId: pending.clientID,
            clientMutationId: UUID(uuidString: pending.id)!, clientRevision: pending.clientRevision,
            effectiveDay: pending.change.effectiveDay, deleted: pending.change.deleted,
            invalidatedFrom: pending.change.effectiveDay)
    }

    func testMaintenanceReclaimsSettledChildrenButRetainsPartialAndConflictedDebt() async throws {
        try await withMaintenanceFixture { f, journal in
            let settled = try await fillHistory(f, journal: journal, count: 1, server: true)
            for _ in 0..<2 {
                let next = try await journal.next()
                let pending = try XCTUnwrap(next)
                try await journal.settle(pending, receipt: maintenanceReceipt(pending))
            }
            let partial = try await fillHistory(f, journal: journal, after: settled.position, count: 1, server: true)
            let first = try await journal.next()
            let child = try XCTUnwrap(first)
            try await journal.settle(child, receipt: maintenanceReceipt(child))
            let conflicted = try await journal.next()
            let conflictChild = try XCTUnwrap(conflicted)
            try await journal.retry(conflictChild, conflict: true)
            let unresolved = try await fillHistory(f, journal: journal, after: partial.position, count: 1, server: true)
            let beforeChildren = try f.rows("input_change")
            let last = try await fillHistory(f, journal: journal, after: unresolved.position, count: 4_093)
            let next = try maintenanceIntent(f, after: last.position)
            let receipt = try await f.inputs.admitPreferenceIntent(next, allowing: { true })
            XCTAssertEqual(receipt.position, next.position)
            let retained = try f.intents()
            XCTAssertEqual(retained.count, 3_969)
            XCTAssertFalse(retained.contains(settled))
            XCTAssertTrue(retained.contains(partial))
            XCTAssertTrue(retained.contains(unresolved))
            XCTAssertEqual(try f.rows("input_change"), beforeChildren)
            let conflicts = try await journal.conflicts()
            XCTAssertEqual(conflicts.count, 1)
            XCTAssertEqual(conflicts.first?.pending.id, conflictChild.id)
        }
    }

    func testMaintenanceCannotEvictUnresolvedCapacityAndRetriesExactIntentAfterSettlement() async throws {
        try await withMaintenanceFixture { f, journal in
            let last = try await fillHistory(f, journal: journal, count: 2_048, server: true)
            let next = try maintenanceIntent(f, after: last.position, server: true)
            let frozen = try next.encoded()
            var maintenanceCalls = 0
            do {
                _ = try await f.inputs.admitPreferenceIntent(next, allowing: { true }, atMaintenance: { _ in maintenanceCalls += 1 })
                XCTFail("unresolved children cannot be evicted")
            } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .storageLimit) }
            XCTAssertEqual(maintenanceCalls, 2)
            XCTAssertEqual(try f.rows("input_change").count, 4_096)
            XCTAssertEqual(try f.intents().count, 2_048)
            for _ in 0..<2 {
                let pending = try await journal.next()
                let child = try XCTUnwrap(pending)
                try await journal.settle(child, receipt: maintenanceReceipt(child))
            }
            let receipt = try await f.inputs.admitPreferenceIntent(next, allowing: { true })
            XCTAssertEqual(receipt.position, next.position)
            XCTAssertEqual(receipt.profileMutationID, next.profileMutationID)
            XCTAssertEqual(receipt.configMutationID, next.configMutationID)
            XCTAssertEqual(try f.intents().last?.encoded(), frozen)
            XCTAssertEqual(try f.rows("input_change").count, 4_096)
        }
    }

    func testExactReplayPrecedesMaintenanceAndConcurrentRetryGetsSameReceipt() async throws {
        try await withMaintenanceFixture { f, journal in
            let first = try await fillHistory(f, journal: journal, count: 1)
            let last = try await fillHistory(f, journal: journal, after: first.position, count: 4_095)
            let original = try await journal.admitPreferenceIntent(last, allowing: { true })
            let replay = try await f.inputs.admitPreferenceIntent(last, allowing: { true }, atMaintenance: { _ in
                XCTFail("retained exact replay must not compact")
            })
            XCTAssertEqual(replay, original)
            XCTAssertEqual(try f.intents().count, 4_096)
            let next = try maintenanceIntent(f, after: last.position, server: true)
            let gate = PreferenceRuntimeGate()
            let admission = Task { try await f.inputs.admitPreferenceIntent(next, allowing: { true }, atMaintenance: { point in
                if point == .beforeCompaction { await gate.wait() }
            }) }
            await fulfillment(of: [gate.entered], timeout: 8)
            let duplicate = Task { try await f.inputs.admitPreferenceIntent(next, allowing: { true }) }
            await Task.yield()
            await gate.release()
            let accepted = try await admission.value
            let duplicateReceipt = try await duplicate.value
            XCTAssertEqual(accepted, duplicateReceipt)
            XCTAssertEqual(accepted.profileMutationID, next.profileMutationID)
            XCTAssertEqual(try f.intents().count, 3_969)
            XCTAssertEqual(try f.rows("input_change").count, 2)
            let again = try await f.inputs.admitPreferenceIntent(next, allowing: { true })
            XCTAssertEqual(again, accepted)
            do {
                _ = try await f.inputs.admitPreferenceIntent(first, allowing: { true })
                XCTFail("compacted old intent must not manufacture a receipt")
            } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .stalePreferenceIntent) }
        }
    }

    func testRetirementBeforeAndAfterMaintenanceNeverAdmitsNewIntent() async throws {
        for point in [ScoringInputCoordinator.PreferenceMaintenancePoint.beforeCompaction, .afterCompaction] {
            try await withMaintenanceFixture { f, journal in
                let last = try await fillHistory(f, journal: journal)
                let next = try maintenanceIntent(f, after: last.position)
                do {
                    _ = try await f.inputs.admitPreferenceIntent(next, allowing: { true }, atMaintenance: { observed in
                        if observed == point { f.current.set(false); f.runtime.retire(); f.inputs.retire() }
                    })
                    XCTFail("retirement must prevent the retry")
                } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retired) }
                XCTAssertEqual(try f.intents().count, point == .beforeCompaction ? 4_096 : 3_968)
                XCTAssertEqual(try f.rows("input_change").count, 0)
                XCTAssertNil(f.runtime.accepted)
                XCTAssertEqual(try f.rows("preference_state").first?["sequence"] as Int64?, last.position.sequence)
                XCTAssertFalse(try f.intents().contains(next))
            }
        }
    }

    func testCapturedPermitIsRecheckedAfterMaintenanceWithoutChangingIntent() async throws {
        try await withMaintenanceFixture { f, journal in
            let last = try await fillHistory(f, journal: journal)
            let next = try maintenanceIntent(f, after: last.position, server: true)
            let originalBytes = try next.encoded()
            let permit = PreferenceRuntimeFlag()
            do {
                _ = try await f.inputs.admitPreferenceIntent(next, allowing: { permit.get() }, atMaintenance: { point in
                    if point == .afterCompaction { permit.set(false) }
                })
                XCTFail("a revoked captured permit cannot admit the retry")
            } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .held) }
            XCTAssertEqual(try f.intents().count, 3_968)
            XCTAssertEqual(try f.rows("input_change").count, 0)
            permit.set(true)
            let receipt = try await f.inputs.admitPreferenceIntent(next, allowing: { permit.get() })
            XCTAssertEqual(receipt.position, next.position)
            XCTAssertEqual(try f.intents().last?.encoded(), originalBytes)
            XCTAssertEqual(try f.rows("input_change").count, 2)
        }
    }

    func testMaintenanceRetainsResolvedConflictUntilReplacementActuallySettles() async throws {
        try await withMaintenanceFixture { f, journal in
            let original = try await fillHistory(f, journal: journal, count: 1, server: true)
            let first = try await journal.next()
            let child = try XCTUnwrap(first)
            try await journal.retry(child, conflict: true)
            let conflicts = try await journal.conflicts()
            let review = try XCTUnwrap(conflicts.first)
            let head = ScoringInputHead(schemaVersion: 1, userId: UUID(uuidString: f.context.scope.userID)!,
                sourceDeviceId: UUID(uuidString: PreferenceRuntimeFixture.device)!, kind: .profile,
                entity: "primary", headRevision: 8)
            let replacementID = try await journal.resolveConflict(review, head: head, replacement: XCTUnwrap(original.profile))
            let configPending = try await journal.next()
            let config = try XCTUnwrap(configPending)
            XCTAssertEqual(config.change.kind, .config)
            try await journal.settle(config, receipt: maintenanceReceipt(config))
            let archive = try f.rows("input_resolution")
            let pending = try f.rows("input_change")
            let last = try await fillHistory(f, journal: journal, after: original.position, count: 4_095)
            let next = try maintenanceIntent(f, after: last.position)
            _ = try await f.inputs.admitPreferenceIntent(next, allowing: { true })
            XCTAssertTrue(try f.intents().contains(original))
            XCTAssertEqual(try f.rows("input_resolution"), archive)
            XCTAssertEqual(try f.rows("input_change"), pending)
            let replacementPending = try await journal.next()
            let replacement = try XCTUnwrap(replacementPending)
            XCTAssertEqual(replacement.id, replacementID)
            XCTAssertEqual(replacement.expectedRevision, 8)
            try await journal.settle(replacement, receipt: maintenanceReceipt(replacement))
            let later = try await fillHistory(f, journal: journal, after: next.position, count: 127)
            _ = try await f.inputs.admitPreferenceIntent(maintenanceIntent(f, after: later.position), allowing: { true })
            XCTAssertFalse(try f.intents().contains(original))
            XCTAssertEqual(try f.intents().count, 3_969)
            XCTAssertEqual(try f.rows("input_change").count, 0)
            XCTAssertEqual(try f.rows("input_resolution").first?["id"] as String?, child.id)
        }
    }

    func testCancelledMaintenanceWaiterReleasesSerializationWithoutAReceipt() async throws {
        try await withMaintenanceFixture { f, journal in
            let last = try await fillHistory(f, journal: journal)
            let next = try maintenanceIntent(f, after: last.position, server: true)
            let gate = PreferenceRuntimeGate()
            let first = Task { try await f.inputs.admitPreferenceIntent(next, allowing: { true }, atMaintenance: { point in
                if point == .beforeCompaction { await gate.wait() }
            }) }
            await fulfillment(of: [gate.entered], timeout: 8)
            let cancelled = Task { try await f.inputs.admitPreferenceIntent(next, allowing: { true }) }
            await Task.yield()
            cancelled.cancel()
            await gate.release()
            let receipt = try await first.value
            XCTAssertEqual(receipt.position, next.position)
            do { _ = try await cancelled.value; XCTFail("cancelled waiter must not report acceptance") }
            catch { XCTAssertTrue(error is CancellationError) }
            let later = try maintenanceIntent(f, after: next.position)
            let laterReceipt = try await f.inputs.admitPreferenceIntent(later, allowing: { true })
            XCTAssertEqual(laterReceipt.position, later.position)
            XCTAssertEqual(try f.rows("input_change").count, 2)
            XCTAssertEqual(try f.intents().last, later)
        }
    }

    func testPendingHeadReadDoesNotAttachAcceptanceWaiterAndClearsAfterSettlement() async throws {
        let gate = PreferenceRuntimeGate()
        try await fixture(PreferenceRuntimeFixture(hooks: .init(beforePublication: { await gate.wait() }))) { f in
            try await f.runtime.hydrate()
            XCTAssertNil(f.runtime.pendingHeadTicket)
            let ticket = f.runtime.complete(f.action())
            await fulfillment(of: [gate.entered], timeout: 8)
            let waiting = Task { try await ticket.acceptance() }
            await Task.yield()
            for _ in 0..<20 { XCTAssertTrue(f.runtime.pendingHeadTicket === ticket) }
            XCTAssertEqual(f.runtime.pendingCount, 1)
            await gate.release()
            let receipt = try await waiting.value
            XCTAssertEqual(receipt.position.id, ticket.id)
            XCTAssertNil(f.runtime.pendingHeadTicket)
            XCTAssertEqual(try f.intents().count, 1)
        }
    }

    func testPendingHeadViewReopenKeepsSameIdentityAndCapturedPayload() async throws {
        let permit = PreferenceRuntimeFlag(false)
        try await fixture { f in
            try await f.runtime.hydrate()
            let date = PreferenceRuntimeFixture.date.addingTimeInterval(-86_400)
            let consent = ScoringPreferenceSnapshot.Consent(journalEnabled: true, cycleEnabled: false)
            let ticket = f.runtime.complete(f.action([.init(key: .weightKg, value: .number(82))],
                date: date, zone: "Asia/Kathmandu", consent: consent, permit: { permit.get() }))
            let draft = try XCTUnwrap(f.runtime.draft)
            let captured = try draft.payloads(at: date, timezone: "Asia/Kathmandu", consent: consent)
            await rejected(ticket, .held)
            let id = ticket.id
            f.defaults.set(129, forKey: "profile.weightKg")
            f.inputs.captureAdmission = { XCTFail("view reopen recaptured a permit"); return { true } }
            // A new view reads the runtime's retained head, without submitting another action.
            let reopened = try XCTUnwrap(f.runtime.pendingHeadTicket)
            XCTAssertTrue(reopened === ticket)
            XCTAssertEqual(reopened.id, id)
            XCTAssertEqual(reopened.state, .held(.held))
            XCTAssertEqual(f.runtime.pendingCount, 1)
            XCTAssertEqual(try f.intents().count, 0)
            permit.set(true)
            f.runtime.retry(reopened)
            let receipt = try await reopened.acceptance()
            let stored = try XCTUnwrap(f.intents().first)
            XCTAssertEqual(receipt.position.id, id)
            XCTAssertEqual(stored.id, id)
            XCTAssertEqual(stored.occurredAt, date)
            XCTAssertEqual(stored.timezone, "Asia/Kathmandu")
            XCTAssertEqual(stored.device, PreferenceRuntimeFixture.device)
            XCTAssertEqual(stored.profile?.payload, captured.profile)
            XCTAssertEqual(stored.config?.payload, captured.config)
            XCTAssertEqual(try f.intents().count, 1)
            XCTAssertNil(f.runtime.pendingHeadTicket)
        }
    }

    func testPendingHeadAdvancesWithFIFOAndIsNilAfterDiscardOrRetirement() async throws {
        let permit = PreferenceRuntimeFlag(false)
        try await fixture { f in
            try await f.runtime.hydrate()
            let first = f.runtime.complete(f.action(permit: { permit.get() }))
            let second = f.runtime.complete(f.action([.init(key: .heightCm, value: .number(183))], permit: { false }))
            await rejected(first, .held)
            XCTAssertTrue(f.runtime.pendingHeadTicket === first)
            permit.set(true)
            f.runtime.retry(first)
            _ = try await first.acceptance()
            await rejected(second, .held)
            XCTAssertTrue(f.runtime.pendingHeadTicket === second)
            let dependent = f.runtime.complete(f.action())
            XCTAssertTrue(f.runtime.discardUnacceptedChain(from: second))
            XCTAssertEqual(second.state, .discarded)
            XCTAssertEqual(dependent.state, .discarded)
            XCTAssertNil(f.runtime.pendingHeadTicket)
            let third = f.runtime.complete(f.action(source: nil))
            XCTAssertTrue(f.runtime.pendingHeadTicket === third)
            f.current.set(false)
            XCTAssertNil(f.runtime.pendingHeadTicket, "old generation must not expose a ticket before retire is called")
            f.runtime.retire()
            XCTAssertNil(f.runtime.pendingHeadTicket)
            XCTAssertEqual(third.state, .held(.retired))
            XCTAssertEqual(f.runtime.pendingCount, 0)
        }
    }
}
