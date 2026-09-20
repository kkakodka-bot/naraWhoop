import XCTest
@testable import NoopPush

final class RRPacketAppendTests: XCTestCase {
    func testVersionedPacketCompanionRetainsRawBytesAndStableIdentity() throws {
        let hex = "aa011a00010023592f12000000000000f153650000003c03000400000002c74eaa5b"
        let id = "e52beecb9be542acaabce3b8e6d34e4b95e19e31b0c39c910df986da3b2b578b"
        let row = PushAppendRecord(rowId: 1, key: ["packetId": .string(id)], data: [
            "ts": .int(1700000000), "sensorTs": .int(1700000000), "recordIndex": .int(0), "rawHex": .string(hex),
            "srcChannel": .int(5), "schemaVersion": .int(1), "decoderVersion": .string("whoop5-v18-original-words-v1"),
            "clockVersion": .string("sensor-second-unmapped"), "timestampPrecisionSeconds": .int(1),
            "clockOffsetSeconds": .int(0), "declaredCount": .int(3)])
        let batch = try PushProtocol.appendBatch(table: .rrPacketProvenance,
            sourceId: "3a3486dd-5030-4e17-a00d-a781399890f9", deviceId: "d", startCursor: nil, records: [row])
        XCTAssertEqual(batch.protocolVersion, "1.1")
        let lines = String(decoding: batch.body, as: UTF8.self).split(separator: "\n")
        let header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        let record = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as! [String: Any]
        XCTAssertEqual(header["protocolVersion"] as? String, "1.1")
        XCTAssertEqual((record["key"] as? [String: Any])?["packetId"] as? String, id)
        XCTAssertEqual((record["data"] as? [String: Any])?["rawHex"] as? String, hex)
    }
}
