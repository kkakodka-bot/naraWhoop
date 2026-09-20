import Combine
import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class WhoopIdentityIsolationTests: XCTestCase {
    private let selected = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let nearby = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    private func fixture(pin: String?, replay: String?, encrypted: Bool) async throws
        -> (DeviceRegistry, LiveState, CurrentValueSubject<String?, Never>, SourceCoordinator) {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryWriter))
        registry.reload()
        registry.setPeripheralId("my-whoop", peripheralId: pin)
        let live = LiveState()
        live.selectBatteryDevice("my-whoop")
        live.encryptedBond = encrypted
        let events = CurrentValueSubject<String?, Never>(replay)
        let coordinator = SourceCoordinator(
            registry: registry, live: live, storeHandle: { store },
            startWhoop: {}, stopWhoop: {}, setWhoopPreferredPeripheral: { _ in },
            setWhoopActiveDeviceId: { _ in },
            connectedPeripheralUUID: events.eraseToAnyPublisher())
        return (registry, live, events, coordinator)
    }

    func testLateSubscriberCannotReplaceSelectedStrapWithRestoredPeripheral() async throws {
        // The phone restored a different peripheral, set encryptedBond, then wired this subscriber.
        let (registry, _, _, coordinator) = try await fixture(pin: selected, replay: nearby, encrypted: true)
        coordinator.start()
        XCTAssertEqual(registry.devices.first?.peripheralId, selected)
    }

    func testBondedCallbackCannotReassignExistingDataToAnotherStrap() async throws {
        let (registry, live, events, coordinator) = try await fixture(pin: selected, replay: nil, encrypted: false)
        coordinator.start()
        events.send(nearby)
        XCTAssertEqual(registry.devices.first?.peripheralId, selected)
        live.encryptedBond = true
        events.send(nil)
        events.send(nearby)
        XCTAssertEqual(registry.devices.first?.peripheralId, selected)
    }

    func testFirstPairingPinsTransportBeforeAnotherDiscoveryCanWin() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryWriter))
        registry.reload()
        let events = CurrentValueSubject<String?, Never>(nil)
        var transportPin: String?
        let coordinator = SourceCoordinator(
            registry: registry, live: LiveState(), storeHandle: { store },
            startWhoop: {}, stopWhoop: {}, setWhoopPreferredPeripheral: { transportPin = $0 },
            setWhoopActiveDeviceId: { _ in }, connectedPeripheralUUID: events.eraseToAnyPublisher())
        coordinator.start()
        events.send(selected)
        XCTAssertEqual(registry.devices.first?.peripheralId, selected)
        XCTAssertEqual(transportPin, selected)
        events.send(nearby)
        XCTAssertEqual(registry.devices.first?.peripheralId, selected)
        XCTAssertEqual(transportPin, selected)
    }

    func testExistingStrapReconnectPreservesIdentityAndBattery() async throws {
        let (registry, live, events, coordinator) = try await fixture(pin: selected, replay: nil, encrypted: false)
        live.setBattery(22.8)
        coordinator.start()
        events.send(selected)
        live.encryptedBond = true
        events.send(nil)
        events.send(selected)
        XCTAssertEqual(registry.devices.first?.peripheralId, selected)
        XCTAssertEqual(live.batteryPct, 22.8)
    }

    func testExplicitDeviceSelectionStillWorks() async throws {
        let (registry, _, events, coordinator) = try await fixture(pin: selected, replay: selected, encrypted: true)
        coordinator.start()
        registry.add(PairedDevice(id: "other-whoop", brand: "WHOOP", model: "WHOOP 5.0 / MG",
            peripheralId: nearby, sourceKind: .liveBLE, capabilities: [.hr],
            status: .paired, addedAt: 1, lastSeenAt: 1))
        registry.setActive("other-whoop")
        events.send(nearby)
        XCTAssertEqual(registry.devices.first { $0.id == "my-whoop" }?.peripheralId, selected)
        XCTAssertEqual(registry.devices.first { $0.id == "other-whoop" }?.peripheralId, nearby)
        XCTAssertEqual(registry.activeDeviceId, "other-whoop")
    }

    func testRestorationSelectsRegisteredDeviceRegardlessOfArrayOrder() throws {
        let a = try XCTUnwrap(UUID(uuidString: selected))
        let b = try XCTUnwrap(UUID(uuidString: nearby))
        for candidates in [[a, b], [b, a], [a]] {
            XCTAssertEqual(BLEManager.restoredPeripheralID(preferred: a, candidates: candidates), a)
        }
        XCTAssertNil(BLEManager.restoredPeripheralID(preferred: a, candidates: [b]))
        XCTAssertNil(BLEManager.restoredPeripheralID(preferred: nil, candidates: [b]))
        XCTAssertNil(BLEManager.restoredPeripheralID(preferred: a, candidates: []))
    }

    func testBatteryAndDataCallbacksRequireLoadedMatchingIdentity() throws {
        let a = try XCTUnwrap(UUID(uuidString: selected))
        let b = try XCTUnwrap(UUID(uuidString: nearby))
        XCTAssertTrue(BLEManager.acceptsInboundPeripheral(a, current: a, preferred: a, identityLoaded: true))
        XCTAssertFalse(BLEManager.acceptsInboundPeripheral(b, current: b, preferred: a, identityLoaded: true))
        XCTAssertFalse(BLEManager.acceptsInboundPeripheral(b, current: a, preferred: a, identityLoaded: true))
        XCTAssertFalse(BLEManager.acceptsInboundPeripheral(a, current: a, preferred: nil, identityLoaded: false))
        XCTAssertFalse(BLEManager.acceptsInboundPeripheral(a, current: nil, preferred: a, identityLoaded: true))
    }
}
