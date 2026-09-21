import Foundation
import XCTest
@testable import StrandAnalytics

final class WholeDaySwiftCurrentCorpusTests: XCTestCase {
    typealias Corpus = WholeDaySwiftCurrentCorpus
    typealias Exporter = WholeDaySwiftParityExporter

    func testActualCurrentSwiftCorpusPreservesCapabilityAbstention() async throws {
        let sourceHashes = try Corpus.sourceHashes()
        _ = try WholeDaySwiftHistoricalProvenance.verify(.v1, repository: Corpus.repository)
        _ = try WholeDaySwiftHistoricalProvenance.verify(.v2, repository: Corpus.repository)
        assertQualifiedSyntheticControls()
        let recipes = try WholeDaySwiftV2Corpus.recipes()
        XCTAssertEqual(recipes.count, 13)
        var cases: [(String, Data)] = []
        for recipe in recipes {
            let value = try await Corpus.export(recipe)
            let expected = try XCTUnwrap(value["expected"] as? [String: Any])
            let selection = try XCTUnwrap(expected["selection"] as? [String: Any])
            let streams = try XCTUnwrap(selection["streams"] as? [String: Any])
            let result = try XCTUnwrap(expected["result"] as? [String: Any])
            let daily = try XCTUnwrap(result["daily"] as? [String: Any])
            let sessions = try XCTUnwrap(result["sleep"] as? [[String: Any]])
            let windows = try XCTUnwrap(selection["hrvWindows"] as? [[String: Any]])
            // None of these coarse WHOOP RR inputs establishes verified beat spans or a calibrated
            // oxygen capability. A successful pipeline must retain those unavailable measurements.
            XCTAssertTrue(daily["avgHrv"] is NSNull, recipe.id)
            XCTAssertTrue(daily["spo2Pct"] is NSNull, recipe.id)
            XCTAssertTrue(sessions.allSatisfy { $0["avgHRV"] is NSNull }, recipe.id)
            for window in windows {
                XCTAssertTrue(window["rmssd"] is NSNull, recipe.id)
                XCTAssertEqual(window["measurementValid"] as? Bool, false, recipe.id)
                XCTAssertEqual(window["baselineEligible"] as? Bool, false, recipe.id)
                let reason = try XCTUnwrap(window["reason"] as? String, recipe.id)
                XCTAssertTrue(["no_observations", "continuity_unverified"].contains(reason), "\(recipe.id): \(reason)")
                XCTAssertEqual(window["baselineReason"] as? String, reason, recipe.id)
            }
            if recipe.id == "whoop5-channel5-order-exclusions" {
                XCTAssertEqual(streams["rr"] as? [String], ["rr-2", "rr-1"])
            }
            if recipe.id == "whoop5-channel7-suspect5-future5" {
                XCTAssertEqual(streams["rr"] as? [String], ["rr-1", "rr-2"])
            }
            if recipe.id.hasPrefix("dense-night") {
                XCTAssertEqual(sessions.count, 1, recipe.id)
                XCTAssertTrue(sessions.allSatisfy { $0["hrOnly"] as? Bool == false }, recipe.id)
                XCTAssertFalse(windows.isEmpty, recipe.id)
            }
            if recipe.id == "dense-night-v1-deep-hrv" {
                XCTAssertTrue(windows.contains { $0["stage"] as? String == "deep" })
                XCTAssertTrue(windows.contains { $0["reason"] as? String == "continuity_unverified" })
            }
            if recipe.id == "dense-night-v1-no-rr-deep-hrv" {
                XCTAssertEqual(streams["rr"] as? [String], [])
                XCTAssertTrue(windows.allSatisfy { $0["reason"] as? String == "no_observations" })
            }
            if recipe.id == "dense-night-v2-no-deep-hrv" {
                XCTAssertFalse(windows.contains { $0["stage"] as? String == "deep" })
            }
            if recipe.id == "fragmented-main-night-and-nap" {
                XCTAssertGreaterThanOrEqual(sessions.count, 3)
                XCTAssertEqual((selection["mainNightIndices"] as? [Int])?.count, 2)
            }
            if recipe.id == "dense-night-v2-and-workout" {
                XCTAssertFalse(try XCTUnwrap(result["workouts"] as? [[String: Any]]).isEmpty)
            }
            if recipe.id == "whoop5-hr-only-night" {
                XCTAssertFalse(sessions.isEmpty)
                XCTAssertTrue(sessions.allSatisfy { $0["hrOnly"] as? Bool == true })
            }
            XCTAssertEqual(Set(result.keys), Set(["daily", "sleep", "workouts", "scores", "sessionMotionByStart", "sessionSleepStateByStart", "detectionFunnel"]))
            print("SWIFT_CURRENT_CASE \(recipe.id) windows=\(windows.count) measurement=unavailable")
            cases.append((recipe.id, try Exporter.bytes(value)))
        }
        XCTAssertEqual(try Corpus.sourceHashes(), sourceHashes, "source changed while executing")
        guard testRun?.failureCount == 0 else { throw Exporter.Failure.invalidRecipe }
        if let target = ProcessInfo.processInfo.environment["W4_SWIFT_CURRENT_EXPORT_DIR"] {
            try Corpus.write(cases, target: target, sourceHashes: sourceHashes)
        }
    }

    func testCurrentWriterRejectsHistoricalOrExistingTargets() throws {
        for path in [WholeDaySwiftV2Corpus.directory.path, WholeDaySwiftV2Corpus.parentDirectory.path,
                     Corpus.repository.path, "/private/tmp/not-the-authorized-recipe"] {
            XCTAssertThrowsError(try Corpus.validateTarget(path))
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("swift-current-corpus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let existing = temporary.appendingPathComponent(Corpus.directoryName)
        XCTAssertEqual(try Corpus.validateTarget(existing.path).path, existing.path)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        XCTAssertThrowsError(try Corpus.validateTarget(existing.path))
    }

    private func assertQualifiedSyntheticControls() {
        // Explicitly synthetic ECG controls are separate from WHOOP acquisition recipes. Their
        // interval spans test supported measurement behavior, not missing production clock proof.
        let context = [PhysiologyQuality.ContextEpoch(start: 0, end: 300, state: "sleep", qualified: true)]
        for (count, pattern, expected) in [(300, [1000.0], 0.0), (240, [450.0, 1250.0, 2050.0, 1250.0], 800.0)] {
            let valid = HrvWindow.measure(start: 0, observations: hrvEvidence(count: count, pattern: pattern), context: context)
            XCTAssertTrue(valid.measurementValid)
            XCTAssertTrue(valid.baselineEligible)
            XCTAssertNil(valid.reason)
            XCTAssertEqual(valid.observedRMSSD, expected)
            let unverified = HrvWindow.measure(start: 0, observations: hrvEvidence(count: count, pattern: pattern, mode: "packet"), context: context)
            XCTAssertFalse(unverified.measurementValid)
            XCTAssertEqual(unverified.reason, "timing_coverage_unverified")
            XCTAssertNil(unverified.observedRMSSD)
        }
    }
}
