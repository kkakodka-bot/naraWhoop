import Foundation
import GRDB
import WhoopProtocol
import XCTest
@testable import WhoopStore

final class V18AuxIdentityMigrationTests: XCTestCase {
    private func legacy(_ path: String? = nil) throws -> DatabaseQueue {
        let db = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(db, upTo: "v50-account-store-owner")
        return db
    }

    func testStrictIdentityRejectsTruncatedTrailingUnknownAndFutureBlobs() {
        let valid = V18AuxCodec.pack(V18AuxSample(ts: 1, recordIndex: 0, statusWord: 7))
        XCTAssertEqual(V18AuxCodec.strictRecordIndex(in: valid), 0)
        XCTAssertEqual(V18AuxCodec.strictRecordIndex(in: V18AuxCodec.pack(
            V18AuxSample(ts: 1, recordIndex: Int(UInt32.max)))), Int(UInt32.max))
        for end in 0..<valid.count { XCTAssertNil(V18AuxCodec.strictRecordIndex(in: valid.prefix(end))) }
        XCTAssertNil(V18AuxCodec.strictRecordIndex(in: valid + Data([0])))
        var future = valid; future[0] = 3
        XCTAssertNil(V18AuxCodec.strictRecordIndex(in: future))
        var unknown = valid; unknown[4] |= 0x80
        XCTAssertNil(V18AuxCodec.strictRecordIndex(in: unknown))
        XCTAssertNil(V18AuxCodec.strictRecordIndex(in: V18AuxCodec.pack(V18AuxSample(ts: 1, statusWord: 7))))
    }

    func testFileMigrationPreservesSparseRowidsExactBytesKeysAndLedgerOnReopen() throws {
        let path = NSTemporaryDirectory() + "aux-v51-\(UUID().uuidString).sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let dbq = try legacy(path)
        let valid = V18AuxCodec.pack(V18AuxSample(ts: 100, recordIndex: 42, statusWord: 3))
        let fixtures = [valid, Data(valid.dropLast()), Data([3, 0, 0, 0, 0]), Data()]
        let ids: [Int64] = [-4, 0, 88, 9000]
        let scope = DurableIngestScope(environment: "https://fixture.invalid", accountID: "owner", deviceID: "strap")
        try dbq.write { db in
            for (i, bytes) in fixtures.enumerated() {
                try db.execute(sql: "INSERT INTO v18AuxSample(rowid,deviceId,ts,fields) VALUES (?,'strap',?,?)",
                    arguments: [ids[i], 100 + i, bytes])
            }
            try WhoopStore.registerRawResource(db, scope: scope, lane: "v18AuxSample", key: "100", bytes: valid)
            try WhoopStore.installV18AuxIdentitySchema(db)
        }
        let reopened = try DatabaseQueue(path: path)
        try reopened.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT rowid,* FROM v18AuxSample ORDER BY rowid")
            XCTAssertEqual(rows.map { $0["rowid"] as Int64 }, ids)
            XCTAssertEqual(rows.map { $0["fields"] as Data }, fixtures)
            XCTAssertEqual(rows.map { $0["recordIndex"] as Int }, [42, -1, -1, -1])
            XCTAssertEqual(rows.map { $0["resourceKey"] as String }, ["100", "101", "102", "103"])
            XCTAssertEqual(try db.primaryKey("v18AuxSample").columns, ["deviceId", "ts", "recordIndex"])
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT resourceKey FROM ingestRawResource"), "100")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawDurabilityReceipt"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM localAccountOwner"), 0)
        }
    }

    func testDigestMismatchRollsBackEntireMigration() throws {
        let dbq = try legacy()
        try dbq.write { db in
            try db.execute(sql: "INSERT INTO v18AuxSample VALUES ('strap',1,X'0200000000')")
            try WhoopStore.registerRawResource(db, scope: .unassigned(deviceID: "strap"),
                lane: "v18AuxSample", key: "1", bytes: Data([9]))
        }
        XCTAssertThrowsError(try dbq.write { try WhoopStore.installV18AuxIdentitySchema($0) }) {
            XCTAssertEqual($0 as? V18AuxIdentitySchemaError, .ledgerMismatch)
        }
        try dbq.read { db in
            XCTAssertEqual(try db.primaryKey("v18AuxSample").columns, ["deviceId", "ts"])
            // Query SQLite itself, not GRDB's schema cache populated before the rollback.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name='v18AuxSample_v51'"), 0)
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT fields FROM v18AuxSample"), Data([2, 0, 0, 0, 0]))
        }
    }

    func testResourceKeyUsesOneNamedUniqueIndexWithoutImplicitDuplicate() throws {
        let dbq = try legacy()
        try dbq.write { db in
            try WhoopStore.installV18AuxIdentitySchema(db)
            let indexes = try Row.fetchAll(db, sql: "PRAGMA index_list(v18AuxSample)")
            XCTAssertEqual(indexes.count, 2, "only the composite primary key and named resource-key index")
            XCTAssertEqual(indexes.filter { ($0["origin"] as String) == "pk" }.count, 1)
            XCTAssertFalse(indexes.contains { ($0["origin"] as String) == "u" },
                "inline UNIQUE would add a redundant implicit index")
            let resourceIndex = try XCTUnwrap(indexes.first {
                ($0["name"] as String) == "index_v18AuxSample_deviceId_resourceKey"
            })
            XCTAssertEqual(resourceIndex["unique"] as Int, 1)
            XCTAssertEqual(resourceIndex["origin"] as String, "c")
            XCTAssertEqual(resourceIndex["partial"] as Int, 0)
            let columns = try Row.fetchAll(db, sql: "PRAGMA index_info(index_v18AuxSample_deviceId_resourceKey)")
            XCTAssertEqual(columns.map { $0["name"] as String }, ["deviceId", "resourceKey"])
            try db.execute(sql: "INSERT INTO v18AuxSample VALUES ('strap',1,1,X'02','same-key')")
            XCTAssertThrowsError(try db.execute(sql:
                "INSERT INTO v18AuxSample VALUES ('strap',1,2,X'03','same-key')"))
            try db.execute(sql: "INSERT INTO v18AuxSample VALUES ('other',1,2,X'03','same-key')")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v18AuxSample"), 2)
        }
    }

    func testPagedCopyPreservesEveryRowAndDoesNotTransferLegacyReceipt() throws {
        let dbq = try legacy()
        try dbq.write { db in
            for i in 0..<1025 {
                try db.execute(sql: "INSERT INTO v18AuxSample(rowid,deviceId,ts,fields) VALUES (?,'strap',?,?)",
                    arguments: [i * 3 + 1, i, V18AuxCodec.pack(V18AuxSample(ts: i, recordIndex: 1))])
            }
            try WhoopStore.installV18AuxIdentitySchema(db)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v18AuxSample"), 1025)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT MAX(rowid) FROM v18AuxSample"), 3073)
            try db.execute(sql: "INSERT INTO v18AuxSample VALUES ('strap',0,2,X'02','0:2')")
            XCTAssertThrowsError(try db.execute(sql: "INSERT INTO v18AuxSample VALUES ('strap',0,3,X'03','0')"))
            XCTAssertThrowsError(try db.execute(sql: "INSERT INTO v18AuxSample VALUES ('strap',0,-2,X'03','bad')"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawDurabilityReceipt"), 0)
        }
    }

    func testScalarHelperPreservesRowsAndLeavesLegacyProvenanceNull() throws {
        let dbq = try legacy()
        try dbq.write { db in
            try db.execute(sql: "INSERT INTO stepSample(deviceId,ts,counter) VALUES ('strap',1,65535)")
            try WhoopStore.installScalarProvenanceSchema(db)
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT rowid,counter,provenanceJSON FROM stepSample"))
            XCTAssertEqual(row["rowid"] as Int, 1)
            XCTAssertEqual(row["counter"] as Int, 65535)
            XCTAssertNil(row["provenanceJSON"] as String?)
            for table in ["stepSample", "sleepStateSample", "ppgHrSample"] {
                XCTAssertTrue(try db.columns(in: table).contains { $0.name == "provenanceJSON" && !$0.isNotNull })
            }
        }
    }

    func testLegacyVerifiedReceiptNeverAuthorizesSameSecondSibling() throws {
        let dbq = try legacy()
        let scope = DurableIngestScope(environment: "https://fixture.invalid", accountID: "owner", deviceID: "strap")
        let original = V18AuxCodec.pack(V18AuxSample(ts: 123, recordIndex: 1))
        let sibling = V18AuxCodec.pack(V18AuxSample(ts: 123, recordIndex: 2))
        try dbq.write { db in
            try db.execute(sql: "INSERT INTO v18AuxSample VALUES ('strap',123,?)", arguments: [original])
            try WhoopStore.registerRawResource(db, scope: scope, lane: "v18AuxSample", key: "123", bytes: original)
            try db.execute(sql: """
                INSERT INTO rawDurabilityReceipt VALUES
                ('v18AuxSample','strap','123',?,?,'original/object','original-receipt',1,2)
                """, arguments: [scope.key, DurableIngestScope.sha256(original)])
            let receiptBefore = try Row.fetchAll(db, sql: "SELECT * FROM rawDurabilityReceipt")
            try WhoopStore.installV18AuxIdentitySchema(db)
            try db.execute(sql: "INSERT INTO v18AuxSample VALUES ('strap',123,2,?,'123:2')", arguments: [sibling])
            try WhoopStore.registerRawResource(db, scope: scope, lane: "v18AuxSample", key: "123:2", bytes: sibling)
            let eligible = try Int.fetchAll(db, sql: """
                SELECT recordIndex FROM v18AuxSample WHERE
                \(WhoopStore.rawReceiptPredicate(table: "v18AuxSample", keySQL: "v18AuxSample.resourceKey"))
                """, arguments: [100])
            XCTAssertEqual(eligible, [1])
            XCTAssertEqual(try Row.fetchAll(db, sql: "SELECT * FROM rawDurabilityReceipt"), receiptBefore)
        }
    }
}
