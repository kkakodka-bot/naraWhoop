import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore

/// Serial offload pipeline: FIFO frames, begin/timeout serialized with ingest.
final class BackfillActorPipelineTests: XCTestCase {
    private actor OrderedInsertStore: BackfillStoreWriting {
        private(set) var insertOrder: [Int] = []
        private(set) var activeInserts = 0
        private(set) var maxConcurrentInserts = 0
        private var pauseFirstInsert: Bool
        private var enteredFirstInsert = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        private let pauseCursorAfterInserts: Int?
        private var cursorPaused = false
        private var cursorWaiter: CheckedContinuation<Void, Never>?
        private var cursorRelease: CheckedContinuation<Void, Never>?

        init(pauseFirstInsert: Bool = false, pauseCursorAfterInserts: Int? = nil) {
            self.pauseFirstInsert = pauseFirstInsert
            self.pauseCursorAfterInserts = pauseCursorAfterInserts
        }

        func waitForFirstInsert() async {
            if enteredFirstInsert { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }

        func releaseFirstInsert() {
            pauseFirstInsert = false
            releaseWaiter?.resume()
            releaseWaiter = nil
        }

        func waitForPausedCursor() async {
            if cursorPaused { return }
            await withCheckedContinuation { cursorWaiter = $0 }
        }

        func releaseCursor() {
            cursorRelease?.resume()
            cursorRelease = nil
        }

        @discardableResult
        func insertAndMarkJobsOwed(_ streams: Streams, deviceId: String,
                                   postOffloadJobKinds: [String],
                                   note: String?) async throws -> BackfillInsertOutcome {
            activeInserts += 1
            maxConcurrentInserts = max(maxConcurrentInserts, activeInserts)
            if !enteredFirstInsert {
                enteredFirstInsert = true
                enteredWaiter?.resume()
                enteredWaiter = nil
                if pauseFirstInsert { await withCheckedContinuation { releaseWaiter = $0 } }
            }
            insertOrder.append(streams.hr.first?.bpm ?? -1)
            activeInserts -= 1
            return BackfillInsertOutcome(counts: (1, 0, 0, 0, 0, 0, 0, 0), markedJobs: true)
        }

        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            (0, 0, 0, 0, 0, 0, 0, 0)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws {
            guard insertOrder.count == pauseCursorAfterInserts, !cursorPaused else { return }
            cursorPaused = true
            cursorWaiter?.resume()
            cursorWaiter = nil
            await withCheckedContinuation { cursorRelease = $0 }
        }
        func cursor(_ name: String) async throws -> Int? { nil }
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

    private func makeHrFrame(unix: UInt32, bpm: UInt8) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: 64)
        frame[0] = 0xAA; frame[1] = 0x01
        frame[2] = UInt8(frame.count - 8)
        frame[4] = 1; frame[5] = 0
        frame[8] = 0x2f; frame[9] = bpm
        frame[15] = UInt8(unix & 0xff); frame[16] = UInt8((unix >> 8) & 0xff)
        frame[17] = UInt8((unix >> 16) & 0xff); frame[18] = UInt8((unix >> 24) & 0xff)
        let headerCRC = crc16Modbus(Array(frame[0..<6]))
        frame[6] = UInt8(headerCRC & 0xff); frame[7] = UInt8((headerCRC >> 8) & 0xff)
        let payloadEnd = frame.count - 4
        let bodyCRC = crc32(Array(frame[8..<payloadEnd]))
        frame[payloadEnd] = UInt8(bodyCRC & 0xff); frame[payloadEnd + 1] = UInt8((bodyCRC >> 8) & 0xff)
        frame[payloadEnd + 2] = UInt8((bodyCRC >> 16) & 0xff); frame[payloadEnd + 3] = UInt8((bodyCRC >> 24) & 0xff)
        return frame
    }

    private func makeActor(store: BackfillStoreWriting,
                           ack: @escaping @Sendable () async -> Void = {},
                           banked: @escaping @Sendable () async -> Void = {},
                           chunkInfo: (@MainActor @Sendable ([BackfillChunkInfo]) -> Void)? = nil) async -> BackfillActor {
        let actor = BackfillActor()
        let hooks = BackfillMainHooks(
            ackTrim: { _, _ in await ack() },
            onBankedOffload: { _ in await banked() },
            log: { _ in },
            rejectedSink: { _, _, _ in true },
            onChunk: { _, _ in },
            connectionActive: { false },
            connectionLog: { _ in },
            firmwareLayout: { _ in },
            onPersistCircuitBreak: {},
            onChunkCommitBegin: {},
            onChunkCommitAborted: {},
            onOffloadComplete: {},
            chunkInfo: chunkInfo)
        let extract: Backfiller.Extractor = { parsed, _, _, _, _ in
            Streams(hr: [HRSample(ts: 1_700_000_100, bpm: parsed.first?.seq ?? -1)])
        }
        await actor.configure(store: store, deviceId: "dev", hooks: hooks,
                              enableRawCapture: false, postOffloadJobKinds: [],
                              extract: extract)
        return actor
    }

    func testBeginDuringDrainStartsNoConcurrentIngest() async {
        let store = OrderedInsertStore(pauseFirstInsert: true)
        let actor = await makeActor(store: store)
        await actor.begin(family: .whoop5, continuedAfterRows: false)
        actor.yieldFrame(makeHrFrame(unix: 1_500, bpm: 10))
        actor.yieldFrame(hexBytes(whoop5HistoryEndHex))
        await store.waitForFirstInsert()
        let beginTask = Task { await actor.begin(family: .whoop5, continuedAfterRows: false) }
        await store.releaseFirstInsert()
        await beginTask.value
        let maximum = await store.maxConcurrentInserts
        let order = await store.insertOrder
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(order, [10])
    }

    func testFramesAroundSessionStartPreserveArrivalOrder() async {
        let store = OrderedInsertStore()
        let acked = expectation(description: "three chunks acknowledged")
        acked.expectedFulfillmentCount = 3
        let actor = await makeActor(store: store, ack: { acked.fulfill() })
        await actor.begin(family: .whoop5, continuedAfterRows: false)
        actor.yieldFrame(makeHrFrame(unix: 1_500, bpm: 11))
        actor.yieldFrame(hexBytes(whoop5HistoryEndHex))
        actor.yieldFrame(makeHrFrame(unix: 1_501, bpm: 12))
        actor.yieldFrame(hexBytes(whoop5HistoryEndHex))
        actor.yieldFrame(makeHrFrame(unix: 1_502, bpm: 13))
        actor.yieldFrame(hexBytes(whoop5HistoryEndHex))
        await fulfillment(of: [acked], timeout: 5)
        let order = await store.insertOrder
        XCTAssertEqual(order, [11, 12, 13])
    }

    func testTimeoutDuringInFlightIngestFinishesIngestFirst() async {
        let store = OrderedInsertStore(pauseFirstInsert: true)
        let acked = expectation(description: "invalidated chunk must not acknowledge")
        acked.isInverted = true
        let actor = await makeActor(store: store, ack: { acked.fulfill() })
        await actor.begin(family: .whoop5, continuedAfterRows: false)
        actor.yieldFrame(makeHrFrame(unix: 1_500, bpm: 20))
        actor.yieldFrame(hexBytes(whoop5HistoryEndHex))
        await store.waitForFirstInsert()
        actor.invalidateSession()
        let timeoutTask = Task { await actor.timeoutFired() }
        let before = await store.insertOrder
        XCTAssertEqual(before, [], "timeout must wait for ingest")
        await store.releaseFirstInsert()
        await timeoutTask.value
        let after = await store.insertOrder
        XCTAssertEqual(after, [20])
        let stillBackfilling = await actor.isBackfilling()
        XCTAssertFalse(stillBackfilling)
        await fulfillment(of: [acked], timeout: 0.05)
    }

    func testInvalidationDropsOldQueuedChunkAndAllowsNewSession() async {
        let store = OrderedInsertStore(pauseFirstInsert: true)
        let acked = expectation(description: "only new session acknowledges")
        acked.assertForOverFulfill = true
        let banked = expectation(description: "only new session publishes banked count")
        banked.assertForOverFulfill = true
        let actor = await makeActor(store: store, ack: { acked.fulfill() }, banked: { banked.fulfill() })
        let old = UUID(), next = UUID()
        actor.reserveSession(old)
        await actor.begin(family: .whoop5, continuedAfterRows: false, sessionID: old)
        actor.yieldFrame(makeHrFrame(unix: 1_500, bpm: 21), sessionID: old)
        actor.yieldFrame(hexBytes(whoop5HistoryEndHex), sessionID: old)
        await store.waitForFirstInsert()
        actor.yieldFrame(makeHrFrame(unix: 1_501, bpm: 22), sessionID: old)
        actor.yieldFrame(hexBytes(whoop5HistoryEndHex), sessionID: old)
        actor.invalidateSession(old)
        actor.reserveSession(next)
        await store.releaseFirstInsert()
        let began = await actor.begin(family: .whoop5, continuedAfterRows: false, sessionID: next)
        XCTAssertTrue(began)
        actor.yieldFrame(makeHrFrame(unix: 1_502, bpm: 23), sessionID: next)
        actor.yieldFrame(hexBytes(whoop5HistoryEndHex), sessionID: next)
        await fulfillment(of: [acked, banked], timeout: 5)
        let order = await store.insertOrder
        XCTAssertEqual(order, [21, 23], "already running persistence can finish; stale queued frames cannot")
        await actor.timeoutFired(sessionID: next)
    }

    func testInvalidatedReservationCannotStartAndOldTimeoutCannotStopNewSession() async {
        let actor = await makeActor(store: OrderedInsertStore())
        let old = UUID(), next = UUID()
        actor.reserveSession(old)
        actor.invalidateSession(old)
        let staleBegan = await actor.begin(family: .whoop5, continuedAfterRows: false, sessionID: old)
        XCTAssertFalse(staleBegan)
        actor.reserveSession(next)
        let began = await actor.begin(family: .whoop5, continuedAfterRows: false, sessionID: next)
        XCTAssertTrue(began)
        await actor.timeoutFired(sessionID: old)
        let active = await actor.isBackfilling()
        XCTAssertTrue(active)
        await actor.timeoutFired(sessionID: next)
    }

    func testSnapshotExcludesPartialChunkWhileCursorWriteIsSuspended() async {
        let store = OrderedInsertStore(pauseCursorAfterInserts: 2)
        let acked = expectation(description: "two complete chunks acknowledged")
        acked.expectedFulfillmentCount = 2
        let actor = await makeActor(store: store, ack: { acked.fulfill() })
        await actor.begin(family: .whoop5, continuedAfterRows: false)
        actor.yieldFrame(makeHrFrame(unix: 1_500, bpm: 31))
        actor.yieldFrame(hexBytes(whoop5HistoryEndHex))
        actor.yieldFrame(makeHrFrame(unix: 1_501, bpm: 32))
        actor.yieldFrame(hexBytes(whoop5HistoryEndHex))
        await store.waitForPausedCursor()

        let stored = await store.insertOrder
        XCTAssertEqual(stored, [31, 32], "the second insert is durable but its chunk has not finished")
        let during = await actor.sessionSnapshot()
        XCTAssertEqual(during?.sessionRowsPersisted, 1)
        XCTAssertEqual(during?.phaseSamples.count, 1)

        await store.releaseCursor()
        await fulfillment(of: [acked], timeout: 5)
        await actor.timeoutFired()
        let after = await actor.sessionSnapshot()
        XCTAssertEqual(after?.sessionRowsPersisted, 2)
        XCTAssertEqual(after?.phaseSamples.count, 2)
    }

    @MainActor
    private final class InfoTrace {
        var observations: [String] = []
        var stages: [String] = []
        var batches = 0
        var archived: [[UInt8]] = []
        func stage(_ name: String) { stages.append(name) }

        func log(_ line: String) {
            // Elapsed timing differs between runs; the trace itself remains independently tested.
            guard !line.hasPrefix("offload chunk trim=") else { return }
            observations.append(line)
        }

        func consume(_ events: [BackfillChunkInfo]) {
            batches += 1
            stages.append("batch")
            for event in events {
                switch event {
                case .log(let line): log(line)
                case .connectionLog(let line): log("connection: " + line)
                case .firmwareLayout(let version): log("layout: \(version)")
                case .chunk(let decoded, let console): log("chunk: \(decoded),\(console)")
                case .banked(let hr, let rr, let ev, let bat, let spo2, let skin, let resp, let grav):
                    log("banked: \(hr),\(rr),\(ev),\(bat),\(spo2),\(skin),\(resp),\(grav)")
                }
            }
        }
    }

    private actor InfoStore: BackfillStoreWriting {
        enum Failure: CaseIterable { case insert, raw, cursor, archive }
        let trace: InfoTrace
        let failure: Failure?
        init(trace: InfoTrace, failure: Failure? = nil) { self.trace = trace; self.failure = failure }

        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            await trace.stage("insert")
            if failure == .insert { throw NSError(domain: "info-test", code: 1) }
            return (1, 2, 3, 4, 5, 6, 7, 8)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
            await trace.stage("raw")
            if failure == .raw { throw NSError(domain: "info-test", code: 2) }
        }
        func setCursor(_ name: String, _ value: Int) async throws {
            await trace.stage("cursor")
            if failure == .cursor { throw NSError(domain: "info-test", code: 3) }
        }
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private let mappedV18 = "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    @MainActor
    private func replayInfoChunk(batched: Bool, frame: [UInt8], failure: InfoStore.Failure? = nil) async -> InfoTrace {
        let trace = InfoTrace()
        let store = InfoStore(trace: trace, failure: failure)
        let actor = BackfillActor()
        let finished = expectation(description: "chunk acknowledged or explicitly held")
        let batch: (@MainActor @Sendable ([BackfillChunkInfo]) -> Void)?
        if batched { batch = { trace.consume($0) } } else { batch = nil }
        let hooks = BackfillMainHooks(
            ackTrim: { _, _ in await MainActor.run { trace.stages.append("ack"); finished.fulfill() } },
            onBankedOffload: { c in await MainActor.run {
                trace.log("banked: \(c.hr),\(c.rr),\(c.events),\(c.battery),\(c.spo2),\(c.skinTemp),\(c.resp),\(c.gravity)")
            } },
            log: { line in await MainActor.run { trace.log(line) } },
            rejectedSink: { frames, _, _ in await MainActor.run {
                trace.stages.append("archive")
                trace.archived += frames
                return failure != .archive
            } },
            onChunk: { decoded, console in await MainActor.run { trace.log("chunk: \(decoded),\(console)") } },
            connectionActive: { true },
            connectionLog: { line in await MainActor.run {
                if !line.hasPrefix("offload chunk trim=") { trace.log("connection: " + line) }
            } },
            firmwareLayout: { v in await MainActor.run { trace.log("layout: \(v)") } },
            onPersistCircuitBreak: {},
            onChunkCommitBegin: { await MainActor.run { trace.stages.append("begin") } },
            onChunkCommitAborted: { await MainActor.run { trace.stages.append("abort"); finished.fulfill() } },
            onOffloadComplete: {}, chunkInfo: batch)
        await actor.configure(store: store, deviceId: "test", hooks: hooks,
                              enableRawCapture: true, postOffloadJobKinds: [],
                              extract: { _, _, _, _, _ in
            Streams(hr: [HRSample(ts: 1_700_000_100, bpm: 70)], rr: [RRInterval(ts: 1_700_000_100, rrMs: 900)])
        })
        await actor.begin(family: .whoop5, continuedAfterRows: false)
        actor.yieldFrame(frame)
        actor.yieldFrame(hexBytes(whoop5HistoryEndHex))
        await fulfillment(of: [finished], timeout: 5)
        await actor.timeoutFired()
        return trace
    }

    @MainActor
    func testProductionInfoBatchPreservesEveryLegacyObservationAndSafeTrimOrder() async {
        let frame = hexBytes(mappedV18)
        let legacy = await replayInfoChunk(batched: false, frame: frame)
        let batched = await replayInfoChunk(batched: true, frame: frame)
        XCTAssertEqual(batched.observations, legacy.observations)
        XCTAssertEqual(batched.batches, 1)
        XCTAssertEqual(batched.stages, ["begin", "insert", "raw", "batch", "cursor", "ack"])
        XCTAssertTrue(batched.observations.contains("layout: 18"))
        XCTAssertTrue(batched.observations.contains("chunk: true,false"))
        XCTAssertTrue(batched.observations.contains("banked: 1,2,3,4,5,6,7,8"))
    }

    @MainActor
    func testProductionInfoBatchPreservesRejectedBytesAndFailureContextWithoutAck() async {
        var rejected = hexBytes(mappedV18)
        rejected[rejected.count - 1] ^= 1
        for failure in InfoStore.Failure.allCases {
            let legacy = await replayInfoChunk(batched: false, frame: rejected, failure: failure)
            let batched = await replayInfoChunk(batched: true, frame: rejected, failure: failure)
            XCTAssertEqual(batched.observations, legacy.observations, "\(failure)")
            XCTAssertEqual(batched.archived, legacy.archived, "\(failure)")
            XCTAssertFalse(batched.stages.contains("ack"), "\(failure)")
            XCTAssertEqual(batched.stages.last, "abort", "\(failure)")
            XCTAssertTrue(batched.observations.contains { $0.contains("holding ack") }, "\(failure)")
            if failure != .insert {
                XCTAssertEqual(batched.archived, [rejected], "raw bytes must survive the batching change")
                XCTAssertLessThan(batched.stages.firstIndex(of: "batch")!, batched.stages.firstIndex(of: "archive")!)
            }
        }
    }

    @MainActor
    func testInvalidationDuringInsertDiscardsPendingProductionBatch() async {
        let store = OrderedInsertStore(pauseFirstInsert: true)
        let trace = InfoTrace()
        let actor = await makeActor(store: store, chunkInfo: { trace.consume($0) })
        await actor.begin(family: .whoop5, continuedAfterRows: false)
        actor.yieldFrame(hexBytes(mappedV18))
        actor.yieldFrame(hexBytes(whoop5HistoryEndHex))
        await store.waitForFirstInsert()
        XCTAssertEqual(trace.batches, 0)
        actor.invalidateSession()
        await store.releaseFirstInsert()
        await actor.timeoutFired()
        XCTAssertEqual(trace.batches, 0, "queued informational effects cannot outlive their session")
        XCTAssertTrue(trace.observations.isEmpty)
    }
}
