import XCTest
@testable import NoopPush

final class PpgIdentityBinaryTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Row: Decodable {
            let rowId: Int64; let ts: Int64; let burstIndex: Int32?; let recordIndex: Int64?; let samples: String
        }
        let rows: [Row]; let hex: String
    }
    private func hex(_ value: String) -> Data {
        let chars = Array(value)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! })
    }
    func testSharedOraclePreservesMultipleRecordsAndUnsignedIdentity() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ppg_identity_binary_oracle", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let records = fixture.rows.map { PushPpgWaveformRecord(rowId: $0.rowId, ts: $0.ts,
            burstIndex: $0.burstIndex, samples: hex($0.samples), recordIndex: $0.recordIndex) }
        let bytes = try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: records.map(PushBinaryRow.ppgWaveform))
        XCTAssertEqual(bytes, hex(fixture.hex))
        let decoded = try PushBinaryCodec.unpackPpgRecords(bytes)
        XCTAssertEqual(decoded.map(\.recordIndex), records.map(\.recordIndex))
        XCTAssertEqual(decoded.map(\.samples), records.map(\.samples))
        XCTAssertEqual(decoded.map(\.rowId), records.map(\.rowId))
        XCTAssertEqual(decoded.map(\.ts), records.map(\.ts))
        XCTAssertNotEqual(try PushProtocol.binaryKeyFingerprint(table: .ppgWaveformSample, deviceId: "d", row: .ppgWaveform(records[0])),
                          try PushProtocol.binaryKeyFingerprint(table: .ppgWaveformSample, deviceId: "d", row: .ppgWaveform(records[1])))
        for size in 0..<bytes.count {
            XCTAssertThrowsError(try PushBinaryCodec.unpackPpgRecords(bytes.prefix(size)))
        }
        XCTAssertThrowsError(try PushBinaryCodec.unpackPpgRecords(bytes + Data([0])))
    }
    func testLegacyV1StillDecodesAndRetainsOriginalBytes() throws {
        let bytes = hex("4e5042310101010000000500000000000000320000000000000000010000000a")
        let rows = try PushBinaryCodec.unpackPpgRecords(bytes)
        XCTAssertNil(rows.first?.recordIndex)
        XCTAssertEqual(try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: rows.map(PushBinaryRow.ppgWaveform)), bytes)
    }
}
