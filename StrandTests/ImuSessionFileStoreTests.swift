import XCTest
@testable import Strand
import WhoopProtocol

/// Behavioral coverage for the canonical .imus session store (FRWHOOP issue #1).
@MainActor
final class ImuSessionFileStoreTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ImuSessionFileStore!

    override func setUp() {
        super.setUp()
        directory = (ProcessInfo.processInfo.environment["NARA_TEST_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "imu-store-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = ImuSessionFileStore(directory: directory, defaultsKey: "windows", defaults: defaults)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// CRC-valid 1244-byte 5/MG IMU buffer. The verified decoder rejects envelope/CRC failures,
    /// so fixtures must match the on-wire contract rather than only sample-count offsets.
    private func imuFrame(ts: Int64, seed: UInt8 = 0) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: Whoop5RawImu.bufferLength)
        frame[0] = 0xAA
        frame[1] = 0x01
        let declaredLength = frame.count - 8
        frame[2] = UInt8(declaredLength & 0xFF)
        frame[3] = UInt8((declaredLength >> 8) & 0xFF)
        frame[4] = 0x01
        frame[8] = 43
        frame[15] = UInt8(ts & 0xff); frame[16] = UInt8((ts >> 8) & 0xff)
        frame[17] = UInt8((ts >> 16) & 0xff); frame[18] = UInt8((ts >> 24) & 0xff)
        frame[24] = 100; frame[630] = 100
        if seed != 0 { frame[28] = seed }
        return stampWhoop5Crc(frame)
    }

    private func stampWhoop5Crc(_ frame: [UInt8]) -> [UInt8] {
        var frame = frame
        let headerCRC = crc16Modbus(frame, 0, 6)
        frame[6] = UInt8(headerCRC & 0xFF)
        frame[7] = UInt8(headerCRC >> 8)
        let payloadEnd = frame.count - 4
        let payloadCRC = crc32(frame, 8, payloadEnd)
        frame[payloadEnd] = UInt8(payloadCRC & 0xFF)
        frame[payloadEnd + 1] = UInt8((payloadCRC >> 8) & 0xFF)
        frame[payloadEnd + 2] = UInt8((payloadCRC >> 16) & 0xFF)
        frame[payloadEnd + 3] = UInt8((payloadCRC >> 24) & 0xFF)
        return frame
    }

    func testColumnsDigestMatchesCrossPlatformOracle() {
        var columns = [Int16]()
        columns.reserveCapacity(600)
        for index in 0..<600 { columns.append(Int16(index * 7 - 300)) }
        XCTAssertEqual(ImuSessionFileStore.columnsDigest(columns), 3_602_392_056_726_433_541)
        XCTAssertEqual(ImuSessionFileStore.columnsDigest([]), 0xcbf29ce484222325)
    }

    func testAppendRoutesMatchingWindowAndDedupesExactRedelivery() {
        store.register(id: "s1", deviceId: "devA", fromMs: 1_000_000, toMs: 2_000_000)
        let ts: Int64 = 1_500
        XCTAssertEqual(store.append(deviceId: "devA", frame: imuFrame(ts: ts), receivedAtMs: 9_000), 1)
        XCTAssertEqual(store.append(deviceId: "devA", frame: imuFrame(ts: ts), receivedAtMs: 9_001), 0)
        let stats = store.stats("s1", from: Int(ts), to: Int(ts))
        XCTAssertEqual(stats.coveredSeconds, 1)
    }

    func testConflictingRedeliveryRecordsEvidence() {
        store.register(id: "s1", deviceId: "devA", fromMs: 1_000_000, toMs: 2_000_000)
        let ts: Int64 = 1_500
        XCTAssertEqual(store.append(deviceId: "devA", frame: imuFrame(ts: ts, seed: 1), receivedAtMs: 1), 1)
        XCTAssertEqual(store.append(deviceId: "devA", frame: imuFrame(ts: ts, seed: 2), receivedAtMs: 2), 0)
        XCTAssertEqual(store.conflictTimestamps("s1"), [ts])
    }

    func testPersistHistoricalImuFlushesBeforeReportingSuccess() {
        store.register(id: "s1", deviceId: "devA", fromMs: 1_000_000, toMs: 2_000_000)
        let frames = (0..<3).map { imuFrame(ts: 1_500 + Int64($0)) }
        XCTAssertTrue(store.persistHistoricalImu(deviceId: "devA", frames: frames, receivedAtMs: 42))
        store.prepareForRead("s1")
        let stats = store.stats("s1", from: 1_500, to: 1_502)
        XCTAssertEqual(stats.coveredSeconds, 3)
    }

    func testContinuousNamespaceIsSeparateFromSharedSessions() {
        XCTAssertFalse(ImuSessionFileStore.continuous === ImuSessionFileStore.shared)
        XCTAssertTrue(ImuSessionFileStore.continuous.registeredWindows().isEmpty)
    }

    func testCorruptedAppendedBlockRollsBackAndLeavesRecordsPending() {
        store.register(id: "s1", deviceId: "devA", fromMs: 1_000_000, toMs: 2_000_000)
        store.testFailAppendVerification = true
        let ts: Int64 = 1_500
        for index in 0..<ImuSessionFileStore.blockSeconds {
            _ = store.append(deviceId: "devA", frame: imuFrame(ts: ts + Int64(index)), receivedAtMs: 1)
        }
        // Failed verification rolls back the append — nothing exportable on disk yet.
        XCTAssertTrue(store.exportSegments("s1", from: Int(ts),
                                          to: Int(ts + Int64(ImuSessionFileStore.blockSeconds) - 1)).isEmpty)
        store.testFailAppendVerification = false
        XCTAssertTrue(store.persistHistoricalImu(deviceId: "devA",
                                                 frames: (0..<ImuSessionFileStore.blockSeconds)
            .map { imuFrame(ts: ts + Int64($0)) },
                                                 receivedAtMs: 2))
        store.prepareForRead("s1")
        let after = store.stats("s1", from: Int(ts), to: Int(ts + Int64(ImuSessionFileStore.blockSeconds) - 1))
        XCTAssertEqual(after.coveredSeconds, ImuSessionFileStore.blockSeconds)
    }

    private func records(from: Int, count: Int) -> [(baseTs: Int, columns: [Int16])] {
        (0..<count).map { (from + $0, [Int16](repeating: Int16($0), count: 600)) }
    }

    private func segmentURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("s1"),
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "imus" }
    }

    func testHistoricalMultiBlockChunkSynchronizesEachSpoolOnceAndReplaysWithoutDuplicates() {
        store.register(id: "s1", deviceId: "devA", fromMs: 1_000_000, toMs: 3_000_000)
        var events: [String] = []
        store.testSynchronization = { events.append($0) }
        let offered = records(from: 1_500, count: 95)
        XCTAssertTrue(store.persistHistoricalImu(deviceId: "devA", records: offered, receivedAtMs: 42))
        XCTAssertEqual(events.filter { $0 == "segment" }.count, 1,
                       "Four encoded blocks in one historical chunk need one file durability sync")
        XCTAssertEqual(events.filter { $0 == "directory" }.count, 3,
                       "New file and containing directory entries must be synchronized")
        events.removeAll()
        XCTAssertTrue(store.persistHistoricalImu(deviceId: "devA", records: offered, receivedAtMs: 43))
        XCTAssertTrue(events.isEmpty, "Exact replay must not rewrite or resynchronize unchanged bytes")
        let reopened = ImuSessionFileStore(directory: directory, defaultsKey: "windows", defaults: defaults)
        XCTAssertEqual(reopened.exportSegments("s1", from: 1_500, to: 1_594).map(\.sampleCount), [9_500])
    }

    func testHistoricalChunkCrossingSegmentBoundarySynchronizesBothSpoolsOnce() {
        store.register(id: "s1", deviceId: "devA", fromMs: 1_000_000, toMs: 3_000_000)
        var fileSyncs = 0
        store.testSynchronization = { if $0 == "segment" { fileSyncs += 1 } }
        XCTAssertTrue(store.persistHistoricalImu(deviceId: "devA", records: records(from: 1_780, count: 95)))
        XCTAssertEqual(fileSyncs, 2)
        XCTAssertEqual(store.exportSegments("s1", from: 1_780, to: 1_874).map(\.sampleCount), [2_000, 7_500])
    }

    func testMultiBlockVerificationFailurePreservesOldPrefixAndRetriesEntireAppend() throws {
        store.register(id: "s1", deviceId: "devA", fromMs: 1_000_000, toMs: 3_000_000)
        XCTAssertTrue(store.persistHistoricalImu(deviceId: "devA", records: records(from: 1_500, count: 30)))
        let file = try XCTUnwrap(segmentURLs().first)
        let original = try Data(contentsOf: file)
        let offered = records(from: 1_530, count: 95)
        store.testFailAppendVerification = true
        XCTAssertFalse(store.persistHistoricalImu(deviceId: "devA", records: offered))
        XCTAssertEqual(try Data(contentsOf: file), original, "Failed append must retain every old byte")
        store.testFailAppendVerification = false
        var fileSyncs = 0
        store.testSynchronization = { if $0 == "segment" { fileSyncs += 1 } }
        XCTAssertTrue(store.persistHistoricalImu(deviceId: "devA", records: offered))
        XCTAssertEqual(fileSyncs, 1)
        XCTAssertEqual(store.exportSegments("s1", from: 1_500, to: 1_624).map(\.sampleCount), [12_500])
    }

    func testFileAndDirectorySyncFailuresHoldHistoricalSuccessAndPreserveRetry() {
        for failDirectory in [false, true] {
            let id = failDirectory ? "directory-failure" : "file-failure"
            store.register(id: id, deviceId: id, fromMs: 1_000_000, toMs: 3_000_000)
            let offered = records(from: 1_500, count: 95)
            store.testFailDirectorySynchronization = failDirectory
            store.testFailSegmentSynchronization = !failDirectory
            XCTAssertFalse(store.persistHistoricalImu(deviceId: id, records: offered))
            store.testFailDirectorySynchronization = false
            store.testFailSegmentSynchronization = false
            XCTAssertTrue(store.persistHistoricalImu(deviceId: id, records: offered))
            let reopened = ImuSessionFileStore(directory: directory, defaultsKey: "windows", defaults: defaults)
            XCTAssertEqual(reopened.exportSegments(id, from: 1_500, to: 1_594).map(\.sampleCount), [9_500])
        }
    }

    func testPreexistingCorruptSegmentCannotAuthorizeAppendOrBeSilentlyTruncated() throws {
        store.register(id: "s1", deviceId: "devA", fromMs: 1_000_000, toMs: 3_000_000)
        XCTAssertTrue(store.persistHistoricalImu(deviceId: "devA", records: records(from: 1_500, count: 30)))
        let file = try XCTUnwrap(segmentURLs().first)
        var original = try Data(contentsOf: file)
        original.append(0xA5)
        try original.write(to: file)
        let reopened = ImuSessionFileStore(directory: directory, defaultsKey: "windows", defaults: defaults)
        XCTAssertFalse(reopened.persistHistoricalImu(deviceId: "devA", records: records(from: 1_530, count: 30)))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(reopened.exportSegments("s1", from: 1_500, to: 1_559).isEmpty)
    }
}
