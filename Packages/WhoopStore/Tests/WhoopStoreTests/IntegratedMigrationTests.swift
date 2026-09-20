import GRDB
import XCTest
@testable import WhoopStore

final class IntegratedMigrationTests: XCTestCase {
    func testPR16UpgradePreservesScoreCacheAndLegacyPpgBytes() throws {
        let dbq = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbq, upTo: "v47-server-score-cache")
        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO ppgWaveformSample (rowid, deviceId, ts, samples, burstIndex)
                VALUES (88, 'migration-fixture', 123, X'01000200', 14);
                INSERT INTO serverScoreCache
                    (day, algorithmVersion, dailyJson, nightsJson, stale, fetchedAt)
                VALUES ('2026-09-17', 'frwhoop-server-1', '{"restingHrBpm":60}', '[]', 1, 123);
                """)
        }
        try migrator.migrate(dbq)
        try migrator.migrate(dbq)
        try dbq.read { db in
            let ppg = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT rowid, * FROM ppgWaveformSample"))
            XCTAssertEqual(ppg["rowid"] as Int, 88)
            XCTAssertEqual(ppg["samples"] as Data, Data([1, 0, 2, 0]))
            XCTAssertEqual(ppg["recordIndex"] as Int, -1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT dailyJson FROM serverScoreCache"),
                           "{\"restingHrBpm\":60}")
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
        }
    }

    func testPR15UpgradeAppliesOtherFeatureMigrationsWithoutRebuildingPpg() throws {
        let dbq = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbq, upTo: "v45-backfill-frontier")
        try dbq.write { db in
            try db.execute(sql: """
                DROP TABLE ppgWaveformSample;
                CREATE TABLE ppgWaveformSample (
                    deviceId TEXT NOT NULL, ts INTEGER NOT NULL, samples BLOB NOT NULL,
                    burstIndex INTEGER, recordIndex INTEGER NOT NULL,
                    PRIMARY KEY(deviceId, ts, recordIndex));
                INSERT INTO ppgWaveformSample (rowid, deviceId, ts, samples, burstIndex, recordIndex)
                VALUES (80, 'migration-fixture', 123, X'0100', 14, 10),
                       (81, 'migration-fixture', 123, X'0200', 14, 11);
                INSERT INTO grdb_migrations VALUES ('v46-ppg-record-identity');
                """)
        }
        try migrator.migrate(dbq)
        try migrator.migrate(dbq)
        try dbq.read { db in
            XCTAssertEqual(try Int.fetchAll(db, sql: "SELECT rowid FROM ppgWaveformSample ORDER BY rowid"), [80, 81])
            XCTAssertEqual(try Int.fetchAll(db, sql: "SELECT recordIndex FROM ppgWaveformSample ORDER BY rowid"), [10, 11])
            XCTAssertEqual(try Data.fetchAll(db, sql: "SELECT samples FROM ppgWaveformSample ORDER BY rowid"),
                           [Data([1, 0]), Data([2, 0])])
            XCTAssertTrue(try db.tableExists("serverScoreCache"))
            XCTAssertTrue(try db.indexes(on: "rrInterval").contains { $0.name == "rrInterval_source_suspect" })
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations"), migrator.migrations.count)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
        }
    }
}
