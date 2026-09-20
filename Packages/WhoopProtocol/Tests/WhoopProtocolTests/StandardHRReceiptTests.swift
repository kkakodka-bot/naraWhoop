import XCTest
@testable import WhoopProtocol

final class StandardHRReceiptTests: XCTestCase {
    private let session = "11111111-2222-3333-4444-555555555555"

    func testOriginalTicksAndSlotsSurviveSerializationWithoutInventedBeatTime() throws {
        let receipt = try XCTUnwrap(StandardHRReceipt.capture([0x16, 60, 0, 4, 0, 0, 0, 4],
            sessionId: session, notificationOrdinal: 7, receivedUnixMs: 1_700_000_000_999,
            receivedMonotonicNs: 10_000_000_000_000_001))
        XCTAssertEqual(receipt.rrRawTicks, [1024, 0, 1024])
        XCTAssertEqual(receipt.ts, 1_700_000_000)
        XCTAssertEqual(receipt.clockVersion, "host-arrival-unmapped")
        XCTAssertEqual(try JSONDecoder().decode(StandardHRReceipt.self, from: JSONEncoder().encode(receipt)), receipt)
        XCTAssertEqual(try JSONDecoder().decode(Streams.self, from: JSONEncoder().encode(Streams(standardHrReceipts: [receipt]))).standardHrReceipts, [receipt])
    }

    func testEqualSameSecondNotificationsHaveDistinctIdentityButReplayIsStable() throws {
        func capture(_ ordinal: Int64) throws -> StandardHRReceipt {
            try XCTUnwrap(StandardHRReceipt.capture([0x10, 60, 0, 4], sessionId: session,
                notificationOrdinal: ordinal, receivedUnixMs: 1001, receivedMonotonicNs: 2000))
        }
        XCTAssertNotEqual(try capture(0).receiptId, try capture(1).receiptId)
        XCTAssertEqual(try capture(0), try capture(0))
        XCTAssertNil(StandardHRReceipt.capture([0], sessionId: "invalid", notificationOrdinal: 0,
            receivedUnixMs: 0, receivedMonotonicNs: 0))
    }

    func testIncompleteFieldsRetainBytesButCannotInventPartialRrTrain() throws {
        for bytes: [UInt8] in [[0x10, 60, 0], [0x18, 60, 0], [0x10, 60], [0x01, 60]] {
            let receipt = try XCTUnwrap(StandardHRReceipt.capture(bytes, sessionId: session,
                notificationOrdinal: 0, receivedUnixMs: 0, receivedMonotonicNs: 0))
            XCTAssertTrue(receipt.isValid)
            XCTAssertNil(receipt.rrRawTicks)
        }
    }
}
