import XCTest
import WhoopProtocol
@testable import Strand

@MainActor
final class LiveBluetoothDiagnosticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func frame(type: UInt8, secondsAgo: Int = 0, imu: Bool = true) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: imu ? 1244 : 32)
        bytes[0] = 0xAA; bytes[1] = 1; bytes[4] = 1; bytes[8] = type
        if type == 47 { bytes[9] = 21 }
        let length = bytes.count - 8
        bytes[2] = UInt8(length & 255); bytes[3] = UInt8(length >> 8)
        let ts = UInt32(now.timeIntervalSince1970) - UInt32(secondsAgo)
        for i in 0..<4 { bytes[15+i] = UInt8(truncatingIfNeeded: ts >> (8*i)) }
        if imu { bytes[24] = 100; bytes[630] = 100 }
        let header = crc16Modbus(bytes, 0, 6)
        bytes[6] = UInt8(truncatingIfNeeded: header); bytes[7] = UInt8(header >> 8)
        let end = bytes.count - 4, payload = crc32(bytes, 8, bytes.count - 4)
        for i in 0..<4 { bytes[end+i] = UInt8(truncatingIfNeeded: payload >> (8*i)) }
        return bytes
    }

    func testHistoryAndRepliesCannotAppearLiveEvenWithoutAnOffloadSession() {
        let model = LiveBluetoothDiagnostics()
        model.imuVisualization.activate(at: now)
        for type: UInt8 in [47, 48, 49, 50, 52, 53, 54, 55, 56, 36, 38] {
            model.receiveFrame(frame(type: type), family: .whoop5, at: now)
        }
        XCTAssertTrue(model.streams.isEmpty)
        XCTAssertNil(model.imuVisualization.presentation(at: now))
        model.receiveFrame(frame(type: 43), family: .whoop5, at: now)
        XCTAssertEqual(model.streams["imu"]?.packets, 1)
        XCTAssertNotNil(model.imuVisualization.presentation(at: now))
    }

    func testStaleAndCorruptImuAreExcluded() {
        let model = LiveBluetoothDiagnostics()
        model.receiveFrame(frame(type: 43, secondsAgo: 20), family: .whoop5, at: now)
        var corrupt = frame(type: 43); corrupt[200] ^= 1
        model.receiveFrame(corrupt, family: .whoop5, at: now)
        XCTAssertTrue(model.streams.isEmpty)
    }

    func testRRAgesIndependentlyWhileHeartRateContinues() throws {
        let model = LiveBluetoothDiagnostics()
        model.receiveHeartRate([0x16, 70, 0, 4], at: now) // 1024 ticks = 1000 ms
        model.receiveHeartRate([0x06, 72], at: now.addingTimeInterval(6))
        let rr = try XCTUnwrap(model.streams["rr"])
        XCTAssertEqual(rr.detail, "1000 ms")
        XCTAssertFalse(rr.isActive(at: now.addingTimeInterval(6)))
        XCTAssertTrue(try XCTUnwrap(model.streams["hr"]).isActive(at: now.addingTimeInterval(6)))
        XCTAssertEqual(rr.packetsPerSecond(at: now.addingTimeInterval(11)), 0)
        model.reset()
        XCTAssertTrue(model.streams.isEmpty)
    }

    func testUndecodedRawNeverClaimsOpticalOr100Hz() throws {
        let model = LiveBluetoothDiagnostics()
        model.receiveFrame(frame(type: 43, imu: false), family: .whoop5, at: now)
        let raw = try XCTUnwrap(model.streams["raw-43"])
        XCTAssertEqual(raw.title, "Undecoded live raw data")
        XCTAssertFalse(raw.detail.contains("100 Hz"))
        XCTAssertNil(model.streams["imu"])
    }

    func testLivePacketsStillCountWhileHistoryArrives() {
        let model = LiveBluetoothDiagnostics()
        for _ in 0..<10 {
            model.receiveFrame(frame(type: 47), family: .whoop5, at: now)
            model.receiveFrame(frame(type: 43), family: .whoop5, at: now)
        }
        XCTAssertEqual(model.streams.count, 1)
        XCTAssertEqual(model.streams["imu"]?.packets, 10)
        XCTAssertEqual(model.streams["imu"]?.packetsPerSecond(at: now), 1)
    }

    func testCandidateType51DoesNotClaimVerifiedImu() {
        let model = LiveBluetoothDiagnostics()
        model.receiveFrame(frame(type: 51), family: .whoop5, at: now)
        XCTAssertNil(model.streams["imu"])
        XCTAssertEqual(model.streams["raw-51"]?.packets, 1)
    }

    func testThroughputCountsNotificationBytesWithoutCountingReassemblyAgain() {
        let model = LiveBluetoothDiagnostics()
        // One 1,244-byte frame delivered as three Bluetooth values.
        for size in [500, 500, 244] { model.receiveBytes(size, at: now) }
        model.receiveFrame(frame(type: 43), family: .whoop5, at: now)
        // Backfill and control payloads are included in the combined incoming total.
        model.receiveBytes(2000, at: now)
        model.receiveBytes(20, at: now)
        let rates = model.trafficRates(at: now)
        XCTAssertEqual(model.receivedBytes, 3264)
        XCTAssertEqual(rates.bytesPerSecond, 326.4, accuracy: 0.0001)
        XCTAssertEqual(rates.bitsPerSecond, 2611.2, accuracy: 0.0001)
        XCTAssertEqual(rates.chunksPerSecond, 0)
    }

    func testChunkRateOnlyCountsCommitBoundaryAndAgesToZero() {
        let model = LiveBluetoothDiagnostics()
        for _ in 0..<10 { model.receiveFrame(frame(type: 47), family: .whoop5, at: now) }
        XCTAssertEqual(model.savedChunks, 0)
        model.didSaveBackfillChunk(at: now)
        model.didSaveBackfillChunk(at: now.addingTimeInterval(1))
        XCTAssertEqual(model.savedChunks, 2)
        XCTAssertEqual(model.trafficRates(at: now.addingTimeInterval(2)).chunksPerSecond, 0.2)
        XCTAssertEqual(model.trafficRates(at: now.addingTimeInterval(11)).chunksPerSecond, 0)
        model.reset()
        XCTAssertEqual(model.savedChunks, 0)
        XCTAssertNil(model.lastSavedChunk)
    }

    func testByteRatesExpireAndConnectionResetClearsTotals() {
        let model = LiveBluetoothDiagnostics()
        // High notification count must not lose byte totals to a sample-array cap.
        for _ in 0..<5000 { model.receiveBytes(100, at: now) }
        XCTAssertEqual(model.trafficRates(at: now).bytesPerSecond, 50_000)
        XCTAssertEqual(model.trafficRates(at: now.addingTimeInterval(10)).bytesPerSecond, 0)
        model.receiveBytes(200, at: now.addingTimeInterval(11))
        XCTAssertEqual(model.trafficRates(at: now.addingTimeInterval(11)).bytesPerSecond, 20)
        model.reset()
        XCTAssertEqual(model.receivedBytes, 0)
        XCTAssertEqual(model.trafficRates(at: now.addingTimeInterval(11)).bytesPerSecond, 0)
    }
}
