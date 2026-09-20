#if DEBUG
import GRDB
import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class WhoopBindingRepairTests: XCTestCase {
    private let mg = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let other = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    private func fixture() async throws -> (WhoopStore, UserDefaults, String) {
        let store = try await WhoopStore.inMemory()
        try DeviceRegistryStore(dbQueue: store.registryWriter).setPeripheralId("my-whoop", peripheralId: other)
        let suite = "WhoopBindingRepairTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(1234.0, forKey: LastSyncAttribution.prefKey(peripheralId: mg)!)
        return (store, defaults, suite)
    }

    private var request: [String: String] {
        ["NOOP_REPAIR_WHOOP_FROM": other, "NOOP_REPAIR_WHOOP_TO": mg]
    }

    func testOrdinaryLaunchDoesNotRepairAnything() async throws {
        let (store, defaults, suite) = try await fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(try WhoopBindingRepair.apply(store: store, defaults: defaults, environment: [:]))
        XCTAssertEqual(try DeviceRegistryStore(dbQueue: store.registryWriter).all().first?.peripheralId, other)
    }

    func testExplicitRepairChangesOnlyBindingAndIsIdempotent() async throws {
        let (store, defaults, suite) = try await fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let before = try XCTUnwrap(registry.all().first)
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO battery(deviceId, ts, soc) VALUES ('my-whoop', 1234, 22.8)")
        }
        XCTAssertTrue(try WhoopBindingRepair.apply(store: store, defaults: defaults, environment: request))
        let after = try XCTUnwrap(registry.all().first)
        XCTAssertEqual(after.peripheralId, mg)
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.lastSeenAt, before.lastSeenAt)
        XCTAssertEqual(after.status, before.status)
        let battery = try await store.registryWriter.read { db in
            try Double.fetchOne(db, sql: "SELECT soc FROM battery WHERE deviceId = 'my-whoop' AND ts = 1234")
        }
        XCTAssertEqual(battery, 22.8)
        XCTAssertFalse(try WhoopBindingRepair.apply(store: store, defaults: defaults, environment: request))
    }

    func testChangedBindingCannotBeOverwrittenByOldRepairRequest() async throws {
        let (store, defaults, suite) = try await fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = UUID().uuidString
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.setPeripheralId("my-whoop", peripheralId: current)
        XCTAssertFalse(try WhoopBindingRepair.apply(store: store, defaults: defaults, environment: request))
        XCTAssertEqual(try registry.all().first?.peripheralId, current)
    }

    func testAmbiguousSyncHistoryCannotBeRepaired() async throws {
        let (store, defaults, suite) = try await fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1235.0, forKey: LastSyncAttribution.prefKey(peripheralId: other)!)
        XCTAssertFalse(try WhoopBindingRepair.apply(store: store, defaults: defaults, environment: request))
    }

    func testMissingHistoricalIdentityCannotBeRepaired() async throws {
        let (store, defaults, suite) = try await fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removeObject(forKey: LastSyncAttribution.prefKey(peripheralId: mg)!)
        XCTAssertFalse(try WhoopBindingRepair.apply(store: store, defaults: defaults, environment: request))
    }

    func testMultipleRegisteredDevicesCannotBeRepaired() async throws {
        let (store, defaults, suite) = try await fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        try DeviceRegistryStore(dbQueue: store.registryWriter).add(PairedDevice(
            id: "other-whoop", brand: "WHOOP", model: "WHOOP 5.0 / MG", peripheralId: mg,
            sourceKind: .liveBLE, capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
        XCTAssertFalse(try WhoopBindingRepair.apply(store: store, defaults: defaults, environment: request))
    }
}
#endif
