import XCTest
import WhoopProtocol
@testable import Strand

@MainActor
final class BluetoothOpticalRecorderTests: XCTestCase {
    private let deviceId = "test-whoop"
    private func fixture() throws -> [UInt8] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Packages/WhoopProtocol/Tests/WhoopProtocolTests/Resources/r20_optical_oracle.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        let hex = try XCTUnwrap(records.first?["hex"] as? String)
        let chars = Array(hex)
        return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! }
    }

    private func environment() throws -> (URL, UserDefaults) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
        return (folder, defaults)
    }

    func testNativeOpticalIsDurableAndNeverRelabeled100Hz() throws {
        let (folder, defaults) = try environment()
        let recorder = BluetoothOpticalRecorder(directory: folder, defaults: defaults)
        recorder.bonded(deviceId: deviceId)
        recorder.setEnabled(true)
        let frame = try fixture()
        XCTAssertTrue(recorder.persistHistory(deviceId: deviceId, frames: [frame]))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let data = try Data(contentsOf: XCTUnwrap(files.first))
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(row["origin"] as? String, "historical")
        XCTAssertEqual(row["verified_100hz"] as? Bool, false)
        XCTAssertEqual(row["sample_counts_per_slot"] as? [Int], Whoop5RawOptical.decode(frame)?.blocks.map(\.sampleCount))
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(row["frame_base64"] as? String)), Data(frame))
        XCTAssertEqual(recorder.status.historyFrames, 1)
        XCTAssertEqual(recorder.status.liveCandidateFrames, 0)
    }

    func testDiskFailureIsReportedSoCallerCanHoldAck() throws {
        let (folder, defaults) = try environment()
        try Data([1]).write(to: folder) // not a directory; deterministic write failure
        let recorder = BluetoothOpticalRecorder(directory: folder, defaults: defaults)
        recorder.bonded(deviceId: deviceId)
        recorder.setEnabled(true)
        XCTAssertFalse(recorder.persistHistory(deviceId: deviceId, frames: [try fixture()]))
        XCTAssertNotNil(recorder.status.error)
        XCTAssertEqual(recorder.status.historyFrames, 0)
    }

    func testCaptureDefaultsOffAndExplicitChoiceSurvivesReconnect() throws {
        let (folder, defaults) = try environment()
        let recorder = BluetoothOpticalRecorder(directory: folder, defaults: defaults)
        var starts = 0, stops = 0
        recorder.sendEnable = { starts += 1 }; recorder.sendDisable = { stops += 1 }
        recorder.bonded(deviceId: deviceId)
        XCTAssertFalse(recorder.status.enabled)
        XCTAssertEqual(starts, 0)
        recorder.setEnabled(true)
        recorder.bonded(deviceId: deviceId)
        XCTAssertEqual(starts, 1)
        recorder.disconnected()
        recorder.setEnabled(false)
        recorder.bonded(deviceId: deviceId)
        XCTAssertFalse(recorder.status.enabled)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(recorder.isEnabled(for: deviceId))
    }

    func testCorruptFrameNeverBecomesAnOpticalRecord() throws {
        var frame = try fixture()
        XCTAssertTrue(BluetoothOpticalRecorder.isOpticalHistory(frame))
        XCTAssertFalse(BluetoothOpticalRecorder.isLiveCandidate(frame))
        frame[100] ^= 1
        XCTAssertFalse(BluetoothOpticalRecorder.isOpticalHistory(frame))
    }
    func testCommandAckAloneNeverCountsAsOpticalSamples() throws {
        let (folder, defaults) = try environment()
        let recorder = BluetoothOpticalRecorder(directory: folder, defaults: defaults)
        recorder.bonded(deviceId: deviceId)
        recorder.setEnabled(true)
        // Synthetic CRC-valid puffin COMMAND_RESPONSE, revision 1, SUCCESS result 1.
        var frame = [UInt8](repeating: 0, count: 17)
        frame[0] = 0xAA; frame[1] = 1; frame[2] = 9
        frame[8] = 36; frame[10] = 107; frame[11] = 1; frame[12] = 1
        let h = crc16Modbus(frame, 0, 6)
        frame[6] = UInt8(truncatingIfNeeded: h); frame[7] = UInt8(truncatingIfNeeded: h >> 8)
        let c = crc32(frame, 8, 13)
        for i in 0..<4 { frame[13+i] = UInt8(truncatingIfNeeded: c >> (8*i)) }
        recorder.observeCommandResponse(frame)
        XCTAssertEqual(recorder.status.responseCode, 1)
        XCTAssertEqual(recorder.status.historyFrames, 0)
        XCTAssertEqual(recorder.status.liveCandidateFrames, 0)
        XCTAssertTrue(recorder.status.lastSampleCounts.isEmpty)
    }

}
