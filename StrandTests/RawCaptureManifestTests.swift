import XCTest
import WhoopProtocol
import WhoopStore
import NoopPush
@testable import Strand

@MainActor
final class RawCaptureManifestTests: XCTestCase {
    private let timestamp = 1_790_000_000

    private final class CaptureStore: StoreWriting, BackfillStoreWriting {
        var metas: [RawBatchMeta] = []
        var operations: [String] = []
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            operations.append("insert")
            return (streams.hr.count, 0, 0, 0, 0, 0, 0, 0)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
            metas.append(meta)
            operations.append("raw")
        }
        func setCursor(_ name: String, _ value: Int) async throws { operations.append("cursor") }
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private func endFrame() -> [UInt8] {
        func le32(_ value: UInt32) -> [UInt8] {
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        return frameFromPayload(le32(UInt32(timestamp)) + [0, 0] + le32(0) + le32(99) + le32(0),
                                type: 49, seq: 0, cmd: 2)
    }

    private func manifest(_ meta: RawBatchMeta) throws -> PushBinaryBatch {
        try PushProtocol.binaryObjectBatch(table: .rawBatch,
            sourceId: "00000000-0000-4000-8000-000000000001", deviceId: meta.deviceId, startCursor: nil,
            rows: [.rawBatch(.init(rowId: 1, batchId: meta.batchId, capturedAt: Int64(meta.capturedAt),
                deviceClockRef: Int64(meta.clockRef.device), wallClockRef: Int64(meta.clockRef.wall),
                startTs: Int64(meta.startTs), endTs: Int64(meta.endTs), frameCount: Int32(meta.frameCount),
                byteSize: Int32(meta.byteSize), framesBlob: Data([1])))],
            protocolVersion: PushProtocol.identityObjectVersion)
    }

    func testHistoricalSingleSecondUsesDecodedBoundsAndRawPrecedesAck() async throws {
        let store = CaptureStore()
        let ts = timestamp
        let backfiller = Backfiller(store: store, deviceId: "fixture", ackTrim: { _, _ in
            await MainActor.run { store.operations.append("ack") }
        }, enableRawCapture: true, extract: { _, _, _, _, _ in Streams(hr: [HRSample(ts: ts, bpm: 60)]) })
        backfiller.begin(family: .whoop4)
        await backfiller.ingest(frameFromPayload([0], type: 50, seq: 0, cmd: 0))
        await backfiller.ingest(endFrame())
        let meta = try XCTUnwrap(store.metas.first)
        XCTAssertEqual(meta.startTs, ts)
        XCTAssertEqual(meta.endTs, ts + 1)
        XCTAssertEqual(store.operations, ["insert", "raw", "cursor", "ack"])
        let first = try manifest(meta)
        XCTAssertEqual(first.endTs - first.startTs, 1)
        XCTAssertEqual(first.objectId, try manifest(meta).objectId)
    }

    func testDecodedEmptyHistoryKeepsEndBoundsAcrossClockChanges() async throws {
        let store = CaptureStore()
        let backfiller = Backfiller(store: store, deviceId: "fixture", ackTrim: { _, _ in },
            enableRawCapture: true, extract: { _, _, _, _, _ in Streams() })
        for wall in [timestamp + 1_000, timestamp + 5_000] {
            backfiller.begin(family: .whoop4)
            backfiller.clockRef = ClockRef(device: wall, wall: wall)
            await backfiller.ingest(frameFromPayload([0], type: 50, seq: 0, cmd: 0))
            await backfiller.ingest(endFrame())
        }
        XCTAssertEqual(store.metas.count, 2)
        XCTAssertEqual(store.metas.map(\.startTs), [timestamp, timestamp])
        XCTAssertEqual(store.metas.map(\.endTs), [timestamp + 1, timestamp + 1])
        XCTAssertEqual(store.metas.first?.batchId, store.metas.last?.batchId)
        XCTAssertFalse(backfiller.persistStalled)
    }

    func testDecodedEmptyLiveCapturePersistsFallbackBoundsForRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let suite = "RawCaptureManifestTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let imu = ImuSessionFileStore(directory: directory, defaults: defaults)
        let store = CaptureStore()
        var wall = timestamp
        let collector = Collector(store: store, deviceId: "fixture", enableRawCapture: true,
                                  now: { wall }, monotonic: { 0 }, imuStore: imu)
        collector.clockRef = ClockRef(device: timestamp, wall: timestamp)
        collector.ingest(frameFromPayload([0], type: 50, seq: 0, cmd: 0))
        await collector.flush()
        let meta = try XCTUnwrap(store.metas.first)
        XCTAssertEqual(meta.startTs, timestamp)
        XCTAssertEqual(meta.endTs, timestamp + 1)
        let first = try manifest(meta)
        wall += 10_000
        let retry = try manifest(meta)
        XCTAssertEqual(first.manifestJSON, retry.manifestJSON)
        XCTAssertEqual(first.payload, retry.payload)
    }
}
