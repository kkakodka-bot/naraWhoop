import XCTest
@testable import Strand
import WhoopProtocol

/// Pins `PuffinDeepBufferLog.isDeepBuffer` — the pure predicate behind the durable high-rate deep-buffer
/// log (#423). A reassembled WHOOP 5/MG frame carries its inner-record type at offset 8; the R22 deep
/// packets are type 0x2F (47). The 1 Hz historical rollup is the SAME type but small, so the log keeps
/// only the big (≥ 1 KB) high-rate buffers. BLE delivery can't be unit-tested, but this offset-8 +
/// size gate CAN be, so a frame-shape change can't silently stop the research log filling. Mirrors
/// `PuffinEventLogTests`.
final class PuffinDeepBufferLogTests: XCTestCase {

    func testAcceptsBigType2FAtOffset8() {
        var f = [UInt8](repeating: 0, count: 2140) // the 2140-B high-rate buffer
        f[8] = 0x2F
        XCTAssertTrue(PuffinDeepBufferLog.isDeepBuffer(f))
        var g = [UInt8](repeating: 0, count: 1244) // the 1244-B high-rate buffer
        g[8] = 0x2F
        XCTAssertTrue(PuffinDeepBufferLog.isDeepBuffer(g))
    }

    func testRejectsSmallType2FRecord() {
        // The ~124-B type-0x2F frame is the 1 Hz rollup NOOP already decodes — below the size gate,
        // it must NOT be logged as a high-rate buffer.
        var f = [UInt8](repeating: 0, count: 124)
        f[8] = 0x2F
        XCTAssertFalse(PuffinDeepBufferLog.isDeepBuffer(f))
    }

    func testRejectsOtherTypesEvenWhenBig() {
        // Big frames of other inner types (REALTIME 0x28, COMMAND_RESPONSE 0x24, EVENT 0x30,
        // METADATA 0x31) must never be treated as a deep buffer.
        for t: UInt8 in [0x28, 0x24, 0x30, 0x31, 0x32, 47 &+ 1] {
            var f = [UInt8](repeating: 0, count: 2140)
            f[8] = t
            XCTAssertFalse(PuffinDeepBufferLog.isDeepBuffer(f), "type \(t) must not be a deep buffer")
        }
    }

    func testRejectsTooShortToIndexOffset8() {
        for n in 0...8 {
            XCTAssertFalse(PuffinDeepBufferLog.isDeepBuffer([UInt8](repeating: 0x2F, count: n)))
        }
    }

    // MARK: - Inline decoded-IMU summary (#423/#455): the log's first caller of Whoop5RawImu.decode

    /// A well-formed 1244-B 6-axis IMU buffer (`Whoop5RawImu` layout): countA/countB = 100, gravity on
    /// Z, and an X channel that alternates 800/0 so the decoded accel MAGNITUDE actually varies —
    /// giving non-zero AC energy so the feature extractor exercises its cadence path and stays finite.
    /// (A ±X swing would not: squaring cancels the sign, leaving magnitude constant.)
    private func imuBuffer() -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 1244)
        f[0] = 0xAA; f[1] = 0x01
        let declaredLength = f.count - 8
        f[2] = UInt8(truncatingIfNeeded: declaredLength)
        f[3] = UInt8(truncatingIfNeeded: declaredLength >> 8)
        f[4] = 0x01
        f[8] = 0x2F
        f[9] = 21
        f[24] = 100          // countA (u16 LE) — Whoop5RawImu.decode requires == 100
        f[630] = 100         // countB (u16 LE)
        func put(_ off: Int, _ i: Int, _ v: Int16) {
            f[off + 2 * i] = UInt8(truncatingIfNeeded: v)
            f[off + 2 * i + 1] = UInt8(truncatingIfNeeded: v >> 8)
        }
        for i in 0..<100 {
            put(28,  i, i % 2 == 0 ? 800 : 0)   // ax @28  — magnitude actually varies
            put(428, i, 4096)                    // az @428 — ~1 g
        }
        return sealingChecksums(f)
    }

    private func sealingChecksums(_ frame: [UInt8]) -> [UInt8] {
        var f = frame
        let header = crc16Modbus(Array(f[0..<6]))
        f[6] = UInt8(truncatingIfNeeded: header)
        f[7] = UInt8(truncatingIfNeeded: header >> 8)
        let payloadEnd = f.count - 4
        let payload = crc32(Array(f[8..<payloadEnd]))
        for byte in 0..<4 { f[payloadEnd + byte] = UInt8(truncatingIfNeeded: payload >> (8 * byte)) }
        return f
    }

    func testEmitsInlineDecodedImuFieldForImuBuffer() {
        let frame = imuBuffer()
        XCTAssertTrue(verifyFrame(frame, family: .whoop5).ok)
        let field = PuffinDeepBufferLog.decodedImuField(frame)
        XCTAssertTrue(field.hasPrefix(",\"imu\":{"), "a 1244-B IMU buffer must emit an inline summary")
        XCTAssertTrue(field.contains("\"sampleCount\":100"), "summary carries the 100 decoded samples")
        XCTAssertTrue(field.contains("accelEnergyG"), "summary carries the activity features")
    }

    func testNoImuFieldForOpticalOrUndecodableBuffers() {
        // The 2140-B optical buffer is a different, still-undecoded layout — no IMU summary.
        var optical = [UInt8](repeating: 0, count: 2140); optical[8] = 0x2F
        XCTAssertEqual(PuffinDeepBufferLog.decodedImuField(optical), "")
        // A 1244-length frame whose count fields aren't 100 fails decode → field omitted, never a throw.
        var bogus = imuBuffer(); bogus[24] = 0
        bogus = sealingChecksums(bogus)
        XCTAssertTrue(verifyFrame(bogus, family: .whoop5).ok)
        XCTAssertEqual(PuffinDeepBufferLog.decodedImuField(bogus), "")
    }

    func testNoImuSummaryForCorruptOrUnrecognizedEnvelope() {
        for offset in [6, 100] {
            var corrupt = imuBuffer(); corrupt[offset] ^= 1
            XCTAssertFalse(verifyFrame(corrupt, family: .whoop5).ok)
            XCTAssertEqual(PuffinDeepBufferLog.decodedImuField(corrupt), "",
                           "A plausible IMU shape must not bypass either checksum in diagnostic summaries")
        }
        var unknown = imuBuffer(); unknown[9] = 22
        unknown = sealingChecksums(unknown)
        XCTAssertTrue(verifyFrame(unknown, family: .whoop5).ok)
        XCTAssertEqual(PuffinDeepBufferLog.decodedImuField(unknown), "")
    }

    /// The optical phase marker is a stable machine schema the offline analyzer depends on.
    func testOpticalMarkerSchemaUsesStableClockAndLabelKeys() throws {
        let line = try XCTUnwrap(PuffinDeepBufferLog.markerJSONLine(
            phase: .offWristDark, tsMs: 1_234_567, unixTs: 1_234))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])

        XCTAssertEqual(object["kind"] as? String, "optical_phase")
        XCTAssertEqual(object["label"] as? String, "off_wrist_dark")
        XCTAssertEqual(object["unix_ts"] as? Int, 1_234)
        XCTAssertEqual(object["ts_ms"] as? Int, 1_234_567)
        XCTAssertNil(object["strap_ts"])
        XCTAssertNil(object["hex"])
    }
}
