import XCTest
import WhoopProtocol
@testable import StrandAnalytics

func hrvEvidence(start: Int = 0, count: Int = 300, pattern: [Double] = [1000], offset: Double = 0,
                 mode: String = "", deviceId: String = "d", firmware: String? = "test-v1") -> [PhysiologyQuality.IntervalObservation] {
    var time = Double(start) + offset
    var rows: [PhysiologyQuality.IntervalObservation] = []
    for i in 0..<count {
        let value = mode == "boundary" && i == 0 ? 2000 : pattern[i % pattern.count]
        let end = time + value / 1000
        var row = PhysiologyQuality.IntervalObservation(originalId: "i\(i)", deviceId: deviceId,
            source: mode == "source_switch" && i >= 150 ? "other" : "test", modality: mode == "sdnn" ? "sdnn" : "ecg_nn",
            eventTime: time, originalRRMs: value, startBeatId: mode == "legacy" ? nil : "b\(i)",
            endBeatId: mode == "legacy" ? nil : "b\(i + 1)", continuityGroup: mode == "legacy" ? nil : "run",
            verifiedSpan: ["legacy", "packet"].contains(mode) ? nil : .init(time, end), timestampPrecisionSeconds: 0.001,
            decoderVersion: "fixture-v1", clockVersion: "verified-fixture-v1", ordinal: i, deviceFirmware: firmware)
        if mode == "rejected_beat" && i == 149 { row.endBeatAccepted = false }
        if mode == "corrected" && i == 150 {
            row.correctedRRMs = 1200
            row.corrections = [.init(id: "edit", pass: "p1", kind: "replaced"), .init(id: "edit", pass: "p2", kind: "replaced")]
        }
        if mode == "many_corrections" && i < 31 { row.corrections = [.init(id: "edit", pass: "p1", kind: "replaced")] }
        if mode != "hole" || i != 150 { rows.append(row) }
        time = end
    }
    return mode == "duplicate" ? rows + rows : rows
}

final class HrvWindowTests: XCTestCase {
    private struct Goldens: Decodable {
        struct Case: Decodable {
            let id: String; let count: Int; let pattern: [Double]; let offset: Double?; let mode: String?; let context: String?
            let pairs: Int; let coverage: Double; let gap: Double; let rmssd: Double?; let sdnn: Double?; let corrected: Double?; let reason: String?; let baseline: Bool
        }
        let cases: [Case]
    }
    func testSharedGoldenWindows() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "hrv_window_oracle", withExtension: "json", subdirectory: "Resources"))
        for c in try JSONDecoder().decode(Goldens.self, from: Data(contentsOf: url)).cases {
            let rows = hrvEvidence(count: c.count, pattern: c.pattern, offset: c.offset ?? 0, mode: c.mode ?? "")
            let context: [PhysiologyQuality.ContextEpoch] = c.context == "mixed" ? [
                .init(start: 0, end: 150, state: "sleep", qualified: true), .init(start: 150, end: 300, state: "active", qualified: true)
            ] : [.init(start: 0, end: 300, state: c.context ?? "sleep", qualified: true)]
            let r = HrvWindow.measure(start: 0, observations: rows, context: context, inputRevision: "golden")
            XCTAssertEqual(r.reason, c.reason, c.id); XCTAssertEqual(r.measurementValid, c.reason == nil, c.id)
            XCTAssertEqual(r.baselineEligible, c.baseline, c.id); XCTAssertEqual(r.validPairCount, c.pairs, c.id)
            XCTAssertEqual(r.observedTimeFraction, c.coverage, accuracy: 1e-9, c.id)
            XCTAssertEqual(r.maximumGapSeconds, c.gap, accuracy: 1e-9, c.id)
            if let value = c.rmssd { XCTAssertEqual(try XCTUnwrap(r.observedRMSSD, c.id), value, accuracy: 1e-9, c.id) }
            else { XCTAssertNil(r.observedRMSSD, c.id) }
            if let value = c.sdnn { XCTAssertEqual(try XCTUnwrap(r.sdnn, c.id), value, accuracy: 1e-9, c.id) }
            if let value = c.corrected {
                XCTAssertEqual(try XCTUnwrap(r.correctedRMSSD), value, accuracy: 1e-9, c.id)
                XCTAssertEqual(r.correctionEventCount, 2); XCTAssertEqual(r.correctionFraction, 1 / 300.0, accuracy: 1e-12)
            } else { XCTAssertNil(r.correctedRMSSD, c.id) }
            XCTAssertEqual(r, HrvWindow.measure(start: 0, observations: rows.reversed(), context: context, inputRevision: "golden"), c.id)
        }
    }
    func testConflictingReplayNeverChoosesArrivalOrder() {
        let rows = hrvEvidence()
        var conflicting = rows[0]; conflicting.originalAccepted = false
        let a = HrvWindow.measure(start: 0, observations: rows + [conflicting])
        XCTAssertEqual(a.reason, "original_identity_conflict")
        XCTAssertEqual(a, HrvWindow.measure(start: 0, observations: ([conflicting] + rows).reversed()))
        XCTAssertNil(a.researchObservedRMSSD)
    }
    func testThreeAcceptedBeatsAndGapAreRequired() {
        var rows = hrvEvidence(); rows[150].originalAccepted = false
        let result = HrvWindow.measure(start: 0, observations: rows)
        XCTAssertFalse(result.pairMask[150]); XCTAssertFalse(result.pairMask[151]); XCTAssertEqual(result.validPairCount, 297)
        var policy = HrvWindow.Policy(); policy.minimumObservedFraction = 0.8; policy.maximumGapSeconds = 10
        let gap = HrvWindow.measure(start: 0, observations: rows.filter { $0.eventTime < 100 || $0.eventTime >= 120 }, policy: policy)
        XCTAssertEqual(gap.reason, "acquisition_gap"); XCTAssertEqual(gap.maximumGapSeconds, 20)
    }
    func testActualPacketAdapterDoesNotInventCoverageOrBridgeRemovedWords() throws {
        func decode(_ hex: String) -> ParsedFrame {
            let chars = Array(hex)
            return parseFrame(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! }, family: .whoop5)
        }
        let frame = decode("aa011800010022e12f12000000000000f153650000003c0200040002700d85e7")
        let rows = PhysiologyQuality.historicalPacket(frame, packetId: "verified-packet-hash", deviceId: "d")
        XCTAssertEqual(rows.map(\.originalRRMs), [1000, 500])
        XCTAssertEqual(rows[0].endBeatId, rows[1].startBeatId); XCTAssertTrue(rows.allSatisfy { $0.verifiedSpan == nil })
        let result = HrvWindow.measure(start: HrvWindow.alignedStart(Int(rows[0].eventTime)), observations: rows)
        XCTAssertEqual(result.reason, "timing_coverage_unverified"); XCTAssertEqual(result.validPairCount, 1)
        let zeroFrame = decode("aa011a00010023592f12000000000000f153650000003c03000400000002c74eaa5b")
        XCTAssertTrue(PhysiologyQuality.historicalPacket(zeroFrame, packetId: "zero-word-packet", deviceId: "d").isEmpty)
    }
    func testFirmwareSwitchAndMissingProvenanceFailClosed() {
        let rows = hrvEvidence()
        let switched = Array(rows.prefix(150)) + Array(hrvEvidence(firmware: "test-v2").suffix(150))
        XCTAssertEqual(HrvWindow.measure(start: 0, observations: switched).reason, "acquisition_version_switch")
        var corrected = rows; corrected[4].correctedRRMs = 900
        XCTAssertEqual(HrvWindow.measure(start: 0, observations: corrected).reason, "missing_correction_provenance")
        var policy = HrvWindow.Policy(); policy.minimumObservedFraction = .nan
        XCTAssertEqual(HrvWindow.measure(start: 0, observations: rows, policy: policy).reason, "invalid_quality_policy")
        XCTAssertEqual(HrvWindow.alignedStart(-1), -300)
    }
    func testManyShortIntervalsCannotHideOneUninterpretableLongSpan() {
        let long = PhysiologyQuality.IntervalObservation(originalId: "long", deviceId: "d", source: "test", modality: "ecg_nn",
            eventTime: 100, originalRRMs: 200000, startBeatId: "b100", endBeatId: "b101", continuityGroup: "run",
            verifiedSpan: .init(100, 300), timestampPrecisionSeconds: 0.001, decoderVersion: "fixture-v1", clockVersion: "verified-fixture-v1", deviceFirmware: "test-v1")
        let r = HrvWindow.measure(start: 0, observations: hrvEvidence(count: 100) + [long])
        XCTAssertEqual(r.observedTimeFraction, 1); XCTAssertGreaterThan(r.validIntervalFraction, 0.9)
        XCTAssertEqual(r.reason, "insufficient_accepted_duration"); XCTAssertNil(r.observedRMSSD)
    }

    func testVerifiedTimingCannotInflateCoverageUsingCoarsePrecision() {
        func rows(count: Int = 300, duration: Double = 1, precision: Double) -> [PhysiologyQuality.IntervalObservation] {
            (0..<count).map { i in
                .init(originalId: "i\(i)", deviceId: "d", source: "test", eventTime: Double(i) * duration,
                    originalRRMs: 1000, startBeatId: "b\(i)", endBeatId: "b\(i+1)", continuityGroup: "run",
                    verifiedSpan: .init(Double(i) * duration, Double(i+1) * duration), timestampPrecisionSeconds: precision,
                    decoderVersion: "fixture-v1", clockVersion: "verified-fixture-v1")
            }
        }
        for evidence in [rows(count: 60, duration: 5, precision: 5), rows(precision: 1),
                         rows(duration: 1.003, precision: 0.020)] {
            let result = HrvWindow.measure(start: 0, observations: evidence)
            XCTAssertEqual(result.reason, "invalid_timing_metadata")
            XCTAssertFalse(result.measurementValid); XCTAssertNil(result.observedRMSSD)
            XCTAssertEqual(result.observedTimeFraction, 0); XCTAssertEqual(result.acceptedDurationSeconds, 0)
        }
        XCTAssertTrue(HrvWindow.measure(start: 0, observations: rows(precision: 0.020)).measurementValid)
        XCTAssertTrue(HrvWindow.measure(start: 0, observations: rows(duration: 1.002, precision: 0.020)).measurementValid)
        XCTAssertEqual(HrvWindow.Policy().version, "engineering-shadow-90-v2")
    }
}
