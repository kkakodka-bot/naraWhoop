import Foundation
import XCTest
@testable import StrandAnalytics

final class RespirationEstimatorTests: XCTestCase {
    private let clean = RespirationEstimator.Contamination(motionObservedFraction: 1, evidenceVersion: "synthetic-motion-v1")
    private func wave(start: Double = 0, bpm: Double = 12) -> RespirationEstimator.Input {
        var input = RespirationEstimator.Input(start: start, sampleRateHz: 4,
            values: (0..<480).map { sin(2 * .pi * bpm * Double($0) / 240) },
            observed: [Bool](repeating: true, count: 480), source: "fixture", modality: "respiratory_modulation",
            timingVerified: true, channelVerified: true)
        input.contamination = clean
        return input
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
            input.contamination = clean
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
        let valid = RespirationEstimator.fromIntervals(start: 0, duration: 120, observations: rsaRows(), contamination: clean)
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
        XCTAssertNil(summary.median)
        XCTAssertNil(summary.mean)
        XCTAssertEqual(summary.reason, "insufficient_accepted_duration")
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

    func testMotionEvidenceIsRequiredAndKnownContaminationRemainsAttributed() {
        var input = wave()
        for evidence in [RespirationEstimator.Contamination(), .init(motionObservedFraction: 0.89, evidenceVersion: "verified"),
                         .init(motionObservedFraction: 1.01, evidenceVersion: "verified"), .init(motionObservedFraction: 1)] {
            input.contamination = evidence
            XCTAssertEqual(RespirationEstimator.estimate(input).reason, "motion_evidence_unavailable")
        }
        input.contamination = .init(motionObservedFraction: 1, motionContaminated: true, evidenceVersion: "verified")
        XCTAssertEqual(RespirationEstimator.estimate(input).reason, "motion_contamination")
        input.contamination = .init(motionObservedFraction: 1, signalQualityReasons: ["low_perfusion"], evidenceVersion: "verified")
        let result = RespirationEstimator.estimate(input)
        XCTAssertEqual(result.reason, "signal_quality_contamination")
        XCTAssertTrue(result.rejectionReasons.contains("low_perfusion"))
        XCTAssertEqual(result.qualityPolicyVersion, "resp-quality-2")
    }

    private func train(count: Int = 300, modality: String = "ppg_ibi", baseMs: Double = 1000,
                       source: (Int) -> String = { _ in "source" }) -> [PhysiologyQuality.IntervalObservation] {
        var time = 0.0
        return (0..<count).map { index in
            let rr = baseMs + (baseMs == 1000 ? 0 : 5 * sin(2 * .pi * time / 5))
            let row = PhysiologyQuality.IntervalObservation(originalId: "i\(index)", deviceId: "d", source: source(index),
                modality: modality, eventTime: time, originalRRMs: rr, startBeatId: "b\(index)", endBeatId: "b\(index + 1)",
                continuityGroup: "original", verifiedSpan: .init(time, time + rr / 1000), timestampPrecisionSeconds: 0.001,
                decoderVersion: "fixture", clockVersion: "fixture")
            time += rr / 1000
            return row
        }
    }

    func testImpossibleIbiNeverEntersInterpolationAndPlausibilityIsModalitySpecific() {
        let impossible = RespirationEstimator.fromIntervals(start: 0, duration: 120,
            observations: train(count: 1500, baseMs: 100), contamination: clean)
        XCTAssertTrue(impossible.timingVerified)
        XCTAssertTrue(impossible.observed.allSatisfy { !$0 })
        XCTAssertEqual(RespirationEstimator.estimate(impossible).reason, "interval_out_of_plausibility")
        let optical = RespirationEstimator.fromIntervals(start: 0, duration: 120,
            observations: train(count: 60, baseMs: 2700), contamination: clean)
        let ecg = RespirationEstimator.fromIntervals(start: 0, duration: 120,
            observations: train(count: 60, modality: "ecg_nn", baseMs: 2700), contamination: clean)
        XCTAssertTrue(optical.observed.allSatisfy { !$0 })
        XCTAssertGreaterThan(ecg.observed.filter { $0 }.count, 450)
        XCTAssertTrue(optical.inputRejectionReasons.contains("interval_out_of_plausibility"))
    }

    func testSourceChangesAreScopedToEachWindowAndNeverInterpolatedAcross() {
        let across = train(source: { $0 < 120 ? "first" : "second" })
        XCTAssertTrue(RespirationEstimator.fromIntervals(start: 0, duration: 120, observations: across).timingVerified)
        XCTAssertTrue(RespirationEstimator.fromIntervals(start: 120, duration: 120, observations: across).timingVerified)
        let inside = RespirationEstimator.fromIntervals(start: 60, duration: 120, observations: across)
        XCTAssertFalse(inside.timingVerified)
        XCTAssertTrue(inside.observed.allSatisfy { !$0 })
    }

    func testMixedTimingAndKnownSignalRejectionsCannotBecomeCleanRespiration() {
        var rows = rsaRows()
        rows.append(.init(originalId: "unverified", deviceId: "device", source: "fixture", eventTime: 50, originalRRMs: 1000))
        let mixed = RespirationEstimator.fromIntervals(start: 0, duration: 120, observations: rows, contamination: clean)
        XCTAssertEqual(RespirationEstimator.estimate(mixed).reason, "timing_unverified")
        var rejected = rsaRows()
        for i in rejected.indices { rejected[i].contactAccepted = false }
        let input = RespirationEstimator.fromIntervals(start: 0, duration: 120, observations: rejected, contamination: clean)
        XCTAssertTrue(input.observed.allSatisfy { !$0 })
        XCTAssertTrue(input.inputRejectionReasons.contains("contact_rejected"))
        XCTAssertNil(RespirationEstimator.estimate(input).breathsPerMinute)
    }

    func testDominantSecondHarmonicWithWeakFundamentalCannotDoubleRate() {
        for amplitude in [0.05, 0.1, 0.3] {
            let values = (0..<480).map { j in
                let angle = 2 * Double.pi * 12 * Double(j) / 240
                return amplitude * sin(angle) + sin(2 * angle)
            }
            var input = RespirationEstimator.Input(start: 0, sampleRateHz: 4, values: values,
                observed: Array(repeating: true, count: 480), source: "fixture", modality: "respiratory_modulation",
                timingVerified: true, channelVerified: true)
            input.contamination = clean
            let result = RespirationEstimator.estimate(input)
            XCTAssertNil(result.breathsPerMinute)
            XCTAssertEqual(result.reason, "harmonic_ambiguity")
            XCTAssertEqual(result.spectralRate ?? -1, 24, accuracy: 0.1)
        }
    }

    func testMalformedSpansAndCorrectionNeverAcquireTiming() {
        var malformed = train()
        malformed[50] = replacingSpan(malformed[50], .init(.nan, .nan))
        let unknown = RespirationEstimator.fromIntervals(start: 0, duration: 120, observations: malformed, contamination: clean)
        XCTAssertFalse(unknown.timingVerified)
        XCTAssertEqual(RespirationEstimator.estimate(unknown).reason, "timing_unverified")
        var corrected = train()
        corrected[50] = replacingSpan(corrected[50], nil)
        corrected[50].corrections = [.init(id: "correction", pass: "fixture", kind: "interpolation")]
        let missing = RespirationEstimator.fromIntervals(start: 0, duration: 120, observations: corrected, contamination: clean)
        XCTAssertFalse(missing.timingVerified)
        XCTAssertTrue(missing.observed.allSatisfy { !$0 })
    }

    private func replacingSpan(_ row: PhysiologyQuality.IntervalObservation, _ span: PhysiologyQuality.Span?) -> PhysiologyQuality.IntervalObservation {
        .init(originalId: row.originalId, userId: row.userId, deviceId: row.deviceId, source: row.source,
              modality: row.modality, eventTime: row.eventTime, originalRRMs: row.originalRRMs,
              startBeatId: row.startBeatId, endBeatId: row.endBeatId, continuityGroup: row.continuityGroup,
              verifiedSpan: span, timestampPrecisionSeconds: row.timestampPrecisionSeconds,
              decoderVersion: row.decoderVersion, clockVersion: row.clockVersion)
    }

    func testTinyUnverifiedGapAndExtremeAlternationRemainMissing() {
        var gapped = train()
        gapped[50] = replacingSpan(gapped[50], .init(50.001, 51.001))
        let input = RespirationEstimator.fromIntervals(start: 0, duration: 120, observations: gapped, contamination: clean)
        XCTAssertTrue(input.timingVerified)
        XCTAssertFalse(input.observed[200])
        XCTAssertFalse(input.observed[203])
        var time = 0.0
        let alternating = (0..<160).map { index -> PhysiologyQuality.IntervalObservation in
            let rr = index.isMultiple(of: 2) ? 300.0 : 1700.0
            let row = PhysiologyQuality.IntervalObservation(originalId: "a\(index)", deviceId: "d", source: "s",
                eventTime: time, originalRRMs: rr, startBeatId: "b\(index)", endBeatId: "b\(index + 1)",
                continuityGroup: "original", verifiedSpan: .init(time, time + rr / 1000), timestampPrecisionSeconds: 0.001,
                decoderVersion: "fixture", clockVersion: "fixture")
            time += rr / 1000
            return row
        }
        let ambiguous = RespirationEstimator.fromIntervals(start: 0, duration: 120, observations: alternating, contamination: clean)
        XCTAssertTrue(ambiguous.inputRejectionReasons.contains("rhythm_ambiguity"))
        XCTAssertTrue(ambiguous.observed.allSatisfy { !$0 })
        XCTAssertNil(RespirationEstimator.estimate(ambiguous).breathsPerMinute)
    }

    func testNightRequiresDurationAndDistributedCoverageWhileRetainingDiagnostics() {
        let full = stride(from: 0, to: 3600, by: 120).map { RespirationEstimator.estimate(wave(start: Double($0))) }
        let one = RespirationEstimator.summarize([full[0]], start: 0, end: 3600, context: "qualified_sleep")
        XCTAssertNil(one.median); XCTAssertNil(one.mean)
        XCTAssertEqual(one.reason, "insufficient_accepted_duration")
        XCTAssertEqual(one.acceptedSeconds, 120)
        XCTAssertEqual(one.distributionBpm.count, 1)
        let early = RespirationEstimator.summarize(Array(full.prefix(16)), start: 0, end: 3600, context: "qualified_sleep")
        XCTAssertNil(early.median)
        XCTAssertEqual(early.reason, "unrepresentative_temporal_coverage")
        XCTAssertEqual(early.coverageByThird.last, 0)
        let complete = RespirationEstimator.summarize(full, start: 0, end: 3600, context: "qualified_sleep")
        XCTAssertNil(complete.reason)
        XCTAssertEqual(complete.median ?? -1, 12, accuracy: 0.1)
        XCTAssertEqual(complete.coverageByThird, [1, 1, 1])
        XCTAssertEqual(complete, RespirationEstimator.summarize(full + full, start: 0, end: 3600, context: "qualified_sleep"))
        var mixedFirmware = full
        mixedFirmware[15].acquisitionIdentity = ["changed-firmware"]
        XCTAssertEqual(RespirationEstimator.summarize(mixedFirmware, start: 0, end: 3600, context: "qualified_sleep").reason,
                       "incompatible_window_provenance")
    }
}
