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
        let writes = Trace()
        init(failure: Failure? = nil) { self.failure = failure }
        @discardableResult
        func insertAndMarkJobsOwed(_ streams: Streams, deviceId: String,
                                   postOffloadJobKinds: [String],
                                   note: String?) async throws -> BackfillInsertOutcome {
            writes.append("insert")
            if failure == .insert { throw Failure.insert }
            return BackfillInsertOutcome(counts: (1, 0, 0, 0, 0, 0, 0, 0), markedJobs: true)
        }
        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            (0, 0, 0, 0, 0, 0, 0, 0)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
            writes.append("raw")
            if failure == .raw { throw Failure.raw }
        }
        func setCursor(_ name: String, _ value: Int) async throws {
            writes.append("cursor")
            if failure == .cursor { throw Failure.cursor }
            writes.append("cursor.committed")
        }
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private struct DurableArchive {
        let store: WhoopStore
        let path: String
        let trace: Trace
        let scope = DurableIngestScope.unassigned(deviceID: "test")

        func persist(_ frames: [[UInt8]], trim: UInt32, family: DeviceFamily) async -> Bool {
            do {
                try await store.persistSensorQuarantine(frames, scope: scope,
                    family: String(describing: family), trim: trim, preserveOccurrences: true)
                trace.append("archive")
                return true
            } catch {
                trace.append("archive.failed")
                return false
            }
        }

        func reopenedRecords() async throws -> [SensorQuarantineRecord] {
            let reopened = try await WhoopStore(path: path)
            return try await reopened.pendingSensorQuarantine(scope: scope)
        }

        func assertPersistedFrames(_ frames: [[UInt8]], trim: UInt32, family: DeviceFamily,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
            let records = try await reopenedRecords()
            let members = records.map {
                (record: $0, identity: QuarantineArchiveIdentity(recordID: $0.id,
                    family: $0.family, trim: $0.trim))
            }
            XCTAssertEqual(members.compactMap { $0.identity.ordinal }.sorted(),
                           Array(frames.indices), "every occurrence needs its original ordinal", file: file, line: line)
            let ordered = members.sorted { ($0.identity.ordinal ?? -1) < ($1.identity.ordinal ?? -1) }
            XCTAssertEqual(ordered.map { Array($0.record.frame) }, frames,
                           "reopened bytes must preserve the entire chunk in order", file: file, line: line)
            XCTAssertTrue(records.allSatisfy { $0.scope == scope && $0.trim == trim
                && $0.family == String(describing: family) }, file: file, line: line)
            XCTAssertEqual(Set(members.compactMap { $0.identity.chunkSHA256 }).count, 1,
                           "all members must belong to the same captured chunk", file: file, line: line)
        }
    }

    private func durableArchive(trace: Trace) async throws -> DurableArchive {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackfillIdleWatchdog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("quarantine.sqlite").path
        return DurableArchive(store: try await WhoopStore(path: path), path: path, trace: trace)
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

    func testCommitBeginsBeforeDecodeAndDiagnostics() async throws {
        let trace = Trace()
        let archive = try await durableArchive(trace: trace)
        let backfiller = Backfiller(
            store: CommitHookStore(), deviceId: "test",
            ackTrim: { _, _ in trace.append("ack") },
            log: { _ in trace.append("diagnostic") },
            rejectedSink: { await archive.persist($0, trim: $1, family: $2) },
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
        XCTAssertTrue(events.contains("archive"))
        XCTAssertEqual(events.last, "ack")
        XCTAssertFalse(events.contains("aborted"))
        let records = try await archive.reopenedRecords()
        XCTAssertEqual(records.map { Array($0.frame) }, [makeValidImuFrame()])
    }

    func testEveryFailedCommitBalancesPauseWithoutAck() async throws {
        for failure in Failure.allCases {
            let trace = Trace()
            let archiveTrace = Trace()
            let archive = try await durableArchive(trace: archiveTrace)
            let store = CommitHookStore(failure: failure)
            let backfiller = Backfiller(
                store: store, deviceId: "test",
                ackTrim: { _, _ in trace.append("ack") },
                enableRawCapture: true,
                rejectedSink: { frames, trim, family in
                    if failure == .archive {
                        archiveTrace.append("archive.failed")
                        return false
                    }
                    return await archive.persist(frames, trim: trim, family: family)
                },
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
            let writes = store.writes.snapshot
            let expectedWrites: [String]
            switch failure {
            case .insert, .archive: expectedWrites = ["insert"]
            case .raw, .imu: expectedWrites = ["insert", "raw"]
            case .cursor: expectedWrites = ["insert", "raw", "cursor"]
            }
            XCTAssertEqual(writes, expectedWrites, "must reach the selected failure=\(failure)")
            let expectedArchive = failure == .insert ? [] : [failure == .archive ? "archive.failed" : "archive"]
            XCTAssertEqual(archiveTrace.snapshot, expectedArchive, "failure=\(failure)")
            let records = try await archive.reopenedRecords()
            XCTAssertEqual(records.map { Array($0.frame) },
                           failure == .insert || failure == .archive ? [] : [makeValidImuFrame()])
            // The stall fence rejects later ENDs before starting another commit or watchdog pause.
            await backfiller.ingest(hexBytes(whoop5HistoryEndHex))
            XCTAssertEqual(trace.snapshot, ["begin", "aborted"], "failure=\(failure)")
            XCTAssertEqual(store.writes.snapshot, writes, "stalled END must not reach the store")
            XCTAssertEqual(archiveTrace.snapshot, expectedArchive, "stalled END must not retry archival")
            XCTAssertTrue(backfiller.persistStalled)
            XCTAssertNil(backfiller.lastAckedTrim)
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

    func testMetadataFilterPreservesRecordsAndCorruptEnds() async throws {
        let formats: [(DeviceFamily, UInt8)] = [(.whoop4, 49), (.whoop5, 49)]
        for (family, type) in formats {
            let trace = Trace()
            let archive = try await durableArchive(trace: trace)
            let store = CommitHookStore()
            let record = family == .whoop5 ? makeValidImuFrame()
                : frameFromPayload([42], type: 47, seq: 0, cmd: 18)
            let end = metadata(family: family, type: type, command: 2)
            var corruptEnd = end
            corruptEnd[corruptEnd.count - 1] ^= 1
            let expectedFrames = [record, corruptEnd, [0xaa]]
            let backfiller = Backfiller(
                store: store, deviceId: "test",
                ackTrim: { trim, endData in
                    XCTAssertEqual(trace.snapshot, ["decode:3", "archive"])
                    XCTAssertEqual(store.writes.snapshot, ["insert", "cursor", "cursor.committed"])
                    XCTAssertEqual(endData, Backfiller.endData(from: end, family: family))
                    do { try await archive.assertPersistedFrames(expectedFrames, trim: trim, family: family) }
                    catch { XCTFail("ACK reached before a durable archive could be reopened: \(error)") }
                    trace.append("ack")
                },
                rejectedSink: { frames, trim, capturedFamily in
                    XCTAssertEqual(frames, expectedFrames)
                    XCTAssertEqual(capturedFamily, family)
                    XCTAssertEqual(trace.snapshot, ["decode:3"])
                    XCTAssertEqual(store.writes.snapshot, ["insert"])
                    return await archive.persist(frames, trim: trim, family: capturedFamily)
                },
                extract: { frames, _, _, _, _ in
                    XCTAssertEqual(frames.map(\.rawHex),
                                   expectedFrames.map { parseFrame($0, family: family).rawHex })
                    trace.append("decode:\(frames.count)")
                    return Streams(hr: [HRSample(ts: 1_700_000_100, bpm: 61)])
                })
            backfiller.begin(family: family)
            for frame in expectedFrames { await backfiller.ingest(frame) }
            XCTAssertEqual(trace.snapshot, [], "corrupt END must not close or acknowledge a chunk")
            XCTAssertEqual(store.writes.snapshot, [])
            XCTAssertNil(backfiller.lastAckedTrim)
            let beforeEnd = try await archive.reopenedRecords()
            XCTAssertTrue(beforeEnd.isEmpty)
            await backfiller.ingest(end)
            XCTAssertEqual(trace.snapshot, ["decode:3", "archive", "ack"], "family=\(family), type=\(type)")
            let trim = try XCTUnwrap(backfiller.lastAckedTrim)
            try await archive.assertPersistedFrames(expectedFrames, trim: trim, family: family)
            XCTAssertFalse(backfiller.persistStalled)
            await backfiller.ingest(metadata(family: family, type: type, command: 3))
            XCTAssertFalse(backfiller.isBackfilling)
            await backfiller.ingest(metadata(family: family, type: type, command: 1))
            XCTAssertTrue(backfiller.isBackfilling)
        }
    }

    func testCanonicalMetadataWithoutMappedFieldsRemainsBuffered() async throws {
        let trace = Trace()
        let archive = try await durableArchive(trace: trace)
        let store = CommitHookStore()
        let unknownMetadata = [UInt8(2), UInt8(3)].map {
            metadata(family: .whoop5, type: 56, command: $0)
        }
        let expectedFrames = [makeValidImuFrame()] + unknownMetadata
        let end = hexBytes(whoop5HistoryEndHex)
        let backfiller = Backfiller(
            store: store, deviceId: "test",
            ackTrim: { trim, endData in
                XCTAssertEqual(trace.snapshot, ["decode:3", "archive"])
                XCTAssertEqual(store.writes.snapshot, ["insert", "cursor", "cursor.committed"])
                XCTAssertEqual(endData, Backfiller.endData(from: end, family: .whoop5))
                do { try await archive.assertPersistedFrames(expectedFrames, trim: trim, family: .whoop5) }
                catch { XCTFail("ACK reached before a durable archive could be reopened: \(error)") }
                trace.append("ack")
            },
            rejectedSink: { frames, trim, family in
                XCTAssertEqual(frames, expectedFrames)
                XCTAssertEqual(family, .whoop5)
                XCTAssertEqual(trace.snapshot, ["decode:3"])
                XCTAssertEqual(store.writes.snapshot, ["insert"])
                return await archive.persist(frames, trim: trim, family: family)
            },
            extract: { frames, _, _, _, _ in
                XCTAssertEqual(frames.map(\.rawHex),
                               expectedFrames.map { parseFrame($0, family: .whoop5).rawHex })
                trace.append("decode:\(frames.count)")
                return Streams(hr: [HRSample(ts: 1_700_000_100, bpm: 61)])
            })
        backfiller.begin(family: .whoop5)
        await backfiller.ingest(makeValidImuFrame())
        // Type 56 has a canonical name but no field schema in this revision. The optimization
        // must preserve the full parser's .other verdict rather than invent a metadata layout.
        for frame in unknownMetadata {
            XCTAssertEqual(frameTypeName(frame, family: .whoop5), "METADATA")
            XCTAssertEqual(classifyHistoricalMeta(parseFrame(frame, family: .whoop5)), .other)
            await backfiller.ingest(frame)
        }
        XCTAssertTrue(backfiller.isBackfilling)
        XCTAssertEqual(trace.snapshot, [])
        XCTAssertEqual(store.writes.snapshot, [])
        XCTAssertNil(backfiller.lastAckedTrim)
        let beforeEnd = try await archive.reopenedRecords()
        XCTAssertTrue(beforeEnd.isEmpty)
        await backfiller.ingest(end)
        XCTAssertEqual(trace.snapshot, ["decode:3", "archive", "ack"])
        // Successful HR extraction cannot justify discarding the IMU or unmapped metadata bytes.
        let trim = try XCTUnwrap(backfiller.lastAckedTrim)
        try await archive.assertPersistedFrames(expectedFrames, trim: trim, family: .whoop5)
        XCTAssertFalse(backfiller.persistStalled)
    }

    func testRejectedRecordWithoutArchiveStallsAndIgnoresLaterEnd() async {
        let trace = Trace()
        let store = CommitHookStore()
        let backfiller = Backfiller(
            store: store, deviceId: "test",
            ackTrim: { _, _ in trace.append("ack") },
            onChunkCommitBegin: { trace.append("begin") },
            onChunkCommitAborted: { trace.append("aborted") },
            extract: { _, _, _, _, _ in
                Streams(hr: [HRSample(ts: 1_700_000_100, bpm: 61)])
            })
        backfiller.begin(family: .whoop5)
        await backfiller.ingest(makeValidImuFrame())
        await backfiller.ingest(hexBytes(whoop5HistoryEndHex))
        XCTAssertEqual(trace.snapshot, ["begin", "aborted"])
        XCTAssertEqual(store.writes.snapshot, ["insert"])
        XCTAssertTrue(backfiller.persistStalled)
        XCTAssertNil(backfiller.lastAckedTrim)
        await backfiller.ingest(hexBytes(whoop5HistoryEndHex))
        XCTAssertEqual(trace.snapshot, ["begin", "aborted"])
        XCTAssertEqual(store.writes.snapshot, ["insert"])
        XCTAssertTrue(backfiller.persistStalled)
        XCTAssertNil(backfiller.lastAckedTrim)
    }
}
