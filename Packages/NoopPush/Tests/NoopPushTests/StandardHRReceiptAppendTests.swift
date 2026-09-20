import XCTest
@testable import NoopPush

final class StandardHRReceiptAppendTests: XCTestCase {
    func testSameSecondIdenticalNotificationsKeepIdentityAndExactMonotonicClock() throws {
        let session = "00000000-0000-4000-8000-000000000001"
        let source = "00000000-0000-4000-8000-000000000002"
        let rows = (0...1).map { ordinal in
            PushAppendRecord(rowId: Int64(ordinal + 1), key: ["receiptId": .string("\(session):\(ordinal)")], data: [
                "ts": .int(1_700_000_000), "sessionId": .string(session), "notificationOrdinal": .int(Int64(ordinal)),
                "receivedUnixMs": .int(1_700_000_000_123), "receivedMonotonicNs": .string("9007199254740993"),
                "rawHex": .string("103c0004"), "schemaVersion": .int(1), "clockVersion": .string("host-arrival-unmapped")])
        }
        let batch = try PushProtocol.appendBatch(table: .standardHRReceipt, sourceId: source, deviceId: "d", startCursor: nil, records: rows)
        let replay = try PushProtocol.appendBatch(table: .standardHRReceipt, sourceId: source, deviceId: "d", startCursor: nil, records: rows)
        XCTAssertEqual(batch.protocolVersion, "1.1")
        XCTAssertEqual(batch.recordCount, 2)
        XCTAssertEqual(batch.body, replay.body)
        let lines = try String(decoding: batch.body, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(lines[0]["protocolVersion"] as? String, "1.1")
        for ordinal in 0...1 {
            let row = lines[ordinal + 1]
            XCTAssertEqual((row["key"] as? [String: Any])?["receiptId"] as? String, "\(session):\(ordinal)")
            XCTAssertEqual((row["data"] as? [String: Any])?["receivedMonotonicNs"] as? String, "9007199254740993")
            XCTAssertNil((row["data"] as? [String: Any])?["verifiedSpan"])
        }
    }
}
