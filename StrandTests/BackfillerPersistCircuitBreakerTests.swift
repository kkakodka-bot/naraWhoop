import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore

/// A persist failure fences all further input until a fresh session retries the retained chunk.
final class BackfillerPersistCircuitBreakerTests: XCTestCase {
    private final class FailingStore: BackfillStoreWriting {
        private(set) var attempts = 0

        @discardableResult
        func insertAndMarkJobsOwed(_ streams: Streams, deviceId: String,
                                   postOffloadJobKinds: [String],
                                   note: String?) async throws -> BackfillInsertOutcome {
            attempts += 1
            throw NSError(domain: "test", code: 1)
        }

        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            attempts += 1
            throw NSError(domain: "test", code: 1)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws {}
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private let whoop5HistoryEndHex =
        "aa011c00010023d1316a0284a3266a0a373d00000041b601001000000000000044d21e3d"

    private func makeValidImuFrame(unix: UInt32, seed: UInt8 = 0) -> [UInt8] {
        let total = 1244
        var frame = [UInt8](repeating: 0, count: total)
        frame[0] = 0xAA; frame[1] = 0x01
        let declared = total - 8
        frame[2] = UInt8(declared & 0xff); frame[3] = UInt8((declared >> 8) & 0xff)
        frame[4] = 0x01; frame[5] = 0x00
        frame[8] = 0x2f; frame[9] = 21
        frame[10] = 0x80
        frame[15] = UInt8(unix & 0xff); frame[16] = UInt8((unix >> 8) & 0xff)
        frame[17] = UInt8((unix >> 16) & 0xff); frame[18] = UInt8((unix >> 24) & 0xff)
        frame[24] = 100; frame[630] = 100
        if seed != 0 { frame[28] = seed }
        let headerCRC = crc16Modbus(Array(frame[0..<6]))
        frame[6] = UInt8(headerCRC & 0xff); frame[7] = UInt8((headerCRC >> 8) & 0xff)
        let payloadEnd = total - 4
        let bodyCRC = crc32(Array(frame[8..<payloadEnd]))
        frame[payloadEnd] = UInt8(bodyCRC & 0xff); frame[payloadEnd + 1] = UInt8((bodyCRC >> 8) & 0xff)
        frame[payloadEnd + 2] = UInt8((bodyCRC >> 16) & 0xff); frame[payloadEnd + 3] = UInt8((bodyCRC >> 24) & 0xff)
        return frame
    }

    private func hexBytes(_ hex: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(hex.count / 2); var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    private func makeHrFrame(unix: UInt32) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: 64)
        frame[0] = 0xAA; frame[1] = 0x01
        frame[4] = 0x2f; frame[5] = 18
        frame[10] = UInt8(unix & 0xff); frame[11] = UInt8((unix >> 8) & 0xff)
        frame[12] = UInt8((unix >> 16) & 0xff); frame[13] = UInt8((unix >> 24) & 0xff)
        frame[14] = 70
        let headerCRC = crc16Modbus(Array(frame[0..<6]))
        frame[6] = UInt8(headerCRC & 0xff); frame[7] = UInt8((headerCRC >> 8) & 0xff)
        let payloadEnd = frame.count - 4
        let bodyCRC = crc32(Array(frame[8..<payloadEnd]))
        frame[payloadEnd] = UInt8(bodyCRC & 0xff); frame[payloadEnd + 1] = UInt8((bodyCRC >> 8) & 0xff)
        frame[payloadEnd + 2] = UInt8((bodyCRC >> 16) & 0xff); frame[payloadEnd + 3] = UInt8((bodyCRC >> 24) & 0xff)
        return frame
    }

    func testFirstPersistFailureFencesInputUntilFreshSession() async {
        let store = FailingStore()
        var acks = 0
        let broke = BreakerBox()
        let backfiller = Backfiller(
            store: store,
            deviceId: "devA",
            ackTrim: { _, _ in acks += 1 },
            onPersistCircuitBreak: { broke.tripped = true })
        backfiller.begin(family: .whoop5)
        for _ in 1...3 {
            await backfiller.ingest(makeValidImuFrame(unix: 1_500))
            await backfiller.ingest(hexBytes(whoop5HistoryEndHex))
        }
        XCTAssertEqual(acks, 0)
        XCTAssertEqual(store.attempts, 1, "a stalled session must not keep decoding or retrying writes")
        XCTAssertTrue(backfiller.persistStalled)
        XCTAssertFalse(broke.tripped, "discarded later packets are not additional persistence attempts")

        backfiller.timeoutFired()
        XCTAssertFalse(backfiller.isBackfilling)
        backfiller.begin(family: .whoop5)
        XCTAssertFalse(backfiller.persistStalled)
        await backfiller.ingest(makeValidImuFrame(unix: 1_500))
        await backfiller.ingest(hexBytes(whoop5HistoryEndHex))
        XCTAssertEqual(store.attempts, 2, "the fresh session must retry data left on the strap")
        XCTAssertTrue(backfiller.persistStalled)
        XCTAssertEqual(acks, 0)
    }
}

private final class BreakerBox: @unchecked Sendable {
    var tripped = false
}
