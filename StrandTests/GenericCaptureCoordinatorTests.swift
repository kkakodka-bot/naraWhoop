import XCTest
import Combine
import WhoopStore
@testable import Strand

@MainActor
final class GenericCaptureCoordinatorTests: XCTestCase {
    private let deviceID = "synthetic-standard-hr"
    private let measurement: [UInt8] = [0x16, 72, 0x00, 0x04, 0x00, 0x04]

    private func registry(_ store: WhoopStore) -> DeviceRegistry {
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryWriter))
        registry.reload()
        registry.add(PairedDevice(id: deviceID, brand: "Synthetic", model: "HR",
                                  sourceKind: .liveBLE, capabilities: [.hr, .hrv],
                                  status: .paired, addedAt: 0, lastSeenAt: 0))
        registry.setActive(deviceID)
        return registry
    }

    func testCoordinatorCaptureBeforeShutdownRetainsStopBufferAndIsIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        let journal = GenericCaptureJournal(store: store, maxBatches: 1)
        let live = LiveState()
        var source: StandardHRSource?
        var resolverCalls = 0
        let coordinator = SourceCoordinator(
            registry: registry(store), live: live,
            storeHandle: { resolverCalls += 1; return nil },
            startWhoop: {}, stopWhoop: {},
            setWhoopPreferredPeripheral: { _ in }, setWhoopActiveDeviceId: { _ in },
            connectedPeripheralUUID: Empty<String?, Never>().eraseToAnyPublisher(),
            genericCapture: journal,
            standardSourceFactory: { id in
                let result = StandardHRSource(live: live, deviceId: id, persist: { _ in XCTFail() },
                                              admit: { journal.admit($0, deviceID: id) }, startCentral: false)
                source = result
                return result
            })
        coordinator.start()
        let actual = try XCTUnwrap(source)
        for index in 0..<3 { XCTAssertTrue(actual.ingestHeartRateMeasurement(measurement, at: 1_750_000_000 + index)) }
        let captured = try XCTUnwrap(coordinator.captureDrainForAccountChange())
        XCTAssertTrue(captured === journal)
        XCTAssertEqual(captured.pendingBatchCount, 1)
        XCTAssertEqual(captured.pendingFinalBufferCount, 1)
        XCTAssertEqual(actual.pendingCaptureCount, 2)
        coordinator.shutdownForAccountChange()
        XCTAssertTrue(coordinator.captureDrainForAccountChange() === captured)
        XCTAssertFalse(actual.ingestHeartRateMeasurement(measurement, at: 1_750_000_003))
        let drained = await captured.drain()
        XCTAssertTrue(drained)
        XCTAssertEqual(resolverCalls, 0, "standard capture must never resolve a possibly replaced Repository")
        let rows = try await store.hrSamples(deviceId: deviceID, from: 1_750_000_000, to: 1_750_000_010, limit: 100)
        XCTAssertEqual(rows.map(\.ts), [1_750_000_000, 1_750_000_001, 1_750_000_002])
        XCTAssertEqual(actual.pendingCaptureCount, 0)
    }

    func testSourceSwitchCannotStartWhoopUntilFinalBufferDrainSucceeds() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = registry(store)
        let journal = GenericCaptureJournal(store: store, maxBatches: 1)
        let live = LiveState()
        var source: StandardHRSource?
        var starts = 0
        let coordinator = SourceCoordinator(
            registry: registry, live: live, storeHandle: { nil },
            startWhoop: { starts += 1 }, stopWhoop: {},
            setWhoopPreferredPeripheral: { _ in }, setWhoopActiveDeviceId: { _ in },
            connectedPeripheralUUID: Empty<String?, Never>().eraseToAnyPublisher(),
            genericCapture: journal,
            standardSourceFactory: { id in
                let result = StandardHRSource(live: live, deviceId: id, persist: { _ in XCTFail() },
                                              admit: { journal.admit($0, deviceID: id) }, startCentral: false)
                source = result
                return result
            })
        coordinator.start()
        let actual = try XCTUnwrap(source)
        for index in 0..<3 { XCTAssertTrue(actual.ingestHeartRateMeasurement(measurement, at: 1_750_000_000 + index)) }
        registry.setActive("my-whoop")
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(journal.isHeld)
        XCTAssertEqual(journal.pendingFinalBufferCount, 1)
        let drained = await coordinator.retryCapturePersistence()
        XCTAssertTrue(drained)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(actual.pendingCaptureCount, 0)
        XCTAssertFalse(actual.ingestHeartRateMeasurement(measurement, at: 1_750_000_003))
        coordinator.shutdownForAccountChange()
    }

    func testMissingCapturedWriterFailsClosedBeforeSourceConstruction() async throws {
        let store = try await WhoopStore.inMemory()
        var constructed = 0
        let coordinator = SourceCoordinator(
            registry: registry(store), live: LiveState(), storeHandle: { store },
            startWhoop: {}, stopWhoop: {},
            setWhoopPreferredPeripheral: { _ in }, setWhoopActiveDeviceId: { _ in },
            connectedPeripheralUUID: Empty<String?, Never>().eraseToAnyPublisher(),
            standardSourceFactory: { id in
                constructed += 1
                return StandardHRSource(live: LiveState(), deviceId: id, persist: { _ in }, startCentral: false)
            })
        coordinator.start()
        XCTAssertEqual(constructed, 0)
        coordinator.shutdownForAccountChange()
    }

    func testLateGenericFailureAfterWhoopSwitchResumesSameWhoopOnlyAfterRetry() async throws {
        enum Failure: Error { case unavailable }
        let store = try await WhoopStore.inMemory()
        let registry = registry(store)
        let failed = expectation(description: "last generic write failed after switch")
        var fail = true
        let journal = GenericCaptureJournal { streams, id in
            if fail { failed.fulfill(); throw Failure.unavailable }
            _ = try await store.insert(streams, deviceId: id)
        }
        let live = LiveState()
        var source: StandardHRSource?
        var starts = 0
        var stops = 0
        let coordinator = SourceCoordinator(
            registry: registry, live: live, storeHandle: { nil },
            startWhoop: { starts += 1 }, stopWhoop: { stops += 1 },
            setWhoopPreferredPeripheral: { _ in }, setWhoopActiveDeviceId: { _ in },
            connectedPeripheralUUID: Empty<String?, Never>().eraseToAnyPublisher(),
            genericCapture: journal,
            standardSourceFactory: { id in
                let result = StandardHRSource(live: live, deviceId: id, persist: { _ in XCTFail() },
                                              admit: { journal.admit($0, deviceID: id) }, startCentral: false)
                source = result
                return result
            })
        coordinator.start()
        XCTAssertTrue(try XCTUnwrap(source).ingestHeartRateMeasurement(measurement, at: 1_750_000_000))
        registry.setActive("my-whoop")
        XCTAssertEqual(starts, 1)
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertTrue(journal.isHeld)
        fail = false
        let drained = await coordinator.retryCapturePersistence()
        XCTAssertTrue(drained)
        XCTAssertEqual(starts, 2, "same WHOOP id must resume after the late generic persistence hold")
        XCTAssertGreaterThanOrEqual(stops, 2)
        let rows = try await store.hrSamples(deviceId: deviceID, from: 1_750_000_000, to: 1_750_000_010, limit: 100)
        XCTAssertEqual(rows.count, 1)
        coordinator.shutdownForAccountChange()
    }
}
