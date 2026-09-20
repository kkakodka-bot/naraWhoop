import Foundation
import GRDB
import WhoopStore
import XCTest
@testable import Strand

@MainActor
final class IntelligenceRuntimeIsolationTests: XCTestCase {
    private final class Gate {
        let entered: XCTestExpectation
        var continuation: CheckedContinuation<Void, Never>?
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func pause() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
        func release() { continuation?.resume(); continuation = nil }
    }

    func testRetirementAfterSecondaryScanCannotOverwriteSuccessorPreferencesOrWatermark() async throws {
        try await runBarrier(.afterCalibrationScan)
    }

    func testRetirementBeforePersistenceDoesNotAdvanceSuccessMarkers() async throws {
        try await runBarrier(.beforeScorePersistence)
    }

    private func runBarrier(_ checkpoint: IntelligenceEngine.LifecycleCheckpoint) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "test.analyzer.retire." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keys = [RescoreBackgroundScheduler.owedKey, RescoreBackgroundScheduler.owedTokenKey,
                    RescoreBackgroundScheduler.lastPassSecondsKey]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) } }
        let store = try await WhoopStore(path: root.appendingPathComponent("capture.sqlite").path)
        let repo = Repository(deviceId: "isolated", openStore: { store })
        let oldProfile = ProfileStore(defaults: defaults)
        let gate = Gate(expectation(description: "real analyzer reached lifecycle checkpoint"))
        let engine = IntelligenceEngine(repo: repo, profile: oldProfile, deviceId: "isolated", defaults: defaults,
            analysisStoreProvider: { store }, lifecycleCheckpoint: { reached in
                if reached == checkpoint { await gate.pause() }
            })
        let running = Task { await engine.analyzeRecent(maxDays: 0) }
        await fulfillment(of: [gate.entered], timeout: 5)
        engine.shutdownForAccountChange()
        repo.shutdownForAccountChange()
        oldProfile.retire()
        let successor = ProfileStore(defaults: defaults)
        successor.stepsCalibrationCoefficient = 777
        successor.stepsCalibrationSampleDays = 23
        successor.stepsHasBankedMotion = true
        defaults.set("successor-watermark", forKey: "noop.analyzeWatermark")
        RescoreBackgroundScheduler.markRescoreOwed()
        let successorToken = RescoreBackgroundScheduler.currentOwedToken
        UserDefaults.standard.set(123.0, forKey: RescoreBackgroundScheduler.lastPassSecondsKey)
        gate.release()
        await running.value
        // Also fence a retained reference independently of the analyzer's continuation guard.
        oldProfile.stepsCalibrationCoefficient = 1
        oldProfile.stepsCalibrationSampleDays = 1
        oldProfile.stepsHasBankedMotion = false
        let reopened = ProfileStore(defaults: defaults)
        XCTAssertEqual(reopened.stepsCalibrationCoefficient, 777)
        XCTAssertEqual(reopened.stepsCalibrationSampleDays, 23)
        XCTAssertTrue(reopened.stepsHasBankedMotion)
        XCTAssertEqual(defaults.string(forKey: "noop.analyzeWatermark"), "successor-watermark")
        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed)
        XCTAssertEqual(RescoreBackgroundScheduler.currentOwedToken, successorToken)
        XCTAssertEqual(UserDefaults.standard.double(forKey: RescoreBackgroundScheduler.lastPassSecondsKey), 123)
        XCTAssertTrue(engine.results.isEmpty)
    }
}
