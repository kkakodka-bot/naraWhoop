import XCTest
import WhoopProtocol
import GRDB
@testable import WhoopStore

final class StandardHRReceiptStoreTests: XCTestCase {
    func testSameSecondIdentityReplayAndDeviceIsolationOnRealSQLite() async throws {
        let store = try await WhoopStore.inMemory()
        let receipts = try (0..<3).map { ordinal in
            try XCTUnwrap(StandardHRReceipt.capture([0x10, 60, 0, 4],
                sessionId: "11111111-2222-3333-4444-555555555555", notificationOrdinal: Int64(ordinal),
                receivedUnixMs: 1700000000123, receivedMonotonicNs: Int64(ordinal)))
        }
        for owner in ["my-whoop", "other-device"] {
            for _ in 0..<2 { _ = try await store.insert(Streams(standardHrReceipts: receipts), deviceId: owner) }
        }
        let loaded = try await store.standardHrReceipts(deviceId: "my-whoop", from: 1700000000, to: 1700000001)
        XCTAssertEqual(loaded, receipts)
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        XCTAssertTrue(try registry.adoptSerialIdentity(from: "my-whoop", to: "serial-device"))
        let moved = try await store.standardHrReceipts(deviceId: "serial-device", from: 1700000000, to: 1700000001)
        XCTAssertEqual(moved, receipts)
        try registry.deleteAllData(deviceId: "serial-device")
        let gone = try await store.standardHrReceipts(deviceId: "serial-device", from: 1700000000, to: 1700000001)
        let other = try await store.standardHrReceipts(deviceId: "other-device", from: 1700000000, to: 1700000001)
        XCTAssertTrue(gone.isEmpty)
        XCTAssertEqual(other, receipts)
    }

    func testMigrationPreservesOriginalDataAndDoesNotInventReceiptEvidence() throws {
        let db = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(db, upTo: "v50-rr-packet-provenance")
        try db.write { try $0.execute(sql: "INSERT INTO rrInterval(deviceId,ts,rrMs) VALUES('d',1700000000,1000)") }
        try WhoopStore.makeMigrator().migrate(db)
        try db.read {
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rrInterval"), 1)
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM standardHRReceipt"), 0)
        }
    }
}
