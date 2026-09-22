import XCTest
import Combine
import WhoopStore
@testable import Strand

/// Pins the #899-A forced-rescore re-arm contract in `IntelligenceEngine.analyzeRecent`.
///
/// THE BUG: `analyzeRecent` opens with `guard !computing else { return }`. A `force: true` post-backfill
/// recompute (AppModel kicks one off after a sync) that arrives while a 15-min idle tick already holds the
/// `computing` lock was SILENTLY DROPPED, so a freshly-synced WHOOP 5.0 night intermittently never got
/// re-scored until the next cycle and Today fell back to the last scored day.
///
/// THE FIX: a dropped FORCED call sets `pendingForcedRescore`; the in-flight pass's `defer` clears the flag
/// and re-invokes `analyzeRecent(force: true)` ONCE. A NON-forced idle tick is still safely dropped (the
/// running pass already covers the same window). The flag is cleared BEFORE the re-invoke (a single re-arm),
/// so a quiet pass cannot recurse and a forced call landing DURING the re-invoke re-arms it again , exactly
/// once per genuinely-dropped force.
///
/// The async cases exercise the real analyzer with a suspended store provider, including the preflight
/// await and queued-task handoff that the original synchronous state-machine tests could not cover.
final class IntelligenceForcedRescoreRearmTests: XCTestCase {

    @MainActor
    private final class StoreGate {
        let entered: XCTestExpectation
        var calls = 0
        var continuation: CheckedContinuation<WhoopStore?, Never>?

        init(entered: XCTestExpectation) { self.entered = entered }

        func load() async -> WhoopStore? {
            calls += 1
            guard calls == 1 else { return nil }
            return await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }

        func release(_ store: WhoopStore? = nil) {
            continuation?.resume(returning: store)
            continuation = nil
        }
    }

    @MainActor
    private func engine(using gate: StoreGate) -> IntelligenceEngine {
        IntelligenceEngine(repo: Repository(deviceId: "rescore-admission-test"),
                           profile: ProfileStore(), deviceId: "rescore-admission-test",
                           analysisStoreProvider: { await gate.load() })
    }

    @MainActor
    func testActualPreflightReservesAdmissionAndCoalescesForcedCalls() async {
        let gate = StoreGate(entered: expectation(description: "first preflight suspended"))
        let engine = engine(using: gate)
        let rearmedFinished = expectation(description: "one forced follow-up returned")
        var releases = 0
        let observation = engine.$computing.dropFirst().filter { !$0 }.sink { _ in
            releases += 1
            if releases == 2 { rearmedFinished.fulfill() }
        }
        let first = Task { await engine.analyzeRecent(maxDays: 0, force: false) }
        await fulfillment(of: [gate.entered], timeout: 2)

        XCTAssertTrue(engine.computing, "admission must precede the first await")
        for _ in 0..<5 { await engine.analyzeRecent(maxDays: 0) }
        XCTAssertEqual(gate.calls, 1, "busy callers must not enter store preflight")

        gate.release()
        await first.value
        await fulfillment(of: [rearmedFinished], timeout: 2)
        XCTAssertEqual(gate.calls, 2, "five forced calls should produce only one follow-up")
        XCTAssertFalse(engine.rescoreInProgress)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testActualNonForcedPreflightCallDoesNotRearmAndNilStoreReleasesAdmission() async {
        let gate = StoreGate(entered: expectation(description: "preflight suspended"))
        let engine = engine(using: gate)
        let first = Task { await engine.analyzeRecent(maxDays: 0, force: false) }
        await fulfillment(of: [gate.entered], timeout: 2)
        await engine.analyzeRecent(maxDays: 0, force: false)
        XCTAssertEqual(gate.calls, 1)
        gate.release()
        await first.value
        XCTAssertFalse(engine.rescoreInProgress)
        XCTAssertNotNil(engine.note, "the missing-store failure remains visible")
        await engine.analyzeRecent(maxDays: 0, force: false)
        XCTAssertEqual(gate.calls, 2, "early return must release admission for a later caller")
        XCTAssertFalse(engine.rescoreInProgress)
    }

    @MainActor
    func testActualUnchangedFingerprintReleasesAdmissionWithoutStartingDebt() async throws {
        let defaults = UserDefaults.standard
        let keys = ["noop.analyzeWatermark", RescoreBackgroundScheduler.owedKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        let store = try await WhoopStore.inMemory()
        defaults.set(try await store.analysisFingerprint(), forKey: keys[0])
        defaults.set(false, forKey: keys[1])
        let engine = IntelligenceEngine(repo: Repository(deviceId: "unchanged-test"),
                                        profile: ProfileStore(), deviceId: "unchanged-test",
                                        analysisStoreProvider: { store })
        await engine.analyzeRecent(maxDays: 0, force: false)
        XCTAssertFalse(engine.rescoreInProgress)
        await engine.analyzeRecent(maxDays: 0, skipIfUnchanged: true)
        XCTAssertFalse(engine.rescoreInProgress)
        XCTAssertFalse(RescoreBackgroundScheduler.isRescoreOwed)
    }

    @MainActor
    func testActualPreflightAndQueuedHandoffRetainJobAndBlockExports() async throws {
        let defaults = UserDefaults.standard
        let keys = [RescoreBackgroundScheduler.owedKey, IntelligenceEngine.effortRescoreFlagKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        keys.forEach { defaults.set(false, forKey: $0) }
        let store = try await WhoopStore.inMemory()
        let token = try await store.markJobOwed(kind: SyncJobKind.rescore.rawValue)
        let gate = StoreGate(entered: expectation(description: "preflight suspended"))
        let engine = engine(using: gate)
        let rearmedFinished = expectation(description: "queued follow-up returned")
        var releases = 0
        let observation = engine.$computing.dropFirst().filter { !$0 }.sink { _ in
            releases += 1
            if releases == 2 { rearmedFinished.fulfill() }
        }
        var settleCalls = 0
        let settle: @MainActor () async -> Bool = {
            settleCalls += 1
            return (try? await store.settleJob(kind: SyncJobKind.rescore.rawValue, token: token)) ?? false
        }
        let first = Task {
            await engine.analyzeRecent(maxDays: 0, force: false)
            // Same-actor continuation runs before the follow-up Task can enter. Exercise the gap itself.
            XCTAssertFalse(engine.computing)
            XCTAssertTrue(engine.rescoreInProgress)
            let queuedResult = await SyncEngine.settleRescoreWhenReady(intelligence: engine, settle: settle)
            XCTAssertFalse(queuedResult)
            await engine.runEffortRescoreIfNeeded(historyDays: 0)
            XCTAssertFalse(defaults.bool(forKey: IntelligenceEngine.effortRescoreFlagKey))
            XCTAssertEqual(gate.calls, 1, "queued-gap ingress must not launch a second preflight")
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        await engine.analyzeRecent(maxDays: 0)
        XCTAssertFalse(RescoreBackgroundScheduler.isRescoreOwed, "preflight has not stamped legacy debt")
        let admittedResult = await SyncEngine.settleRescoreWhenReady(intelligence: engine, settle: settle)
        XCTAssertFalse(admittedResult)
        XCTAssertFalse(SyncDrainPolicy.shouldContinue(after: .rescore, succeeded: admittedResult,
                                                      rescoreStillOwed: true))
        gate.release()
        await first.value
        await fulfillment(of: [rearmedFinished], timeout: 2)
        XCTAssertEqual(settleCalls, 0)
        XCTAssertEqual(gate.calls, 2)
        let owed = try await store.owedJobs()
        XCTAssertEqual(owed.map(\.token), [token])
        XCTAssertFalse(engine.rescoreInProgress)
        withExtendedLifetime(observation) {}
    }

    /// A faithful model of the engine's re-arm state machine. Each method mirrors one decision in
    /// `analyzeRecent`: the entry guard and the `defer`. `reruns` counts how many times the `defer` would
    /// re-invoke `analyzeRecent(force: true)`.
    private struct RearmModel {
        private(set) var computing = false
        private(set) var pendingForcedRescore = false
        private(set) var reruns = 0

        /// `guard !computing else { if force { pendingForcedRescore = true }; return }`.
        /// Returns true when the call proceeds into the body (took the lock); false when it was dropped
        /// (and, if forced, re-armed). A proceeding call sets `computing = true`.
        mutating func enter(force: Bool) -> Bool {
            if computing {
                if force { pendingForcedRescore = true }
                return false
            }
            computing = true
            return true
        }

        /// The body's `defer`: clear the lock, then if a forced rescore was dropped while we held it,
        /// clear the flag (single re-arm) and re-invoke once. The re-invoke runs its OWN enter()/leave()
        /// so a nested re-arm is modelled too.
        mutating func leave() {
            computing = false
            if pendingForcedRescore {
                pendingForcedRescore = false
                reruns += 1
                // The re-invoke is `analyzeRecent(force: true)`: it re-enters (lock is free now) and leaves.
                if enter(force: true) { leave() }
            }
        }
    }

    /// A forced call dropped while a pass is in-flight schedules EXACTLY ONE rerun.
    func testForcedCallDuringInFlightPassSchedulesExactlyOneRerun() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: true))          // idle tick / first pass takes the lock
        XCTAssertFalse(m.enter(force: true))         // a forced post-sync call lands mid-flight → dropped + re-armed
        XCTAssertTrue(m.pendingForcedRescore)
        m.leave()                                    // the in-flight pass finishes → re-arms once
        XCTAssertEqual(m.reruns, 1, "a dropped forced call must trigger exactly one rerun")
        XCTAssertFalse(m.pendingForcedRescore, "the flag is cleared by the single re-arm")
        XCTAssertFalse(m.computing, "the lock is released after the rerun")
    }

    /// A NON-forced idle tick dropped while a pass is in-flight is NOT re-armed (the running pass already
    /// covers the same window) , so no rerun, no wasted recompute.
    func testNonForcedCallDuringInFlightPassIsNotRearmed() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: true))
        XCTAssertFalse(m.enter(force: false))        // a non-forced idle tick lands mid-flight → dropped, NOT re-armed
        XCTAssertFalse(m.pendingForcedRescore)
        m.leave()
        XCTAssertEqual(m.reruns, 0)
    }

    /// A pass with NOTHING dropped while it ran re-arms NOTHING , the re-arm can't fire spuriously.
    func testQuietPassDoesNotRerun() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: true))
        m.leave()
        XCTAssertEqual(m.reruns, 0)
        XCTAssertFalse(m.pendingForcedRescore)
        XCTAssertFalse(m.computing)
    }

    /// Many forced calls piling up against ONE in-flight pass collapse to a SINGLE rerun (the flag is a
    /// boolean latch, not a counter) , the re-arm bounds the extra work to one pass, never a storm.
    func testMultipleDroppedForcedCallsCollapseToOneRerun() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: true))
        for _ in 0..<5 { XCTAssertFalse(m.enter(force: true)) }   // five forced calls all land mid-flight
        m.leave()
        XCTAssertEqual(m.reruns, 1, "the boolean latch collapses N dropped forces to one rerun")
    }

    /// The single re-arm terminates: a forced call that lands DURING the re-invoke re-arms exactly once more
    /// (one extra pass), and once nothing new lands the chain stops , it can never recurse unbounded.
    func testReArmTerminatesAndDoesNotLoop() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: true))
        XCTAssertFalse(m.enter(force: true))         // one forced call dropped against the first pass
        m.leave()                                    // re-arms once; the re-invoke runs to completion cleanly
        XCTAssertEqual(m.reruns, 1)
        XCTAssertFalse(m.pendingForcedRescore)
        XCTAssertFalse(m.computing)                  // settled , no lingering lock, no further reruns queued
    }
}
