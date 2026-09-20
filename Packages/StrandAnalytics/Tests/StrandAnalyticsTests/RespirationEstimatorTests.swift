import Foundation
import XCTest
@testable import StrandAnalytics

final class RespirationEstimatorTests: XCTestCase {
    private func wave(start: Double = 0, bpm: Double = 12) -> RespirationEstimator.Input {
        RespirationEstimator.Input(start: start, sampleRateHz: 4,
            values: (0..<480).map { sin(2 * .pi * bpm * Double($0) / 240) },
            observed: [Bool](repeating: true, count: 480), source: "fixture", modality: "respiratory_modulation",
            timingVerified: true, channelVerified: true)
    }
    func testSharedSyntheticOracle() throws {
        let url = Bundle.module.url(forResource: "respiration_oracle", withExtension: "json", subdirectory: "Resources")!
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        for c in json["cases"] as! [[String: Any]] {
            let n = (c["duration"] as! Int) * 4, bpm = (c["rate"] as! NSNumber).doubleValue
            let amplitude = (c["amplitude"] as! NSNumber).doubleValue
            let harmonic = (c["harmonic"] as? NSNumber)?.doubleValue ?? 0
            let values = (0..<n).map { j -> Double in
                let angle = 2 * Double.pi * bpm * Double(j) / 240
                return amplitude * sin(angle) + harmonic * sin(2 * angle)
            }
            let gapStart = (c["gap_start"] as? NSNumber)?.doubleValue ?? 1e9
            let gapEnd = (c["gap_end"] as? NSNumber)?.doubleValue ?? 1e9
            let mask = (0..<n).map { Double($0) / 4 < gapStart || Double($0) / 4 >= gapEnd }
            var input = RespirationEstimator.Input(start: 0, sampleRateHz: 4, values: values, observed: mask,
                source: "fixture", modality: "respiratory_modulation", timingVerified: true, channelVerified: true)
            input.maximumSupportedRate = (c["maximum_supported_rate"] as? NSNumber)?.doubleValue
            let r = RespirationEstimator.estimate(input)
            XCTAssertEqual(r.reason, c["reason"] as? String, c["id"] as! String)
            if let expected = (c["expected_rate"] as? NSNumber)?.doubleValue {
                XCTAssertEqual(r.breathsPerMinute ?? -1, expected, accuracy: 0.1, c["id"] as! String)
            } else { XCTAssertNil(r.breathsPerMinute) }
            XCTAssertEqual(r.publicationMode, "shadow")
        }
    }
    func testRejectsUnknownTimingAndChannel() {
        let input = wave()
        let unknown = RespirationEstimator.Input(start: 0, sampleRateHz: 4, values: input.values, observed: input.observed,
            source: "fixture", modality: "unknown", timingVerified: true, channelVerified: false)
        XCTAssertEqual(RespirationEstimator.estimate(unknown).reason, "channel_semantics_unverified")
        var motion = input; motion.motionContaminated = true
        XCTAssertEqual(RespirationEstimator.estimate(motion).reason, "motion_contamination")
    }
    func testCoarseIntervalsDoNotAcquireTiming() {
        let row = PhysiologyQuality.IntervalObservation(originalId: "i", deviceId: "d", source: "s", eventTime: 0,
            originalRRMs: 1000, startBeatId: "b0", endBeatId: "b1", continuityGroup: "packet")
        let input = RespirationEstimator.fromIntervals(start: 0, duration: 120, observations: [row])
        XCTAssertEqual(RespirationEstimator.estimate(input).reason, "timing_unverified")
        XCTAssertTrue(input.observed.allSatisfy { !$0 })
    }
    private func rsaRows(spanError: Double = 0, precision: Double = 0.020) -> [PhysiologyQuality.IntervalObservation] {
        var cursor = 0.0
        return (0..<360).map { index in
            let rr = 1000 + 100 * sin(2 * Double.pi * cursor / 5)
            let end = cursor + rr / 1000 + spanError
            let row = PhysiologyQuality.IntervalObservation(originalId: "i\(index)", deviceId: "device", source: "fixture",
                eventTime: cursor, originalRRMs: rr, startBeatId: "b\(index)", endBeatId: "b\(index + 1)",
                continuityGroup: "verified", verifiedSpan: .init(cursor, end), timestampPrecisionSeconds: precision,
                decoderVersion: "fixture-v1", clockVersion: "verified-v1")
            cursor = end
            return row
        }
    }
    func testRsaClockUncertaintyCannotExpandOriginalRRDurationTolerance() {
        let valid = RespirationEstimator.fromIntervals(start: 0, duration: 120, observations: rsaRows())
        XCTAssertTrue(valid.timingVerified)
        XCTAssertNotNil(RespirationEstimator.estimate(valid).breathsPerMinute)
        let quantized = RespirationEstimator.fromIntervals(start: 0, duration: 120, observations: rsaRows(spanError: 0.002))
        XCTAssertTrue(quantized.timingVerified)
        for rows in [rsaRows(spanError: 0.030), rsaRows(spanError: 0.00201), rsaRows(precision: 0), rsaRows(precision: 0.021)] {
            XCTAssertFalse(HrvWindow.measure(start: 0, observations: rows).measurementValid)
            let input = RespirationEstimator.fromIntervals(start: 0, duration: 120, observations: rows)
            XCTAssertFalse(input.timingVerified)
            XCTAssertTrue(input.observed.allSatisfy { !$0 })
            XCTAssertEqual(RespirationEstimator.estimate(input).reason, "timing_unverified")
        }
    }
    func testRsaRejectedSharedEndpointCannotContributeObservedSamples() {
        var rows = rsaRows()
        rows[50].startBeatAccepted = false
        let input = RespirationEstimator.fromIntervals(start: 0, duration: 120, observations: rows)
        let firstAffected = rows[49].verifiedSpan!.start
        let lastAffected = rows[50].verifiedSpan!.end
        let affected = input.observed.indices.filter { Double($0) / 4 >= firstAffected && Double($0) / 4 < lastAffected }
        XCTAssertTrue(input.timingVerified)
        XCTAssertTrue(input.observed[40])
        XCTAssertFalse(affected.isEmpty)
        XCTAssertTrue(affected.allSatisfy { !input.observed[$0] })
    }
    func testOverlappingWindowsCountDurationOnce() {
        let results = [RespirationEstimator.estimate(wave()), RespirationEstimator.estimate(wave(start: 60))]
        let summary = RespirationEstimator.summarize(results, start: 0, end: 300, context: "qualified_sleep")
        XCTAssertEqual(summary.acceptedSeconds, 180, accuracy: 1e-9)
        XCTAssertEqual(summary.coverage, 0.6, accuracy: 1e-9)
        XCTAssertEqual(summary.median ?? -1, 12, accuracy: 0.1)
    }
    func testUpsamplingDoesNotInventBandwidthAndFusionDoesNotMultiplyConfidence() {
        var limited = wave(bpm: 30); limited.maximumSupportedRate = 24
        XCTAssertEqual(RespirationEstimator.estimate(limited).reason, "out_of_supported_range")
        let first = RespirationEstimator.estimate(wave())
        let fused = RespirationEstimator.fuse([first, first])
        XCTAssertEqual(first.autocorrelation, fused.evidenceStrength)
        XCTAssertEqual(RespirationEstimator.fuse([first, RespirationEstimator.estimate(wave(bpm: 18))]).reason, "cross_channel_disagreement")
        XCTAssertEqual(RespirationEstimator.fuse([first, RespirationEstimator.estimate(wave(start: 60))]).reason, "channel_windows_not_aligned")
    }
    func testSummaryDistributionRetainsOnlyAcceptedInContextValuesInStableOrder() {
        var rejected = wave(bpm: 24); rejected.motionContaminated = true
        let results = [RespirationEstimator.estimate(wave(start: 60, bpm: 18)),
                       RespirationEstimator.estimate(rejected), RespirationEstimator.estimate(wave(bpm: 12)),
                       RespirationEstimator.estimate(wave(start: 240, bpm: 30))]
        let summary = RespirationEstimator.summarize(results, start: 0, end: 300, context: "qualified_sleep")
        XCTAssertEqual(summary.distributionBpm.count, 2)
        XCTAssertEqual(summary.acceptedWindows, 2)
        XCTAssertEqual(summary.totalWindows, 3)
        XCTAssertEqual(summary.distributionBpm[0], 12, accuracy: 0.1)
        XCTAssertEqual(summary.distributionBpm[1], 18, accuracy: 0.1)
        XCTAssertEqual(summary, RespirationEstimator.summarize(Array(results.reversed()), start: 0, end: 300, context: "qualified_sleep"))
        let empty = RespirationEstimator.summarize([results[1]], start: 0, end: 300, context: "qualified_awake_rest")
        XCTAssertTrue(empty.distributionBpm.isEmpty); XCTAssertNil(empty.mean); XCTAssertNil(empty.median)
    }
}
