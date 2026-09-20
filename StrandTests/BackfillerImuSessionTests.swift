import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore

/// FRWHOOP issue #1: historical 100 Hz IMU buffers must reach the session store before trim ack.
@MainActor
final class BackfillerImuSessionTests: XCTestCase {
    private final class SpyStore: BackfillStoreWriting {
        var operations: [String] = []

        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            operations.append("insert")
            return (0, 0, 0, 0, 0, 0, 0, 0)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws { operations.append("raw") }
        func setCursor(_ name: String, _ value: Int) async throws { operations.append("cursor") }
        func cursor(_ name: String) async throws -> Int? { nil }
        func markJobsOwed(kinds: [String], note: String?) async throws -> [String: String] {
            operations.append("debt")
            return Dictionary(uniqueKeysWithValues: kinds.map { ($0, "token") })
        }
    }

    private let whoop5HistoryEndHex =
        "aa011c00010023d1316a0284a3266a0a373d00000041b601001000000000000044d21e3d"

    private func hexBytes(_ hex: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(hex.count / 2); var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

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

    func testHistoricalImuReachesSinkBeforeAck() async {
        let store = SpyStore()
        var imuRecordsSeen = 0
        var acked = false
        let backfiller = Backfiller(
            store: store,
            deviceId: "devA",
            ackTrim: { _, _ in
                store.operations.append("ack")
                acked = true
            },
            rejectedSink: { frames, _, _ in
                XCTAssertFalse(frames.isEmpty)
                XCTAssertFalse(acked)
                store.operations.append("archive")
                return true
            },
            imuSessionSink: { _, records in
                XCTAssertFalse(acked)
                store.operations.append("imu")
                imuRecordsSeen += records.count
                return true
            })
        backfiller.begin(family: .whoop5)
        await backfiller.ingest(makeValidImuFrame(unix: 1_500))
        await backfiller.ingest(hexBytes(whoop5HistoryEndHex))

        XCTAssertEqual(imuRecordsSeen, 1)
        XCTAssertTrue(acked)
        XCTAssertFalse(backfiller.persistStalled)
        XCTAssertEqual(store.operations.filter { ["archive", "imu", "cursor", "ack"].contains($0) },
                       ["archive", "imu", "cursor", "ack"],
                       "exact recovery evidence and IMU must be durable before cursor and ACK")
    }

    func testChunkTimingIncludesSlowDiagnosticAndArchiveCallbacksBeforeAck() async {
        let store = SpyStore()
        var acked = false
        let backfiller = Backfiller(
            store: store, deviceId: "devA",
            ackTrim: { _, _ in acked = true },
            log: { _ in try? await Task.sleep(nanoseconds: 20_000_000) },
            rejectedSink: { _, _, _ in
                try? await Task.sleep(nanoseconds: 20_000_000)
                return true
            })
        backfiller.begin(family: .whoop5)
        await backfiller.ingest(makeValidImuFrame(unix: 1_500, seed: 1))
        await backfiller.ingest(hexBytes(whoop5HistoryEndHex))
        guard let sample = backfiller.sessionPhaseTimingSamples().last else {
            return XCTFail("Missing chunk timing")
        }
        XCTAssertTrue(acked)
        XCTAssertGreaterThanOrEqual(sample.diagnosticsMs, 20)
        XCTAssertGreaterThanOrEqual(sample.archiveMs, 20)
        XCTAssertGreaterThanOrEqual(sample.totalMs, sample.diagnosticsMs + sample.archiveMs)
    }

    func testImuFlushFailureStallsAck() async {
        let store = SpyStore()
        var acked = false
        let backfiller = Backfiller(
            store: store,
            deviceId: "devA",
            ackTrim: { _, _ in acked = true },
            imuSessionSink: { _, _ in false })
        backfiller.begin(family: .whoop5)
        await backfiller.ingest(makeValidImuFrame(unix: 1_500))
        await backfiller.ingest(hexBytes(whoop5HistoryEndHex))

        XCTAssertTrue(backfiller.persistStalled)
        XCTAssertFalse(acked)
        XCTAssertFalse(store.operations.contains("cursor"))
    }

    func testCachedImuRecordsKeepExactColumnsAndExcludeInvalidFrames() async throws {
        let first = makeValidImuFrame(unix: 1_500, seed: 1)
        let second = makeValidImuFrame(unix: 1_501, seed: 2)
        var corrupt = first
        corrupt[28] ^= 0xff
        var unknownLayout = second
        unknownLayout[9] = 22
        let crc = crc32(Array(unknownLayout[8..<(unknownLayout.count - 4)]))
        for offset in 0..<4 { unknownLayout[unknownLayout.count - 4 + offset] = UInt8(truncatingIfNeeded: crc >> (offset * 8)) }
        XCTAssertNil(Whoop5RawImu.decodeColumns(corrupt))
        XCTAssertNil(Whoop5RawImu.decodeColumns(unknownLayout))
        var seen: [(baseTs: Int, columns: [Int16])] = []
        var acked = false
        let backfiller = Backfiller(store: SpyStore(), deviceId: "synthetic",
            ackTrim: { _, _ in acked = true }, rejectedSink: { _, _, _ in true },
            imuSessionSink: { _, records in seen = records; return true })
        backfiller.begin(family: .whoop5)
        for frame in [first, corrupt, unknownLayout, second] { await backfiller.ingest(frame) }
        await backfiller.ingest(hexBytes(whoop5HistoryEndHex))
        XCTAssertTrue(acked)
        XCTAssertEqual(seen.map(\.baseTs), [1_500, 1_501])
        XCTAssertEqual(seen.map(\.columns), [try XCTUnwrap(Whoop5RawImu.decodeColumns(first)).columns,
                                           try XCTUnwrap(Whoop5RawImu.decodeColumns(second)).columns])
    }
}
