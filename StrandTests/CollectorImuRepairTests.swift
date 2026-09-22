import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore

/// FRWHOOP issue #1: best-effort repair from the retained rawBatch archive.
@MainActor
final class CollectorImuRepairTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var imuStore: ImuSessionFileStore!

    override func setUp() {
        super.setUp()
        directory = (ProcessInfo.processInfo.environment["NARA_TEST_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "imu-repair-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        imuStore = ImuSessionFileStore(directory: directory, defaultsKey: "windows", defaults: defaults)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeValidImuFrame(unix: UInt32) -> [UInt8] {
        let total = 1244
        var frame = [UInt8](repeating: 0, count: total)
        frame[0] = 0xAA; frame[1] = 0x01
        let declared = total - 8
        frame[2] = UInt8(declared & 0xff); frame[3] = UInt8((declared >> 8) & 0xff)
        frame[4] = 0x01; frame[5] = 0x00
        frame[8] = 0x2f; frame[9] = 21
        frame[24] = 100; frame[630] = 100
        frame[15] = UInt8(unix & 0xff); frame[16] = UInt8((unix >> 8) & 0xff)
        frame[17] = UInt8((unix >> 16) & 0xff); frame[18] = UInt8((unix >> 24) & 0xff)
        let headerCRC = crc16Modbus(Array(frame[0..<6]))
        frame[6] = UInt8(headerCRC & 0xff); frame[7] = UInt8((headerCRC >> 8) & 0xff)
        let payloadEnd = total - 4
        let bodyCRC = crc32(Array(frame[8..<payloadEnd]))
        frame[payloadEnd] = UInt8(bodyCRC & 0xff); frame[payloadEnd + 1] = UInt8((bodyCRC >> 8) & 0xff)
        frame[payloadEnd + 2] = UInt8((bodyCRC >> 16) & 0xff); frame[payloadEnd + 3] = UInt8((bodyCRC >> 24) & 0xff)
        return frame
    }

    func testRepairPagesThroughRetainedBatches() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "devA", mac: nil, name: nil)
        imuStore.register(id: "session", deviceId: "devA", fromMs: 1_000_000, toMs: 2_000_000)

        for index in 0..<3 {
            var frames: [[UInt8]] = []
            for offset in 0..<2 {
                frames.append(makeValidImuFrame(unix: UInt32(1_500 + index * 2 + offset)))
            }
            let byteSize = frames.reduce(0) { $0 + $1.count }
            let meta = RawBatchMeta(batchId: "batch-\(index)", deviceId: "devA",
                                    clockRef: ClockRef(device: index, wall: index),
                                    capturedAt: 1_800_000_000 + index, startTs: 0, endTs: 0,
                                    frameCount: frames.count, byteSize: byteSize)
            try await store.enqueueRawBatch(meta, frames: frames)
        }

        let collector = Collector(store: store, deviceId: "devA")
        let repaired = await collector.repairImuSessionsFromRawArchive(imuStore: imuStore, allowsWork: { true })
        XCTAssertEqual(repaired, 6)
        let stats = imuStore.stats("session", from: 1_500, to: 1_505)
        XCTAssertEqual(stats.coveredSeconds, 6)
    }

    func testRepairShortCircuitsWithoutSessionWindows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "devA", mac: nil, name: nil)
        let frames = [makeValidImuFrame(unix: 1_500)]
        let meta = RawBatchMeta(batchId: "batch", deviceId: "devA",
                                clockRef: ClockRef(device: 0, wall: 0),
                                capturedAt: 1, startTs: 0, endTs: 0,
                                frameCount: 1, byteSize: frames[0].count)
        try await store.enqueueRawBatch(meta, frames: frames)

        let collector = Collector(store: store, deviceId: "devA")
        let repaired = await collector.repairImuSessionsFromRawArchive(imuStore: imuStore, allowsWork: { true })
        XCTAssertEqual(repaired, 0)
    }
    func testPressureBetweenFramesRetainsArchiveAndResumesWithoutDuplicates() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "devA", mac: nil, name: nil)
        imuStore.register(id: "session", deviceId: "devA", fromMs: 1_000_000, toMs: 2_000_000)
        let frames = (0..<6).map { makeValidImuFrame(unix: UInt32(1_500 + $0)) }
        let meta = RawBatchMeta(batchId: "pressure", deviceId: "devA",
            clockRef: ClockRef(device: 0, wall: 0), capturedAt: 1_800_000_000,
            startTs: 0, endTs: 0, frameCount: frames.count, byteSize: frames.reduce(0) { $0 + $1.count })
        try await store.enqueueRawBatch(meta, frames: frames)
        let collector = Collector(store: store, deviceId: "devA")
        let denied = await collector.repairImuSessionsFromRawArchive(imuStore: imuStore, allowsWork: { false })
        XCTAssertEqual(denied, 0)
        var admissionChecks = 0
        let partial = await collector.repairImuSessionsFromRawArchive(imuStore: imuStore) {
            admissionChecks += 1
            return admissionChecks < 5
        }
        XCTAssertEqual(partial, 1)
        let retained = try await store.rawFrames(batchId: meta.batchId)
        XCTAssertEqual(retained, frames)
        let resumed = await collector.repairImuSessionsFromRawArchive(imuStore: imuStore, allowsWork: { true })
        XCTAssertEqual(resumed, 5)
        XCTAssertEqual(imuStore.stats("session", from: 1_500, to: 1_505).coveredSeconds, 6)
    }

}
