import Foundation
import GRDB
import NoopPush
import StrandAnalytics
import WhoopProtocol
import WhoopStore
import XCTest
@testable import Strand

private func recomputeFixtureBaseDirectory() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["NARA_TEST_FIXTURE_ROOT"] else {
        return URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
    }
    var isDirectory: ObjCBool = false
    guard path.hasPrefix("/"), !path.utf8.contains(0),
          FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw NSError(domain: "NARATestFixtureRoot", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "NARA_TEST_FIXTURE_ROOT must name an existing absolute directory"
        ])
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}

@MainActor
final class ScoringPreferenceRecomputeTests: XCTestCase {
    @MainActor private final class Barrier {
        var target: IntelligenceEngine.LifecycleCheckpoint = .beforeScorePersistence
        var entered: XCTestExpectation?
        private var continuation: CheckedContinuation<Void, Never>?
        func visit(_ point: IntelligenceEngine.LifecycleCheckpoint) async {
            guard point == target, let entered else { return }
            self.entered = nil
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    private final class FailOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining = true
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; let value = remaining; remaining = false; return value }
    }
    private enum SyntheticFailure: Error { case unavailable }

    @MainActor private final class Fixture {
        let root: URL
        let layout: AccountStorageLayout
        let defaults: UserDefaults
        var context: AccountSessionContext
        var store: WhoopStore
        var model: AppModel?
        let barrier = Barrier()
        var completedPasses = 0

        init(seed: [String: Any] = [:]) async throws {
            let temporary = try recomputeFixtureBaseDirectory()
            root = temporary.appendingPathComponent("preference-recompute-" + UUID().uuidString)
            context = .init(scope: try AccountScope(projectURL: "https://" + UUID().uuidString + ".invalid",
                userID: UUID().uuidString), generation: UUID())
            layout = .init(baseDirectory: root, scope: context.scope)
            try layout.prepare()
            defaults = try XCTUnwrap(UserDefaults(suiteName: layout.preferencesSuite))
            defaults.setPersistentDomain(seed, forName: layout.preferencesSuite)
            store = try await WhoopStore(path: layout.databaseURL.path)
            try await store.bindAccountOwner(projectURL: context.scope.projectURL,
                                             userID: context.scope.userID)
        }

        func makeModel(automatic: Bool = true, journalFailure: FailOnce? = nil) -> AppModel {
            let context = context, store = store
            var inputs = ScoringPreferenceAppTestSupport.dependencies(context: context, isCurrent: { $0 == context })
            let openJournal = inputs.openJournal
            inputs.openJournal = { layout, fence in
                if journalFailure?.take() == true { throw SyntheticFailure.unavailable }
                return try await openJournal(layout, fence)
            }
            let driver = IntelligenceEngine.PreferenceRecomputeDriver(
                checkpoint: { [barrier] in await barrier.visit($0) },
                markOwed: { nil }, markCompleted: { [weak self] _, _ in self?.completedPasses += 1; return true })
            let next = AppModel(storageLayout: layout, context: context, captureAllowed: false,
                openStore: { store }, scoringInputDependencies: inputs,
                nativePreferenceCurrent: { $0 == context }, preferenceScoringEnabled: { false },
                preferenceRecomputeDriver: automatic ? driver : nil, isCurrent: { $0 == context })
            model = next
            return next
        }

        func stopModel() async throws {
            guard let model else { return }
            let captured = model.shutdownForAccountChange()
            barrier.release()
            await model.retryScoringPreferenceRecompute()
            let bleDrained = await model.ble.drainCaptureAfterAccountChange()
            XCTAssertTrue(bleDrained)
            if let captured {
                let genericDrained = await captured.drain()
                XCTAssertTrue(genericDrained)
            }
            await model.scoringPreferences?.waitForRetirement()
            try await model.scoringInputs?.waitForRetirement()
            self.model = nil
        }

        func reopen(automatic: Bool = true) async throws -> AppModel {
            try await stopModel()
            try store.registryWriter.close()
            context = .init(scope: context.scope, generation: UUID())
            store = try await WhoopStore(path: layout.databaseURL.path)
            try await store.bindAccountOwner(projectURL: context.scope.projectURL,
                                             userID: context.scope.userID)
            return makeModel(automatic: automatic)
        }

        func close() async throws {
            try await stopModel()
            try store.registryWriter.close()
            defaults.removePersistentDomain(forName: layout.preferencesSuite)
            try FileManager.default.removeItem(at: root)
        }

        func inputCounts() throws -> (children: Int, position: Int64) {
            var config = Configuration(); config.readonly = true
            let db = try DatabaseQueue(path: layout.directory.appendingPathComponent("history-inputs.sqlite").path,
                                       configuration: config)
            defer { try? db.close() }
            return try db.read {
                (try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM input_change") ?? -1,
                 try Int64.fetchOne($0, sql: "SELECT sequence FROM preference_state WHERE singleton=1") ?? -1)
            }
        }

        @discardableResult func populate() async throws -> (start: Int, end: Int) {
            let now = Int(Date().timeIntervalSince1970), offset = TimeZone.current.secondsFromGMT()
            let midnight = IntelligenceEngine.midnightLocal(now, offsetSec: offset)
            let start = midnight - 86_400 + 3600, duration = 6 * 3600
            let hr = (0..<duration).map { HRSample(ts: start + $0, bpm: 60 + ($0 / 300) % 3) }
            let rr = (0..<duration).map {
                RRInterval(ts: start + $0, rrMs: $0.isMultiple(of: 2) ? 960 : 1040, srcChannel: .whoop5Historical)
            }
            let gravity = stride(from: 0, to: duration, by: 10).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1) }
            _ = try await store.insert(Streams(hr: hr, rr: rr, gravity: gravity), deviceId: "my-whoop")
            let baseline = (2...16).map { day in
                DailyMetric(day: AnalyticsEngine.dayString(midnight - day * 86_400, offsetSec: offset),
                    totalSleepMin: 420, efficiency: 0.9, deepMin: 70, remMin: 90, lightMin: 260,
                    disturbances: 1, restingHr: 60, avgHrv: 50, recovery: nil, strain: 4, exerciseCount: 0)
            }
            _ = try await store.upsertDailyMetrics(baseline, deviceId: "my-whoop")
            return (start, start + duration)
        }
    }

    private func fixture(seed: [String: Any] = [:]) async throws -> Fixture {
        try XCTSkipUnless(AppRuntimeMode.isUnitTesting, "real AppModel must retain hermetic startup guards")
        let f = try await Fixture(seed: seed)
        addTeardownBlock { @MainActor in try await f.close() }
        return f
    }

    private struct EditedNight {
        let start: Int
        let end: Int
        let offset: Int
        let day: String
        let aStages: String
        let bStages: String
        var correctedStart: Int { start + 1800 }
    }

    private func editedNight(_ f: Fixture, daysAgo: Int = 1, sparseHR: Bool = false,
                             bHasHR: Bool = true, bProbeOnly: Bool = false,
                             override: String? = "A", insertEdit: Bool = true) async throws -> EditedNight {
        let offset = TimeZone.current.secondsFromGMT()
        let midnight = IntelligenceEngine.midnightLocal(Int(Date().timeIntervalSince1970), offsetSec: offset)
        let start = midnight - daysAgo * 86_400 + 3600, end = start + 6 * 3600
        let registry = DeviceRegistryStore(dbQueue: f.store.registryWriter)
        for id in ["A", "B"] {
            try registry.add(PairedDevice(id: id, brand: "WHOOP", model: "WHOOP 4.0",
                sourceKind: .liveBLE, capabilities: [.hr, .sleep], status: .paired,
                addedAt: start, lastSeenAt: start))
        }
        try registry.setActive("B")
        let day = AnalyticsEngine.dayString(end, offsetSec: offset)
        if let override { try registry.setDayOwner(day: day, deviceId: override, locked: true) }
        let aHR = sparseHR ? [HRSample(ts: start, bpm: 52)]
            : (start..<end).map { HRSample(ts: $0, bpm: 52 + (($0 - start) / 60) % 3) }
        let aGravity = stride(from: start, to: end, by: 10).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        let bHR = bHasHR ? (start..<end).map { HRSample(ts: $0, bpm: 150 + (($0 - start) / 60) % 10) } : []
        let bGravity = stride(from: start, to: end, by: 10).enumerated().map {
            GravitySample(ts: $0.element, x: $0.offset.isMultiple(of: 2) ? 0 : 2, y: 0, z: 1)
        }
        _ = try await f.store.insert(Streams(hr: aHR, gravity: aGravity), deviceId: "A")
        _ = try await f.store.insert(Streams(hr: bHR, gravity: bGravity), deviceId: "B")
        if bProbeOnly {
            // Outside the edited window AND its ±1h restaging reads, but inside the actual day-owner probe.
            _ = try await f.store.insert(Streams(hr: [HRSample(ts: start - 86_400, bpm: 80)]), deviceId: "B")
        }
        let aStages = try XCTUnwrap(AnalyticsEngine.encodeStages(SleepStager.stageSession(
            start: start + 1800, end: end, grav: aGravity, hr: aHR, rr: [], resp: [])))
        let bStages = try XCTUnwrap(AnalyticsEngine.encodeStages(SleepStager.stageSession(
            start: start + 1800, end: end, grav: bGravity, hr: bHR, rr: [], resp: [])))
        XCTAssertNotEqual(aStages, bStages, "real A/B stagers must discriminate a wrong raw-owner read")
        let night = EditedNight(start: start, end: end, offset: offset, day: day, aStages: aStages, bStages: bStages)
        if insertEdit { try await insertCanonicalEdit(night, store: f.store) }
        _ = try await f.store.insertManualSleepSession(deviceId: "B-noop", startTs: start,
            endTs: end - 3600, efficiency: 0.4, stagesJSON: "[]")
        return night
    }

    private func insertCanonicalEdit(_ night: EditedNight, store: WhoopStore) async throws {
        _ = try await store.insertManualSleepSession(deviceId: "my-whoop-noop", startTs: night.start,
            endTs: night.end, efficiency: 0.5, stagesJSON: "[]")
        let changed = try await store.applySleepEdit(deviceId: "my-whoop-noop", detectedStartTs: night.start,
            newStartTs: night.correctedStart, newEndTs: night.end)
        XCTAssertEqual(changed, 1)
    }

    private func canonicalRow(_ night: EditedNight, store: WhoopStore) async throws -> CachedSleepSession {
        let rows = try await store.sleepSessions(deviceId: "my-whoop-noop", from: night.start, to: night.end, limit: 100)
        return try XCTUnwrap(rows.first { $0.startTs == night.start })
    }

    private func assertEditedRow(_ row: CachedSleepSession, night: EditedNight, stages: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(row.startTs, night.start, file: file, line: line)
        XCTAssertEqual(row.effectiveStartTs, night.correctedStart, file: file, line: line)
        XCTAssertEqual(row.endTs, night.end, file: file, line: line)
        XCTAssertTrue(row.userEdited, file: file, line: line)
        XCTAssertEqual(row.stagesJSON, stages, file: file, line: line)
    }

    func testPopulatedResetCannotCompleteBeforeActualScorePersistenceAndDoesNotNeedNewRaw() async throws {
        let f = try await fixture(seed: ["noopExperimentalSleepV2": false])
        try await f.populate()
        let model = f.makeModel()
        await model.retryScoringPreferenceRecompute()
        XCTAssertFalse(model.intelligence.hasPendingPreferenceRecompute)
        XCTAssertFalse(model.intelligence.results.isEmpty)
        XCTAssertTrue(model.intelligence.results.contains { $0.recovery != nil }, "populated baseline must discriminate reset")
        let completed = try XCTUnwrap(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey))
        let raw = try await f.store.analysisFingerprint()
        let entered = expectation(description: "accepted reset reached actual persistence")
        f.barrier.entered = entered
        let reset = try XCTUnwrap(model.recalibrateChargeBaseline(now: Date().timeIntervalSince1970))
        _ = try await reset.acceptance()
        await fulfillment(of: [entered], timeout: 15)
        XCTAssertTrue(model.intelligence.hasPendingPreferenceRecompute)
        XCTAssertEqual(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey), completed)
        f.barrier.release()
        await model.retryScoringPreferenceRecompute()
        XCTAssertFalse(model.intelligence.hasPendingPreferenceRecompute)
        XCTAssertFalse(model.intelligence.results.isEmpty)
        XCTAssertTrue(model.intelligence.results.allSatisfy { $0.recovery == nil }, "reset must discard the populated old baseline")
        let rawAfter = try await f.store.analysisFingerprint()
        XCTAssertEqual(rawAfter, raw)
        XCTAssertEqual(try f.inputCounts().children, 0)
        XCTAssertEqual(try f.inputCounts().position, 1)
    }

    func testCrashEquivalentAcceptedButUnstartedReopensSameOwnerAndDrainsWithoutChildren() async throws {
        let f = try await fixture()
        let first = f.makeModel()
        await first.retryScoringPreferenceRecompute()
        let oldWitness = try XCTUnwrap(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey))
        let raw = try await f.store.analysisFingerprint()
        let unstarted = try await f.reopen(automatic: false)
        try await unstarted.prepareScoringPreferences()
        let ticket = try unstarted.completePreferenceAction([.init(key: .effortMethod, value: .text("BANISTER"))])
        let receipt = try await ticket.acceptance()
        XCTAssertEqual(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey), oldWitness)
        XCTAssertTrue(unstarted.intelligence.hasPendingPreferenceRecompute)
        let oldGeneration = f.context.generation
        let reopened = try await f.reopen()
        XCTAssertNotEqual(f.context.generation, oldGeneration)
        await reopened.retryScoringPreferenceRecompute()
        XCTAssertFalse(reopened.intelligence.hasPendingPreferenceRecompute)
        XCTAssertEqual(reopened.acceptedScoringPreferences?.position.id, receipt.position.id)
        XCTAssertEqual(try f.inputCounts().children, 0)
        XCTAssertEqual(try f.inputCounts().position, 1)
        let rawAfter = try await f.store.analysisFingerprint()
        XCTAssertEqual(rawAfter, raw)
        let passes = f.completedPasses
        let again = try await f.reopen()
        await again.retryScoringPreferenceRecompute()
        XCTAssertFalse(again.intelligence.hasPendingPreferenceRecompute)
        XCTAssertEqual(f.completedPasses, passes, "generation changes alone do not invalidate completion")
    }

    func testOlderPassCannotAcknowledgeNewerAcceptedPosition() async throws {
        let f = try await fixture(), model = f.makeModel()
        await model.retryScoringPreferenceRecompute()
        let before = f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey)
        let first = expectation(description: "first accepted position in flight")
        f.barrier.target = .beforeCompletion; f.barrier.entered = first
        _ = try await model.completePreferenceAction([.init(key: .hrvWindow, value: .text("deep"))]).acceptance()
        await fulfillment(of: [first], timeout: 15)
        _ = try await model.completePreferenceAction([.init(key: .effortMethod, value: .text("BANISTER"))]).acceptance()
        let second = expectation(description: "newer accepted position needs its own pass")
        f.barrier.entered = second
        f.barrier.release()
        await fulfillment(of: [second], timeout: 15)
        XCTAssertEqual(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey), before)
        XCTAssertTrue(model.intelligence.hasPendingPreferenceRecompute)
        f.barrier.release()
        await model.retryScoringPreferenceRecompute()
        XCTAssertFalse(model.intelligence.hasPendingPreferenceRecompute)
        XCTAssertEqual(try f.inputCounts().position, 2)
        XCTAssertEqual(try f.inputCounts().children, 0)
    }

    func testCancelledActualPassCannotAdvanceCompletion() async throws {
        let f = try await fixture(), model = f.makeModel(automatic: false)
        try await model.prepareScoringPreferences()
        // Use the actual engine directly so cancellation belongs to the pass, not a preparation waiter.
        let entered = expectation(description: "cancel actual pass at persistence")
        let barrier = Barrier(); barrier.entered = entered
        let engine = IntelligenceEngine(repo: model.repo, profile: model.profile, deviceId: "my-whoop",
            defaults: f.defaults, scoringPreferences: { model.acceptedScoringPreferences },
            preferenceRecomputeDriver: .init(checkpoint: { await barrier.visit($0) }, markOwed: { nil },
                                            markCompleted: { _, _ in XCTFail("cancelled pass completed"); return false }))
        let running = Task { await engine.analyzeRecent() }
        await fulfillment(of: [entered], timeout: 15)
        running.cancel(); barrier.release(); await running.value
        XCTAssertNil(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey))
        XCTAssertTrue(engine.hasPendingPreferenceRecompute)
    }

    func testRetirementAtFinalBarrierCannotAdvanceCompletion() async throws {
        let f = try await fixture(), model = f.makeModel()
        let entered = expectation(description: "retire before completion witness")
        f.barrier.target = .beforeCompletion; f.barrier.entered = entered
        let running = Task { await model.retryScoringPreferenceRecompute() }
        await fulfillment(of: [entered], timeout: 15)
        _ = model.shutdownForAccountChange()
        f.barrier.release(); await running.value
        XCTAssertNil(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey))
        XCTAssertEqual(f.completedPasses, 0)
    }

    func testSecondarySQLiteFailureKeepsDebtUntilExplicitRetry() async throws {
        let f = try await fixture(), model = f.makeModel()
        // The workout deletion is a real secondary write, after primary score persistence.
        try await f.store.registryWriter.write {
            try $0.execute(sql: "CREATE TRIGGER fail_recompute_delete BEFORE DELETE ON workout BEGIN SELECT RAISE(ABORT, 'synthetic secondary failure'); END")
        }
        _ = try await f.store.upsertWorkouts([WorkoutRow(startTs: Int(Date().timeIntervalSince1970) - 120,
            endTs: Int(Date().timeIntervalSince1970) - 60, sport: "detected", source: "my-whoop-noop", durationS: 60,
            energyKcal: 1, avgHr: 100, maxHr: 100, strain: 1, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)],
            deviceId: "my-whoop-noop")
        await model.retryScoringPreferenceRecompute()
        XCTAssertNil(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey))
        XCTAssertTrue(model.intelligence.hasPendingPreferenceRecompute)
        XCTAssertEqual(f.completedPasses, 0)
        try await f.store.registryWriter.write { try $0.execute(sql: "DROP TRIGGER fail_recompute_delete") }
        await model.retryScoringPreferenceRecompute()
        XCTAssertFalse(model.intelligence.hasPendingPreferenceRecompute)
        XCTAssertEqual(try f.inputCounts().children, 0)
        XCTAssertEqual(try f.inputCounts().position, 0)
    }

    func testTransientHydrationFailureCanBeRetriedWithoutCreatingAction() async throws {
        let f = try await fixture(), model = f.makeModel(journalFailure: FailOnce())
        await model.retryScoringPreferenceRecompute()
        XCTAssertNil(model.acceptedScoringPreferences)
        XCTAssertNil(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey))
        await model.retryScoringPreferenceRecompute()
        XCTAssertNotNil(model.acceptedScoringPreferences)
        XCTAssertFalse(model.intelligence.hasPendingPreferenceRecompute)
        XCTAssertEqual(try f.inputCounts().children, 0)
        XCTAssertEqual(try f.inputCounts().position, 0)
    }

    func testPrimarySQLiteFailureCannotCertifyPopulatedPass() async throws {
        let f = try await fixture(seed: ["noopExperimentalSleepV2": false])
        try await f.populate()
        try await f.store.registryWriter.write {
            try $0.execute(sql: "CREATE TRIGGER fail_recompute_primary BEFORE INSERT ON dailyMetric WHEN NEW.deviceId = 'my-whoop-noop' BEGIN SELECT RAISE(ABORT, 'synthetic primary failure'); END")
        }
        let model = f.makeModel()
        await model.retryScoringPreferenceRecompute()
        XCTAssertTrue(model.intelligence.hasPendingPreferenceRecompute)
        XCTAssertNil(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey))
        XCTAssertEqual(f.completedPasses, 0)
        try await f.store.registryWriter.write { try $0.execute(sql: "DROP TRIGGER fail_recompute_primary") }
        await model.retryScoringPreferenceRecompute()
        XCTAssertFalse(model.intelligence.results.isEmpty)
        XCTAssertFalse(model.intelligence.hasPendingPreferenceRecompute)
    }

    func testCompletionCannotCrossOwnerOrCertifyDifferentPositionZeroSeed() async throws {
        let f = try await fixture(), first = f.makeModel()
        await first.retryScoringPreferenceRecompute()
        let witness = try XCTUnwrap(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey))
        try await f.stopModel()
        f.defaults.set(99.0, forKey: "profile.weightKg")
        let reseeded = try await f.reopen(automatic: false)
        try await reseeded.prepareScoringPreferences()
        XCTAssertEqual(reseeded.acceptedScoringPreferences?.position, .initial)
        XCTAssertEqual(reseeded.profile.weightKg, 99)
        XCTAssertTrue(reseeded.intelligence.hasPendingPreferenceRecompute)

        let other = try await fixture()
        other.defaults.set(witness, forKey: IntelligenceEngine.preferenceCompletionKey)
        let secondOwner = other.makeModel(automatic: false)
        try await secondOwner.prepareScoringPreferences()
        XCTAssertEqual(secondOwner.acceptedScoringPreferences?.position, .initial)
        XCTAssertTrue(secondOwner.intelligence.hasPendingPreferenceRecompute)
        XCTAssertEqual(try other.inputCounts().children, 0)
    }

    func testDelegatedSleepStageSQLiteFailureCannotCertifyAndRetryHealsActualRow() async throws {
        let f = try await fixture(seed: ["noopExperimentalSleepV2": false])
        let window = try await f.populate()
        _ = try await f.store.insertManualSleepSession(deviceId: "my-whoop-noop",
            startTs: window.start, endTs: window.end, efficiency: nil, stagesJSON: nil)
        try await f.store.registryWriter.write {
            try $0.execute(sql: "CREATE TRIGGER fail_delegated_stages BEFORE UPDATE OF stagesJSON ON sleepSession WHEN NEW.deviceId = 'my-whoop-noop' AND OLD.userEdited = 1 BEGIN SELECT RAISE(ABORT, 'synthetic delegated failure'); END")
        }
        let model = f.makeModel()
        await model.retryScoringPreferenceRecompute()
        let failedRows = try await f.store.sleepSessions(deviceId: "my-whoop-noop",
            from: window.start, to: window.end, limit: 10)
        let failed = try XCTUnwrap(failedRows.first { $0.startTs == window.start })
        XCTAssertTrue(failed.userEdited)
        XCTAssertNil(failed.stagesJSON)
        XCTAssertNil(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey))
        XCTAssertTrue(model.intelligence.hasPendingPreferenceRecompute)
        XCTAssertEqual(f.completedPasses, 0)
        try await f.store.registryWriter.write { try $0.execute(sql: "DROP TRIGGER fail_delegated_stages") }
        await model.retryScoringPreferenceRecompute()
        let repairedRows = try await f.store.sleepSessions(deviceId: "my-whoop-noop",
            from: window.start, to: window.end, limit: 10)
        let repaired = try XCTUnwrap(repairedRows.first { $0.startTs == window.start })
        XCTAssertNotNil(repaired.stagesJSON)
        XCTAssertTrue(repaired.userEdited)
        XCTAssertEqual(repaired.effectiveStartTs, window.start)
        XCTAssertEqual(repaired.endTs, window.end)
        XCTAssertFalse(model.intelligence.hasPendingPreferenceRecompute)
        XCTAssertEqual(try f.inputCounts().children, 0)
        XCTAssertEqual(try f.inputCounts().position, 0)
    }

    func testDayCycleReadFailureReportsToPassRecorderAndPreservesMarkers() async throws {
        let f = try await fixture()
        let status = ScoringAnalysisPassStatus()
        let result = await DayCycleIntelligenceIntegration.compute(nights: [], editedRows: [], store: f.store,
            candidates: [(owner: "my-whoop", priority: 0)], physiologyOwners: ["my-whoop"], workouts: [],
            windowStart: 1000, now: 2000, offsetSec: 0, habitualMidsleepSec: nil, ticksPerStep: 1,
            mode: .sleepOnset, cache: .init(),
            profile: UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male", stepTicksPerStep: 1),
            maxHROverride: nil, effortMethod: .edwards,
            recoveryReader: .init(sleepSessions: { _, _, _ in [] }, markers: { _, _, _ in throw SyntheticFailure.unavailable }),
            onFailure: { status.recordFailure() })
        XCTAssertTrue(status.failed)
        if case .preserve = result.markerUpdate {} else { XCTFail("failed recovery cannot authorize marker replacement") }
        XCTAssertTrue(result.stepsByWakeDay.isEmpty)
    }

    func testCanonicalEditedSleepUsesHistoricalOwnerAndPersistsBeforeCompletion() async throws {
        let f = try await fixture(seed: ["noopExperimentalSleepV2": false])
        let night = try await editedNight(f)
        let bBefore = try await f.store.sleepSessions(deviceId: "B-noop", from: night.start, to: night.end, limit: 10)
        let rawBefore = try await f.store.analysisFingerprint()
        let model = f.makeModel()
        XCTAssertTrue(model.repo.adoptActiveDeviceId("B"))
        f.barrier.target = .beforeCompletion
        let entered = expectation(description: "historical A canonical write precedes completion")
        f.barrier.entered = entered
        let running = Task { await model.retryScoringPreferenceRecompute() }
        await fulfillment(of: [entered], timeout: 20)
        let row = try await canonicalRow(night, store: f.store)
        assertEditedRow(row, night: night, stages: night.aStages)
        let bAfter = try await f.store.sleepSessions(deviceId: "B-noop", from: night.start, to: night.end, limit: 10)
        XCTAssertEqual(bAfter, bBefore)
        let days = try await f.store.dailyMetrics(deviceId: "my-whoop-noop", from: night.day, to: night.day)
        let daily = try XCTUnwrap(days.first)
        let minutes = try XCTUnwrap(SleepStageTotals.minutes(fromStagesJSON: night.aStages))
        XCTAssertEqual(try XCTUnwrap(daily.totalSleepMin), minutes.asleep, accuracy: 0.001)
        let overlaps = try await f.store.sleepSessions(deviceId: "my-whoop-noop",
            from: night.start - 3600, to: night.end, limit: 100)
        XCTAssertEqual(overlaps.filter { $0.effectiveStartTs < night.end && $0.endTs > night.correctedStart }.count, 1)
        XCTAssertNil(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey))
        XCTAssertTrue(model.intelligence.hasPendingPreferenceRecompute)
        f.barrier.release(); await running.value
        XCTAssertFalse(model.intelligence.hasPendingPreferenceRecompute)
        let rawAfter = try await f.store.analysisFingerprint()
        XCTAssertEqual(rawAfter, rawBefore)
        XCTAssertEqual(try f.inputCounts().children, 0)
        XCTAssertEqual(try f.inputCounts().position, 0)
    }

    func testCanonicalEditedSleepWithoutOverrideUsesActualADataWhenActiveBHasNone() async throws {
        let f = try await fixture(seed: ["noopExperimentalSleepV2": false])
        let night = try await editedNight(f, bHasHR: false, override: nil)
        let model = f.makeModel()
        XCTAssertTrue(model.repo.adoptActiveDeviceId("B"))
        await model.retryScoringPreferenceRecompute()
        let row = try await canonicalRow(night, store: f.store)
        assertEditedRow(row, night: night, stages: night.aStages)
        XCTAssertFalse(model.intelligence.hasPendingPreferenceRecompute)
    }

    func testCanonicalEditedSleepUsesBWhenActualResolverSelectsB() async throws {
        let f = try await fixture(seed: ["noopExperimentalSleepV2": false])
        let night = try await editedNight(f, override: nil)
        let model = f.makeModel()
        XCTAssertTrue(model.repo.adoptActiveDeviceId("B"))
        await model.retryScoringPreferenceRecompute()
        let row = try await canonicalRow(night, store: f.store)
        assertEditedRow(row, night: night, stages: night.bStages)
        XCTAssertFalse(model.intelligence.hasPendingPreferenceRecompute)
    }

    func testLowHRSkippedDayStillCarriesItsActualOwnerIntoCanonicalHealing() async throws {
        let f = try await fixture(seed: ["noopExperimentalSleepV2": false])
        let night = try await editedNight(f, sparseHR: true, bHasHR: false)
        let model = f.makeModel()
        XCTAssertTrue(model.repo.adoptActiveDeviceId("B"))
        await model.retryScoringPreferenceRecompute()
        let row = try await canonicalRow(night, store: f.store)
        assertEditedRow(row, night: night, stages: night.aStages)
        XCTAssertFalse(model.intelligence.results.contains { $0.day == night.day }, "owner selection must not promote sparse HR into a scored day")
        XCTAssertFalse(model.intelligence.hasPendingPreferenceRecompute)
    }

    func testLookbackEditedDayUsesFullNightProbeNotShorterEditedWindow() async throws {
        let f = try await fixture(seed: ["noopExperimentalSleepV2": false])
        let night = try await editedNight(f, daysAgo: 21, bHasHR: false, bProbeOnly: true, override: nil)
        let bEditedWindow = try await f.store.hrSamples(deviceId: "B", from: night.correctedStart - 3600,
            to: night.end + 3600, limit: 10)
        XCTAssertTrue(bEditedWindow.isEmpty)
        let model = f.makeModel()
        XCTAssertTrue(model.repo.adoptActiveDeviceId("B"))
        await model.retryScoringPreferenceRecompute()
        let row = try await canonicalRow(night, store: f.store)
        assertEditedRow(row, night: night, stages: night.bStages)
        XCTAssertFalse(model.intelligence.results.contains { $0.day == night.day })
        XCTAssertFalse(model.intelligence.hasPendingPreferenceRecompute)
    }

    func testNewUnmappedLookbackEditRetainsDebtUntilFreshSelectionRetry() async throws {
        let f = try await fixture(seed: ["noopExperimentalSleepV2": false])
        let night = try await editedNight(f, daysAgo: 21, insertEdit: false)
        let model = f.makeModel()
        XCTAssertTrue(model.repo.adoptActiveDeviceId("B"))
        f.barrier.target = .beforeEditedSleepHealing
        let entered = expectation(description: "immutable owner map captured before new edit")
        f.barrier.entered = entered
        let running = Task { await model.retryScoringPreferenceRecompute() }
        await fulfillment(of: [entered], timeout: 20)
        try await insertCanonicalEdit(night, store: f.store)
        f.barrier.release(); await running.value
        let held = try await canonicalRow(night, store: f.store)
        assertEditedRow(held, night: night, stages: "[]")
        XCTAssertNil(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey))
        XCTAssertTrue(model.intelligence.hasPendingPreferenceRecompute)
        await model.retryScoringPreferenceRecompute()
        let repaired = try await canonicalRow(night, store: f.store)
        assertEditedRow(repaired, night: night, stages: night.aStages)
        XCTAssertFalse(model.intelligence.hasPendingPreferenceRecompute)
        XCTAssertEqual(try f.inputCounts().children, 0)
        XCTAssertEqual(try f.inputCounts().position, 0)
    }

    func testHistoricalCanonicalUpdateFailureReopensAndRetriesWithoutNewIntent() async throws {
        let f = try await fixture(seed: ["noopExperimentalSleepV2": false])
        let night = try await editedNight(f)
        try await f.store.registryWriter.write {
            try $0.execute(sql: "CREATE TRIGGER fail_canonical_owner BEFORE UPDATE OF stagesJSON ON sleepSession WHEN NEW.deviceId='my-whoop-noop' AND OLD.userEdited=1 BEGIN SELECT RAISE(ABORT, 'synthetic canonical owner failure'); END")
        }
        let model = f.makeModel()
        XCTAssertTrue(model.repo.adoptActiveDeviceId("B"))
        await model.retryScoringPreferenceRecompute()
        let held = try await canonicalRow(night, store: f.store)
        assertEditedRow(held, night: night, stages: "[]")
        XCTAssertNil(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey))
        XCTAssertTrue(model.intelligence.hasPendingPreferenceRecompute)
        try await f.store.registryWriter.write { try $0.execute(sql: "DROP TRIGGER fail_canonical_owner") }
        let reopened = try await f.reopen()
        XCTAssertTrue(reopened.repo.adoptActiveDeviceId("B"))
        await reopened.retryScoringPreferenceRecompute()
        let repaired = try await canonicalRow(night, store: f.store)
        assertEditedRow(repaired, night: night, stages: night.aStages)
        XCTAssertFalse(reopened.intelligence.hasPendingPreferenceRecompute)
        XCTAssertEqual(try f.inputCounts().children, 0)
        XCTAssertEqual(try f.inputCounts().position, 0)
    }

    func testHistoricalCanonicalHealKeepsActiveGenerationFence() async throws {
        let f = try await fixture(seed: ["noopExperimentalSleepV2": false])
        let night = try await editedNight(f)
        let model = f.makeModel()
        XCTAssertTrue(model.repo.adoptActiveDeviceId("B"))
        model.repo.preferenceRecoveryCheckpoint = { point in
            if case .sleepGravityRead = point {
                XCTAssertTrue(model.repo.adoptActiveDeviceId("C"))
                XCTAssertTrue(model.repo.adoptActiveDeviceId("B"))
            }
        }
        await model.retryScoringPreferenceRecompute()
        let held = try await canonicalRow(night, store: f.store)
        assertEditedRow(held, night: night, stages: "[]")
        XCTAssertTrue(model.intelligence.hasPendingPreferenceRecompute)
        XCTAssertNil(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey))
        model.repo.preferenceRecoveryCheckpoint = nil
        await model.retryScoringPreferenceRecompute()
        let repaired = try await canonicalRow(night, store: f.store)
        assertEditedRow(repaired, night: night, stages: night.aStages)
        XCTAssertFalse(model.intelligence.hasPendingPreferenceRecompute)
    }

    private actor MotionReads {
        private(set) var calls = 0
        func read(store: WhoopStore, owner: String, from: Int, to: Int) async throws -> (gravity: Int, aux: Int) {
            calls += 1
            if calls <= 2 { throw SyntheticFailure.unavailable }
            return try await store.stepDiagnosticMotionCounts(deviceId: owner, from: from, to: to)
        }
    }

    func testFailedMotionReadIsRetriedAtSameCycleKeyUntilRealStoreReadSucceeds() async throws {
        let f = try await fixture()
        let start = 1_800_057_600, end = start + 6 * 3600, now = end + 3600
        let day = AnalyticsEngine.dayString(end, offsetSec: 0)
        let stages = "[{\"start\":\(start),\"end\":\(end),\"stage\":\"light\"}]"
        _ = try await f.store.insertManualSleepSession(deviceId: "my-whoop-noop", startTs: start,
            endTs: end, efficiency: 1, stagesJSON: stages)
        _ = try await f.store.upsertMetricSeries([.init(day: day, key: DayCycleIntelligenceIntegration.onsetKey,
            value: Double(start))], deviceId: "my-whoop-noop")
        let steps = (0..<30).map { StepSample(ts: end + $0 * 10, counter: 100 + $0, activityClass: 1) }
        _ = try await f.store.insert(Streams(gravity: [GravitySample(ts: end + 1, x: 0, y: 0, z: 1)], steps: steps),
            deviceId: "my-whoop")
        let cache = DayCycleIntelligenceIntegration.Cache(), reads = MotionReads()
        let revision = await f.store.stepDataRevisionSignature(deviceId: "my-whoop", from: start, to: now)
        var successful: DayCycleIntelligenceIntegration.Result?
        for attempt in 0..<4 {
            let status = ScoringAnalysisPassStatus()
            var lines: [String] = []
            let result = await DayCycleIntelligenceIntegration.compute(nights: [], editedRows: [], store: f.store,
                candidates: [(owner: "my-whoop", priority: 0)], physiologyOwners: ["my-whoop"], workouts: [],
                windowStart: start, now: now, offsetSec: 0, habitualMidsleepSec: nil, ticksPerStep: 1,
                mode: .sleepOnset, cache: cache, profile: UserProfile(), maxHROverride: nil, effortMethod: .edwards,
                motionCountReader: { [store = f.store] in try await reads.read(store: store, owner: $0, from: $1, to: $2) },
                trace: { lines.append($0) }, onFailure: { status.recordFailure() })
            XCTAssertEqual(status.failed, attempt < 2)
            let calls = await reads.calls
            XCTAssertEqual(calls, min(attempt + 1, 3))
            let currentRevision = await f.store.stepDataRevisionSignature(deviceId: "my-whoop", from: start, to: now)
            XCTAssertEqual(currentRevision, revision)
            XCTAssertEqual(result.onsetByWakeDay[day], start)
            XCTAssertGreaterThan(try XCTUnwrap(result.stepsByWakeDay[day]), 0)
            if attempt >= 2 {
                XCTAssertTrue(lines.contains { $0.contains("gravitySamples=1") })
                if let successful { XCTAssertEqual(result.stepsByWakeDay, successful.stepsByWakeDay) }
                successful = result
            }
        }
        let productionDefault = await DayCycleIntelligenceIntegration.compute(nights: [], editedRows: [], store: f.store,
            candidates: [(owner: "my-whoop", priority: 0)], physiologyOwners: ["my-whoop"], workouts: [],
            windowStart: start, now: now, offsetSec: 0, habitualMidsleepSec: nil, ticksPerStep: 1,
            mode: .sleepOnset, cache: .init(), profile: UserProfile(), maxHROverride: nil, effortMethod: .edwards)
        XCTAssertEqual(productionDefault.stepsByWakeDay, successful?.stepsByWakeDay)
    }
}
