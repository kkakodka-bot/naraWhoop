import Foundation
import GRDB
import NoopPush
import StrandAnalytics
import WhoopProtocol
import WhoopStore
import XCTest
@testable import Strand

@MainActor
final class RepositoryPreferenceRecoveryTests: XCTestCase {
    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func record() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private actor Gate {
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func wait() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
        func release() { continuation?.resume(); continuation = nil }
    }

    private func owner() throws -> AccountSessionContext {
        .init(scope: try AccountScope(projectURL: "https://repository-recovery.invalid", userID: UUID().uuidString),
              generation: UUID())
    }

    private func repository(_ store: WhoopStore, device: String = "A",
                            preferences: (() -> ScoringPreferenceSnapshot?)? = nil,
                            opener: (@Sendable () async throws -> WhoopStore)? = nil) async throws -> Repository {
        let context = try owner()
        try await store.bindAccountOwner(projectURL: context.scope.projectURL, userID: context.scope.userID)
        let snapshot = ScoringPreferenceSnapshot.seed(context: context, domain: ["noopExperimentalSleepV2": false])
        let scratch = ProcessInfo.processInfo.environment["SCORING_PREFERENCE_SCRATCH"]
            ?? ProcessInfo.processInfo.environment["TMPDIR"]
        let base = scratch.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("repository-recovery-" + UUID().uuidString, isDirectory: true)
        let layout = AccountStorageLayout(baseDirectory: root, scope: context.scope)
        let repo = Repository(deviceId: device, storageLayout: layout, openStore: opener ?? { store },
                              scoringPreferences: preferences ?? { snapshot })
        addTeardownBlock { @MainActor in
            repo.shutdownForAccountChange()
            UserDefaults(suiteName: layout.preferencesSuite)?.removePersistentDomain(forName: layout.preferencesSuite)
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        return repo
    }

    private func apple(_ steps: Int, day: String? = nil) -> AppleDaily {
        .init(day: day ?? Repository.localDayKey(Date()), steps: steps, activeKcal: nil, basalKcal: nil, vo2max: nil,
              avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil)
    }

    private func workout(_ start: Int, source: String = "manual", strain: Double? = nil) -> WorkoutRow {
        .init(startTs: start, endTs: start + 3600, sport: "Running", source: source,
              durationS: 3600, energyKcal: nil, avgHr: nil, maxHr: nil, strain: strain,
              distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    private func sleepFixture(_ store: WhoopStore, device: String = "A") async throws -> (Int, Int, String) {
        let start = 1_700_000_000, duration = 6 * 3600
        let hr = (0..<duration).map { HRSample(ts: start + $0, bpm: 52 + ($0 / 60) % 3) }
        let gravity = (0..<duration).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1) }
        _ = try await store.insert(Streams(hr: hr, gravity: gravity), deviceId: device)
        _ = try await store.insertManualSleepSession(deviceId: device + "-noop", startTs: start,
            endTs: start + duration, efficiency: nil, stagesJSON: nil)
        let stages = try XCTUnwrap(AnalyticsEngine.encodeStages(SleepStager.stageSession(start: start, end: start + duration,
            grav: gravity, hr: hr, rr: [], resp: [])))
        XCTAssertNotEqual(stages, "[]")
        return (start, start + duration, stages)
    }

    private func sql(_ store: WhoopStore, _ statement: String) throws {
        try store.registryWriter.write { db in try db.execute(sql: statement) }
    }

    func testWarmActualAppleCacheIsUnavailableAfterRetirement() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        _ = try await store.upsertAppleDaily([apple(4321)], deviceId: "apple-health")
        let loaded = await repo.performAppleHealthLoad(seriesKeys: [], allowCache: false)
        XCTAssertEqual(loaded.appleRows.first?.steps, 4321)
        let warm = await repo.performAppleHealthLoad(seriesKeys: [], allowCache: true)
        XCTAssertEqual(warm.appleRows, loaded.appleRows)
        XCTAssertEqual(repo.loadFireCounts["appleHealth"], 1)
        repo.shutdownForAccountChange()
        let retired = await repo.performAppleHealthLoad(seriesKeys: [], allowCache: true)
        XCTAssertTrue(retired.appleRows.isEmpty)
        XCTAssertTrue(retired.series.isEmpty)
        XCTAssertNil(repo.appleHealthCache)
        XCTAssertEqual(repo.appleHealthLoadedSeq, -1)
        XCTAssertEqual(repo.appleHealthLoadedDayKey, "")
        XCTAssertEqual(repo.loadFireCounts["appleHealth"], 1)
        XCTAssertNil(repo.captureScoringReaderInputs())
    }

    func testWarmActualExplorerAndWidgetCachesAreUnavailableAfterRetirement() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, device: "my-whoop")
        let day = Repository.localDayKey(Date())
        _ = try await store.upsertMetricSeries([.init(day: day, key: "recovery", value: 71)], deviceId: "my-whoop")
        _ = try await store.upsertDailyMetrics([.init(day: day, totalSleepMin: nil, efficiency: nil,
            deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: 51, avgHrv: 65,
            recovery: 71, strain: nil, exerciseCount: nil)], deviceId: "my-whoop")
        await repo.refresh(days: 2)
        let loadedSeries = await repo.exploreAllSeries()
        let series = try XCTUnwrap(loadedSeries)
        XCTAssertTrue(series.values.contains { $0.contains { $0.value == 71 } })
        XCTAssertNotNil(repo.cachedWidgetAnchor())
        repo.todayHistoryWideLoadedSeq = repo.refreshSeq
        repo.todayDayScopedLoadedSeq = repo.refreshSeq
        repo.todayDayScopedLoadedDayKey = day
        repo.insightsLoadedSeq = repo.refreshSeq
        repo.insightsLoadedDayKey = day
        repo.shutdownForAccountChange()
        let retired = await repo.exploreAllSeries()
        XCTAssertNil(retired)
        XCTAssertNil(repo.cachedWidgetAnchor())
        XCTAssertNil(repo.todayHistoryWideCache)
        XCTAssertNil(repo.todayDayScopedCache)
        XCTAssertNil(repo.insightsCache)
        XCTAssertEqual(repo.todayHistoryWideLoadedSeq, -1)
        XCTAssertEqual(repo.todayDayScopedLoadedSeq, -1)
        XCTAssertEqual(repo.insightsLoadedSeq, -1)
        XCTAssertEqual(repo.todayDayScopedLoadedDayKey, "")
        XCTAssertEqual(repo.insightsLoadedDayKey, "")
    }

    func testRetirementAfterActualAppleReadCannotRestoreCache() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        _ = try await store.upsertAppleDaily([apple(7654)], deviceId: "apple-health")
        repo.preferenceRecoveryCheckpoint = { point in
            if case .appleReadComplete = point { repo.shutdownForAccountChange() }
        }
        let result = await repo.performAppleHealthLoad(seriesKeys: [], allowCache: false)
        XCTAssertTrue(result.appleRows.isEmpty)
        XCTAssertNil(repo.appleHealthCache)
        XCTAssertEqual(repo.appleHealthLoadedSeq, -1)
    }

    private func overlappingAppleLoads(changeSequence: Bool) async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        let day = Repository.localDayKey(Date())
        _ = try await store.upsertAppleDaily([apple(111)], deviceId: "apple-health")
        _ = try await store.upsertMetricSeries([.init(day: day, key: "steps", value: 111)], deviceId: "apple-health")
        let gate = Gate(expectation(description: "old SQL snapshot read"))
        var first = true
        repo.preferenceRecoveryCheckpoint = { point in
            if case .appleReadComplete = point, first { first = false; await gate.wait() }
        }
        let old = Task { await repo.performAppleHealthLoad(seriesKeys: ["steps"], allowCache: false) }
        await fulfillment(of: [gate.entered], timeout: 5)
        _ = try await store.upsertAppleDaily([apple(999)], deviceId: "apple-health")
        _ = try await store.upsertMetricSeries([.init(day: day, key: "steps", value: 999)], deviceId: "apple-health")
        let oldSeq = repo.refreshSeq
        if changeSequence { repo.noteScoringPreferencesChanged() }
        let newer = await repo.performAppleHealthLoad(seriesKeys: ["steps"], allowCache: false)
        XCTAssertEqual(newer.appleRows.first?.steps, 999)
        XCTAssertEqual(newer.series["steps"]?.first?.value, 999)
        await gate.release()
        let stale = await old.value
        XCTAssertTrue(stale.appleRows.isEmpty)
        XCTAssertTrue(stale.series.isEmpty)
        XCTAssertEqual(repo.appleHealthLoadedSeq, oldSeq + (changeSequence ? 1 : 0))
        XCTAssertEqual(repo.appleHealthLoadedDayKey, day)
        let cached = await repo.performAppleHealthLoad(seriesKeys: ["steps"], allowCache: true)
        XCTAssertEqual(cached.appleRows.first?.steps, 999)
        XCTAssertEqual(cached.series["steps"]?.first?.value, 999)
        XCTAssertEqual(repo.loadFireCounts["appleHealth"], 2)
    }

    func testOldAppleLoadCannotOverwriteNewSQLSnapshotAtSameSequence() async throws {
        try await overlappingAppleLoads(changeSequence: false)
    }

    func testOldAppleLoadCannotClaimNewAcceptedRefreshSequence() async throws {
        try await overlappingAppleLoads(changeSequence: true)
    }

    func testActiveSourceChangeInvalidatesWarmAndInflightAppleLoads() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        _ = try await store.upsertAppleDaily([apple(888)], deviceId: "apple-health")
        _ = await repo.performAppleHealthLoad(seriesKeys: [], allowCache: false)
        XCTAssertNotNil(repo.appleHealthCache)
        XCTAssertTrue(repo.adoptActiveDeviceId("B"))
        XCTAssertNil(repo.appleHealthCache)
        repo.preferenceRecoveryCheckpoint = { point in
            if case .appleReadComplete = point { _ = repo.adoptActiveDeviceId("A") }
        }
        let old = await repo.performAppleHealthLoad(seriesKeys: [], allowCache: false)
        XCTAssertTrue(old.appleRows.isEmpty)
        XCTAssertNil(repo.appleHealthCache)
        repo.preferenceRecoveryCheckpoint = nil
        let retry = await repo.performAppleHealthLoad(seriesKeys: [], allowCache: false)
        XCTAssertEqual(retry.appleRows.first?.steps, 888)
    }

    func testActualStagerCannotPublishIntoOtherSourceWithSameDetectedKey() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        let (start, end, expected) = try await sleepFixture(store)
        let bJSON = "[{\"start\":\(start),\"end\":\(end - 3600),\"stage\":\"light\"}]"
        _ = try await store.insertManualSleepSession(deviceId: "B-noop", startTs: start,
            endTs: end - 3600, efficiency: nil, stagesJSON: bJSON)
        let failure = Failures(), gate = Gate(expectation(description: "real A stager completed"))
        repo.preferenceRecoveryCheckpoint = { point in
            if case .sleepStaged = point { await gate.wait() }
        }
        let running = Task { await repo.selfHealEditedStages(from: start, to: end, onFailure: { failure.record() }) }
        await fulfillment(of: [gate.entered], timeout: 10)
        XCTAssertTrue(repo.adoptActiveDeviceId("B"))
        await gate.release()
        let aborted = await running.value
        XCTAssertTrue(aborted.isEmpty)
        XCTAssertGreaterThan(failure.count, 0)
        let aRows = try await store.sleepSessions(deviceId: "A-noop", from: start, to: end, limit: 10)
        let bRows = try await store.sleepSessions(deviceId: "B-noop", from: start, to: end, limit: 10)
        XCTAssertNil(aRows.first?.stagesJSON)
        XCTAssertEqual(bRows.first?.stagesJSON, bJSON)
        XCTAssertEqual(bRows.first?.endTs, end - 3600)
        XCTAssertNotEqual(expected, bJSON)
        repo.preferenceRecoveryCheckpoint = nil
        XCTAssertTrue(repo.adoptActiveDeviceId("A"))
        let retried = await repo.selfHealEditedStages(from: start, to: end)
        XCTAssertEqual(retried.first?.stagesJSON, expected)
        let bAfter = try await store.sleepSessions(deviceId: "B-noop", from: start, to: end, limit: 10)
        XCTAssertEqual(bAfter, bRows)
    }

    func testSourceABAWhileRawReadIsInFlightInvalidatesBatch() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        let (start, end, _) = try await sleepFixture(store)
        let failure = Failures()
        repo.preferenceRecoveryCheckpoint = { point in
            if case .sleepGravityRead = point {
                XCTAssertTrue(repo.adoptActiveDeviceId("B"))
                XCTAssertTrue(repo.adoptActiveDeviceId("A"))
            }
        }
        let result = await repo.selfHealEditedStages(from: start, to: end, onFailure: { failure.record() })
        XCTAssertTrue(result.isEmpty)
        XCTAssertGreaterThan(failure.count, 0)
        let rows = try await store.sleepSessions(deviceId: "A-noop", from: start, to: end, limit: 10)
        XCTAssertNil(rows.first?.stagesJSON)
    }

    func testRetirementAfterRealStagingLeavesEditedSQLUnchanged() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        let (start, end, _) = try await sleepFixture(store)
        let failure = Failures()
        repo.preferenceRecoveryCheckpoint = { point in
            if case .sleepStaged = point { repo.shutdownForAccountChange() }
        }
        let result = await repo.selfHealEditedStages(from: start, to: end, onFailure: { failure.record() })
        XCTAssertTrue(result.isEmpty)
        XCTAssertGreaterThan(failure.count, 0)
        let rows = try await store.sleepSessions(deviceId: "A-noop", from: start, to: end, limit: 10)
        XCTAssertNil(rows.first?.stagesJSON)
        XCTAssertEqual(rows.first?.endTs, end)
    }

    func testCapturedStagerRecipeAndRepeatNoOpUseActualSQL() async throws {
        let store = try await WhoopStore.inMemory(), context = try owner()
        let initial = ScoringPreferenceSnapshot.seed(context: context, domain: ["noopExperimentalSleepV2": false])
        var live = initial, captures = 0
        let repo = try await repository(store, preferences: { captures += 1; return live })
        let (start, end, expected) = try await sleepFixture(store)
        repo.preferenceRecoveryCheckpoint = { point in
            if case .sleepRowsRead = point {
                live = .seed(context: context, domain: ["noopExperimentalSleepV2": true])
            }
        }
        let failure = Failures()
        let first = await repo.selfHealEditedStages(from: start, to: end, onFailure: { failure.record() })
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(first.first?.stagesJSON, expected)
        XCTAssertEqual(failure.count, 0)
        repo.preferenceRecoveryCheckpoint = nil
        try sql(store, "CREATE TRIGGER reject_restage_repeat BEFORE UPDATE OF stagesJSON ON sleepSession BEGIN SELECT RAISE(ABORT, 'unexpected repeat write'); END")
        let repeatRows = await repo.selfHealEditedStages(from: start, to: end,
            preferences: .init(accepted: initial), onFailure: { failure.record() })
        XCTAssertEqual(repeatRows, first)
        XCTAssertEqual(captures, 1, "explicit captured inputs must not consult the provider")
        XCTAssertEqual(failure.count, 0, "equality must skip the SQL update, not swallow its failure")
    }

    func testMissingCapturedPreferencesFailsWithoutStagingOrGlobalFallback() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, preferences: { nil })
        let (start, end, _) = try await sleepFixture(store)
        let failure = Failures()
        let result = await repo.selfHealEditedStages(from: start, to: end, onFailure: { failure.record() })
        XCTAssertTrue(result.isEmpty)
        XCTAssertGreaterThan(failure.count, 0)
        let rows = try await store.sleepSessions(deviceId: "A-noop", from: start, to: end, limit: 10)
        XCTAssertNil(rows.first?.stagesJSON)
    }

    func testEngineWorkoutInputsAndExplicitNilProfileNeverRecapture() async throws {
        let store = try await WhoopStore.inMemory(), context = try owner()
        let accepted = ScoringPreferenceSnapshot.seed(context: context, domain: [:])
        var providerReads = 0
        let repo = try await repository(store, preferences: { providerReads += 1; return nil })
        let start = Int(Date().timeIntervalSince1970) - 7200
        let hr = (0..<3600).map { HRSample(ts: start + $0, bpm: 125) }
        _ = try await store.insert(Streams(hr: hr), deviceId: "A")
        _ = try await store.upsertWorkouts([workout(start)], deviceId: "A")
        repo.strainProfile = .init(hrMax: 150, sex: "female")
        let nilProfile = await repo.workoutRows(days: 1, preferences: .init(accepted: accepted), strainProfile: nil)
        XCTAssertEqual(providerReads, 0)
        XCTAssertNil(nilProfile.first?.strain)
        XCTAssertEqual(nilProfile.first?.avgHr, 125)
        let expected = try XCTUnwrap(StrainScorer.strain(hr, maxHR: 190, method: .edwards, sex: "male"))
        let result = await repo.workoutRows(days: 1, preferences: .init(accepted: accepted),
            strainProfile: .init(hrMax: 190, sex: "male"))
        XCTAssertEqual(providerReads, 0)
        XCTAssertEqual(try XCTUnwrap(result.first?.strain), expected, accuracy: 0.0000001)
        let stored = try await store.workouts(deviceId: "A", from: start, to: start + 3600, limit: 10)
        XCTAssertNil(stored.first?.strain, "fill remains display-only")
    }

    func testStoredWorkoutStrainIsNotReplacedByReadProjection() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        let start = Int(Date().timeIntervalSince1970) - 7200
        _ = try await store.insert(Streams(hr: (0..<3600).map { HRSample(ts: start + $0, bpm: 125) }), deviceId: "A")
        _ = try await store.upsertWorkouts([workout(start, strain: 8.75)], deviceId: "A")
        repo.strainProfile = .init(hrMax: 190, sex: "male")
        let result = await repo.workoutRows(days: 1)
        XCTAssertEqual(result.first?.strain, 8.75)
    }

    func testWorkoutRowsReadBeforeRetirementAreNotReturned() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        let start = Int(Date().timeIntervalSince1970) - 7200
        _ = try await store.upsertWorkouts([workout(start)], deviceId: "A")
        let failure = Failures()
        repo.preferenceRecoveryCheckpoint = { point in
            if case .workoutRowsRead = point { repo.shutdownForAccountChange() }
        }
        let result = await repo.workoutRows(days: 1, onFailure: { failure.record() })
        XCTAssertTrue(result.isEmpty)
        XCTAssertGreaterThan(failure.count, 0)
        let stored = try await store.workouts(deviceId: "A", from: start, to: start + 3600, limit: 10)
        XCTAssertEqual(stored.count, 1)
    }

    func testWorkoutSourceSwitchAbortsBeforeTraceReconciliation() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        let start = Int(Date().timeIntervalSince1970) - 7200
        _ = try await store.upsertWorkouts([workout(start)], deviceId: "A")
        let failure = Failures()
        repo.preferenceRecoveryCheckpoint = { point in
            if case .workoutRowsRead = point { _ = repo.adoptActiveDeviceId("B") }
        }
        let result = await repo.workoutRows(days: 1, onFailure: { failure.record() })
        XCTAssertTrue(result.isEmpty)
        XCTAssertGreaterThan(failure.count, 0)
    }

    func testRequiredStoreOpenFailuresReachEachDelegatedRecorder() async throws {
        struct OpenFailure: Error {}
        let store = try await WhoopStore.inMemory()
        let repo = try await repository(store, opener: { throw OpenFailure() })
        let daily = Failures(), sleep = Failures(), workout = Failures()
        _ = await repo.localDailyMetrics(fromDay: "2026-01-01", toDay: "2026-01-02", onFailure: { daily.record() })
        _ = await repo.selfHealEditedStages(from: 0, to: 1, onFailure: { sleep.record() })
        _ = await repo.workoutRows(onFailure: { workout.record() })
        XCTAssertGreaterThan(daily.count, 0)
        XCTAssertGreaterThan(sleep.count, 0)
        XCTAssertGreaterThan(workout.count, 0)
    }

    func testEmptySuccessfulSQLAndSparseSleepDoNotReportFailure() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        _ = try await store.insertManualSleepSession(deviceId: "A-noop", startTs: 1000, endTs: 2000,
            efficiency: nil, stagesJSON: nil)
        let failure = Failures()
        let daily = await repo.localDailyMetrics(fromDay: "2026-01-01", toDay: "2026-01-02", onFailure: { failure.record() })
        let sleep = await repo.selfHealEditedStages(from: 1000, to: 2000, onFailure: { failure.record() })
        let workouts = await repo.workoutRows(onFailure: { failure.record() })
        XCTAssertTrue(daily.isEmpty)
        XCTAssertTrue(workouts.isEmpty)
        XCTAssertEqual(sleep.count, 1)
        XCTAssertNil(sleep.first?.stagesJSON)
        XCTAssertEqual(failure.count, 0)
    }

    func testDailySQLFailureIsReportedWithExistingEmptyFallback() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        _ = await repo.storeHandle()
        try sql(store, "DROP TABLE dailyMetric")
        let failure = Failures()
        let result = await repo.localDailyMetrics(fromDay: "2026-01-01", toDay: "2026-01-02", onFailure: { failure.record() })
        XCTAssertTrue(result.isEmpty)
        XCTAssertGreaterThan(failure.count, 0)
    }

    func testSleepSessionReadFailureIsReported() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        _ = await repo.storeHandle()
        try sql(store, "DROP TABLE sleepSession")
        let failure = Failures()
        let result = await repo.selfHealEditedStages(from: 0, to: Int.max / 2, onFailure: { failure.record() })
        XCTAssertTrue(result.isEmpty)
        XCTAssertGreaterThan(failure.count, 0)
    }

    func testRequiredRawReadFailureCannotLookLikeSuccessfulSparseInput() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        let (start, end, _) = try await sleepFixture(store)
        _ = await repo.storeHandle()
        try sql(store, "DROP TABLE gravitySample")
        let failure = Failures()
        let result = await repo.selfHealEditedStages(from: start, to: end, onFailure: { failure.record() })
        XCTAssertEqual(result.count, 1, "ordinary display fallback is retained")
        XCTAssertNil(result.first?.stagesJSON)
        XCTAssertGreaterThan(failure.count, 0)
    }

    func testRestageWriteFailureReportsAndRetryReallyPersists() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        let (start, end, expected) = try await sleepFixture(store)
        try sql(store, "CREATE TRIGGER fail_restage BEFORE UPDATE OF stagesJSON ON sleepSession BEGIN SELECT RAISE(ABORT, 'injected update failure'); END")
        let failed = Failures()
        let result = await repo.selfHealEditedStages(from: start, to: end, onFailure: { failed.record() })
        XCTAssertNil(result.first?.stagesJSON)
        XCTAssertGreaterThan(failed.count, 0)
        try sql(store, "DROP TRIGGER fail_restage")
        let retryFailure = Failures()
        let retry = await repo.selfHealEditedStages(from: start, to: end, onFailure: { retryFailure.record() })
        XCTAssertEqual(retry.first?.stagesJSON, expected)
        XCTAssertEqual(retryFailure.count, 0)
    }

    func testWorkoutRegistryAndSQLReadFailuresAreNotHiddenByFallbacks() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        _ = await repo.storeHandle()
        try sql(store, "DROP TABLE pairedDevice")
        let registryFailure = Failures()
        _ = await repo.workoutRows(onFailure: { registryFailure.record() })
        XCTAssertGreaterThan(registryFailure.count, 0)
        try sql(store, "DROP TABLE workout")
        let queryFailure = Failures()
        let rows = await repo.workoutRows(onFailure: { queryFailure.record() })
        XCTAssertTrue(rows.isEmpty)
        XCTAssertGreaterThan(queryFailure.count, registryFailure.count)
    }

    func testWorkoutHRQueryFailureRetainsRowsButCannotCertifySuccess() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store)
        let start = Int(Date().timeIntervalSince1970) - 7200
        _ = try await store.upsertWorkouts([workout(start)], deviceId: "A")
        _ = await repo.storeHandle()
        try sql(store, "DROP TABLE hrSample")
        let failure = Failures()
        let rows = await repo.workoutRows(days: 1, onFailure: { failure.record() })
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.avgHr)
        XCTAssertGreaterThan(failure.count, 0)
    }

    private struct CanonicalFixture {
        let start: Int
        let adjustedStart: Int
        let end: Int
        let aStages: String
        let bStages: String
        let offset = -7 * 3600
        var wakeDay: String { AnalyticsEngine.dayString(end, offsetSec: offset) }
        func selection(rawOwner: String = "A") -> EditedSleepSourceSelection {
            .init(computedRowOwner: "my-whoop-noop", rawOwnerByWakeDay: [wakeDay: rawOwner],
                  offsetSeconds: offset)
        }
    }

    private func canonicalFixture(_ store: WhoopStore, start: Int = 1_700_000_000) async throws -> CanonicalFixture {
        let duration = 6 * 3600, adjustedStart = start + 900, end = start + duration
        let aHr = (0..<duration).map { HRSample(ts: start + $0, bpm: 52 + ($0 / 60) % 3) }
        let aGravity = (0..<duration).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1) }
        let bHr = (0..<duration).map { HRSample(ts: start + $0, bpm: 110 + ($0 / 60) % 20) }
        let bGravity = (0..<duration).map { GravitySample(ts: start + $0, x: $0 % 2 == 0 ? 1 : -1, y: 0, z: 0) }
        _ = try await store.insert(Streams(hr: aHr, gravity: aGravity), deviceId: "A")
        _ = try await store.insert(Streams(hr: bHr, gravity: bGravity), deviceId: "B")
        _ = try await store.insertManualSleepSession(deviceId: "my-whoop-noop", startTs: start,
            endTs: end, efficiency: 0.8, stagesJSON: nil)
        _ = try await store.applySleepEdit(deviceId: "my-whoop-noop", detectedStartTs: start,
            newStartTs: adjustedStart, newEndTs: end)
        for source in ["A-noop", "B-noop", "my-whoop"] {
            _ = try await store.insertManualSleepSession(deviceId: source, startTs: start,
                endTs: end - 1800, efficiency: 0.7, stagesJSON: "[]")
        }
        let aStages = try XCTUnwrap(AnalyticsEngine.encodeStages(SleepStager.stageSession(
            start: adjustedStart, end: end, grav: aGravity, hr: aHr, rr: [], resp: [])))
        let bStages = try XCTUnwrap(AnalyticsEngine.encodeStages(SleepStager.stageSession(
            start: adjustedStart, end: end, grav: bGravity, hr: bHr, rr: [], resp: [])))
        XCTAssertNotEqual(aStages, bStages, "the native fixture must distinguish the two raw owners")
        return .init(start: start, adjustedStart: adjustedStart, end: end, aStages: aStages, bStages: bStages)
    }

    private func canonicalRows(_ store: WhoopStore, _ fixture: CanonicalFixture,
                               source: String = "my-whoop-noop") async throws -> [CachedSleepSession] {
        try await store.sleepSessions(deviceId: source, from: fixture.start, to: fixture.end, limit: 10)
    }

    func testExplicitHistoricalRawOwnerStagesCanonicalRowAndPreservesEqualKeys() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, device: "B")
        let fixture = try await canonicalFixture(store)
        var before: [String: [CachedSleepSession]] = [:]
        for source in ["A-noop", "B-noop", "my-whoop"] {
            before[source] = try await canonicalRows(store, fixture, source: source)
        }
        let failures = Failures()
        let result = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end,
            selection: fixture.selection(), onFailure: { failures.record() })
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.stagesJSON, fixture.aStages)
        XCTAssertEqual(result.first?.startTs, fixture.start)
        XCTAssertEqual(result.first?.startTsAdjusted, fixture.adjustedStart)
        XCTAssertEqual(result.first?.endTs, fixture.end)
        XCTAssertEqual(result.first?.efficiency, 0.8)
        XCTAssertEqual(result.first?.userEdited, true)
        let persisted = try await canonicalRows(store, fixture)
        XCTAssertEqual(persisted, result)
        for source in ["A-noop", "B-noop", "my-whoop"] {
            let unchanged = try await canonicalRows(store, fixture, source: source)
            XCTAssertEqual(unchanged, before[source], source)
        }
        XCTAssertEqual(failures.count, 0)
    }

    func testExplicitCurrentRawOwnerStillWritesOnlyCanonicalNamespace() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, device: "B")
        let fixture = try await canonicalFixture(store)
        let bBefore = try await canonicalRows(store, fixture, source: "B-noop")
        let failures = Failures()
        let result = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end,
            selection: fixture.selection(rawOwner: "B"), onFailure: { failures.record() })
        XCTAssertEqual(result.first?.stagesJSON, fixture.bStages)
        let canonical = try await canonicalRows(store, fixture)
        let bAfter = try await canonicalRows(store, fixture, source: "B-noop")
        XCTAssertEqual(canonical, result)
        XCTAssertEqual(bAfter, bBefore)
        XCTAssertEqual(failures.count, 0)
    }

    func testExplicitCanonicalSingleSourceMatchesExistingStager() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, device: "my-whoop")
        let (start, end, expected) = try await sleepFixture(store, device: "my-whoop")
        let day = AnalyticsEngine.dayString(end, offsetSec: 0), failures = Failures()
        let result = await repo.selfHealEditedStages(from: start, to: end,
            selection: .init(computedRowOwner: "my-whoop-noop", rawOwnerByWakeDay: [day: "my-whoop"], offsetSeconds: 0),
            onFailure: { failures.record() })
        XCTAssertEqual(result.first?.stagesJSON, expected)
        XCTAssertEqual(failures.count, 0)
    }

    func testExplicitMissingLaterWakeDayFailsBeforeAnyRawReadOrStageWrite() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, device: "B")
        let fixture = try await canonicalFixture(store), secondStart = fixture.start + 86400
        _ = try await store.insertManualSleepSession(deviceId: "my-whoop-noop", startTs: secondStart,
            endTs: fixture.end + 86400, efficiency: nil, stagesJSON: nil)
        let before = try await store.sleepSessions(deviceId: "my-whoop-noop", from: fixture.start,
            to: fixture.end + 86400, limit: 10)
        var rawReads = 0
        repo.preferenceRecoveryCheckpoint = { point in
            if case .sleepGravityRead = point { rawReads += 1 }
        }
        let failures = Failures()
        let result = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end + 86400,
            selection: fixture.selection(), onFailure: { failures.record() })
        let after = try await store.sleepSessions(deviceId: "my-whoop-noop", from: fixture.start,
            to: fixture.end + 86400, limit: 10)
        XCTAssertEqual(result, before)
        XCTAssertEqual(after, before)
        XCTAssertEqual(rawReads, 0, "preflight must reject the entire incomplete selection")
        XCTAssertGreaterThan(failures.count, 0)
    }

    func testExplicitEmptySelectionNeverFallsBackToActiveOwner() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, device: "B")
        let fixture = try await canonicalFixture(store)
        let before = try await canonicalRows(store, fixture)
        let invalid: [EditedSleepSourceSelection] = [
            .init(computedRowOwner: "", rawOwnerByWakeDay: [fixture.wakeDay: "A"], offsetSeconds: fixture.offset),
            .init(computedRowOwner: " \n", rawOwnerByWakeDay: [fixture.wakeDay: "A"], offsetSeconds: fixture.offset),
            .init(computedRowOwner: "my-whoop-noop", rawOwnerByWakeDay: [:], offsetSeconds: fixture.offset),
            fixture.selection(rawOwner: ""), fixture.selection(rawOwner: " \n")
        ]
        var rawReads = 0
        repo.preferenceRecoveryCheckpoint = { point in
            if case .sleepGravityRead = point { rawReads += 1 }
        }
        for selection in invalid {
            let failures = Failures()
            _ = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end, selection: selection,
                onFailure: { failures.record() })
            XCTAssertGreaterThan(failures.count, 0)
            let after = try await canonicalRows(store, fixture)
            XCTAssertEqual(after, before)
        }
        XCTAssertEqual(rawReads, 0)
    }

    func testExplicitWakeDayUsesCapturedOffsetNotUTC() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, device: "B")
        let fixture = try await canonicalFixture(store)
        let utcDay = AnalyticsEngine.dayString(fixture.end, offsetSec: 0)
        XCTAssertNotEqual(utcDay, fixture.wakeDay)
        let wrong = Failures()
        let unchanged = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end,
            selection: .init(computedRowOwner: "my-whoop-noop", rawOwnerByWakeDay: [utcDay: "A"],
                             offsetSeconds: fixture.offset), onFailure: { wrong.record() })
        XCTAssertNil(unchanged.first?.stagesJSON)
        XCTAssertGreaterThan(wrong.count, 0)
        let correct = Failures()
        let result = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end,
            selection: fixture.selection(), onFailure: { correct.record() })
        XCTAssertEqual(result.first?.stagesJSON, fixture.aStages)
        XCTAssertEqual(correct.count, 0)
    }

    func testExplicitWakeDayUsesEndInsteadOfDetectedStart() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, device: "B")
        let fixture = try await canonicalFixture(store)
        let startDay = AnalyticsEngine.dayString(fixture.start, offsetSec: 0)
        let endDay = AnalyticsEngine.dayString(fixture.end, offsetSec: 0)
        XCTAssertNotEqual(startDay, endDay)
        let wrong = Failures()
        let unchanged = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end,
            selection: .init(computedRowOwner: "my-whoop-noop", rawOwnerByWakeDay: [startDay: "A"], offsetSeconds: 0),
            onFailure: { wrong.record() })
        XCTAssertNil(unchanged.first?.stagesJSON)
        XCTAssertGreaterThan(wrong.count, 0)
        let correct = Failures()
        let result = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end,
            selection: .init(computedRowOwner: "my-whoop-noop", rawOwnerByWakeDay: [endDay: "A"], offsetSeconds: 0),
            onFailure: { correct.record() })
        XCTAssertEqual(result.first?.stagesJSON, fixture.aStages)
        XCTAssertEqual(correct.count, 0)
    }

    func testExplicitKnownSparseOwnerIsNoOpWithoutDenseActiveFallback() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, device: "B")
        let fixture = try await canonicalFixture(store), failures = Failures()
        let before = try await canonicalRows(store, fixture)
        var staged = 0
        repo.preferenceRecoveryCheckpoint = { point in if case .sleepStaged = point { staged += 1 } }
        let result = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end,
            selection: fixture.selection(rawOwner: "known-sparse-A"), onFailure: { failures.record() })
        let after = try await canonicalRows(store, fixture)
        XCTAssertEqual(result, before)
        XCTAssertEqual(after, before)
        XCTAssertEqual(staged, 0)
        XCTAssertEqual(failures.count, 0)
    }

    func testExplicitCanonicalReadFailureCannotCertifyEmptyResult() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, device: "B")
        let fixture = try await canonicalFixture(store), failures = Failures()
        _ = await repo.storeHandle()
        try sql(store, "DROP TABLE sleepSession")
        let result = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end,
            selection: fixture.selection(), onFailure: { failures.record() })
        XCTAssertTrue(result.isEmpty)
        XCTAssertGreaterThan(failures.count, 0)
    }

    func testExplicitHistoricalRawReadFailureRetainsCanonicalRowAndReportsDebt() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, device: "B")
        let fixture = try await canonicalFixture(store), failures = Failures()
        let before = try await canonicalRows(store, fixture)
        _ = await repo.storeHandle()
        try sql(store, "DROP TABLE gravitySample")
        let result = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end,
            selection: fixture.selection(), onFailure: { failures.record() })
        let after = try await canonicalRows(store, fixture)
        XCTAssertEqual(result, before)
        XCTAssertEqual(after, before)
        XCTAssertGreaterThan(failures.count, 0)
    }

    func testExplicitCanonicalUpdateFailureRetriesExactSQLTarget() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, device: "B")
        let fixture = try await canonicalFixture(store)
        let before = try await canonicalRows(store, fixture)
        let bBefore = try await canonicalRows(store, fixture, source: "B-noop")
        try sql(store, "CREATE TRIGGER reject_canonical BEFORE UPDATE OF stagesJSON ON sleepSession WHEN OLD.deviceId = 'my-whoop-noop' BEGIN SELECT RAISE(ABORT, 'canonical update failed'); END")
        let failed = Failures()
        let result = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end,
            selection: fixture.selection(), onFailure: { failed.record() })
        XCTAssertEqual(result, before)
        XCTAssertGreaterThan(failed.count, 0)
        let rejected = try await canonicalRows(store, fixture)
        XCTAssertEqual(rejected, before)
        try sql(store, "DROP TRIGGER reject_canonical")
        let retryFailure = Failures()
        let retry = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end,
            selection: fixture.selection(), onFailure: { retryFailure.record() })
        let persisted = try await canonicalRows(store, fixture)
        let bAfter = try await canonicalRows(store, fixture, source: "B-noop")
        XCTAssertEqual(retry.first?.stagesJSON, fixture.aStages)
        XCTAssertEqual(persisted, retry)
        XCTAssertEqual(bAfter, bBefore)
        XCTAssertEqual(retryFailure.count, 0)
    }

    func testExplicitHistoricalOwnerStillRejectsActiveABADuringGravityRead() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, device: "B")
        let fixture = try await canonicalFixture(store), failures = Failures()
        let before = try await canonicalRows(store, fixture)
        repo.preferenceRecoveryCheckpoint = { point in
            if case .sleepGravityRead = point {
                XCTAssertTrue(repo.adoptActiveDeviceId("C"))
                XCTAssertTrue(repo.adoptActiveDeviceId("B"))
            }
        }
        let result = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end,
            selection: fixture.selection(), onFailure: { failures.record() })
        let after = try await canonicalRows(store, fixture)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(after, before)
        XCTAssertGreaterThan(failures.count, 0)
    }

    func testExplicitHistoricalOwnerStillRejectsActiveABAAfterRealStaging() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, device: "B")
        let fixture = try await canonicalFixture(store), failures = Failures()
        let before = try await canonicalRows(store, fixture)
        let bBefore = try await canonicalRows(store, fixture, source: "B-noop")
        repo.preferenceRecoveryCheckpoint = { point in
            if case .sleepStaged = point {
                XCTAssertTrue(repo.adoptActiveDeviceId("C"))
                XCTAssertTrue(repo.adoptActiveDeviceId("B"))
            }
        }
        let result = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end,
            selection: fixture.selection(), onFailure: { failures.record() })
        let after = try await canonicalRows(store, fixture)
        let bAfter = try await canonicalRows(store, fixture, source: "B-noop")
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(after, before)
        XCTAssertEqual(bAfter, bBefore)
        XCTAssertGreaterThan(failures.count, 0)
    }

    func testExplicitCanonicalStagingCannotWriteAfterRetirement() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, device: "B")
        let fixture = try await canonicalFixture(store), failures = Failures()
        let before = try await canonicalRows(store, fixture)
        repo.preferenceRecoveryCheckpoint = { point in
            if case .sleepStaged = point { repo.shutdownForAccountChange() }
        }
        let result = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end,
            selection: fixture.selection(), onFailure: { failures.record() })
        let after = try await canonicalRows(store, fixture)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(after, before)
        XCTAssertGreaterThan(failures.count, 0)
    }

    func testExplicitCanonicalRecipeCaptureAndRepeatNoOpUseActualSQL() async throws {
        let store = try await WhoopStore.inMemory(), context = try owner()
        var live = ScoringPreferenceSnapshot.seed(context: context, domain: ["noopExperimentalSleepV2": false])
        var captures = 0
        let repo = try await repository(store, device: "B", preferences: { captures += 1; return live })
        let fixture = try await canonicalFixture(store), failures = Failures()
        let preferences = try XCTUnwrap(repo.captureScoringReaderInputs())
        repo.preferenceRecoveryCheckpoint = { point in
            if case .sleepRowsRead = point {
                live = .seed(context: context, domain: ["noopExperimentalSleepV2": true])
            }
        }
        let result = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end, preferences: preferences,
            selection: fixture.selection(), onFailure: { failures.record() })
        XCTAssertEqual(result.first?.stagesJSON, fixture.aStages)
        XCTAssertEqual(captures, 1)
        repo.preferenceRecoveryCheckpoint = nil
        try sql(store, "CREATE TRIGGER reject_canonical_repeat BEFORE UPDATE OF stagesJSON ON sleepSession WHEN OLD.deviceId = 'my-whoop-noop' BEGIN SELECT RAISE(ABORT, 'unexpected canonical repeat write'); END")
        let repeated = await repo.selfHealEditedStages(from: fixture.start, to: fixture.end, preferences: preferences,
            selection: fixture.selection(), onFailure: { failures.record() })
        XCTAssertEqual(repeated, result)
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(failures.count, 0)
    }

    func testExplicitRawOwnerIsChosenIndependentlyForEachWakeDay() async throws {
        let store = try await WhoopStore.inMemory(), repo = try await repository(store, device: "B")
        let first = try await canonicalFixture(store)
        let second = try await canonicalFixture(store, start: first.start + 86400)
        let failures = Failures()
        let result = await repo.selfHealEditedStages(from: first.start, to: second.end,
            selection: .init(computedRowOwner: "my-whoop-noop",
                rawOwnerByWakeDay: [first.wakeDay: "A", second.wakeDay: "B"], offsetSeconds: first.offset),
            onFailure: { failures.record() })
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].stagesJSON, first.aStages)
        XCTAssertEqual(result[1].stagesJSON, second.bStages)
        XCTAssertEqual(result[0].startTsAdjusted, first.adjustedStart)
        XCTAssertEqual(result[1].startTsAdjusted, second.adjustedStart)
        XCTAssertEqual(failures.count, 0)
    }
}
