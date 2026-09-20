import XCTest
@testable import Strand

/// Feature-level parity guard for the Android and Apple raw-data collectors. The shared oracle lists
/// every user-visible/session-lifecycle capability and source markers on both implementations.
final class RawDataCollectorParityTests: XCTestCase {
    private struct Oracle: Decodable {
        let schemaVersion: Int
        let capabilities: [String: Capability]
        enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", capabilities }
    }
    private struct Capability: Decodable { let swift: [String]; let kotlin: [String] }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func oracleData() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "raw_data_collector_parity",
                                                            withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testAppleSurfaceStillImplementsEveryDeclaredCapability() throws {
        let oracle = try JSONDecoder().decode(Oracle.self, from: oracleData())
        XCTAssertEqual(oracle.schemaVersion, 1)
        let paths = [
            "Strand/Collect/RawDataSessionStore.swift", "Strand/Collect/Collector.swift",
            "Strand/BLE/BLEManager.swift", "Strand/Screens/RawDataCollectorView.swift",
            "Strand/Screens/ImuRecorderView.swift",
            "Strand/Collect/ImuSessionFileStore.swift", "Strand/Collect/ImuCoverage.swift",
            "Strand/Collect/ImuContinuousRecorder.swift", "Strand/Collect/Backfiller.swift",
            "Packages/WhoopStore/Sources/WhoopStore/Database.swift",
            "Packages/WhoopStore/Sources/WhoopStore/StreamStore.swift",
            "Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift",
        ]
        let source = try paths.map { try String(contentsOf: repoRoot.appendingPathComponent($0)) }
            .joined(separator: "\n")
        for (name, capability) in oracle.capabilities {
            for marker in capability.swift {
                XCTAssertTrue(source.contains(marker), "Apple collector lost \(name) marker: \(marker)")
            }
        }
    }

    func testAndroidAndAppleOracleCopiesAreByteIdentical() throws {
        let android = repoRoot.appendingPathComponent("android/app/src/test/resources/raw_data_collector_parity.json")
        XCTAssertEqual(try oracleData(), try Data(contentsOf: android),
                       "Raw-data collector parity oracle copies must change together")
    }

    func testAppleImuControlIsNarrowAndControllerOwned() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent("Strand/BLE/BLEManager.swift"))
        XCTAssertTrue(source.contains("func startSensorCapture(_ kind: SensorCaptureKind, duration:"))
        XCTAssertTrue(source.contains("func stopSensorCapture() async -> Bool"))
        XCTAssertTrue(source.contains("Self.isVerifiedSensorAction(action)"))
        XCTAssertTrue(source.contains("command == .startRawData"))
        XCTAssertTrue(source.contains("command == .stopRawData"))
        XCTAssertTrue(source.contains("command == .toggleIMUMode"))
        XCTAssertFalse(source.contains("func captureRawAccel("))
        XCTAssertFalse(source.contains("func startGroundTruthRawCapture("))
        XCTAssertFalse(source.contains("func stopGroundTruthRawCapture("))
        XCTAssertFalse(source.contains("ENABLE_OPTICAL_DATA"))
        XCTAssertFalse(source.contains("TOGGLE_OPTICAL_MODE"))
    }

    /// FRWHOOP issue #1: the Apple-side routing/repair seams are platform-specific (Android routes
    /// every inbound frame in WhoopBleClient and has no rawBatch archive to replay), so they are
    /// guarded by a Swift-only source test rather than the shared oracle.
    func testAppleRoutesLiveAndHistoricalImuIntoSessions() throws {
        let ble = try String(contentsOf: repoRoot.appendingPathComponent("Strand/BLE/BLEManager.swift"))
        XCTAssertTrue(ble.contains("recordGroundTruthImuFrame(frame)"))
        let actor = try String(contentsOf: repoRoot.appendingPathComponent("Strand/Collect/BackfillActor.swift"))
        XCTAssertTrue(actor.contains("imuSessionSink: { deviceId, records in"))
        XCTAssertTrue(actor.contains("persistHistoricalImu(deviceId: deviceId, records: records)"))
        XCTAssertTrue(ble.contains("func repairGroundTruthImuSessions()"))
        let backfiller = try String(contentsOf: repoRoot.appendingPathComponent("Strand/Collect/Backfiller.swift"))
        XCTAssertTrue(backfiller.contains("imuSessionSink(deviceId, imuRecords)"))
        let store = try String(contentsOf: repoRoot.appendingPathComponent("Strand/Collect/ImuSessionFileStore.swift"))
        XCTAssertTrue(store.contains("func persistHistoricalImu("))
        let collector = try String(contentsOf: repoRoot.appendingPathComponent("Strand/Collect/Collector.swift"))
        XCTAssertTrue(collector.contains("func repairImuSessionsFromRawArchive("))
    }
}
