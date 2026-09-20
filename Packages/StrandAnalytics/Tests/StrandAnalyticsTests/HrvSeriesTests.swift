import XCTest
@testable import StrandAnalytics

final class HrvSeriesTests: XCTestCase {
    func testSourcesAreQualifiedSeparatelyInEachWindowAndNeverSpliced() {
        let rows = hrvEvidence(source: "whoop5_history") + hrvEvidence(start: 300, source: "channel:7") +
            hrvEvidence(start: 300, count: 1, source: "whoop5_history")
        let windows = HrvSeries.windows(start: 0, end: 600, observations: rows)
        XCTAssertEqual(windows.map(\.source), ["whoop5_history", "channel:7"])
        XCTAssertTrue(windows.allSatisfy(\.measurementValid))
        let partial = hrvEvidence(count: 150, source: "whoop5_history") + hrvEvidence(count: 150, offset: 150, source: "channel:7")
        XCTAssertFalse(HrvSeries.selectedWindow(start: 0, observations: partial).measurementValid)
        let otherOwner = hrvEvidence(deviceId: "other", source: "other")
        XCTAssertEqual(HrvSeries.selectedWindow(start: 0, observations: rows + otherOwner).reason, "owner_mismatch")
    }

    func testDenseSingleNightAndSeriallyCorrelatedNightsCannotMatureBaseline() {
        let dense = (0..<80).map { measured($0 * 300, 100) }
        let single = HrvSeries.baseline(current: measured(86400, 100), history: dense, minimumSamples: 3)
        XCTAssertEqual(single.independentNightCount, 1); XCTAssertEqual(single.effectiveSampleCount, 1)
        XCTAssertEqual(single.observationCount, 80); XCTAssertEqual(single.reason, "insufficient_baseline")
        let trend = (0..<12).map { measured($0 * 86400, 50 + Double($0) * 10) }
        let serial = HrvSeries.baseline(current: measured(12 * 86400, 200), history: trend, minimumSamples: 3)
        XCTAssertEqual(serial.independentNightCount, 12); XCTAssertLessThan(serial.effectiveSampleCount, 3)
        XCTAssertEqual(serial.reason, "serially_correlated_baseline"); XCTAssertNil(serial.logDeviation)
        let sameNight = HrvSeries.baseline(current: measured(24000, 100), history: dense, minimumSamples: 3)
        XCTAssertEqual(sameNight.effectiveSampleCount, 0)
    }
    private func measured(_ start: Int, _ value: Double, context: String = "sleep", firmware: String = "test-v1", revision: String = "unversioned") -> HrvWindow.Result {
        let base = value > 750 ? 450 : 1000 - value
        return HrvWindow.measure(start: start, observations: hrvEvidence(start: start, pattern: [base, base + value, base + 2 * value, base + value], firmware: firmware),
            context: [.init(start: Double(start), end: Double(start + 300), state: context, qualified: true)], inputRevision: revision)
    }
    func testNightlyArithmeticAndRestNapSeparation() throws {
        let windows = [measured(0, 0), measured(300, 100), measured(600, 800)]
        let r = HrvSeries.summarize(windows, start: 0, end: 900)
        XCTAssertEqual(try XCTUnwrap(r.meanRMSSD), 300, accuracy: 1e-9)
        XCTAssertEqual(r.medianRMSSD, 100); XCTAssertEqual(r.samplingCoverage, 1)
        XCTAssertEqual(r.segmentCoverage, [1, 1, 1]); XCTAssertEqual(r.acceptedDurationSeconds, 900)
        let mixed = [measured(0, 0, context: "nap"), measured(300, 100, context: "quiet_rest"), measured(600, 800)]
        XCTAssertNil(HrvSeries.summarize(mixed, start: 0, end: 900).meanRMSSD)
        XCTAssertEqual(HrvSeries.summarize(mixed, start: 0, end: 900).eligibleWindowCount, 1)
    }
    func testDenseEarlyIslandCannotRepresentNight() {
        let windows = [measured(0, 100), measured(300, 100), measured(600, 100)]
        let r = HrvSeries.summarize(windows, start: 0, end: 1800)
        XCTAssertEqual(r.samplingCoverage, 0.5); XCTAssertEqual(r.reason, "unrepresentative_sampling")
        XCTAssertEqual(r.segmentCoverage, [1, 0.5, 0]); XCTAssertNil(r.meanRMSSD)
    }
    func testBaselineUsesOnlyPastComparablePositiveMeasurements() throws {
        let history = [measured(0, 100), measured(86400, 200), measured(172800, 400)]
        let current = measured(259200, 800)
        let r = HrvSeries.baseline(current: current, history: history + history + [current, measured(345600, 20)], minimumSamples: 3)
        XCTAssertNil(r.reason); XCTAssertEqual(r.effectiveSampleCount, 3)
        XCTAssertEqual(try XCTUnwrap(r.logMedian), log(200), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r.logMAD), log(2), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r.logDeviation), log(4), accuracy: 1e-9)
        XCTAssertEqual(HrvSeries.baseline(current: measured(1200, 800, firmware: "test-v2"), history: history, minimumSamples: 3).reason, "insufficient_baseline")
        XCTAssertEqual(HrvSeries.baseline(current: measured(1200, 800, context: "quiet_rest"), history: history, minimumSamples: 3).effectiveSampleCount, 0)
    }
    func testZerosAndColdStartAreExplicit() {
        let history = [measured(0, 100), measured(86400, 100), measured(172800, 100)]
        XCTAssertEqual(HrvSeries.baseline(current: measured(259200, 0), history: history, minimumSamples: 3).reason, "zero_not_log_transformable")
        let flat = HrvSeries.baseline(current: measured(259200, 800), history: history, minimumSamples: 3)
        XCTAssertEqual(flat.reason, "zero_baseline_dispersion"); XCTAssertNil(flat.robustZ); XCTAssertNotNil(flat.logDeviation)
        let cold = HrvSeries.baseline(current: measured(86400, 100), history: [measured(0, 0)])
        XCTAssertEqual(cold.reason, "insufficient_baseline"); XCTAssertEqual(cold.excludedZeroCount, 1)
    }

    func testRecomputedOvernightOverlapIgnoresOnlyPublicationRevision() {
        let history = [measured(0, 100, revision: "1"), measured(300, 200, revision: "1"), measured(600, 400, revision: "1")]
        let recomputed = [measured(0, 100, revision: "2"), measured(300, 200, revision: "2"), measured(600, 400, revision: "2")]
        let current = measured(86400, 300, revision: "2")
        let expected = HrvSeries.baseline(current: current, history: history, minimumSamples: 3)
        XCTAssertEqual(HrvSeries.baseline(current: current, history: history + recomputed, minimumSamples: 3), expected)
        XCTAssertEqual(HrvSeries.baseline(current: current, history: (history + recomputed).reversed(), minimumSamples: 3), expected)
        XCTAssertEqual(HrvSeries.summarize(history + recomputed, start: 0, end: 900).eligibleWindowCount, 3)
        XCTAssertNotNil(HrvSeries.feature(at: 150, measurements: history + recomputed))
        let conflict = measured(0, 150, revision: "3")
        XCTAssertFalse(history[0].sameMeasurement(as: conflict))
        XCTAssertEqual(HrvSeries.baseline(current: current, history: history + [conflict], minimumSamples: 3).observationCount, 2)
        XCTAssertNil(HrvSeries.feature(at: 150, measurements: history + [conflict]))
    }

    func testSummaryExclusionsCountOnlyUniqueOverlappingBuckets() {
        let windows = [measured(-300, 100), measured(0, 100), measured(300, 100), measured(600, 100), measured(900, 100), measured(1200, 100)]
        XCTAssertEqual(HrvSeries.summarize(windows, start: 0, end: 900).excludedWindowCount, 0)
        let crossing = HrvSeries.summarize(windows, start: 150, end: 1050)
        XCTAssertEqual(crossing.eligibleWindowCount, 2); XCTAssertEqual(crossing.excludedWindowCount, 2)
        let duplicated = windows + [measured(300, 100, revision: "new")]
        XCTAssertEqual(HrvSeries.summarize(duplicated, start: 0, end: 900).excludedWindowCount, 0)
        let conflicted = HrvSeries.summarize(duplicated + [measured(300, 200)], start: 0, end: 900)
        XCTAssertEqual(conflicted.eligibleWindowCount, 2); XCTAssertEqual(conflicted.excludedWindowCount, 1)
    }

    func testInvalidatedOrReclassifiedHistoryCannotRetainItsOldBaselineValue() {
        let history = [measured(0, 100), measured(300, 200), measured(600, 400)]
        let current = measured(86400, 300)
        let invalid = HrvWindow.measure(start: 0, observations: hrvEvidence(pattern: [950, 1050]).map {
            var row = $0; row.rhythmAmbiguous = true; return row
        }, context: [.init(start: 0, end: 300, state: "sleep", qualified: true)], inputRevision: "new")
        XCTAssertFalse(invalid.measurementValid)
        for revision in [invalid, measured(0, 100, context: "awake", revision: "new"),
                         measured(0, 100, context: "quiet_rest", revision: "new")] {
            for rows in [history + [revision], Array((history + [revision]).reversed())] {
                let result = HrvSeries.baseline(current: current, history: rows, minimumSamples: 3)
                XCTAssertEqual(result.observationCount, 2)
                XCTAssertEqual(result.reason, "insufficient_baseline")
            }
        }
        let expected = HrvSeries.baseline(current: current, history: history, minimumSamples: 3)
        let evidence = hrvEvidence(pattern: [950, 1050])
        let otherOwners = ["user", "device", "source"].map { field in
            HrvWindow.measure(start: 0, observations: evidence.map { row in
                .init(originalId: row.originalId, userId: field == "user" ? "other" : row.userId,
                      deviceId: field == "device" ? "other" : row.deviceId, source: field == "source" ? "other" : row.source,
                      modality: row.modality, eventTime: row.eventTime, originalRRMs: row.originalRRMs,
                      startBeatId: row.startBeatId, endBeatId: row.endBeatId, continuityGroup: row.continuityGroup,
                      verifiedSpan: row.verifiedSpan, timestampPrecisionSeconds: row.timestampPrecisionSeconds,
                      decoderVersion: row.decoderVersion, clockVersion: row.clockVersion, ordinal: row.ordinal,
                      deviceFirmware: row.deviceFirmware)
            }, context: [.init(start: 0, end: 300, state: "sleep", qualified: true)])
        }
        var policy = HrvWindow.Policy(); policy.version = "other"
        let otherPolicy = HrvWindow.measure(start: 0, observations: evidence,
            context: [.init(start: 0, end: 300, state: "sleep", qualified: true)], policy: policy)
        XCTAssertEqual(HrvSeries.baseline(current: current, history: history + otherOwners + [otherPolicy, measured(0, 150, firmware: "test-v2")], minimumSamples: 3), expected)
    }
}
