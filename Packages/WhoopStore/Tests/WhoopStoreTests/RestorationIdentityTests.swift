import Foundation
import GRDB
import XCTest
@testable import WhoopStore

final class RestorationIdentityTests: XCTestCase {
    private let project = "https://restoration-fixture.invalid"
    private let user = "11111111-1111-4111-8111-111111111111"
    private let peripheral = "22222222-2222-4222-8222-222222222222"

    private func fixture(_ body: (String, DatabaseQueue) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("restoration.sqlite").path
        let writer = try DatabaseQueue(path: path)
        defer { try? writer.close() }
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
            try WhoopStore.installAccountOwnershipSchema(db)
            try db.execute(sql: """
                CREATE TABLE grdb_migrations(identifier TEXT PRIMARY KEY);
                INSERT INTO grdb_migrations VALUES('fixture-existing-schema');
                CREATE TABLE pairedDevice(id TEXT PRIMARY KEY, brand TEXT NOT NULL,
                    model TEXT NOT NULL, nickname TEXT, peripheralId TEXT, sourceKind TEXT NOT NULL,
                    capabilities TEXT NOT NULL, status TEXT NOT NULL, addedAt INTEGER NOT NULL,
                    lastSeenAt INTEGER NOT NULL);
                """)
            try db.execute(sql: "INSERT INTO localAccountOwner VALUES(1,?,?)", arguments: [project,user])
        }
        try body(path,writer)
    }

    private func device(_ id: String = "synthetic-whoop", status: DeviceStatus = .active,
                        brand: String = "WHOOP", sourceKind: SourceKind = .liveBLE,
                        peripheralID: String? = nil) -> PairedDevice {
        PairedDevice(id:id,brand:brand,model:"WHOOP 5.0",peripheralId:peripheralID ?? peripheral,
                     sourceKind:sourceKind,capabilities:[.hr],status:status,addedAt:1,lastSeenAt:2)
    }

    private func lookup(_ path: String) throws -> PairedDevice? {
        try DeviceRegistryStore.readRestorationDevice(path:path,projectURL:project,userID:user)
    }

    func testReadOnlyLookupSeesCommittedWALWithoutMigrationOrPersistentWrites() throws {
        try fixture { path,writer in
            let expected = device()
            try DeviceRegistryStore(dbQueue:writer).add(expected)
            let mainBefore = try Data(contentsOf:URL(fileURLWithPath:path))
            let walBefore = try Data(contentsOf:URL(fileURLWithPath:path + "-wal"))
            XCTAssertGreaterThan(walBefore.count,0)
            XCTAssertEqual(try lookup(path),expected)
            XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:path)),mainBefore)
            XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:path + "-wal")),walBefore)
            try writer.read { db in
                XCTAssertEqual(try String.fetchAll(db,sql:"SELECT identifier FROM grdb_migrations"),["fixture-existing-schema"])
                XCTAssertFalse(try db.tableExists("quarantineMaintenance"))
            }
        }
    }

    func testOnlyRegisteredActiveWHOOPBLEDeviceCanRestore() throws {
        try fixture { path,writer in
            let registry = DeviceRegistryStore(dbQueue:writer)
            try registry.add(device("paired",status:.paired))
            try registry.add(device("archived",status:.archived))
            XCTAssertNil(try lookup(path))
            try registry.add(device("other",brand:"Polar"))
            XCTAssertNil(try lookup(path))
            try registry.add(device("other",sourceKind:.cloudImport))
            XCTAssertNil(try lookup(path))
            let history = device("other",sourceKind:.historyBLE)
            try registry.add(history)
            XCTAssertEqual(try lookup(path),history)
        }
    }

    func testWrongAccountAndProjectCannotInspectRegisteredPeripheral() throws {
        try fixture { path,writer in
            try DeviceRegistryStore(dbQueue:writer).add(device())
            XCTAssertThrowsError(try DeviceRegistryStore.readRestorationDevice(path:path,projectURL:project,
                userID:"33333333-3333-4333-8333-333333333333")) {
                XCTAssertEqual($0 as? LocalAccountOwnershipError,.mismatchedOwner)
            }
            XCTAssertThrowsError(try DeviceRegistryStore.readRestorationDevice(path:path,
                projectURL:"https://another-fixture.invalid",userID:user)) {
                XCTAssertEqual($0 as? LocalAccountOwnershipError,.mismatchedOwner)
            }
        }
    }

    func testLegacyOrUnboundStoreIsNeverClaimedByRestoration() throws {
        try fixture { path,writer in
            try DeviceRegistryStore(dbQueue:writer).add(device())
            try writer.write { try $0.execute(sql:"DELETE FROM localAccountOwner") }
            XCTAssertThrowsError(try lookup(path)) {
                XCTAssertEqual($0 as? RestorationIdentityError,.missingOwner)
            }
            try writer.read { db in
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM localAccountOwner"),0)
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM pairedDevice"),1)
            }
            try writer.write { try $0.execute(sql:"DROP TABLE localAccountOwner") }
            XCTAssertThrowsError(try lookup(path)) {
                XCTAssertEqual($0 as? RestorationIdentityError,.missingOwner)
            }
        }
    }

    func testAmbiguousActiveRowsAndInvalidPeripheralFailClosed() throws {
        try fixture { path,writer in
            let registry = DeviceRegistryStore(dbQueue:writer)
            try registry.add(device("first"))
            try registry.add(device("second"))
            XCTAssertThrowsError(try lookup(path)) {
                XCTAssertEqual($0 as? RestorationIdentityError,.ambiguousActiveDevice)
            }
            try registry.archive("second")
            try registry.add(device("first",peripheralID:"not-a-uuid"))
            XCTAssertThrowsError(try lookup(path)) {
                XCTAssertEqual($0 as? RestorationIdentityError,.invalidRegisteredDevice)
            }
        }
    }

    func testUncommittedReplacementCannotCrossReadSnapshot() throws {
        try fixture { path,writer in
            let expected = device()
            try DeviceRegistryStore(dbQueue:writer).add(expected)
            try writer.writeWithoutTransaction { db in
                try db.execute(sql:"BEGIN IMMEDIATE")
                defer { try? db.execute(sql:"ROLLBACK") }
                try db.execute(sql:"UPDATE pairedDevice SET peripheralId=?",
                    arguments:["44444444-4444-4444-8444-444444444444"])
                XCTAssertEqual(try lookup(path),expected)
            }
        }
    }

    func testMissingFileIsNotCreatedAndMalformedSchemaIsNotRepaired() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        XCTAssertThrowsError(try lookup(path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:path))
        try fixture { path,writer in
            try writer.write { try $0.execute(sql:"DROP TABLE pairedDevice") }
            XCTAssertThrowsError(try lookup(path))
            try writer.read { XCTAssertFalse(try $0.tableExists("pairedDevice")) }
        }
    }
}
