import XCTest
@testable import WhoopProtocol

/// WHOOP 5.0 type-47 **version-26** record — the high-rate optical PPG buffer.
///
/// v26 is the high-rate sibling of the v18 per-second summary: **24 little-endian i16 samples at bytes
/// [27:75]**, one record per second (`unix` u32 LE @15, the same slot v18 uses). It was verified to be
/// an OPTICAL PPG trace — not IMU/motion — using HR as *internal* ground truth (no external reference):
/// the concatenated waveform's autocorrelation peaks at the heart rate (lag 14 = 102.9 bpm vs a measured
/// 101.7 bpm), trough-detection gives a 563 ms inter-beat interval (≈106 bpm), the pulse stays HR-locked
/// even when the wrist is still, and its amplitude is not motion-driven. See
/// `Tools/linux-capture/analyze_v26_waveform.py` and `BLE_REVERSE_ENGINEERING.md` §5.
///
/// Samples are raw AC-coupled ADC counts — PPG has no absolute unit — so they are exposed verbatim with
/// no invented scale. Real type-47 frames carry no device name / serial / token, so the fixture is real.
final class Whoop5PpgWaveformTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    // Real v26 record (unix 1780917232; a clean PPG upstroke from −1432 toward 0).
    private let v26Hex =
        "aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc8bfd4c" +
        "febafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84fe15ff5cff40" +
        "5fb33c50080101006cb67c17"

    private let expectedWaveform = [
        -1432, -1332, -1139, -954, -629, -436, -326, -294, -147, -170, -43, -5,
        -201, -918, -1563, -1833, -1313, -930, -616, -293, -422, -380, -235, -164,
    ]

    func testV26DecodesAsHistoricalData() {
        let f = parseFrame(bytes(v26Hex), family: .whoop5)
        XCTAssertEqual(f.typeName, "HISTORICAL_DATA")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["hist_version"]?.intValue, 26)
    }

    func testV26PpgWaveformAndUnix() {
        let p = parseFrame(bytes(v26Hex), family: .whoop5).parsed
        XCTAssertEqual(p["unix"]?.intValue, 1780917232)        // real unix, same @15 slot as v18
        XCTAssertEqual(p["ppg_sample_count"]?.intValue, 24)
        XCTAssertEqual(p["ppg_waveform"]?.intArrayValue, expectedWaveform)
        // @21 is the raw per-burst counter `burst_index` (PR#553), NOT a channel id — this fixture reads 1.
        XCTAssertEqual(p["burst_index"]?.intValue, 1)
        XCTAssertNil(p["ppg_channel"])                          // the old (wrong) channel field is gone
        // PR#563: record_index@11 is the only other named field; the rest stay raw/neutral.
        XCTAssertEqual(p["record_index"]?.intValue, 25444781)
        XCTAssertEqual(p["raw_u8_19"]?.intValue, 174)
    }

    /// A second real v26 frame captured in a separate 40 s burst ~19 min later. Its `burst_index` @21
    /// reads `2` (the first frame read `1`). An earlier decode read `frame[12]` = 0x41/0x46 and mistook a
    /// high-entropy counter byte for an optical channel, and a later capture showed @21 itself reaching 65
    /// — far outside any 26-channel sweep — so @21 is a raw per-burst counter, not a channel id (PR#553).
    /// Both frames' waveforms autocorrelate to the heart rate (lag 14 ≈ 103 bpm); no LED mapping is claimed.
    private let v26HexChannel46 =
        "aa015000010035412f1a803546840178a8266af54802004ca006007dfde1fde4fe9904" +
        "5009f40d7f0b380c5109e9013dff0dff19fd6efedafe8efe8cfca0fe98014002c9039f05" +
        "30059201d8abbe3d50080001006b6cb5a5"

    func testV26SecondBurstDecodes() {
        let p = parseFrame(bytes(v26HexChannel46), family: .whoop5).parsed
        XCTAssertEqual(p["hist_version"]?.intValue, 26)
        XCTAssertEqual(p["unix"]?.intValue, 1780918392)
        XCTAssertEqual(p["burst_index"]?.intValue, 2)          // per-burst counter (first frame read 1)
        XCTAssertNil(p["ppg_channel"])                          // no channel semantics asserted
        XCTAssertEqual(p["ppg_sample_count"]?.intValue, 24)
        // Still a smooth pulsatile trace (guards the [27:75] bounds on the other frame too).
        let w = p["ppg_waveform"]!.intArrayValue!
        let range = w.max()! - w.min()!
        let meanStep = zip(w, w.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / (w.count - 1)
        XCTAssertLessThan(meanStep * 4, range)
    }

    func testV26WaveformIsSmoothNotNoise() {
        // A PPG pulse moves smoothly sample-to-sample, so the mean step is a small fraction of the
        // record's range — distinguishing a real decoded waveform from random/garbage bytes, and
        // guarding the [27:75] sample bounds.
        let w = parseFrame(bytes(v26Hex), family: .whoop5).parsed["ppg_waveform"]!.intArrayValue!
        let range = w.max()! - w.min()!
        let meanStep = zip(w, w.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / (w.count - 1)
        XCTAssertLessThan(meanStep * 4, range)
    }

    // MARK: - Durable waveform persistence (issue #156 follow-up)
    //
    // Until now `extractHistoricalStreams` collected a v26 record's waveform into a transient local
    // buffer ONLY to derive a per-second HR estimate (`ppgHr`); the samples themselves were discarded
    // once that estimate was taken. These tests prove the raw waveform now survives as its OWN stream
    // (`Streams.ppgWaveform`), independently of whether the HR estimator had enough context to run.

    /// A single v26 record is one second of samples — nowhere near the >=3-consecutive-second run
    /// `PpgHr.derivePpgHr` requires, so `ppgHr` stays empty. Before this change that meant the ENTIRE
    /// record vanished (nothing else read `ppg_waveform`); now the raw waveform is still captured.
    func testExtractHistoricalStreamsPersistsRawPpgWaveform() {
        let f = parseFrame(bytes(v26Hex), family: .whoop5)
        let streams = extractHistoricalStreams([f], deviceClockRef: 1_780_917_232, wallClockRef: 1_780_917_232)
        XCTAssertEqual(streams.ppgWaveform,
                       [PpgWaveformSample(ts: 1_780_917_232, samples: expectedWaveform,
                                          burstIndex: 1, recordIndex: 25444781)])
        XCTAssertTrue(streams.ppgHr.isEmpty, "a lone 1 s record is too short for a confident HR estimate")
        // Not "no rows at all" — the Backfiller's silent-data-loss diagnostic must see this as decoded.
        XCTAssertFalse(streams.isEmpty)
    }

    func testExtractHistoricalStreamsCarriesEachBurstIndexWithItsWaveform() {
        let parsed = [v26Hex, v26HexChannel46].map { parseFrame(bytes($0), family: .whoop5) }
        let streams = extractHistoricalStreams(parsed,
                                               deviceClockRef: 1_780_917_232,
                                               wallClockRef: 1_780_917_232)
        XCTAssertEqual(streams.ppgWaveform.map(\.burstIndex), [1, 2])
        XCTAssertEqual(streams.ppgWaveform.map(\.recordIndex), parsed.map { $0.parsed["record_index"]?.intValue })
    }

    /// Synthetic samples in the captured v26 framing, with CRCs recomputed after the edits.
    /// This exercises estimator gating, not hardware timing or physiological accuracy.
    private func syntheticPulseFrames() -> [ParsedFrame] {
        (0..<12).map { second in
            var frame = bytes(v26Hex)
            for (offset, value) in [(11, 25_444_781 + second), (15, 1_780_917_232 + second)] {
                for byte in 0..<4 { frame[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
            }
            for sample in 0..<24 {
                let phase = Double(second * 24 + sample) / 24.0
                let value = Int(1000 * sin(2 * Double.pi * (70.0 / 60.0) * phase))
                frame[27 + sample * 2] = UInt8(truncatingIfNeeded: value)
                frame[28 + sample * 2] = UInt8(truncatingIfNeeded: value >> 8)
            }
            let end = frame.count - 4
            let checksum = crc32(frame, 8, end)
            for byte in 0..<4 { frame[end + byte] = UInt8(truncatingIfNeeded: checksum >> (byte * 8)) }
            let parsed = parseFrame(frame, family: .whoop5)
            XCTAssertEqual(parsed.crcOK, true)
            return parsed
        }
    }

    func testDisablingPhoneEstimatorPreservesRawRecordsAndDeviceHeartRate() {
        let v18 = "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"
        var frames = syntheticPulseFrames()
        frames.append(frames[5]) // Replay must not alter the retained raw sample/record identities.
        frames.append(parseFrame(bytes(v18), family: .whoop5))
        let offline = extractHistoricalStreams(frames, deviceClockRef: 0, wallClockRef: 0)
        XCTAssertFalse(offline.ppgHr.isEmpty, "the legacy offline estimator must actually run in this fixture")
        XCTAssertEqual(offline.ppgWaveform.count, 13)
        XCTAssertEqual(offline.hr, [HRSample(ts: 1_780_916_150, bpm: 102)])
        for interpolation in [false, true] {
            let hosted = extractHistoricalStreams(frames, deviceClockRef: 0, wallClockRef: 0,
                                                   subLagInterp: interpolation, derivePpgHeartRate: false)
            XCTAssertTrue(hosted.ppgHr.isEmpty)
            XCTAssertEqual(hosted.ppgWaveform, offline.ppgWaveform)
            XCTAssertEqual(hosted.hr, offline.hr)
            XCTAssertEqual(hosted.rr, offline.rr)
            XCTAssertFalse(hosted.isEmpty)
        }
    }

    func testWaveformOnlyHostedBatchRemainsDurableInput() {
        let frames = syntheticPulseFrames()
        let hosted = extractHistoricalStreams(frames, deviceClockRef: 0, wallClockRef: 0,
                                               derivePpgHeartRate: false)
        XCTAssertTrue(hosted.ppgHr.isEmpty)
        XCTAssertTrue(hosted.hr.isEmpty, "waveform-only input must not fabricate device HR")
        XCTAssertEqual(hosted.ppgWaveform.count, frames.count)
        XCTAssertFalse(hosted.isEmpty)
    }

    /// `Streams.isEmpty` must count a waveform-only decode as non-empty even when `ppgHr` (derived FROM
    /// it) is empty — otherwise the Backfiller's #77 "this chunk carried no sensor records" diagnostic
    /// would misfire on a chunk that in fact persisted a raw waveform.
    func testStreamsIsEmptyConsidersPpgWaveform() {
        var s = Streams()
        XCTAssertTrue(s.isEmpty)
        s.ppgWaveform = [PpgWaveformSample(ts: 1, samples: [1, 2, 3])]
        XCTAssertFalse(s.isEmpty)
    }

    /// Streams decode tolerance: a JSON missing `ppg_waveform` still decodes (defaults to empty), and a
    /// present `ppg_waveform` round-trips, including negative (AC-coupled) sample values. Mirrors the
    /// decodeIfPresent guard for the other biometric keys (see PpgHrTests' ppg_hr analogue).
    func testStreamsDecodeToleratesMissingAndPresentPpgWaveform() throws {
        let dec = JSONDecoder()
        // Missing key → empty.
        let s1 = try dec.decode(Streams.self, from: Data(#"{"hr":[]}"#.utf8))
        XCTAssertTrue(s1.ppgWaveform.isEmpty)
        // Present key → decoded under the snake_case CodingKey.
        let json = #"{"ppg_waveform":[{"ts":1780917232,"samples":[-1432,-1332,12]}]}"#
        let s2 = try dec.decode(Streams.self, from: Data(json.utf8))
        XCTAssertEqual(s2.ppgWaveform, [PpgWaveformSample(ts: 1_780_917_232, samples: [-1432, -1332, 12])])
        XCTAssertNil(s2.ppgWaveform.first?.burstIndex, "legacy JSON has no burst index")
        XCTAssertNil(s2.ppgWaveform.first?.recordIndex, "legacy JSON has no record identity")
        // Round-trip encode → decode is identity.
        let withBurst = Streams(ppgWaveform: [PpgWaveformSample(ts: 1_780_917_232,
                                                                samples: [-1432, -1332, 12],
                                                                burstIndex: 4, recordIndex: 25_444_781)])
        let round = try dec.decode(Streams.self, from: JSONEncoder().encode(withBurst))
        XCTAssertEqual(round.ppgWaveform, withBurst.ppgWaveform)
    }
}
