import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore

@MainActor
final class BackfillIdleWatchdogTests: XCTestCase {
    private enum Failure: Error, CaseIterable { case insert, archive, raw, imu, cursor }

    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        func append(_ event: String) {
            lock.lock(); defer { lock.unlock() }
            events.append(event)
        }
        var snapshot: [String] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }

    private final class CommitHookStore: BackfillStoreWriting {
        let failure: Failure?
        init(failure: Failure? = nil) { self.failure = failure }
        @discardableResult
        func insertAndMarkJobsOwed(_ streams: Streams, deviceId: String,
                                   postOffloadJobKinds: [String],
                                   note: String?) async throws -> BackfillInsertOutcome {
            if failure == .insert { throw Failure.insert }
            return BackfillInsertOutcome(counts: (1, 0, 0, 0, 0, 0, 0, 0), markedJobs: true)
        }
        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            (0, 0, 0, 0, 0, 0, 0, 0)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
            if failure == .raw { throw Failure.raw }
        }
        func setCursor(_ name: String, _ value: Int) async throws {
            if failure == .cursor { throw Failure.cursor }
        }
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private let whoop5HistoryEndHex =
        "aa011c00010023d1316a0284a3266a0a373d00000041b601001000000000000044d21e3d"

    private func hexBytes(_ hex: String) -> [UInt8] {
        var out = [UInt8](); var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    private func stampWhoop5Checksums(_ frame: inout [UInt8]) {
        let headerCRC = crc16Modbus(Array(frame[0..<6]))
        frame[6] = UInt8(headerCRC & 0xff); frame[7] = UInt8((headerCRC >> 8) & 0xff)
        let end = frame.count - 4
        let bodyCRC = crc32(Array(frame[8..<end]))
        for i in 0..<4 { frame[end + i] = UInt8(truncatingIfNeeded: bodyCRC >> (i * 8)) }
    }

    private func makeValidImuFrame() -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: 1244)
        frame[0] = 0xaa; frame[1] = 1
        let declared = frame.count - 8
        frame[2] = UInt8(declared & 0xff); frame[3] = UInt8(declared >> 8)
        frame[4] = 1; frame[8] = 47; frame[9] = 21; frame[10] = 0x80
        let unix: UInt32 = 1_700_000_100
        for i in 0..<4 { frame[15 + i] = UInt8(truncatingIfNeeded: unix >> (i * 8)) }
        frame[24] = 100; frame[630] = 100
        stampWhoop5Checksums(&frame)
        return frame
    }

    private func metadata(family: DeviceFamily, type: UInt8, command: UInt8) -> [UInt8] {
        if family == .whoop4 {
            return frameFromPayload([UInt8](repeating: 0, count: 18), type: type, seq: 0, cmd: command)
        }
        var frame = hexBytes(whoop5HistoryEndHex)
        frame[8] = type; frame[10] = command
        stampWhoop5Checksums(&frame)
        return frame
    }

    override func tearDown() {
        BLEManager.backfillIdleTimeoutSecondsForTesting = nil
        BLEManager.backfillCommitTimeoutSecondsForTesting = nil
        super.tearDown()
    }

    func testCommitBeginsBeforeDecodeAndDiagnostics() async {
        let trace = Trace()
        let backfiller = Backfiller(
            store: CommitHookStore(), deviceId: "test",
            ackTrim: { _, _ in trace.append("ack") },
            log: { _ in trace.append("diagnostic") },
            onChunkCommitBegin: { trace.append("begin") },
            onChunkCommitAborted: { trace.append("aborted") },
            extract: { _, _, _, _, _ in
                trace.append("decode")
                return Streams(hr: [HRSample(ts: 1_700_000_100, bpm: 61)])
            })
        backfiller.begin(family: .whoop5)
        await backfiller.ingest(makeValidImuFrame())
        await backfiller.ingest(hexBytes(whoop5HistoryEndHex))
        let events = trace.snapshot
        XCTAssertEqual(events.first, "begin")
        XCTAssertEqual(events.filter { $0 == "begin" }.count, 1)
        XCTAssertTrue(events.contains("decode"))
        XCTAssertEqual(events.last, "ack")
        XCTAssertFalse(events.contains("aborted"))
    }

    func testEveryFailedCommitBalancesPauseWithoutAck() async {
        for failure in Failure.allCases {
            let trace = Trace()
            let backfiller = Backfiller(
                store: CommitHookStore(failure: failure), deviceId: "test",
                ackTrim: { _, _ in trace.append("ack") },
                enableRawCapture: true,
                rejectedSink: { _, _, _ in failure != .archive },
                imuSessionSink: { _, _ in failure != .imu },
                onChunkCommitBegin: { trace.append("begin") },
                onChunkCommitAborted: { trace.append("aborted") },
                extract: { _, _, _, _, _ in
                    Streams(hr: [HRSample(ts: 1_700_000_100, bpm: 61)])
                })
            backfiller.begin(family: .whoop5)
            await backfiller.ingest(makeValidImuFrame())
            await backfiller.ingest(hexBytes(whoop5HistoryEndHex))
            XCTAssertEqual(trace.snapshot, ["begin", "aborted"], "failure=\(failure)")
            XCTAssertTrue(backfiller.persistStalled, "failure=\(failure)")
            // An empty END after a failed write must balance its pause and still hold the ACK.
            await backfiller.ingest(hexBytes(whoop5HistoryEndHex))
            XCTAssertEqual(trace.snapshot, ["begin", "aborted", "begin", "aborted"], "failure=\(failure)")
        }
    }

    func testEmptyEndCursorFailureBalancesPause() async {
        let trace = Trace()
        let backfiller = Backfiller(
            store: CommitHookStore(failure: .cursor), deviceId: "test",
            ackTrim: { _, _ in trace.append("ack") },
            onChunkCommitBegin: { trace.append("begin") },
            onChunkCommitAborted: { trace.append("aborted") })
        backfiller.begin(family: .whoop5)
        await backfiller.ingest(hexBytes(whoop5HistoryEndHex))
        XCTAssertEqual(trace.snapshot, ["begin", "aborted"])
    }

    func testSlowDecodeRemainsActiveBeyondIdleDeadline() async {
        BLEManager.backfillIdleTimeoutSecondsForTesting = 1
        BLEManager.backfillCommitTimeoutSecondsForTesting = 5
        let live = LiveState()
        let manager = BLEManager(state: live, startCentral: false)
        manager.test_simulateActiveBackfillSessionForWatchdog()
        manager.armBackfillTimeout()
        let decoderStarted = expectation(description: "decoder started")
        let releaseDecoder = DispatchSemaphore(value: 0)
        let backfiller = Backfiller(
            store: CommitHookStore(failure: .insert), deviceId: "test",
            ackTrim: { _, _ in XCTFail("failed persistence must hold the ACK") },
            onChunkCommitBegin: { await MainActor.run { manager.pauseBackfillIdleWatchdogForCommit() } },
            onChunkCommitAborted: { await MainActor.run { manager.resumeBackfillIdleWatchdogAfterAbortedCommit() } },
            extract: { _, _, _, _, _ in
                decoderStarted.fulfill()
                _ = releaseDecoder.wait(timeout: .now() + 5)
                return Streams(hr: [HRSample(ts: 1_700_000_100, bpm: 61)])
            })
        backfiller.begin(family: .whoop5)
        await backfiller.ingest(makeValidImuFrame())
        let end = hexBytes(whoop5HistoryEndHex)
        let commit = Task { await backfiller.ingest(end) }
        await fulfillment(of: [decoderStarted], timeout: 2)
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertTrue(live.backfilling, "a decoder held longer than the 1s idle window is local work")
        XCTAssertTrue(manager.chunkCommitInFlight)
        releaseDecoder.signal()
        await commit.value
        XCTAssertFalse(manager.chunkCommitInFlight)
    }

    func testIdleWatchdogFiresWhenNoCommitInFlight() async {
        BLEManager.backfillIdleTimeoutSecondsForTesting = 1
        let live = LiveState()
        let manager = BLEManager(state: live, startCentral: false)
        manager.test_simulateActiveBackfillSessionForWatchdog()
        manager.armBackfillTimeout()
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertFalse(live.backfilling)
    }

    func testMetadataFilterPreservesRecordsAndCorruptEnds() async {
        let formats: [(DeviceFamily, UInt8)] = [(.whoop4, 49), (.whoop5, 49)]
        for (family, type) in formats {
            let trace = Trace()
            let backfiller = Backfiller(
                store: CommitHookStore(), deviceId: "test",
                ackTrim: { _, _ in trace.append("ack") },
                extract: { frames, _, _, _, _ in
                    trace.append("decode:\(frames.count)")
                    return Streams(hr: [HRSample(ts: 1_700_000_100, bpm: 61)])
                })
            backfiller.begin(family: family)
            await backfiller.ingest(family == .whoop5 ? makeValidImuFrame()
                                   : frameFromPayload([42], type: 47, seq: 0, cmd: 18))
            let end = metadata(family: family, type: type, command: 2)
            var corruptEnd = end
            corruptEnd[corruptEnd.count - 1] ^= 1
            await backfiller.ingest(corruptEnd)
            await backfiller.ingest([0xaa])
            XCTAssertEqual(trace.snapshot, [], "corrupt END must not close or acknowledge a chunk")
            await backfiller.ingest(end)
            XCTAssertEqual(trace.snapshot, ["decode:3", "ack"], "family=\(family), type=\(type)")
            await backfiller.ingest(metadata(family: family, type: type, command: 3))
            XCTAssertFalse(backfiller.isBackfilling)
            await backfiller.ingest(metadata(family: family, type: type, command: 1))
            XCTAssertTrue(backfiller.isBackfilling)
        }
    }

    func testCanonicalMetadataWithoutMappedFieldsRemainsBuffered() async {
        let trace = Trace()
        let backfiller = Backfiller(
            store: CommitHookStore(), deviceId: "test",
            ackTrim: { _, _ in trace.append("ack") },
            extract: { frames, _, _, _, _ in
                trace.append("decode:\(frames.count)")
                return Streams(hr: [HRSample(ts: 1_700_000_100, bpm: 61)])
            })
        backfiller.begin(family: .whoop5)
        await backfiller.ingest(makeValidImuFrame())
        // Type 56 has a canonical name but no field schema in this revision. The optimization
        // must preserve the full parser's .other verdict rather than invent a metadata layout.
        for command in [UInt8(2), UInt8(3)] {
            let frame = metadata(family: .whoop5, type: 56, command: command)
            XCTAssertEqual(frameTypeName(frame, family: .whoop5), "METADATA")
            XCTAssertEqual(classifyHistoricalMeta(parseFrame(frame, family: .whoop5)), .other)
            await backfiller.ingest(frame)
        }
        XCTAssertTrue(backfiller.isBackfilling)
        XCTAssertEqual(trace.snapshot, [])
        await backfiller.ingest(hexBytes(whoop5HistoryEndHex))
        XCTAssertEqual(trace.snapshot, ["decode:3", "ack"])
    }
}
