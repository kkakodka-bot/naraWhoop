import XCTest
import NoopPush
import WhoopStore
@testable import Strand

@MainActor
final class W1ImuRetirementTests: XCTestCase {
    private func fixture() throws -> (BLEManager, URL, UserDefaults, AccountScope) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "W1ImuRetirementTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let scope = try AccountScope(projectURL: "https://fixture.invalid",
            userID: "11111111-1111-4111-8111-111111111111")
        let manager = BLEManager(state: LiveState(), deviceId: "strap-a", startCentral: false,
            databasePath: directory.appendingPathComponent("unused.sqlite").path,
            storageDirectory: directory, accountScope: scope, defaults: defaults)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: directory)
        }
        return (manager, directory, defaults, scope)
    }

    private func append(_ store: ImuSessionFileStore, window: String, device: String, seconds: [Int64]) {
        store.register(id: window, deviceId: device, fromMs: 1_000, toMs: 100_000)
        for second in seconds {
            XCTAssertEqual(store.append(deviceId: device, ts: second,
                columns: Array(repeating: Int16(second), count: 600), receivedAtMs: second * 1000), 1)
        }
    }

    private func verifyReopen(_ directory: URL, defaults: UserDefaults, scope: AccountScope,
                              continuous: Bool, expected: [String: [Int64]]) throws {
        let reopened = ImuSessionFileStore(directory: directory.appendingPathComponent(continuous ? "RawImuContinuous" : "RawImuSessions"),
            defaultsKey: continuous ? "imu-continuous-windows-v1" : "imu-session-windows-v1", defaults: defaults,
            captureScope: .init(environment: scope.projectURL, accountID: scope.userID, deviceID: "strap-a"))
        for (device, seconds) in expected {
            let rows = reopened.pushRecords(deviceId: device, afterTs: 0, limit: 100)
            XCTAssertEqual(rows.map(\.ts), seconds)
            for row in rows {
                let v = UInt16(row.ts)
                let expectedBytes = Data((0..<600).flatMap { _ in [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] })
                XCTAssertEqual(row.columns, expectedBytes)
            }
        }
    }

    func testSessionTailWithoutCollectorAndOtherDeviceFlushBeforeRetirementSucceeds() async throws {
        let (manager, directory, defaults, scope) = try fixture()
        XCTAssertNil(manager.ingestStore)
        append(manager.imuSessionStore, window: "first", device: "strap-a", seconds: [10, 11])
        append(manager.imuSessionStore, window: "other", device: "strap-b", seconds: [12])
        let before = await manager.drainCaptureAfterAccountChange()
        XCTAssertFalse(before)
        manager.shutdownForAccountChange()
        let complete = await manager.drainCaptureAfterAccountChange()
        XCTAssertTrue(complete)
        try verifyReopen(directory, defaults: defaults, scope: scope, continuous: false,
            expected: ["strap-a": [10, 11], "strap-b": [12]])
        let repeated = await manager.drainCaptureAfterAccountChange()
        XCTAssertTrue(repeated)
    }

    func testContinuousFinalWriteFailureRetainsExactOldWriterUntilRetry() async throws {
        let (manager, directory, defaults, scope) = try fixture()
        append(manager.imuSessionStore, window: "session", device: "strap-a", seconds: [10])
        append(manager.imuContinuousStore, window: "continuous", device: "strap-a", seconds: [20, 21])
        append(manager.imuContinuousStore, window: "other", device: "strap-b", seconds: [22])
        manager.imuContinuousStore.testFailAppendVerification = true
        manager.shutdownForAccountChange()
        let retired = RetiredCaptureDrain(automaticRetry: false)
        retired.retain(id: UUID()) { await manager.drainCaptureAfterAccountChange() }
        await retired.retry()
        XCTAssertEqual(retired.pendingCount, 1)
        try verifyReopen(directory, defaults: defaults, scope: scope, continuous: false, expected: ["strap-a": [10]])
        try verifyReopen(directory, defaults: defaults, scope: scope, continuous: true,
            expected: ["strap-a": [], "strap-b": []])
        manager.imuContinuousStore.testFailAppendVerification = false
        await retired.retry()
        XCTAssertEqual(retired.pendingCount, 0)
        try verifyReopen(directory, defaults: defaults, scope: scope, continuous: true,
            expected: ["strap-a": [20, 21], "strap-b": [22]])
    }
}
