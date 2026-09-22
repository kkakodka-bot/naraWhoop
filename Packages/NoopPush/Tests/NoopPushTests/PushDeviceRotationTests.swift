import XCTest
@testable import NoopPush

final class PushDeviceRotationTests: XCTestCase {
    private struct Saved: Codable { let index: Int; let fingerprint: String? }
    private let caps = PushCapabilities(appendTables: [.hrSample], mutableTables: [])
    private func coordinator(_ source: RotationFixture) -> PushCoordinator {
        PushCoordinator(source: source, transport: source, progress: source,
                        sourceId: "11111111-1111-4111-8111-111111111111")
    }

    func testGrowingDiscoveryAfterRelaunchRestartsCycleBeforeNewLeadingSourceCanBeSkipped() async throws {
        let old = RotationFixture(["B","C","D","E","F"])
        let first = await coordinator(old).pushKnownDevices(maxDevices: 4, capabilities: caps)
        let firstVisits = await old.visited
        XCTAssertEqual(firstVisits, ["B","C","D","E"])
        XCTAssertEqual(first.nextDeviceIndex, 4)
        // Restore only the captured checkpoint into a fresh coordinator/process fixture.
        let saved = try JSONEncoder().encode(Saved(index: first.nextDeviceIndex, fingerprint: first.deviceListFingerprint))
        let checkpoint = try JSONDecoder().decode(Saved.self, from: saved)
        let expanded = RotationFixture(["A","B","C","D","E","F","G","H"])
        let second = await coordinator(expanded).pushKnownDevices(startDeviceIndex: checkpoint.index,
            expectedDeviceListFingerprint: checkpoint.fingerprint, maxDevices: 4, capabilities: caps)
        let restartedVisits = await expanded.visited
        XCTAssertEqual(restartedVisits, ["A","B","C","D"])
        XCTAssertEqual(second.nextDeviceIndex, 4, "changed membership must not falsely complete the old cycle")
        XCTAssertNotEqual(second.deviceListFingerprint, first.deviceListFingerprint)
        let third = await coordinator(expanded).pushKnownDevices(startDeviceIndex: second.nextDeviceIndex,
            expectedDeviceListFingerprint: second.deviceListFingerprint, maxDevices: 4, capabilities: caps)
        XCTAssertEqual(third.nextDeviceIndex, 0)
        let completedVisits = await expanded.visited
        XCTAssertEqual(completedVisits, ["A","B","C","D","E","F","G","H"])
    }

    func testLegacyCheckpointWithoutFingerprintRestartsAndSameSortedMembershipResumes() async {
        let f = RotationFixture(["H","G","F","E","D","C","B","A"])
        let legacy = await coordinator(f).pushKnownDevices(startDeviceIndex: 4, maxDevices: 4, capabilities: caps)
        let first = await f.visited
        XCTAssertEqual(first, ["A","B","C","D"])
        let reordered = RotationFixture(["B","D","F","H","G","E","C","A"])
        let resumed = await coordinator(reordered).pushKnownDevices(startDeviceIndex: legacy.nextDeviceIndex,
            expectedDeviceListFingerprint: legacy.deviceListFingerprint, maxDevices: 4, capabilities: caps)
        let rest = await reordered.visited
        XCTAssertEqual(rest, ["E","F","G","H"])
        XCTAssertEqual(resumed.deviceListFingerprint, legacy.deviceListFingerprint)
        XCTAssertEqual(resumed.nextDeviceIndex, 0)
    }

    func testBootstrapDeferralRetainsWorkWithoutInventingDatabaseFailureOrRotationProof() async {
        let f = RotationFixture([], deferred: true)
        let result = await coordinator(f).pushKnownDevices(startDeviceIndex: 4,
            expectedDeviceListFingerprint: String(repeating: "a", count: 64), maxDevices: 4, capabilities: caps)
        XCTAssertTrue(result.hasRetryableFailure); XCTAssertTrue(result.hasMoreAppendRows)
        XCTAssertEqual(result.rejectedBatches, 0); XCTAssertNil(result.failure)
        XCTAssertNil(result.deviceListFingerprint)
        let visited = await f.visited
        XCTAssertTrue(visited.isEmpty)
    }
}

private actor RotationFixture: PushSnapshotSource, PushProgressStore, PushTransport {
    let devices: [String]
    let deferred: Bool
    var visited: [String] = []
    var remembered: Set<String> = []
    init(_ devices: [String], deferred: Bool = false) { self.devices = devices; self.deferred = deferred }
    func knownDeviceIds(capabilities: PushCapabilities) throws -> [String] {
        if deferred { throw PushSourceReadError.deferred }; return devices
    }
    func knownDeviceIds() -> Set<String> { remembered }
    func rememberDeviceId(_ deviceId: String) { remembered.insert(deviceId) }
    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) -> PushAppendRecord? { nil }
    func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) -> [PushAppendRecord] {
        visited.append(deviceId); return []
    }
    func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) -> PushBinaryRow? { nil }
    func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) -> [PushBinaryRow] { [] }
    func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) {}
    func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) -> [PushMutableRecord] { [] }
    func cursor(table: PushAppendTable, deviceId: String) -> PushCursor? { nil }
    func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) {}
    func binaryCursor(table: PushBinaryTable, deviceId: String) -> PushCursor? { nil }
    func saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) {}
    func window(table: PushMutableTable, deviceId: String) -> PushWindowProgress? { nil }
    func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) {}
    func post(_ batch: PushBatch) throws -> PushTransportResponse { throw PushProtocolException("unexpected transfer") }
    func postBinary(_ batch: PushBinaryBatch) throws -> PushTransportResponse { throw PushProtocolException("unexpected transfer") }
}
