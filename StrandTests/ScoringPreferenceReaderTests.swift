import Foundation
import NoopPush
import StrandAnalytics
import WhoopProtocol
import WhoopStore
import XCTest
@testable import Strand

@MainActor
final class ScoringPreferenceReaderTests: XCTestCase {
    private actor StoreGate {
        let store: WhoopStore
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        init(store: WhoopStore, entered: XCTestExpectation) { self.store = store; self.entered = entered }
        func open() async -> WhoopStore {
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
            return store
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    private func context() throws -> AccountSessionContext {
        .init(scope: try AccountScope(projectURL: "https://reader-" + UUID().uuidString + ".invalid",
            userID: UUID().uuidString), generation: UUID())
    }

    private func globals(_ changes: [String: Any]) throws {
        try XCTSkipUnless(AppRuntimeMode.isUnitTesting, "requires isolated hermetic app defaults")
        let saved = changes.map { ($0.key, UserDefaults.standard.object(forKey: $0.key)) }
        addTeardownBlock {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for (key, value) in changes { UserDefaults.standard.set(value, forKey: key) }
    }

    private func defaults() throws -> UserDefaults {
        let name = "test.preference.readers." + UUID().uuidString
        let value = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }

    private func model(seed: [String: Any] = [:]) throws -> AppModel {
        try XCTSkipUnless(AppRuntimeMode.isUnitTesting, "requires hermetic app construction")
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let root = temporary.appendingPathComponent("preference-readers-" + UUID().uuidString)
        let context = try context(), layout = AccountStorageLayout(baseDirectory: root, scope: context.scope)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: layout.preferencesSuite))
        defaults.setPersistentDomain(seed, forName: layout.preferencesSuite)
        let model = AppModel(storageLayout: layout, context: context, captureAllowed: false,
            scoringInputDependencies: ScoringPreferenceAppTestSupport.dependencies(context: context,
                isCurrent: { $0 == context }), nativePreferenceCurrent: { $0 == context },
            preferenceScoringEnabled: { false }, isCurrent: { $0 == context })
        addTeardownBlock { @MainActor in
            let captured = model.shutdownForAccountChange()
            let bleDrained = await model.ble.drainCaptureAfterAccountChange()
            let genericDrained = await captured?.drain() ?? true
            XCTAssertTrue(bleDrained); XCTAssertTrue(genericDrained)
            await model.scoringPreferences?.waitForRetirement()
            try await model.scoringInputs?.waitForRetirement()
            defaults.removePersistentDomain(forName: layout.preferencesSuite)
            if captured == nil, FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        return model
    }

    func testRealAppReadersWaitForHydrationAndIgnorePoisonedGlobals() async throws {
        try globals(["noopBanisterEffort": true, "noopExperimentalSleepV2": false,
            "noopMotionAwareWake": true, "noopStressPersonalBaseline": true,
            "noopSpo2CandidateDisplay": false, "noop.hrvBaselineEpoch": 1234.5,
            "noop.recoveryBaselineEpoch": 6789.5])
        let model = try model()
        XCTAssertNil(model.intelligence.captureScoringReaderInputs())
        XCTAssertNil(model.repo.captureScoringReaderInputs())
        await model.intelligence.analyzeRecent(maxDays: 0)
        XCTAssertNil(model.intelligence.captureScoringReaderInputs())
        try await model.prepareScoringPreferences()
        let engine = try XCTUnwrap(model.intelligence.captureScoringReaderInputs())
        XCTAssertEqual(engine, model.repo.captureScoringReaderInputs())
        XCTAssertEqual(engine.algorithms, .init(banisterEffortEnabled: false, useSleepStagerV2: true,
            useMotionAwareWake: false, daytimePersonalBaselineEnabled: false, spo2CandidateDisplayEnabled: true))
        XCTAssertEqual(engine.hrvWindow, .whole)
        XCTAssertEqual(engine.hrvBaselineEpoch, 0)
        XCTAssertEqual(engine.recoveryBaselineEpoch, 0)
        XCTAssertEqual(engine.accepted?.position, .initial)
        XCTAssertEqual(model.scoringHrvBaselineEpoch, 0)
    }

    func testAcceptedReaderValueStaysImmutableAcrossActionAndRetirement() async throws {
        let model = try model()
        try await model.prepareScoringPreferences()
        let before = try XCTUnwrap(model.intelligence.captureScoringReaderInputs())
        let ticket = try model.completePreferenceAction([
            .init(key: .effortMethod, value: .text("BANISTER")),
            .init(key: .useSleepStagerV2, value: .boolean(false)),
            .init(key: .useMotionAwareWake, value: .boolean(true)),
            .init(key: .daytimePersonalBaselineEnabled, value: .boolean(true)),
            .init(key: .spo2CandidateDisplayEnabled, value: .boolean(false)),
            .init(key: .hrvWindow, value: .text("deep")),
            .init(key: .hrvBaselineEpoch, value: .number(1234.25)),
            .init(key: .recoveryBaselineEpoch, value: .number(6789.75))])
        _ = try await ticket.acceptance()
        let after = try XCTUnwrap(model.repo.captureScoringReaderInputs())
        XCTAssertEqual(after, model.intelligence.captureScoringReaderInputs())
        XCTAssertEqual(after.algorithms, .init(banisterEffortEnabled: true, useSleepStagerV2: false,
            useMotionAwareWake: true, daytimePersonalBaselineEnabled: true, spo2CandidateDisplayEnabled: false))
        XCTAssertEqual(after.hrvWindow, .deep)
        XCTAssertEqual(after.hrvBaselineEpoch, 1234.25)
        XCTAssertEqual(after.recoveryBaselineEpoch, 6789.75)
        XCTAssertEqual(model.scoringHrvBaselineEpoch, 1234.25)
        XCTAssertEqual(before.accepted?.position, .initial)
        XCTAssertEqual(before.hrvBaselineEpoch, 0)
        XCTAssertNotEqual(before, after)
        _ = model.shutdownForAccountChange()
        XCTAssertNil(model.repo.captureScoringReaderInputs())
        XCTAssertNil(model.intelligence.captureScoringReaderInputs())
        XCTAssertEqual(after.hrvBaselineEpoch, 1234.25, "captured values are not mutable runtime facades")
    }

    func testAccountRepositoryWithoutProviderCannotUseLegacyChoices() async throws {
        let context = try context()
        let temporary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let layout = AccountStorageLayout(baseDirectory: temporary.appendingPathComponent(UUID().uuidString), scope: context.scope)
        let repo = Repository(deviceId: "reader", storageLayout: layout)
        let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(defaults: try defaults()), deviceId: "reader")
        XCTAssertNil(repo.captureScoringReaderInputs())
        XCTAssertNil(engine.captureScoringReaderInputs())
        let result = await engine.recomputeFitnessAgeOnly()
        XCTAssertFalse(result)
        repo.shutdownForAccountChange(); engine.shutdownForAccountChange()
    }

    func testUnboundLocalReadersPreserveLegacyChoices() throws {
        try globals(["noopBanisterEffort": true, "noopExperimentalSleepV2": false,
            "noopMotionAwareWake": true, "noopStressPersonalBaseline": true,
            "noopSpo2CandidateDisplay": false, "noop.hrvBaselineEpoch": 1234.25,
            "noop.recoveryBaselineEpoch": 6789.75])
        let repo = Repository(deviceId: "legacy-reader")
        let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(defaults: try defaults()),
            deviceId: "legacy-reader", hrvWindow: { .deep })
        let captured = try XCTUnwrap(engine.captureScoringReaderInputs())
        XCTAssertNil(captured.accepted)
        XCTAssertEqual(captured.hrvWindow, .deep)
        XCTAssertEqual(captured.effortMethod, .banister)
        XCTAssertFalse(captured.algorithms.useSleepStagerV2)
        XCTAssertTrue(captured.algorithms.useMotionAwareWake)
        XCTAssertTrue(captured.algorithms.daytimePersonalBaselineEnabled)
        XCTAssertFalse(captured.algorithms.spo2CandidateDisplayEnabled)
        XCTAssertEqual(captured.hrvBaselineEpoch, 1234.25)
        XCTAssertEqual(captured.recoveryBaselineEpoch, 6789.75)
        XCTAssertEqual(repo.captureScoringReaderInputs()?.algorithms, captured.algorithms)
    }

    func testActualAnalysisReadsProviderOnceBeforeStoreSuspension() async throws {
        try globals([RescoreBackgroundScheduler.owedKey: false,
            RescoreBackgroundScheduler.owedTokenKey: "reader-fixture",
            RescoreBackgroundScheduler.lastPassSecondsKey: 0.0])
        let store = try await WhoopStore.inMemory(), owner = try context(), defaults = try defaults()
        let initial = ScoringPreferenceSnapshot.seed(context: owner, domain: ["noop.hrvBaselineEpoch": 1234.25])
        var current: ScoringPreferenceSnapshot? = initial
        var observed: [ScoringPreferenceSnapshot?] = []
        let gate = StoreGate(store: store, entered: expectation(description: "analysis suspended at actual store opener"))
        let repo = Repository(deviceId: "reader", openStore: { store }, scoringPreferences: { current })
        let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(defaults: defaults), deviceId: "reader",
            defaults: defaults, scoringPreferences: { observed.append(current); return current },
            analysisStoreProvider: { await gate.open() })
        let running = Task { await engine.analyzeRecent(maxDays: 0) }
        await fulfillment(of: [gate.entered], timeout: 5)
        current = .seed(context: owner, domain: ["noop.hrvBaselineEpoch": 9000.75, "noopBanisterEffort": true])
        await gate.release()
        await running.value
        XCTAssertEqual(observed, [initial], "the whole pass, including self-healing, must use its original capture")
        XCTAssertEqual(engine.configuredHrvWindow, .whole)
        engine.shutdownForAccountChange(); repo.shutdownForAccountChange()
    }

    func testActualRestageKeepsCapturedNativeRecipeAcrossOpen() async throws {
        let store = try await WhoopStore.inMemory(), owner = try context()
        let start = 1_700_000_000, duration = 6 * 3_600
        let hr = (0..<duration).map { HRSample(ts: start + $0, bpm: 52 + ($0 / 60) % 3) }
        let gravity = (0..<duration).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1) }
        _ = try await store.insert(Streams(hr: hr, gravity: gravity), deviceId: "reader")
        _ = try await store.insertManualSleepSession(deviceId: "reader-noop", startTs: start,
            endTs: start + duration, efficiency: nil, stagesJSON: nil)
        let expected = AnalyticsEngine.encodeStages(SleepStager.stageSession(start: start, end: start + duration,
            grav: gravity, hr: hr, rr: [], resp: []))
        let otherRecipe = AnalyticsEngine.encodeStages(SleepStagerV2.stageSession(start: start, end: start + duration,
            grav: gravity, hr: hr, rr: [], resp: []))
        XCTAssertNotEqual(expected, otherRecipe, "the fixture must discriminate actual native recipes")
        var current: ScoringPreferenceSnapshot? = .seed(context: owner, domain: ["noopExperimentalSleepV2": false])
        var reads = 0
        let gate = StoreGate(store: store, entered: expectation(description: "restage suspended at actual store opener"))
        let repo = Repository(deviceId: "reader", openStore: { await gate.open() },
            scoringPreferences: { reads += 1; return current })
        let running = Task { await repo.selfHealEditedStages(from: start, to: start + duration) }
        await fulfillment(of: [gate.entered], timeout: 5)
        current = .seed(context: owner, domain: ["noopExperimentalSleepV2": true])
        await gate.release()
        let rows = await running.value
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try XCTUnwrap(rows.first?.stagesJSON), expected)
        repo.shutdownForAccountChange()
    }

    func testActualWorkoutFillUsesCapturedEffortRecipeAcrossOpen() async throws {
        let store = try await WhoopStore.inMemory(), owner = try context()
        let start = Int(Date().timeIntervalSince1970) - 7200, duration = 3600
        let hr = (0..<duration).map { HRSample(ts: start + $0, bpm: 125) }
        _ = try await store.insert(Streams(hr: hr), deviceId: "reader")
        _ = try await store.upsertWorkouts([WorkoutRow(startTs: start, endTs: start + duration,
            sport: "Running", source: "manual", durationS: Double(duration), energyKcal: nil,
            avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)], deviceId: "reader")
        let expected = try XCTUnwrap(StrainScorer.strain(hr, maxHR: 190, method: .edwards, sex: "male"))
        let otherRecipe = try XCTUnwrap(StrainScorer.strain(hr, maxHR: 190, method: .banister, sex: "male"))
        XCTAssertNotEqual(expected, otherRecipe)
        var current: ScoringPreferenceSnapshot? = .seed(context: owner, domain: [:])
        var reads = 0
        let gate = StoreGate(store: store, entered: expectation(description: "workout read suspended at actual store opener"))
        let repo = Repository(deviceId: "reader", openStore: { await gate.open() },
            scoringPreferences: { reads += 1; return current })
        repo.strainProfile = .init(hrMax: 190, sex: "male")
        let running = Task { await repo.workoutRows(days: 1) }
        await fulfillment(of: [gate.entered], timeout: 5)
        current = .seed(context: owner, domain: ["noopBanisterEffort": true])
        repo.strainProfile = .init(hrMax: 150, sex: "female")
        await gate.release()
        let rows = await running.value
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try XCTUnwrap(rows.first?.strain), expected, accuracy: 0.0000001)
        repo.shutdownForAccountChange()
    }

    func testResetCaptionUsesOnlyExplicitEpoch() throws {
        try globals(["noop.hrvBaselineEpoch": 1234.25])
        XCTAssertNil(ChargeBreakdownFormat.currentCalibrationRestartCause(epoch: 0))
        XCTAssertEqual(ChargeBreakdownFormat.currentCalibrationRestartCause(epoch: 6789.75),
            ChargeBreakdownFormat.calibrationRestartCause(recalibratedOn:
                ChargeBreakdownFormat.recalibrationDay(epoch: 6789.75)))
    }

    func testOnlyAcceptedPublicationInvalidatesUnchangedRowCaches() async throws {
        let model = try model()
        let initial = model.repo.refreshSeq
        let held = try model.completePreferenceAction([.init(key: .effortMethod, value: .text("BANISTER"))])
        XCTAssertEqual(held.state, .held(.loading))
        XCTAssertEqual(model.repo.refreshSeq, initial)
        try await model.prepareScoringPreferences()
        let hydrated = model.repo.refreshSeq
        XCTAssertEqual(hydrated, initial + 1)
        let rows = model.repo.days
        model.repo.todayDayScopedLoadedSeq = hydrated
        let ticket = try model.completePreferenceAction([.init(key: .effortMethod, value: .text("BANISTER"))])
        XCTAssertEqual(model.repo.refreshSeq, hydrated, "enqueuing is not accepted publication")
        _ = try await ticket.acceptance()
        XCTAssertEqual(model.repo.refreshSeq, hydrated + 1)
        XCTAssertEqual(model.repo.days, rows, "row equality must not suppress a preference-only refresh")
        XCTAssertNotEqual(model.repo.todayDayScopedLoadedSeq, model.repo.refreshSeq,
                          "the old-method Today cache must miss the existing task/cache key")
        _ = model.shutdownForAccountChange()
        let retired = model.repo.refreshSeq
        model.repo.noteScoringPreferencesChanged()
        XCTAssertEqual(model.repo.refreshSeq, retired)
    }
}
