import XCTest
@testable import NoopPush

final class PpgIdentityCodecTests: XCTestCase {
    func testKnownIdentityCannotUseLegacyPayload() throws {
        let row = PushBinaryRow.ppgWaveform(.init(rowId: 1, ts: 100, burstIndex: nil,
                                                samples: Data([1, 2]), recordIndex: 9))
        XCTAssertThrowsError(try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: [row]))
        let bytes = try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: [row], ppgIdentityV2: true)
        XCTAssertEqual(bytes[4], 2)
        XCTAssertEqual(bytes[26], 1)
        XCTAssertEqual(Array(bytes[27..<35]), [9, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(bytes.count, 10 + (try PushBinaryCodec.packedRowSize(row, ppgIdentityV2: true)))
    }

    func testSameSecondIdentityChangesFingerprintAndUnknownIsExplicit() throws {
        func row(_ index: Int64?) -> PushBinaryRow {
            .ppgWaveform(.init(rowId: 1, ts: 100, burstIndex: nil, samples: Data([1, 2]), recordIndex: index))
        }
        let first = try PushProtocol.binaryKeyFingerprint(table: .ppgWaveformSample, deviceId: "a", row: row(1))
        let second = try PushProtocol.binaryKeyFingerprint(table: .ppgWaveformSample, deviceId: "a", row: row(2))
        XCTAssertNotEqual(first, second)
        let unknown = try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: [row(nil)], ppgIdentityV2: true)
        XCTAssertEqual(unknown[26], 0)
        XCTAssertEqual(try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: [row(nil)])[4], 1)
    }
}
