import XCTest
import GRDB
import NoopPush
import WhoopProtocol
import WhoopStore
@testable import Strand

@MainActor
final class W1AccountIsolationTests: XCTestCase {
    @MainActor
    private final class Fixture {
        enum CleanupFailure: Error { case pendingCapture }
        let directory: URL
        let defaults: UserDefaults
        let suite: String
        var managers: [BLEManager] = []
        var stores: [WhoopStore] = []
        var collectors: [Collector] = []

        init() throws {
            let id = UUID().uuidString
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            suite = "W1AccountIsolationTests.\(id)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        }

        func closeAndRemove() async throws {
            managers.forEach { $0.shutdownForAccountChange() }
            collectors.forEach { $0.shutdownForAccountChange() }
            for manager in managers {
                guard await manager.drainCaptureAfterAccountChange() else { throw CleanupFailure.pendingCapture }
            }
            for collector in collectors {
                guard await collector.drainForShutdown() else { throw CleanupFailure.pendingCapture }
            }
            // Keep owners alive while explicitly closing every connection; ARC is not the barrier.
            var writers = (stores + managers.compactMap(\.ingestStore)).map(\.registryWriter)
            for manager in managers {
                if let source = manager.imuPushSource as? CloudImuPushSource { writers.append(source.index) }
            }
            var closed: Set<ObjectIdentifier> = []
            for writer in writers where closed.insert(ObjectIdentifier(writer)).inserted {
                try writer.close()
            }
            // Failed drain/close leaves the fixture intact for diagnosis, never unlinks a live DB.
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func fixture() throws -> Fixture {
        let fixture = try Fixture()
        addTeardownBlock { try await fixture.closeAndRemove() }
        return fixture
    }

    func testInjectedPreferencesAndShutdownFenceWithoutOpeningDatabase() async throws {
        let fixture = try fixture()
        let directory = fixture.directory, defaults = fixture.defaults
        defaults.set(WhoopModel.whoop5mg.rawValue, forKey: "selectedWhoopModel")
        let path = directory.appendingPathComponent("captured.sqlite").path
        let scope = try AccountScope(projectURL: "https://fixture.invalid", userID: "11111111-1111-4111-8111-111111111111")
        let manager = BLEManager(state: LiveState(), startCentral: false, databasePath: path,
            storageDirectory: directory, accountScope: scope, defaults: defaults)
        fixture.managers.append(manager)
        XCTAssertTrue(manager.isWhoop5)
        XCTAssertEqual(manager.databasePath, path)
        XCTAssertEqual(manager.accountScope, scope)
        var commands = 0
        manager.test_configureHistoryTransport { _, _ in commands += 1; return true }
        manager.requestSync(.manual)
        manager.shutdownForAccountChange()
        manager.requestSync(.manual)
        await manager.bootstrapStore()
        let drained = await manager.drainCaptureAfterAccountChange()
        XCTAssertTrue(drained)
        XCTAssertTrue(manager.accountShutdown)
        XCTAssertEqual(commands, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(manager.send(.sendHistoricalData))
    }

    func testStandardHRBuffersKeepSourceWhenDeviceChangesBeforeFlush() async throws {
        let fixture = try fixture()
        let directory = fixture.directory, defaults = fixture.defaults
        let store = try await WhoopStore.inMemory()
        fixture.stores.append(store)
        let imu = ImuSessionFileStore(directory: directory, defaults: defaults)
        let collector = Collector(store: store, deviceId: "a", imuStore: imu)
        fixture.collectors.append(collector)
        collector.ingestStandardHR(hr: 60, rr: [], at: 100)
        collector.deviceId = "b"
        collector.ingestStandardHR(hr: 70, rr: [], at: 101)
        await collector.flushStandardHR()
        await collector.flushStandardHR()
        let a = try await store.hrSamples(deviceId: "a", from: 0, to: 200, limit: 10)
        let b = try await store.hrSamples(deviceId: "b", from: 0, to: 200, limit: 10)
        XCTAssertEqual(a.map(\.ts), [100])
        XCTAssertEqual(b.map(\.ts), [101])
    }

    func testBLEFirstWriterBindingUsesPreparedImmutableImuMux() async throws {
        let fixture = try fixture()
        let directory = fixture.directory, defaults = fixture.defaults
        let scope = try AccountScope(projectURL: "https://fixture.invalid", userID: "11111111-1111-4111-8111-111111111111")
        let manager = BLEManager(state: LiveState(), startCentral: false,
            databasePath: directory.appendingPathComponent("capture.sqlite").path,
            storageDirectory: directory, accountScope: scope, defaults: defaults)
        fixture.managers.append(manager)
        XCTAssertNil(manager.imuPushSource)
        let prepared = try await manager.prepareImuPushSource()
        await manager.bootstrapStore()
        let store = try XCTUnwrap(manager.ingestStore)
        let binding = try XCTUnwrap(CloudPushCaptureBindings.binding(for: store.registryWriter))
        let bound = try XCTUnwrap(binding.imuSource as? CloudImuPushSource)
        XCTAssertTrue(bound === (prepared as? CloudImuPushSource))
        XCTAssertTrue(bound === (manager.imuPushSource as? CloudImuPushSource))
        let again = try await manager.prepareImuPushSource()
        XCTAssertTrue(bound === (again as? CloudImuPushSource))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("RawImuUploadIndex/membership.sqlite").path))
    }

    func testBLEImuIndexFailureKeepsDebtAndCannotPublishFallbackSource() async throws {
        let fixture = try fixture()
        let directory = fixture.directory, defaults = fixture.defaults
        let scope = try AccountScope(projectURL: "https://fixture.invalid", userID: "11111111-1111-4111-8111-111111111111")
        let path = directory.appendingPathComponent("capture.sqlite").path
        let seed = try await WhoopStore(path: path)
        fixture.stores.append(seed)
        try await seed.bindAccountOwner(projectURL: scope.projectURL, userID: scope.userID)
        _ = try await seed.markJobsOwed(kinds: ["cloudPush"], note: "fixture IMU debt")
        let index = directory.appendingPathComponent("RawImuUploadIndex")
        try Data([1]).write(to: index)
        let state = LiveState()
        let manager = BLEManager(state: state, startCentral: false, databasePath: path,
            storageDirectory: directory, accountScope: scope, defaults: defaults)
        fixture.managers.append(manager)
        await manager.bootstrapStore()
        XCTAssertNil(manager.imuPushSource)
        XCTAssertNil(manager.ingestStore)
        XCTAssertNotNil(state.lastSyncError)
        let jobs = try await seed.owedJobs()
        XCTAssertTrue(jobs.contains { $0.kind == "cloudPush" })
        try FileManager.default.removeItem(at: index)
        await manager.bootstrapStore()
        XCTAssertNotNil(manager.imuPushSource as? CloudImuPushSource)
        XCTAssertNotNil(manager.ingestStore)
        XCTAssertNil(state.lastSyncError)
    }

    func testImuRetentionRequiresOwnReceiptAndSurvivesStoreReopen() throws {
        let fixture = try fixture()
        let directory = fixture.directory, defaults = fixture.defaults
        let scope = DurableIngestScope(environment: "https://fixture.invalid", accountID: "owner-a", deviceID: "strap")
        let store = ImuSessionFileStore(directory: directory, defaults: defaults, captureScope: scope)
        store.register(id: "window", deviceId: "strap", fromMs: 1_000, toMs: 2_000)
        XCTAssertEqual(store.append(deviceId: "strap", ts: 1, columns: Array(repeating: 1, count: 600), receivedAtMs: 1_000), 1)
        store.prepareForRead("window")
        let segment = try XCTUnwrap(store.segmentInventory().first)
        XCTAssertFalse(store.deleteSegment(id: segment.id, bucket: segment.bucket))
        let identity = try XCTUnwrap(store.segmentResourceIdentity(id: segment.id, bucket: segment.bucket))
        func receipt(_ owner: DurableIngestScope, grace: Int) -> RawDurabilityReceipt {
            RawDurabilityReceipt(scope: owner, lane: identity.lane, resourceKey: identity.resourceKey,
                contentSHA256: identity.contentSHA256, objectKey: "fixture/object", receiptID: "verified",
                verifiedAt: 1, retainUntil: grace)
        }
        XCTAssertThrowsError(try store.recordSegmentReceipt(receipt(.unassigned(deviceID: "strap"), grace: 1),
            id: segment.id, bucket: segment.bucket))
        let grace = Int(Date().timeIntervalSince1970) + 100
        try store.recordSegmentReceipt(receipt(scope, grace: grace),
            id: segment.id, bucket: segment.bucket)
        XCTAssertFalse(store.deleteSegment(id: segment.id, bucket: segment.bucket))
        // A repeated receipt must not shorten the already promised grace period.
        try store.recordSegmentReceipt(receipt(scope, grace: 1), id: segment.id, bucket: segment.bucket)
        let reopened = ImuSessionFileStore(directory: directory, defaults: defaults, captureScope: scope)
        XCTAssertFalse(reopened.deleteSegment(id: segment.id, bucket: segment.bucket, now: grace - 1))
        XCTAssertTrue(reopened.deleteSegment(id: segment.id, bucket: segment.bucket, now: grace))
    }
}
