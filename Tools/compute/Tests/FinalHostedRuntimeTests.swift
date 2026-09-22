import XCTest
import SwiftUI
import GRDB
import NoopPush
import WhoopProtocol
import WhoopStore
@testable import Strand

/// Runs in the shipped app host with its real final-mode Info.plist. No task-local/reference
/// override: detached lifecycle work is subject to the same policy as foreground work.
@MainActor
final class FinalHostedRuntimeTests: XCTestCase {
    private func fixture() async throws -> (AppModel, WhoopStore) {
        XCTAssertTrue(PhoneComputeRuntime.isFinalHosted)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NOOPFinalHostedCompute") as? Bool, true)
        XCTAssertNotEqual(ProcessInfo.processInfo.environment["NOOP_COMPUTE_REFERENCE_TESTS"], "1")
        let scope = try AccountScope(projectURL: "https://\(UUID().uuidString).invalid", userID: UUID().uuidString)
        let context = AccountSessionContext(scope: scope, generation: UUID())
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NARA_TEST_FIXTURE_ROOT"]!)
            .appendingPathComponent("final-runtime-\(UUID().uuidString)")
        let layout = AccountStorageLayout(baseDirectory: base, scope: scope)
        try layout.prepare()
        let store = try await WhoopStore(path: layout.databaseURL.path)
        try await store.bindAccountOwner(projectURL: scope.projectURL, userID: scope.userID)
        try await CloudCaptureScope.prepareStore(store.registryWriter, legacyPath: nil)
        let model = AppModel(storageLayout: layout, context: context, captureAllowed: false,
            openStore: { store },
            scoringInputDependencies: ScoringPreferenceAppTestSupport.dependencies(context: context, isCurrent: { $0 == context }),
            nativePreferenceCurrent: { $0 == context }, preferenceScoringEnabled: { false },
            resourceBudget: ResourceBudget(cooldown: 0, thermal: { 0 }, lowPower: { false }), isCurrent: { $0 == context })
        model.syncEngine.bind(model)
        addTeardownBlock { @MainActor in
            let generic = model.shutdownForAccountChange()
            _ = await model.ble.drainCaptureAfterAccountChange()
            _ = await generic?.drain()
            await model.scoringPreferences?.waitForRetirement()
            try await model.scoringInputs?.waitForRetirement()
            try store.registryWriter.close()
            UserDefaults(suiteName: layout.preferencesSuite)?.removePersistentDomain(forName: layout.preferencesSuite)
            try FileManager.default.removeItem(at: base)
        }
        return (model, store)
    }

    private func assertZero(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        let counters = PhoneComputeRuntime.counters()
        XCTAssertTrue(counters.executions.isEmpty, "\(path): \(counters.executions)", file: file, line: line)
        print("FINAL_HOSTED_ZERO path=\(path) executions=0 denied=\(counters.denied.keys.sorted())")
    }

    func testColdLaunchForegroundBackfillPreferencesAndDiagnosticsNeverScore() async throws {
        PhoneComputeRuntime.resetTestCounters()
        let (model, store) = try await fixture()
        let now = Int(Date().timeIntervalSince1970)
        _ = try await store.insert(Streams(hr: [HRSample(ts: now - 5, bpm: 72)],
            rr: [RRInterval(ts: now - 5, rrMs: 800, srcChannel: .whoop5Historical)]), deviceId: model.repo.deviceId)
        model.setForeground(true)
        await model.repo.refresh()
        await model.intelligence.analyzeRecent(force: true)
        await model.retryScoringPreferenceRecompute()
        _ = await model.intelligence.recomputeFitnessAgeOnly()
        await model.intelligence.runEffortRescoreIfNeeded()
        _ = await model.reevaluateIllness()?.value
        model.evaluateStrainTarget()
        model.setForeground(false); model.setForeground(true)
        XCTAssertTrue(model.intelligence.results.isEmpty)
        let habitual = await model.repo.habitualMidsleepSec()
        let detected = await model.repo.autoDetectCandidate()
        XCTAssertNil(habitual); XCTAssertNil(detected)
        let raw = try await store.hrSamples(deviceId: model.repo.deviceId, from: now - 10, to: now, limit: 10)
        XCTAssertEqual(raw.map(\.bpm), [72])
        assertZero("cold_launch_foreground_background_backfill_preferences_diagnostics")
    }

    func testRawUploadRemainsRunnableWithAllLocalAnalyticsDisabled() async throws {
        PhoneComputeRuntime.resetTestCounters()
        let (model, store) = try await fixture()
        let now = Int(Date().timeIntervalSince1970)
        _ = try await store.insert(Streams(hr: [HRSample(ts: now, bpm: 123)]), deviceId: model.repo.deviceId)
        let token = try await store.markJobOwed(kind: "cloudPush")
        _ = try await store.markJobOwed(kind: "rescore")
        var delivered = 0
        model.syncEngine.dependentStageDriver = .init(perform: { stage, admission in
            XCTAssertEqual(stage, .cloudPush)
            guard await admission.validate() else { return false }
            do {
                try admission.checkBoundary()
                let raw = try await store.hrSamples(deviceId: model.repo.deviceId, from: now, to: now, limit: 10)
                XCTAssertEqual(raw.map(\.bpm), [123])
                delivered += 1
                return true
            } catch { XCTFail("\(error)"); return false }
        })
        await model.syncEngine.drain(reason: .foreground)
        XCTAssertEqual(delivered, 1)
        let jobs = try await store.owedJobs()
        XCTAssertFalse(jobs.contains { $0.kind == "cloudPush" && $0.token == token })
        assertZero("durable_raw_upload_with_local_analytics_disabled")
    }

    func testWorkoutLiveSessionBiofeedbackAndAdvancedScreensDoNotInfer() async throws {
        PhoneComputeRuntime.resetTestCounters()
        let (model, _) = try await fixture()
        model.startWorkout(sport: "Other")
        XCTAssertNotNil(model.activeWorkout)
        model.toggleWorkoutPause(); model.toggleWorkoutPause()
        model.endWorkout()
        XCTAssertNil(model.lastWorkout?.strain)
        let runner = LiveSessionRunner()
        runner.start(model: model, repo: model.repo, ble: model.ble, profile: model.profile)
        XCTAssertNil(runner.output); XCTAssertNil(runner.baseBand)
        XCTAssertNil(runner.end()); XCTAssertTrue(runner.finished)
        let biofeedback = BiofeedbackController(model: model, live: model.live)
        biofeedback.startCalmMe()
        XCTAssertNil(biofeedback.calmTargetBpm); XCTAssertFalse(biofeedback.running)
        biofeedback.stop()
        XCTAssertNil(HRVSnapshotView.meanHR(meanNN: 1000))
        let content = VStack {
            CanonicalPhysiologySection(families: Array(ServerCanonicalResults.familyMetrics.keys).sorted())
            LiveWorkoutView(onClose: {})
            HRVSnapshotView()
        }.environmentObject(model).environmentObject(model.repo).environmentObject(model.live)
            .environmentObject(model.profile).frame(width: 600, height: 1200)
        XCTAssertNotNil(ImageRenderer(content: content).nsImage)
        assertZero("workout_start_end_live_session_biofeedback_spot_advanced_render")
    }

    func testSleepEditsDeviceSwitchAndHistoricalMissingnessCannotReconstruct() async throws {
        PhoneComputeRuntime.resetTestCounters()
        let (model, _) = try await fixture()
        let now = Int(Date().timeIntervalSince1970)
        await model.repo.editSleepTimes(detectedStartTs: now - 3600, oldEndTs: now - 1,
            storedStagesJSON: nil, newStartTs: now - 1800, newEndTs: now - 1)
        let deleted = await model.repo.deleteSleepSession(detectedStartTs: now - 3600, endTs: now - 1)
        XCTAssertNil(deleted)
        _ = model.repo.adoptActiveDeviceId("other-device")
        await model.repo.refresh()
        let history = await model.repo.series(key: "sleep_performance", source: "my-whoop-noop", fullHistory: true)
        XCTAssertTrue(history.isEmpty)
        XCTAssertTrue(model.repo.serverPresentation.hasServerOwnership)
        assertZero("sleep_edit_delete_device_switch_historical_empty_day")
    }
}
