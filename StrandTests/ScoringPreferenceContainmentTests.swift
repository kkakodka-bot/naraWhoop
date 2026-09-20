import Foundation
import GRDB
import NoopPush
import StrandAnalytics
import WhoopProtocol
import WhoopStore
import XCTest
@testable import Strand

private func containmentFixtureBaseDirectory() throws -> URL {
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
final class ScoringPreferenceContainmentTests: XCTestCase {
    @MainActor private final class Barrier {
        var target: IntelligenceEngine.LifecycleCheckpoint = .beforeCompletion
        var entered: XCTestExpectation?
        private var continuation: CheckedContinuation<Void, Never>?
        func visit(_ point: IntelligenceEngine.LifecycleCheckpoint) async {
            guard point == target, let entered else { return }
            self.entered = nil
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @MainActor private final class Fixture {
        let root: URL
        let layout: AccountStorageLayout
        let defaults: UserDefaults
        var context: AccountSessionContext
        var store: WhoopStore
        var model: AppModel?
        var starts = 0
        var completions = 0
        var parks = 0
        var legacyToken: String?
        let barrier = Barrier()

        init() async throws {
            let temporary = try containmentFixtureBaseDirectory()
            root = temporary.appendingPathComponent("preference-containment-" + UUID().uuidString)
            context = .init(scope: try AccountScope(projectURL: "https://" + UUID().uuidString + ".invalid",
                userID: UUID().uuidString), generation: UUID())
            layout = .init(baseDirectory: root, scope: context.scope)
            try layout.prepare()
            defaults = try XCTUnwrap(UserDefaults(suiteName: layout.preferencesSuite))
            defaults.setPersistentDomain(["noopExperimentalSleepV2": false], forName: layout.preferencesSuite)
            store = try await WhoopStore(path: layout.databaseURL.path)
            try await store.bindAccountOwner(projectURL: context.scope.projectURL, userID: context.scope.userID)
        }

        func openModel() -> AppModel {
            let context = context, store = store
            let dependencies = ScoringPreferenceAppTestSupport.dependencies(context: context, isCurrent: { $0 == context })
            let driver = IntelligenceEngine.PreferenceRecomputeDriver(checkpoint: { [barrier] in
                await barrier.visit($0)
            }, markOwed: { [weak self] in
                guard let self else { return nil }
                self.starts += 1
                let token = UUID().uuidString
                self.legacyToken = token
                return token
            }, markCompleted: { [weak self] _, token in
                guard let self else { return false }
                self.completions += 1
                guard token == self.legacyToken else { return false }
                self.legacyToken = nil
                return true
            }, parkAttempt: { [weak self] token in
                guard let self, let token, token == self.legacyToken else { return false }
                self.parks += 1
                self.legacyToken = nil
                return true
            })
            let result = AppModel(storageLayout: layout, context: context, captureAllowed: false,
                openStore: { store }, scoringInputDependencies: dependencies,
                nativePreferenceCurrent: { $0 == context }, preferenceScoringEnabled: { false },
                preferenceRecomputeDriver: driver, isCurrent: { $0 == context })
            result.syncEngine.bind(result)
            model = result
            return result
        }

        func stop() async throws {
            guard let model else { return }
            let generic = model.shutdownForAccountChange()
            barrier.release()
            _ = await model.intelligence.runPreferenceProjection()
            let bleDrained = await model.ble.drainCaptureAfterAccountChange()
            XCTAssertTrue(bleDrained)
            if let generic { let drained = await generic.drain(); XCTAssertTrue(drained) }
            await model.scoringPreferences?.waitForRetirement()
            try await model.scoringInputs?.waitForRetirement()
            self.model = nil
        }

        func reopen() async throws -> AppModel {
            try await stop()
            try store.registryWriter.close()
            context = .init(scope: context.scope, generation: UUID())
            store = try await WhoopStore(path: layout.databaseURL.path)
            try await store.bindAccountOwner(projectURL: context.scope.projectURL, userID: context.scope.userID)
            return openModel()
        }

        func close() async throws {
            try await stop()
            try store.registryWriter.close()
            defaults.removePersistentDomain(forName: layout.preferencesSuite)
            try FileManager.default.removeItem(at: root)
        }

        func control() throws -> (serial: Int64, bytes: Data) {
            try store.registryWriter.read { db in
                let row = try XCTUnwrap(Row.fetchOne(db, sql:
                    "SELECT stateSerial,stateBytes FROM workoutPreferenceEvaluation WHERE singleton=1"))
                return (row["stateSerial"], row["stateBytes"])
            }
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

        func populateBaseline() async throws {
            try await populateNight()
            let offset = TimeZone.current.secondsFromGMT()
            let midnight = IntelligenceEngine.midnightLocal(Int(Date().timeIntervalSince1970), offsetSec: offset)
            let baseline = (2...16).map { day in
                DailyMetric(day: AnalyticsEngine.dayString(midnight - day * 86400, offsetSec: offset),
                    totalSleepMin: 420, efficiency: 0.9, deepMin: 70, remMin: 90, lightMin: 260,
                    disturbances: 1, restingHr: 60, avgHrv: 50, recovery: nil, strain: 4, exerciseCount: 0)
            }
            _ = try await store.upsertDailyMetrics(baseline, deviceId: "my-whoop")
        }

        func populateDuplicateSleep() async throws -> (start: Int, end: Int) {
            let midnight = IntelligenceEngine.midnightLocal(Int(Date().timeIntervalSince1970),
                offsetSec: TimeZone.current.secondsFromGMT())
            let start = midnight - 86400 + 3600, end = start + 21600
            let rows = [0, 60].map { shift in
                CachedSleepSession(startTs: start + shift, endTs: end, efficiency: 0.9,
                    restingHr: 60, avgHrv: 40, stagesJSON: nil)
            }
            _ = try await store.upsertSleepSessions(rows, deviceId: "my-whoop-noop")
            return (start, end)
        }

        func populateNight() async throws {
            let midnight = IntelligenceEngine.midnightLocal(Int(Date().timeIntervalSince1970),
                offsetSec: TimeZone.current.secondsFromGMT())
            let start = midnight - 86400 + 3600, duration = 6 * 3600
            let hr = (0..<duration).map { HRSample(ts: start + $0, bpm: 60 + ($0 / 300) % 3) }
            let rr = (0..<duration).map {
                RRInterval(ts: start + $0, rrMs: $0.isMultiple(of: 2) ? 960 : 1040, srcChannel: .whoop5Historical)
            }
            let gravity = stride(from: 0, to: duration, by: 10).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1) }
            _ = try await store.insert(Streams(hr: hr, rr: rr, gravity: gravity), deviceId: "my-whoop")
        }
    }

    private func fixture() async throws -> Fixture {
        try XCTSkipUnless(AppRuntimeMode.isUnitTesting)
        let f = try await Fixture()
        addTeardownBlock { @MainActor in try await f.close() }
        return f
    }

    private func row(start: Int, source: String = "manual", strain: Double? = 0,
                     sport: String = "running") -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + 600, sport: sport, source: source,
            durationS: 600, energyKcal: 1, avgHr: 120, maxHr: 150, strain: strain,
            distanceM: 1234, zonesJSON: "[1, 2]", notes: "synthetic retained bytes", steps: 234)
    }

    func testPopulatedLowKcalAndNilManualRowsRemainExactAndBlockFullCompletion() async throws {
        let f = try await fixture(), start = Int(Date().timeIntervalSince1970) - 7200
        let originals = [row(start: start), row(start: start + 1200, strain: nil)]
        _ = try await f.store.upsertWorkouts(originals, deviceId: "my-whoop")
        _ = try await f.store.insert(Streams(hr: (0..<1800).map { HRSample(ts: start + $0, bpm: 135) }), deviceId: "my-whoop")
        let model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        let stored = try await f.store.workouts(deviceId: "my-whoop", from: start, to: start + 1800, limit: 10)
        XCTAssertEqual(stored, originals)
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .evaluatedPartial)
        XCTAssertTrue(model.intelligence.hasPendingPreferenceRecompute)
        XCTAssertFalse(model.intelligence.hasRunnablePreferenceWork)
        XCTAssertNil(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey))
        XCTAssertEqual(f.completions, 0)
        XCTAssertEqual(f.parks, 1)
    }

    func testHeldRepeatedWakesRetainExactJobsWithoutNewAttemptsOrCoreTokens() async throws {
        let f = try await fixture(), start = Int(Date().timeIntervalSince1970) - 3600
        _ = try await f.store.upsertWorkouts([row(start: start)], deviceId: "other-stored-owner")
        let tokens = try await f.store.markJobsOwed(kinds: SyncJobKind.allCases.map(\.rawValue))
        let model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        let baseline = try f.control()
        let jobs = try await f.store.owedJobs()
        let starts = f.starts
        for _ in 0..<5 {
            let state = await model.intelligence.runPreferenceProjection()
            XCTAssertEqual(state, .evaluatedPartial)
            let runnable = await model.syncEngine.hasRunnableWork()
            XCTAssertFalse(runnable)
            let outstanding = await model.syncEngine.hasOwedWork()
            XCTAssertTrue(outstanding)
        }
        let retained = try await f.store.owedJobs()
        XCTAssertEqual(retained, jobs)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: retained.map { ($0.kind, $0.token) }), tokens)
        XCTAssertEqual(try f.control().serial, baseline.serial)
        XCTAssertEqual(try f.control().bytes, baseline.bytes)
        XCTAssertEqual(f.starts, starts)
        XCTAssertNil(f.legacyToken)
        XCTAssertEqual(f.completions, 0)
    }

    func testFiveHundredThirteenRowsYieldAfterFourPagesThenResumeWithoutAnotherCorePass() async throws {
        let f = try await fixture(), start = Int(Date().timeIntervalSince1970) - 86400
        _ = try await f.store.upsertWorkouts((0..<513).map { row(start: start + $0) }, deviceId: "stored-A")
        let model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        let first = model.intelligence.preferenceWorkDisposition
        XCTAssertEqual(first, .continuation)
        let starts = f.starts
        XCTAssertEqual(f.completions, 0)
        let second = await model.intelligence.runPreferenceProjection()
        XCTAssertEqual(second, .evaluatedPartial)
        XCTAssertEqual(f.starts, starts)
        let retained = try await f.store.workouts(deviceId: "stored-A", from: start, to: start + 513, limit: 600)
        XCTAssertEqual(retained.count, 513)
    }

    func testRepeatedDeferredAccountWakesDoNotRestartHeldCoreOrSettleSQLDebt() async throws {
        let f = try await fixture(), start = Int(Date().timeIntervalSince1970) - 3600
        let original = row(start: start, strain: nil)
        _ = try await f.store.upsertWorkouts([original], deviceId: "stored-A")
        let tokens = try await f.store.markJobsOwed(kinds: SyncJobKind.allCases.map(\.rawValue))
        let model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .evaluatedPartial)
        let baseline = try f.control()
        let jobs = try await f.store.owedJobs()
        let journal = try await f.store.recentSyncJournal()
        let starts = f.starts, parks = f.parks, completions = f.completions
        for _ in 0..<5 {
            await model.runDeferredRescoreIfOwed()
            XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .evaluatedPartial)
            XCTAssertFalse(model.intelligence.hasRunnablePreferenceWork)
        }
        let retained = try await f.store.owedJobs()
        let afterJournal = try await f.store.recentSyncJournal()
        let rows = try await f.store.workouts(deviceId: "stored-A", from: start, to: start, limit: 10)
        XCTAssertEqual(retained, jobs)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: retained.map { ($0.kind, $0.token) }), tokens)
        XCTAssertEqual(afterJournal, journal)
        XCTAssertEqual(try f.control().serial, baseline.serial)
        XCTAssertEqual(try f.control().bytes, baseline.bytes)
        XCTAssertEqual(rows, [original])
        XCTAssertEqual(f.starts, starts)
        XCTAssertEqual(f.parks, parks)
        XCTAssertEqual(f.completions, completions)
        XCTAssertNil(f.legacyToken)
    }

    func testColdHeldReceiptValidatesWithoutRepeatingCompletedCoreOrLosingRows() async throws {
        let f = try await fixture(), start = Int(Date().timeIntervalSince1970) - 3600
        let original = row(start: start, source: "manual", strain: nil)
        _ = try await f.store.upsertWorkouts([original], deviceId: "stored-A")
        let first = f.openModel()
        await first.retryScoringPreferenceRecompute()
        XCTAssertEqual(first.intelligence.preferenceWorkDisposition, .evaluatedPartial)
        let starts = f.starts
        let reopened = try await f.reopen()
        await reopened.retryScoringPreferenceRecompute()
        XCTAssertEqual(reopened.intelligence.preferenceWorkDisposition, .evaluatedPartial)
        XCTAssertEqual(f.starts, starts)
        XCTAssertEqual(f.completions, 0)
        let rows = try await f.store.workouts(deviceId: "stored-A", from: start, to: start, limit: 10)
        XCTAssertEqual(rows, [original])
    }

    func testCompletedReceiptCannotSettleJobAfterNewManualRow() async throws {
        let f = try await fixture()
        let token = try await f.store.markJobOwed(kind: SyncJobKind.rescore.rawValue)
        let model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        _ = try await f.store.upsertWorkouts([row(start: Int(Date().timeIntervalSince1970) - 3600)], deviceId: "stored-A")
        let settled = await model.intelligence.settlePreferenceRescoreJob(capturedToken: token)
        XCTAssertFalse(settled)
        let jobs = try await f.store.owedJobs()
        XCTAssertEqual(jobs.first { $0.kind == SyncJobKind.rescore.rawValue }?.token, token)
    }

    func testEmptyCompleteReceiptSettlesOnlyExactRescoreTokenNotDependentJobs() async throws {
        let f = try await fixture()
        let tokens = try await f.store.markJobsOwed(kinds: SyncJobKind.allCases.map(\.rawValue))
        let model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        let wrong = await model.intelligence.settlePreferenceRescoreJob(capturedToken: UUID().uuidString)
        XCTAssertFalse(wrong)
        let correct = await model.intelligence.settlePreferenceRescoreJob(capturedToken: try XCTUnwrap(tokens["rescore"]))
        XCTAssertTrue(correct)
        let jobs = try await f.store.owedJobs()
        XCTAssertFalse(jobs.contains { $0.kind == "rescore" })
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: jobs.map { ($0.kind, $0.token) }), tokens.filter { $0.key != "rescore" })
    }

    func testExplicitRetryAfterNewSQLTokenRunsFreshCoreWithoutRebasingPreference() async throws {
        let f = try await fixture()
        let oldToken = try await f.store.markJobOwed(kind: SyncJobKind.rescore.rawValue)
        let model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        let accepted = model.acceptedScoringPreferences?.position, starts = f.starts
        // Admission stores second-resolution bounds; make the later proposal observably different.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let newToken = try await f.store.markJobOwed(kind: SyncJobKind.rescore.rawValue)
        XCTAssertNotEqual(newToken, oldToken)
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        XCTAssertEqual(model.acceptedScoringPreferences?.position, accepted)
        XCTAssertEqual(f.starts, starts + 1)
        let stale = await model.intelligence.settlePreferenceRescoreJob(capturedToken: oldToken)
        XCTAssertFalse(stale)
        let current = await model.intelligence.settlePreferenceRescoreJob(capturedToken: newToken)
        XCTAssertTrue(current)
    }

    func testForeignDetectedSpellingCannotBecomeManagedComputedOutput() async throws {
        let f = try await fixture(), start = Int(Date().timeIntervalSince1970) - 3600
        let original = row(start: start, source: "my-whoop-noop", sport: "detected")
        _ = try await f.store.upsertWorkouts([original], deviceId: "foreign-owner")
        let model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .evaluatedPartial)
        let rows = try await f.store.workouts(deviceId: "foreign-owner", from: start, to: start, limit: 10)
        XCTAssertEqual(rows, [original])
    }

    func testCanonicalOwnerWithNonmanagedSourceSurvivesDetectedCleanup() async throws {
        let f = try await fixture(), start = Int(Date().timeIntervalSince1970) - 3600
        let original = row(start: start, source: "imported-custom", sport: "detected")
        _ = try await f.store.upsertWorkouts([original], deviceId: "my-whoop-noop")
        let model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .evaluatedPartial)
        let rows = try await f.store.workouts(deviceId: "my-whoop-noop", from: start, to: start, limit: 10)
        XCTAssertEqual(rows, [original])
        XCTAssertEqual(f.completions, 0)
    }

    func testExplicitForceRefreshesCoreButOrdinaryWakeReusesCompleteReceipt() async throws {
        let f = try await fixture(), model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        let raw = try await f.store.analysisFingerprint()
        let accepted = model.acceptedScoringPreferences?.position
        let starts = f.starts, completions = f.completions
        await model.intelligence.analyzeRecent(force: false)
        XCTAssertEqual(f.starts, starts)
        XCTAssertEqual(f.completions, completions)
        await model.intelligence.analyzeRecent(force: true)
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        XCTAssertEqual(f.starts, starts + 1)
        XCTAssertEqual(f.completions, completions + 1)
        XCTAssertEqual(model.acceptedScoringPreferences?.position, accepted)
        let afterRaw = try await f.store.analysisFingerprint()
        XCTAssertEqual(afterRaw, raw)
    }

    func testFailedForcedCoreCannotReuseOldReceiptAndExplicitRetryBypassesBackoff() async throws {
        let f = try await fixture()
        try await f.populateNight()
        let token = try await f.store.markJobOwed(kind: SyncJobKind.rescore.rawValue)
        let model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        XCTAssertFalse(model.intelligence.results.isEmpty)
        let raw = try await f.store.analysisFingerprint()
        let completed = f.completions
        try await f.store.registryWriter.write {
            try $0.execute(sql: "CREATE TRIGGER fail_containment_refresh BEFORE INSERT ON dailyMetric WHEN NEW.deviceId='my-whoop-noop' BEGIN SELECT RAISE(ABORT, 'synthetic refresh failure'); END")
        }
        await model.intelligence.analyzeRecent(force: true)
        XCTAssertTrue(model.intelligence.hasPendingPreferenceRecompute)
        XCTAssertEqual(f.completions, completed)
        guard case .retryAfter(let deadline) = model.intelligence.preferenceWorkDisposition else {
            return XCTFail("required persistence failure must retain bounded retry state")
        }
        XCTAssertGreaterThan(deadline, Int64(Date().timeIntervalSince1970))
        let settled = await model.intelligence.settlePreferenceRescoreJob(capturedToken: token)
        XCTAssertFalse(settled)
        let starts = f.starts
        await model.runDeferredRescoreIfOwed()
        XCTAssertEqual(f.starts, starts)
        try await f.store.registryWriter.write { try $0.execute(sql: "DROP TRIGGER fail_containment_refresh") }
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        XCTAssertEqual(f.starts, starts + 1)
        XCTAssertEqual(f.completions, completed + 1)
        let afterRaw = try await f.store.analysisFingerprint()
        XCTAssertEqual(afterRaw, raw)
    }

    func testRefreshInFlightCannotExposeOldCompletionToPreflightOrSettlement() async throws {
        let f = try await fixture()
        let token = try await f.store.markJobOwed(kind: SyncJobKind.rescore.rawValue)
        let model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        let completed = f.completions
        let entered = expectation(description: "forced refresh before new core witness")
        f.barrier.entered = entered
        let running = Task { await model.intelligence.analyzeRecent(force: true) }
        await fulfillment(of: [entered], timeout: 15)
        let disposition = await model.intelligence.preparePreferenceProjection()
        XCTAssertEqual(disposition, .busy)
        let settled = await model.intelligence.settlePreferenceRescoreJob(capturedToken: token)
        XCTAssertFalse(settled)
        let jobs = try await f.store.owedJobs()
        XCTAssertEqual(jobs.first { $0.kind == "rescore" }?.token, token)
        XCTAssertEqual(f.completions, completed)
        f.barrier.release()
        await running.value
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        XCTAssertEqual(f.completions, completed + 1)
    }

    private func assertSupersededPublication(at checkpoint: IntelligenceEngine.LifecycleCheckpoint) async throws {
        let f = try await fixture()
        try await f.populateBaseline()
        let model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        XCTAssertTrue(model.intelligence.results.contains { $0.recovery != nil })
        let beforeDays = model.intelligence.results.map(\.day)
        let beforeRecovery = model.intelligence.results.map(\.recovery)
        let beforeNote = model.intelligence.note
        let beforeCompleted = f.completions
        let beforeMirror = f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey)
        let raw = try await f.store.analysisFingerprint()
        f.barrier.target = checkpoint
        let oldEntered = expectation(description: "old accepted pass at \(checkpoint)")
        f.barrier.entered = oldEntered
        let reset = try XCTUnwrap(model.recalibrateChargeBaseline(now: Date().timeIntervalSince1970))
        _ = try await reset.acceptance()
        await fulfillment(of: [oldEntered], timeout: 20)
        let persisted = try await f.store.dailyMetrics(deviceId: "my-whoop-noop", from: "0000-01-01", to: "9999-12-31")
        // Deliberate derived-state sentinels in this fixture's captured profile/defaults only.
        model.profile.stepsHasBankedMotion = true
        model.profile.stepsCalibrationSampleDays = 97
        let second = try await model.completePreferenceAction([
            .init(key: .effortMethod, value: .text("BANISTER"))
        ]).acceptance()
        let refreshAfterAcceptance = model.repo.refreshSeq
        f.barrier.target = .beforeScorePersistence
        let newEntered = expectation(description: "successor held before its own primary persistence")
        f.barrier.entered = newEntered
        f.barrier.release()
        await fulfillment(of: [newEntered], timeout: 20)
        XCTAssertEqual(model.acceptedScoringPreferences?.position, second.position)
        XCTAssertEqual(model.intelligence.results.map(\.day), beforeDays)
        XCTAssertEqual(model.intelligence.results.map(\.recovery), beforeRecovery)
        XCTAssertEqual(model.intelligence.note, beforeNote)
        XCTAssertEqual(model.repo.refreshSeq, refreshAfterAcceptance,
            "a superseded outer AppModel task must not refresh old partial results either")
        XCTAssertTrue(model.profile.stepsHasBankedMotion)
        XCTAssertEqual(model.profile.stepsCalibrationSampleDays, 97)
        XCTAssertEqual(f.completions, beforeCompleted)
        XCTAssertEqual(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey), beforeMirror)
        let after = try await f.store.dailyMetrics(deviceId: "my-whoop-noop", from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(after, persisted, "no old primary write may start after accepted invalidation at the barrier")
        f.barrier.release()
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        XCTAssertFalse(model.intelligence.results.isEmpty)
        XCTAssertTrue(model.intelligence.results.allSatisfy { $0.recovery == nil })
        let afterRaw = try await f.store.analysisFingerprint()
        XCTAssertEqual(afterRaw, raw)
        XCTAssertEqual(try f.inputCounts().position, 2)
        XCTAssertEqual(try f.inputCounts().children, 0)
    }

    func testAcceptedSuccessorPreventsPostManagedCommitPublicationAndRefresh() async throws {
        try await assertSupersededPublication(at: .afterManagedWorkoutPersistence)
    }

    func testAcceptedSuccessorAtPrimaryBarrierPreventsOldScoreWrite() async throws {
        try await assertSupersededPublication(at: .beforeScorePersistence)
    }

    func testAcceptedSuccessorAfterCalibrationScanPreventsOldProfilePublication() async throws {
        try await assertSupersededPublication(at: .afterCalibrationScan)
    }

    func testActualDedupCancellationDisposesFollowupAndExplicitRetryCompletes() async throws {
        let f = try await fixture(), model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        let night = try await f.populateDuplicateSleep()
        let token = try await f.store.markJobOwed(kind: "rescore")
        let completed = f.completions
        let entered = expectation(description: "real dedup requested follow-up before cancellation")
        f.barrier.entered = entered
        let running = Task { await model.intelligence.runPreferenceProjection(mode: .refreshCore) }
        await fulfillment(of: [entered], timeout: 20)
        let deduped = try await f.store.sleepSessions(deviceId: "my-whoop-noop", from: night.start, to: night.end, limit: 10)
        XCTAssertEqual(deduped.count, 1, "exercise the actual stored overlap sweep, not a fake latch")
        running.cancel(); f.barrier.release(); _ = await running.value
        XCTAssertFalse(model.intelligence.rescoreInProgress)
        XCTAssertEqual(f.completions, completed)
        let retained = try await f.store.owedJobs()
        XCTAssertEqual(retained.first { $0.kind == "rescore" }?.token, token)
        let starts = f.starts
        await model.retryScoringPreferenceRecompute()
        XCTAssertGreaterThan(f.starts, starts)
        XCTAssertLessThanOrEqual(f.starts - starts, 2)
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        XCTAssertFalse(model.intelligence.rescoreInProgress)
        XCTAssertEqual(try f.inputCounts().position, 0)
        XCTAssertEqual(try f.inputCounts().children, 0)
    }

    func testActualDedupSupersededPassDoesNotLeaveLegacyLatchSet() async throws {
        let f = try await fixture(), model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        let night = try await f.populateDuplicateSleep()
        let token = try await f.store.markJobOwed(kind: "rescore")
        f.barrier.entered = expectation(description: "old pass has actually deduped")
        let entered = try XCTUnwrap(f.barrier.entered)
        let running = Task { await model.intelligence.runPreferenceProjection(mode: .refreshCore) }
        await fulfillment(of: [entered], timeout: 20)
        let deduped = try await f.store.sleepSessions(deviceId: "my-whoop-noop", from: night.start, to: night.end, limit: 10)
        XCTAssertEqual(deduped.count, 1)
        let accepted = try await model.completePreferenceAction([
            .init(key: .effortMethod, value: .text("BANISTER"))
        ]).acceptance()
        let starts = f.starts
        f.barrier.release(); _ = await running.value
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        XCTAssertFalse(model.intelligence.rescoreInProgress)
        XCTAssertGreaterThan(f.starts, starts)
        XCTAssertLessThanOrEqual(f.starts - starts, 2)
        XCTAssertEqual(model.acceptedScoringPreferences?.position, accepted.position)
        let jobs = try await f.store.owedJobs()
        XCTAssertEqual(jobs.first { $0.kind == "rescore" }?.token, token)
        XCTAssertEqual(try f.inputCounts().position, 1)
        XCTAssertEqual(try f.inputCounts().children, 0)
    }

    func testActualDedupThenManagedWriterFailureDoesNotWedgeRetry() async throws {
        let f = try await fixture()
        let night = try await f.populateDuplicateSleep()
        _ = try await f.store.upsertWorkouts([row(start: Int(Date().timeIntervalSince1970) - 3600,
            source: "my-whoop-noop", sport: "detected")], deviceId: "my-whoop-noop")
        try await f.store.registryWriter.write {
            try $0.execute(sql: "CREATE TRIGGER fail_dedup_managed BEFORE DELETE ON workout BEGIN SELECT RAISE(ABORT, 'synthetic managed failure after dedup'); END")
        }
        let token = try await f.store.markJobOwed(kind: "rescore")
        let model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        let deduped = try await f.store.sleepSessions(deviceId: "my-whoop-noop", from: night.start, to: night.end, limit: 10)
        XCTAssertEqual(deduped.count, 1)
        XCTAssertTrue(model.intelligence.hasPendingPreferenceRecompute)
        XCTAssertFalse(model.intelligence.rescoreInProgress)
        XCTAssertEqual(f.completions, 0)
        let jobs = try await f.store.owedJobs()
        XCTAssertEqual(jobs.first { $0.kind == "rescore" }?.token, token)
        try await f.store.registryWriter.write { try $0.execute(sql: "DROP TRIGGER fail_dedup_managed") }
        let starts = f.starts
        await model.retryScoringPreferenceRecompute()
        XCTAssertGreaterThan(f.starts, starts)
        XCTAssertLessThanOrEqual(f.starts - starts, 2)
        XCTAssertFalse(model.intelligence.rescoreInProgress)
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        XCTAssertEqual(try f.inputCounts().position, 0)
        XCTAssertEqual(try f.inputCounts().children, 0)
    }

    func testAcceptedPreferenceAtActualExportAttemptBarrierPreventsStageStart() async throws {
        let f = try await fixture(), model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        let token = try await f.store.markJobOwed(kind: "widgetPublish")
        let attempt = Barrier()
        let entered = expectation(description: "real job attempt returned before dependent stage")
        attempt.entered = entered
        var exports = 0
        model.syncEngine.dependentStageDriver = .init(afterAttempt: { _ in
            await attempt.visit(.beforeCompletion)
        }, perform: { _, _ in exports += 1; return true })
        let drain = Task { await model.syncEngine.drain(reason: .foreground) }
        addTeardownBlock { @MainActor in attempt.release(); await drain.value }
        await fulfillment(of: [entered], timeout: 15)
        let charged = try await f.store.owedJobs()
        XCTAssertEqual(charged.first { $0.kind == "widgetPublish" }?.attempts, 1)
        f.barrier.target = .beforeScorePersistence
        let successor = expectation(description: "new accepted core held before persistence")
        f.barrier.entered = successor
        let receipt = try await model.completePreferenceAction([
            .init(key: .effortMethod, value: .text("BANISTER"))
        ]).acceptance()
        await fulfillment(of: [successor], timeout: 20)
        attempt.release(); await drain.value
        XCTAssertEqual(exports, 0)
        XCTAssertEqual(model.acceptedScoringPreferences?.position, receipt.position)
        XCTAssertTrue(model.intelligence.hasPendingPreferenceRecompute)
        let retained = try await f.store.owedJobs()
        XCTAssertEqual(retained.first { $0.kind == "widgetPublish" }?.token, token)
        f.barrier.release()
        await model.retryScoringPreferenceRecompute()
        model.syncEngine.dependentStageDriver = .init(perform: { _, admission in
            guard await admission.validate() else { return false }
            exports += 1; return true
        })
        await model.syncEngine.drain(reason: .foreground)
        XCTAssertEqual(exports, 1)
        let completed = try await f.store.owedJobs()
        XCTAssertFalse(completed.contains { $0.kind == "widgetPublish" })
        XCTAssertEqual(try f.inputCounts().position, 1)
    }

    func testNewRawAndRescoreDebtAtActualExportAttemptRetainsBothTokens() async throws {
        let f = try await fixture(), model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        let token = try await f.store.markJobOwed(kind: "healthWriteback")
        let attempt = Barrier()
        let entered = expectation(description: "attempt precedes a new raw commit")
        attempt.entered = entered
        var exports = 0
        model.syncEngine.dependentStageDriver = .init(afterAttempt: { _ in
            await attempt.visit(.beforeCompletion)
        }, perform: { _, _ in exports += 1; return true })
        let drain = Task { await model.syncEngine.drain(reason: .foreground) }
        addTeardownBlock { @MainActor in attempt.release(); await drain.value }
        await fulfillment(of: [entered], timeout: 15)
        _ = try await f.store.insert(Streams(hr: [HRSample(ts: Int(Date().timeIntervalSince1970) - 60, bpm: 123)]),
                                     deviceId: "my-whoop")
        let rescore = try await f.store.markJobOwed(kind: "rescore")
        attempt.release(); await drain.value
        XCTAssertEqual(exports, 0)
        let retained = try await f.store.owedJobs()
        XCTAssertEqual(retained.first { $0.kind == "healthWriteback" }?.token, token)
        XCTAssertEqual(retained.first { $0.kind == "rescore" }?.token, rescore)
        XCTAssertEqual(try f.inputCounts().position, 0)
    }

    func testNewExportTokenAtActualAttemptCannotStartCapturedOldStage() async throws {
        let f = try await fixture(), model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        let old = try await f.store.markJobOwed(kind: "cloudPush")
        let attempt = Barrier()
        let entered = expectation(description: "old export attempt")
        attempt.entered = entered
        var exports = 0
        model.syncEngine.dependentStageDriver = .init(afterAttempt: { _ in
            await attempt.visit(.beforeCompletion)
        }, perform: { _, _ in exports += 1; return true })
        let drain = Task { await model.syncEngine.drain(reason: .foreground) }
        addTeardownBlock { @MainActor in attempt.release(); await drain.value }
        await fulfillment(of: [entered], timeout: 15)
        let new = try await f.store.markJobOwed(kind: "cloudPush")
        XCTAssertNotEqual(old, new)
        attempt.release(); await drain.value
        XCTAssertEqual(exports, 0)
        let rows = try await f.store.owedJobs()
        XCTAssertEqual(rows.first { $0.kind == "cloudPush" }?.token, new)
    }

    func testCapturedStageAdmissionRejectsPayloadAfterAcceptedChange() async throws {
        let f = try await fixture(), model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        let token = try await f.store.markJobOwed(kind: "widgetPublish")
        let payload = Barrier()
        let entered = expectation(description: "synthetic payload awaits under shared production admission")
        payload.entered = entered
        var enteredStage = 0, published = 0
        model.syncEngine.dependentStageDriver = .init(perform: { _, admission in
            enteredStage += 1
            await payload.visit(.beforeCompletion)
            guard await admission.validate() else { return false }
            published += 1; return true
        })
        let drain = Task { await model.syncEngine.drain(reason: .foreground) }
        addTeardownBlock { @MainActor in payload.release(); await drain.value }
        await fulfillment(of: [entered], timeout: 15)
        f.barrier.target = .beforeScorePersistence
        let successor = expectation(description: "new core pending during payload preparation")
        f.barrier.entered = successor
        _ = try await model.completePreferenceAction([.init(key: .hrvWindow, value: .text("deep"))]).acceptance()
        await fulfillment(of: [successor], timeout: 20)
        payload.release(); await drain.value
        XCTAssertEqual(enteredStage, 1)
        XCTAssertEqual(published, 0)
        let retained = try await f.store.owedJobs()
        XCTAssertEqual(retained.first { $0.kind == "widgetPublish" }?.token, token)
        f.barrier.release(); await model.retryScoringPreferenceRecompute()
    }

    func testExportOnlyRawDependencyAdvancesOneCoreWithoutInventingRescoreToken() async throws {
        let f = try await fixture(), model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        _ = try await f.store.insert(Streams(hr: [HRSample(ts: Int(Date().timeIntervalSince1970) - 60, bpm: 123)]),
                                     deviceId: "my-whoop")
        let token = try await f.store.markJobOwed(kind: "widgetPublish")
        let initialJobs = try await f.store.owedJobs()
        XCTAssertEqual(initialJobs.map(\.kind).sorted(), ["cloudPush", "widgetPublish"])
        let cloudToken = try XCTUnwrap(initialJobs.first { $0.kind == "cloudPush" }?.token)
        XCTAssertEqual(initialJobs.first { $0.kind == "widgetPublish" }?.token, token)
        let expectedTokens: [SyncJobKind: String] = [.cloudPush: cloudToken, .widgetPublish: token]
        let expectedStages: [SyncJobKind] = [.cloudPush, .widgetPublish]
        let state = await model.intelligence.preparePreferenceProjection()
        XCTAssertEqual(state, .needsCorePass)
        let starts = f.starts
        var exports = 0
        var observedStages: [SyncJobKind] = []
        model.syncEngine.dependentStageDriver = .init(perform: { stage, admission in
            guard let capturedToken = expectedTokens[stage] else {
                XCTFail("unexpected dependent stage: \(stage)"); return false
            }
            guard await admission.validate() else { return false }
            guard let jobs = try? await f.store.owedJobs() else {
                XCTFail("synthetic export must read its actual jobs"); return false
            }
            XCTAssertEqual(jobs.first { $0.kind == stage.rawValue }?.token, capturedToken)
            XCTAssertEqual(jobs.first { $0.kind == "widgetPublish" }?.token, token)
            XCTAssertFalse(jobs.contains { $0.kind == "rescore" })
            observedStages.append(stage)
            exports += 1; return true
        })
        await model.syncEngine.drain(reason: .foreground)
        XCTAssertEqual(f.starts, starts + 1)
        XCTAssertEqual(observedStages, expectedStages)
        XCTAssertEqual(exports, 2)
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        let retained = try await f.store.owedJobs()
        XCTAssertTrue(retained.isEmpty)
        XCTAssertEqual(try f.inputCounts().position, 0)
    }

    func testColdExportOnlyReceiptContinuesPastFourPagesWithoutNewCoreOrToken() async throws {
        let f = try await fixture()
        let tokens = try await f.store.markJobsOwed(kinds: ["rescore", "widgetPublish"])
        let model = f.openModel()
        f.barrier.target = .afterManagedWorkoutPersistence
        let committed = expectation(description: "core writer completed before synthetic retained membership")
        f.barrier.entered = committed
        let run = Task { await model.retryScoringPreferenceRecompute() }
        await fulfillment(of: [committed], timeout: 20)
        let start = Int(Date().timeIntervalSince1970) - 86400
        let originals = (0..<513).map { row(start: start + $0, source: "my-whoop-noop", sport: "detected") }
        _ = try await f.store.upsertWorkouts(originals, deviceId: "my-whoop-noop")
        f.barrier.release(); await run.value
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .continuation)
        let completed = await model.intelligence.runPreferenceProjection()
        XCTAssertEqual(completed, .complete)
        let settled = await model.intelligence.settlePreferenceRescoreJob(capturedToken: try XCTUnwrap(tokens["rescore"]))
        XCTAssertTrue(settled)
        let sealedControl = try f.control()
        let starts = f.starts
        let reopened = try await f.reopen()
        f.barrier.target = .beforePreferenceEvaluationPages
        let cold = expectation(description: "cold receipt membership must be re-read")
        f.barrier.entered = cold
        let prepare = Task { try await reopened.prepareScoringPreferences() }
        await fulfillment(of: [cold], timeout: 20)
        let joining = expectation(description: "caller joins the held cold invocation")
        let joined = Task {
            joining.fulfill()
            return await reopened.intelligence.runPreferenceProjection()
        }
        await fulfillment(of: [joining], timeout: 15)
        f.barrier.release()
        try await prepare.value
        let firstBudget = await joined.value
        XCTAssertEqual(firstBudget, .needsValidation)
        XCTAssertEqual(f.starts, starts, "cold verification is not a new physiological pass")
        let coldAdmission = await reopened.intelligence.capturePreferenceExportAdmission(expectedStore: f.store)
        XCTAssertNil(coldAdmission, "unfinished cold proof cannot authorize an export")
        XCTAssertTrue(reopened.intelligence.hasPendingPreferenceRecompute)
        let pendingJobs = try await f.store.owedJobs()
        let widgetJob = try XCTUnwrap(pendingJobs.first { $0.kind == "widgetPublish" })
        XCTAssertEqual(widgetJob.token, try XCTUnwrap(tokens["widgetPublish"]))
        XCTAssertEqual(widgetJob.attempts, 0)
        XCTAssertFalse(pendingJobs.contains { $0.kind == "rescore" })
        XCTAssertEqual(pendingJobs.count, 1)
        var exports = 0
        reopened.syncEngine.dependentStageDriver = .init(perform: { _, admission in
            guard await admission.validate() else { return false }
            exports += 1; return true
        })
        let runnable = await reopened.syncEngine.hasRunnableWork()
        XCTAssertTrue(runnable)
        XCTAssertTrue(reopened.intelligence.hasRunnablePreferenceWork)
        XCTAssertEqual(reopened.intelligence.preferenceWorkDisposition, .needsValidation)
        let pendingControl = try f.control()
        XCTAssertEqual(pendingControl.serial, sealedControl.serial)
        XCTAssertEqual(pendingControl.bytes, sealedControl.bytes)
        XCTAssertEqual(exports, 0)
        await reopened.syncEngine.drain(reason: .stateRestoration)
        XCTAssertEqual(exports, 1)
        XCTAssertEqual(f.starts, starts)
        XCTAssertEqual(reopened.intelligence.preferenceWorkDisposition, .complete)
        let jobs = try await f.store.owedJobs()
        XCTAssertTrue(jobs.isEmpty)
        let kept = try await f.store.workouts(deviceId: "my-whoop-noop", from: start, to: start + 513, limit: 600)
        XCTAssertEqual(kept, originals)
        XCTAssertEqual(try f.inputCounts().position, 0)
        XCTAssertEqual(try f.inputCounts().children, 0)
    }

    func testHeldExportOnlyDrainsDoNotRetryCoreOrChargeAttempt() async throws {
        let f = try await fixture(), start = Int(Date().timeIntervalSince1970) - 3600
        let original = row(start: start)
        _ = try await f.store.upsertWorkouts([original], deviceId: "stored-A")
        let token = try await f.store.markJobOwed(kind: "widgetPublish")
        let model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .evaluatedPartial)
        let starts = f.starts, baseline = try f.control()
        var exports = 0
        model.syncEngine.dependentStageDriver = .init(perform: { _, _ in exports += 1; return true })
        for _ in 0..<4 {
            await model.syncEngine.drain(reason: .foreground)
            let runnable = await model.syncEngine.hasRunnableWork()
            XCTAssertFalse(runnable)
        }
        XCTAssertEqual(exports, 0)
        XCTAssertEqual(f.starts, starts)
        XCTAssertEqual(try f.control().serial, baseline.serial)
        XCTAssertEqual(try f.control().bytes, baseline.bytes)
        let retained = try await f.store.owedJobs()
        XCTAssertEqual(retained.first { $0.kind == "widgetPublish" }?.token, token)
        XCTAssertEqual(retained.first { $0.kind == "widgetPublish" }?.attempts, 0)
        XCTAssertFalse(retained.contains { $0.kind == "rescore" })
        let kept = try await f.store.workouts(deviceId: "stored-A", from: start, to: start, limit: 10)
        XCTAssertEqual(kept, [original])
    }

    func testParkingAttemptUsesCapturedTokenAndDoesNotPublishCompletedTelemetry() throws {
        let suite = "containment-scheduler-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: RescoreBackgroundScheduler.owedKey)
        defaults.set("new", forKey: RescoreBackgroundScheduler.owedTokenKey)
        XCTAssertFalse(RescoreBackgroundScheduler.parkRescoreAttempt(owedToken: "old", defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: RescoreBackgroundScheduler.owedKey))
        XCTAssertTrue(RescoreBackgroundScheduler.parkRescoreAttempt(owedToken: "new", defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: RescoreBackgroundScheduler.owedKey))
        XCTAssertNil(defaults.object(forKey: RescoreBackgroundScheduler.lastPassSecondsKey))
    }

    /// Runs on the real Store writer, not MainActor. The input journal remains free to accept P2.
    private final class RetryPersistenceBarrier: TransactionObserver, @unchecked Sendable {
        struct Snapshot {
            var oldState: Data?
            var attemptedState: Data?
            var oldSerial: Int64?
            var coreFailures = 0
            var retryEntries = 0
            var retryRollbacks = 0
            var retryCommits = 0
            var timedOut = false
        }
        private let condition = NSCondition()
        private let entered: XCTestExpectation
        private let failRetryAfterRelease: Bool
        private var released = false
        private var retryTransaction = false
        private var state = Snapshot()

        init(entered: XCTestExpectation, failRetryAfterRelease: Bool) {
            self.entered = entered
            self.failRetryAfterRelease = failRetryAfterRelease
        }

        func failCoreOnce() -> Int {
            condition.lock(); defer { condition.unlock() }
            guard state.coreFailures == 0 else { return 0 }
            state.coreFailures += 1
            return 1
        }

        func retryWrite(new: Data, old: Data, serial: Int64) throws -> Int {
            let object = try JSONSerialization.jsonObject(with: new) as? [String: Any]
            guard object?["retry"] is [String: Any] else { return 0 }
            condition.lock(); defer { condition.unlock() }
            state.retryEntries += 1
            retryTransaction = true
            state.oldState = old; state.attemptedState = new; state.oldSerial = serial
            if state.retryEntries == 1 { entered.fulfill() }
            let deadline = Date().addingTimeInterval(30)
            while !released {
                if !condition.wait(until: deadline) { state.timedOut = true; return 1 }
            }
            return failRetryAfterRelease ? 1 : 0
        }

        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
        var snapshot: Snapshot { condition.lock(); defer { condition.unlock() }; return state }
        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
        func databaseDidChange(with event: DatabaseEvent) {}
        func databaseWillCommit() throws {}
        func databaseDidCommit(_ db: Database) {
            condition.lock(); defer { condition.unlock() }
            if retryTransaction { state.retryCommits += 1; retryTransaction = false }
        }
        func databaseDidRollback(_ db: Database) {
            condition.lock(); defer { condition.unlock() }
            if retryTransaction { state.retryRollbacks += 1; retryTransaction = false }
        }
    }

    private func installRetryPersistenceFailure(_ f: Fixture, barrier: RetryPersistenceBarrier) async throws {
        _ = try await f.store.upsertWorkouts([row(start: Int(Date().timeIntervalSince1970) - 3600,
            source: "my-whoop-noop", sport: "detected")], deviceId: "my-whoop-noop")
        try await f.store.registryWriter.write { db in
            db.add(transactionObserver: barrier, extent: .observerLifetime)
            db.add(function: DatabaseFunction("containmentFailCoreOnce", argumentCount: 0, pure: false) { _ in
                barrier.failCoreOnce()
            })
            db.add(function: DatabaseFunction("containmentHoldRetry", argumentCount: 3, pure: false) { values in
                guard let next = Data.fromDatabaseValue(values[0]),
                      let old = Data.fromDatabaseValue(values[1]),
                      let serial = Int64.fromDatabaseValue(values[2]) else {
                    throw NSError(domain: "SyntheticRetryBarrier", code: 1)
                }
                return try barrier.retryWrite(new: next, old: old, serial: serial)
            })
            try db.execute(sql: """
                CREATE TEMP TRIGGER containmentCoreFailure BEFORE DELETE ON workout
                WHEN OLD.deviceId='my-whoop-noop' AND containmentFailCoreOnce()=1
                BEGIN SELECT RAISE(ABORT, 'synthetic required core failure'); END
                """)
            try db.execute(sql: """
                CREATE TEMP TRIGGER containmentRetryFailure BEFORE UPDATE OF stateBytes ON workoutPreferenceEvaluation
                WHEN containmentHoldRetry(NEW.stateBytes, OLD.stateBytes, OLD.stateSerial)=1
                BEGIN SELECT RAISE(ABORT, 'synthetic same-target retry persistence failure'); END
                """)
        }
    }

    func testRevokedRealRetryTransactionCannotInstallBackoffOnAutomaticSuccessor() async throws {
        let f = try await fixture()
        let entered = expectation(description: "actual retry-state SQL UPDATE held before commit")
        let retry = RetryPersistenceBarrier(entered: entered, failRetryAfterRelease: false)
        try await installRetryPersistenceFailure(f, barrier: retry)
        let token = try await f.store.markJobOwed(kind: "rescore")
        let model = f.openModel()
        let running = Task { await model.retryScoringPreferenceRecompute() }
        addTeardownBlock { @MainActor in retry.release(); f.barrier.release(); await running.value }
        await fulfillment(of: [entered], timeout: 20)
        XCTAssertEqual(retry.snapshot.coreFailures, 1)
        XCTAssertEqual(retry.snapshot.retryEntries, 1)
        XCTAssertEqual(f.starts, 1)
        XCTAssertEqual(f.completions, 0)
        let oldPosition = try XCTUnwrap(model.acceptedScoringPreferences?.position)
        f.barrier.target = .beforeScorePersistence
        let successor = expectation(description: "P2 automatic successor starts without inherited backoff")
        f.barrier.entered = successor
        // This commits through the separate real input journal while WhoopStore's writer is held.
        let receipt = try await model.completePreferenceAction([
            .init(key: .effortMethod, value: .text("BANISTER"))
        ]).acceptance()
        XCTAssertNotEqual(receipt.position, oldPosition)
        XCTAssertNotNil(receipt.position.id)
        XCTAssertEqual(model.acceptedScoringPreferences?.position, receipt.position)
        retry.release()
        await fulfillment(of: [successor], timeout: 20)
        await running.value
        XCTAssertFalse(retry.snapshot.timedOut)
        XCTAssertEqual(retry.snapshot.retryRollbacks, 1, "existing permit/cancellation observer must reject the actual retry transaction")
        XCTAssertEqual(retry.snapshot.retryCommits, 0)
        XCTAssertEqual(f.starts, 2, "no explicit retry was used to start P2")
        XCTAssertEqual(f.completions, 0)
        XCTAssertNil(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey))
        if case .retryAfter = model.intelligence.preferenceWorkDisposition {
            XCTFail("P1's failed deferral must not publish a P2 retry deadline")
        }
        let jobs = try await f.store.owedJobs()
        XCTAssertEqual(jobs.first { $0.kind == "rescore" }?.token, token)
        let durable = try XCTUnwrap(JSONSerialization.jsonObject(with: f.control().bytes) as? [String: Any])
        XCTAssertNil(durable["retry"])
        let target = try XCTUnwrap(durable["target"] as? [String: Any])
        let request = try XCTUnwrap(target["request"] as? [String: Any])
        let preference = try XCTUnwrap(request["preference"] as? [String: Any])
        XCTAssertEqual((preference["sequence"] as? NSNumber)?.int64Value, receipt.position.sequence)
        XCTAssertEqual((preference["id"] as? String).flatMap(UUID.init(uuidString:)), receipt.position.id)
        XCTAssertEqual(try f.inputCounts().position, receipt.position.sequence)
        XCTAssertEqual(try f.inputCounts().children, 0)
        f.barrier.release()
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        XCTAssertEqual(model.acceptedScoringPreferences?.position, receipt.position)
        XCTAssertEqual(f.completions, 1)
        XCTAssertEqual(try f.inputCounts().position, receipt.position.sequence)
        let retained = try await f.store.owedJobs()
        XCTAssertEqual(retained.first { $0.kind == "rescore" }?.token, token)
    }

    func testSameTargetRealRetryPersistenceFailureRetainsFallbackAndExplicitRetry() async throws {
        let f = try await fixture()
        let entered = expectation(description: "same-target retry SQL held before injected failure")
        let retry = RetryPersistenceBarrier(entered: entered, failRetryAfterRelease: true)
        try await installRetryPersistenceFailure(f, barrier: retry)
        let token = try await f.store.markJobOwed(kind: "rescore")
        let model = f.openModel()
        let running = Task { await model.retryScoringPreferenceRecompute() }
        addTeardownBlock { @MainActor in retry.release(); await running.value }
        await fulfillment(of: [entered], timeout: 20)
        let accepted = try XCTUnwrap(model.acceptedScoringPreferences?.position)
        retry.release(); await running.value
        XCTAssertFalse(retry.snapshot.timedOut)
        XCTAssertEqual(retry.snapshot.coreFailures, 1)
        XCTAssertEqual(retry.snapshot.retryEntries, 1)
        XCTAssertEqual(retry.snapshot.retryRollbacks, 1)
        XCTAssertEqual(retry.snapshot.retryCommits, 0)
        guard case .retryAfter(let deadline) = model.intelligence.preferenceWorkDisposition else {
            return XCTFail("a genuine same-target retry persistence failure must retain bounded fallback")
        }
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertGreaterThan(deadline, now)
        XCTAssertLessThanOrEqual(deadline, now + 60)
        XCTAssertEqual(f.completions, 0)
        XCTAssertNil(f.defaults.data(forKey: IntelligenceEngine.preferenceCompletionKey))
        let control = try f.control()
        XCTAssertEqual(control.serial, retry.snapshot.oldSerial)
        XCTAssertEqual(control.bytes, retry.snapshot.oldState, "failed durable retry write must roll back")
        let attempted = try XCTUnwrap(retry.snapshot.attemptedState)
        let attemptedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: attempted) as? [String: Any])
        XCTAssertNotNil(attemptedObject["retry"], "barrier intercepted the real retry persistence, not an earlier admission")
        let starts = f.starts
        let preflight = await model.intelligence.preparePreferenceProjection()
        XCTAssertEqual(preflight, .retryAfter(deadline))
        await model.runDeferredRescoreIfOwed()
        XCTAssertEqual(f.starts, starts)
        XCTAssertEqual(try f.control().bytes, control.bytes)
        let held = try await f.store.owedJobs()
        XCTAssertEqual(held.first { $0.kind == "rescore" }?.token, token)
        XCTAssertEqual(model.acceptedScoringPreferences?.position, accepted)
        XCTAssertEqual(try f.inputCounts().children, 0)
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        XCTAssertEqual(f.starts, starts + 1)
        XCTAssertEqual(f.completions, 1)
        XCTAssertEqual(model.acceptedScoringPreferences?.position, accepted)
        XCTAssertEqual(try f.inputCounts().position, accepted.sequence)
        XCTAssertEqual(try f.inputCounts().children, 0)
    }

    func testActualStageBoundaryRevokesAfterValidationWithoutRevokingAccountWriter() async throws {
        let f = try await fixture(), model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        let token = try await f.store.markJobOwed(kind: "widgetPublish")
        let boundary = Barrier()
        let entered = expectation(description: "validated stage suspended before destination admission")
        boundary.entered = entered
        var captured: SyncEngine.DependentStageAdmission?
        var published = 0
        model.syncEngine.dependentStageDriver = .init(perform: { _, admission in
            guard await admission.validate() else { return false }
            captured = admission
            await boundary.visit(.beforeCompletion)
            do { try admission.checkBoundary() } catch { return false }
            published += 1
            return true
        })
        let drain = Task { await model.syncEngine.drain(reason: .foreground) }
        addTeardownBlock { @MainActor in boundary.release(); f.barrier.release(); await drain.value }
        await fulfillment(of: [entered], timeout: 15)
        let admission = try XCTUnwrap(captured)
        let stillCurrent = await admission.validate()
        XCTAssertTrue(stillCurrent, "re-reading the same complete head must preserve this capability")
        let allowedOffActor = await Task.detached {
            do { try admission.checkBoundary(); return true } catch { return false }
        }.value
        XCTAssertTrue(allowedOffActor)

        f.barrier.target = .beforeScorePersistence
        let successor = expectation(description: "P2 remains pending while old destination resumes")
        f.barrier.entered = successor
        let accepted = try await model.completePreferenceAction([
            .init(key: .effortMethod, value: .text("BANISTER"))
        ]).acceptance()
        await fulfillment(of: [successor], timeout: 20)
        XCTAssertThrowsError(try admission.checkBoundary()) { XCTAssertTrue($0 is CancellationError) }
        // This is a real ordinary Store write, proving preference revocation did not poison its fence.
        try await f.store.appendSyncJournal(wakeReason: "boundary-account-writer-control",
            stagesRun: [], stagesOwed: ["widgetPublish"], durationMs: 0)
        let journal = try await f.store.recentSyncJournal()
        XCTAssertTrue(journal.contains { $0.wakeReason == "boundary-account-writer-control" })
        boundary.release(); await drain.value
        XCTAssertEqual(published, 0)
        let retained = try await f.store.owedJobs()
        XCTAssertEqual(retained.first { $0.kind == "widgetPublish" }?.token, token)
        f.barrier.release(); await model.retryScoringPreferenceRecompute()
        XCTAssertThrowsError(try admission.checkBoundary(), "a revoked capability never becomes current again")
        var current: SyncEngine.DependentStageAdmission?
        model.syncEngine.dependentStageDriver = .init(perform: { _, admission in
            guard await admission.validate() else { return false }
            do { try admission.checkBoundary() } catch { return false }
            current = admission; published += 1; return true
        })
        await model.syncEngine.drain(reason: .foreground)
        XCTAssertEqual(published, 1)
        XCTAssertNoThrow(try XCTUnwrap(current).checkBoundary())
        let completed = try await f.store.owedJobs()
        XCTAssertFalse(completed.contains { $0.kind == "widgetPublish" })
        XCTAssertEqual(model.acceptedScoringPreferences?.position, accepted.position)
        XCTAssertEqual(try f.inputCounts().children, 0)
    }

    func testObservedMembershipChangeRevokesBoundaryAndPartialCannotMintAdmission() async throws {
        let f = try await fixture(), model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        let initial = await model.intelligence.capturePreferenceExportAdmission(expectedStore: f.store)
        let admission = try XCTUnwrap(initial)
        let check = model.intelligence.preferenceExportBoundaryCheck(admission)
        XCTAssertNoThrow(try check())
        let start = Int(Date().timeIntervalSince1970) - 3600
        let original = row(start: start)
        _ = try await f.store.upsertWorkouts([original], deviceId: "stored-A")
        let state = await model.intelligence.preparePreferenceProjection()
        XCTAssertNotEqual(state, .complete)
        XCTAssertThrowsError(try check()) { XCTAssertTrue($0 is CancellationError) }
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .evaluatedPartial)
        let partial = await model.intelligence.capturePreferenceExportAdmission(expectedStore: f.store)
        XCTAssertNil(partial)
        XCTAssertThrowsError(try check())
        let retained = try await f.store.workouts(deviceId: "stored-A", from: start, to: start, limit: 10)
        XCTAssertEqual(retained, [original])
        XCTAssertEqual(try f.inputCounts().position, 0)
        XCTAssertEqual(try f.inputCounts().children, 0)
    }

    func testOpaqueDependentSettlementRequiresCapturedStorePrerequisiteAndExactToken() async throws {
        let f = try await fixture(), other = try await fixture()
        let tokens = try await f.store.markJobsOwed(kinds: SyncJobKind.allCases.map(\.rawValue))
        let model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        let wrongStore = await model.intelligence.capturePreferenceExportAdmission(expectedStore: other.store)
        XCTAssertNil(wrongStore)
        let initial = await model.intelligence.capturePreferenceExportAdmission(expectedStore: f.store)
        let beforeRescore = try XCTUnwrap(initial)
        let rescoreToken = try XCTUnwrap(tokens["rescore"])
        let widgetToken = try XCTUnwrap(tokens["widgetPublish"])
        let wrongKind = await model.intelligence.settlePreferenceDependentJob(kind: .rescore,
            capturedToken: rescoreToken, admission: beforeRescore)
        XCTAssertFalse(wrongKind)
        let prerequisiteOwed = await model.intelligence.settlePreferenceDependentJob(kind: .widgetPublish,
            capturedToken: widgetToken, admission: beforeRescore)
        XCTAssertFalse(prerequisiteOwed)
        let owed = try await f.store.owedJobs()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: owed.map { ($0.kind, $0.token) }), tokens)
        let rescoreSettled = await model.intelligence.settlePreferenceRescoreJob(capturedToken: rescoreToken)
        XCTAssertTrue(rescoreSettled)
        let refreshed = await model.intelligence.capturePreferenceExportAdmission(expectedStore: f.store)
        let admission = try XCTUnwrap(refreshed)
        let replacement = try await f.store.markJobOwed(kind: "widgetPublish")
        XCTAssertNotEqual(replacement, widgetToken)
        let stale = await model.intelligence.settlePreferenceDependentJob(kind: .widgetPublish,
            capturedToken: widgetToken, admission: admission)
        XCTAssertFalse(stale)
        let stillOwed = try await f.store.owedJobs()
        XCTAssertEqual(stillOwed.first { $0.kind == "widgetPublish" }?.token, replacement)
        let settled = await model.intelligence.settlePreferenceDependentJob(kind: .widgetPublish,
            capturedToken: replacement, admission: admission)
        XCTAssertTrue(settled)
        let remaining = try await f.store.owedJobs()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: remaining.map { ($0.kind, $0.token) }),
                       tokens.filter { $0.key == "cloudPush" || $0.key == "healthWriteback" })
        let repeated = await model.intelligence.settlePreferenceDependentJob(kind: .widgetPublish,
            capturedToken: replacement, admission: admission)
        XCTAssertFalse(repeated)
        XCTAssertEqual(try f.inputCounts().position, 0)
        XCTAssertEqual(try f.inputCounts().children, 0)
    }

    private final class ExportSettlementBarrier: TransactionObserver, @unchecked Sendable {
        private let condition = NSCondition()
        private let entered: XCTestExpectation
        private var used = false, released = false, active = false
        private var commits = 0, rollbacks = 0, timedOut = false
        init(entered: XCTestExpectation) { self.entered = entered }
        func holdDeletion() -> Int {
            condition.lock(); defer { condition.unlock() }
            guard !used else { return 0 }
            used = true; active = true; entered.fulfill()
            let deadline = Date().addingTimeInterval(30)
            while !released {
                if !condition.wait(until: deadline) { timedOut = true; break }
            }
            return 0
        }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
        var snapshot: (commits: Int, rollbacks: Int, timedOut: Bool) {
            condition.lock(); defer { condition.unlock() }
            return (commits, rollbacks, timedOut)
        }
        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
        func databaseDidChange(with event: DatabaseEvent) {}
        func databaseWillCommit() throws {}
        func databaseDidCommit(_ db: Database) {
            condition.lock(); defer { condition.unlock() }
            if active { commits += 1; active = false }
        }
        func databaseDidRollback(_ db: Database) {
            condition.lock(); defer { condition.unlock() }
            if active { rollbacks += 1; active = false }
        }
    }

    func testActualSyncSettlementRollsBackWhenAcceptedPositionChangesBeforeCommit() async throws {
        let f = try await fixture(), model = f.openModel()
        await model.retryScoringPreferenceRecompute()
        let token = try await f.store.markJobOwed(kind: "widgetPublish")
        let entered = expectation(description: "real dependent DELETE held inside Store transaction")
        let barrier = ExportSettlementBarrier(entered: entered)
        try await f.store.registryWriter.write { db in
            db.add(transactionObserver: barrier, extent: .observerLifetime)
            db.add(function: DatabaseFunction("containmentHoldExport", argumentCount: 0) { _ in
                barrier.holdDeletion()
            })
            try db.execute(sql: """
                CREATE TEMP TRIGGER containmentExportSettlement BEFORE DELETE ON syncJob
                WHEN OLD.kind='widgetPublish'
                BEGIN SELECT containmentHoldExport(); END;
                """)
        }
        var delivered = 0
        model.syncEngine.dependentStageDriver = .init(perform: { _, admission in
            guard await admission.validate() else { return false }
            do { try admission.checkBoundary() } catch { return false }
            delivered += 1; return true
        })
        let drain = Task { await model.syncEngine.drain(reason: .foreground) }
        addTeardownBlock { @MainActor in barrier.release(); f.barrier.release(); await drain.value }
        await fulfillment(of: [entered], timeout: 20)
        XCTAssertEqual(delivered, 1, "the synthetic destination completed before SQL settlement")
        f.barrier.target = .beforeScorePersistence
        let successor = expectation(description: "new preference core held after old settlement rollback")
        f.barrier.entered = successor
        let accepted = try await model.completePreferenceAction([
            .init(key: .effortMethod, value: .text("BANISTER"))
        ]).acceptance()
        barrier.release()
        await fulfillment(of: [successor], timeout: 20)
        await drain.value
        XCTAssertFalse(barrier.snapshot.timedOut)
        XCTAssertEqual(barrier.snapshot.rollbacks, 1, "the real WPE commit observer must reject the old permit")
        XCTAssertEqual(barrier.snapshot.commits, 0)
        let retained = try await f.store.owedJobs()
        XCTAssertEqual(retained.first { $0.kind == "widgetPublish" }?.token, token)
        XCTAssertEqual(model.acceptedScoringPreferences?.position, accepted.position)
        f.barrier.release(); await model.retryScoringPreferenceRecompute()
        await model.syncEngine.drain(reason: .foreground)
        XCTAssertEqual(delivered, 2)
        let completed = try await f.store.owedJobs()
        XCTAssertFalse(completed.contains { $0.kind == "widgetPublish" })
        XCTAssertEqual(try f.inputCounts().position, accepted.position.sequence)
        XCTAssertEqual(try f.inputCounts().children, 0)
    }
}
