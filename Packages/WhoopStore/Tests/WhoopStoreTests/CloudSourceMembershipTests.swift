import Foundation
import GRDB
import SQLite3
import XCTest
@testable import WhoopStore

private final class MembershipReadAudit {
    let tables = Set(CloudSourceTable.allCases.map(\.rawValue))
    let permitted: Set<String>
    var reads: [(String, String)] = []
    init(permitted: Set<String>) { self.permitted = permitted }
    func install(_ db: Database) {
        sqlite3_set_authorizer(db.sqliteConnection, { context, action, first, second, _, _ in
            guard action == SQLITE_READ, let context, let first else { return SQLITE_OK }
            let audit = Unmanaged<MembershipReadAudit>.fromOpaque(context).takeUnretainedValue()
            let table = String(cString: first), column = second.map { String(cString: $0).lowercased() } ?? ""
            guard audit.tables.contains(table) else { return SQLITE_OK }
            audit.reads.append((table, column))
            return audit.permitted.contains(column) ? SQLITE_OK : SQLITE_DENY
        }, Unmanaged.passUnretained(self).toOpaque())
    }
}

final class CloudSourceMembershipTests: XCTestCase {
    private func writer(upTo: String? = nil) throws -> DatabaseQueue {
        let writer = try DatabaseQueue()
        if let upTo { try WhoopStore.makeMigrator().migrate(writer, upTo: upTo) }
        else { try WhoopStore.makeMigrator().migrate(writer) }
        return writer
    }
    private func bootstrap(_ writer: DatabaseQueue, _ tables: Set<CloudSourceTable>, limit: Int = 2000) throws -> CloudSourceBootstrapProgress {
        try writer.write { try WhoopStore.advanceCloudSourceBootstrap($0, tables: tables, maximumRows: limit) }
    }
    private func membership(_ writer: DatabaseQueue, _ tables: Set<CloudSourceTable>) throws -> CloudSourceMembershipSnapshot {
        try writer.read { try WhoopStore.cloudSourceMembership($0, tables: tables) }
    }

    func testMigrationCreatesOnlyMetadataAndTriggersWithoutScanningLegacySources() throws {
        let writer = try writer(upTo: "v57-cloud-mutable-order")
        try writer.write { db in
            try db.execute(sql: "INSERT INTO event(deviceId,ts,kind,payloadJSON) VALUES('synthetic',1,'fixture',?)", arguments: [String(repeating: "x", count: 1_000_000)])
        }
        let audit = MembershipReadAudit(permitted: [])
        try writer.writeWithoutTransaction { audit.install($0) }
        try WhoopStore.makeMigrator().migrate(writer)
        try writer.writeWithoutTransaction { sqlite3_set_authorizer($0.sqliteConnection, nil, nil) }
        XCTAssertTrue(audit.reads.isEmpty, "migration scanned source data")
        XCTAssertEqual(try membership(writer, [.event]).deviceIDs, [])
        XCTAssertFalse(try membership(writer, [.event]).isComplete)
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloudSourceBootstrap"), CloudSourceTable.allCases.count)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloudSourceBootstrap WHERE complete=1"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_schema WHERE type='trigger' AND name LIKE 'cloudSource_%'"), 3 * CloudSourceTable.allCases.count)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT length(payloadJSON) FROM event"), 1_000_000)
        }
    }

    func testBoundedKeysetProgressSpansTablesAndNeverReadsMoreThanTwoThousandRows() throws {
        let writer = try writer(upTo: "v57-cloud-mutable-order")
        try writer.write { db in
            try db.execute(sql: "INSERT INTO event(rowid,deviceId,ts,kind,payloadJSON) VALUES(-10,'negative-row',1,'fixture','{}')")
            for index in 0..<2500 {
                try db.execute(sql: "INSERT INTO hrSample(deviceId,ts,bpm) VALUES(?,?,60)", arguments: ["synthetic-\(index % 3)",index])
            }
        }
        try WhoopStore.makeMigrator().migrate(writer)
        let first = try bootstrap(writer, [.event,.hrSample])
        XCTAssertEqual(first.rowsRead, 2000); XCTAssertFalse(first.isComplete)
        XCTAssertFalse(try membership(writer, [.hrSample]).isComplete)
        XCTAssertTrue(try membership(writer, [.event]).isComplete)
        let second = try bootstrap(writer, [.event,.hrSample])
        XCTAssertEqual(second.rowsRead, 501); XCTAssertTrue(second.isComplete)
        XCTAssertEqual(try membership(writer, [.event,.hrSample]).deviceIDs, ["negative-row","synthetic-0","synthetic-1","synthetic-2"])
        XCTAssertEqual(try bootstrap(writer, [.event,.hrSample]).rowsRead, 0)
        XCTAssertEqual(try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM syncJob WHERE kind='cloudPush'") }, 1)
    }

    func testExactPageRemainsIncompleteUntilConfirmedEndAndProgressSurvivesReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("membership.sqlite").path
        let original = try DatabaseQueue(path: path)
        try WhoopStore.makeMigrator().migrate(original, upTo: "v57-cloud-mutable-order")
        try original.write { try $0.execute(sql: "INSERT INTO hrSample(deviceId,ts,bpm) VALUES('synthetic',1,60)") }
        try WhoopStore.makeMigrator().migrate(original)
        XCTAssertFalse(try bootstrap(original, [.hrSample], limit: 1).isComplete)
        try original.close()
        let reopened = try DatabaseQueue(path: path)
        defer { XCTAssertNoThrow(try reopened.close()) }
        XCTAssertEqual(try membership(reopened, [.hrSample]).deviceIDs, ["synthetic"])
        let final = try bootstrap(reopened, [.hrSample], limit: 1)
        XCTAssertEqual(final.rowsRead, 0); XCTAssertTrue(final.isComplete)
    }

    func testMovesDeletesAndReusedRowIDsBehindBootstrapCursorRetainBothIdentities() throws {
        let writer = try writer(upTo: "v57-cloud-mutable-order")
        try writer.write { db in
            for index in [10,20,30] {
                try db.execute(sql: "INSERT INTO hrSample(rowid,deviceId,ts,bpm) VALUES(?,?,?,60)", arguments: [index,"legacy-\(index)",index])
            }
        }
        try WhoopStore.makeMigrator().migrate(writer)
        XCTAssertEqual(try bootstrap(writer, [.hrSample], limit: 1).rowsRead, 1)
        try writer.write { db in
            try db.execute(sql: "UPDATE hrSample SET rowid=5,deviceId='moved' WHERE rowid=30")
            try db.execute(sql: "DELETE FROM hrSample WHERE rowid IN (10,20)")
            try db.execute(sql: "INSERT INTO hrSample(rowid,deviceId,ts,bpm) VALUES(10,'reused',100,61),(-20,'new-negative',101,62)")
        }
        XCTAssertTrue(try bootstrap(writer, [.hrSample]).isComplete)
        XCTAssertEqual(try membership(writer, [.hrSample]).deviceIDs,
                       ["legacy-10","legacy-20","legacy-30","moved","new-negative","reused"])
    }

    func testLegacyMutableBootstrapSeedsOldDaysAtFreshRevisionWithoutRewindingExistingMarker() throws {
        let writer = try writer(upTo: "v55-quarantine-maintenance")
        try writer.write { db in
            try db.execute(sql: "INSERT INTO journal(deviceId,day,question,answeredYes) VALUES('synthetic','2020-01-01','fixture',1),('synthetic','2020-01-02','fixture',1)")
            try db.execute(sql: "INSERT INTO workout(deviceId,startTs,endTs,sport,source) VALUES('synthetic',1577836800,1577836801,'fixture','fixture')")
        }
        try WhoopStore.makeMigrator().migrate(writer)
        try writer.write { try $0.execute(sql: "UPDATE journal SET answeredYes=0 WHERE day='2020-01-01'") }
        let prior = try writer.read { try Int64.fetchOne($0, sql: "SELECT revision FROM cloudMutableRevision WHERE rangeKey='d:2020-01-01'")! }
        let result = try bootstrap(writer, [.journal,.workout])
        XCTAssertTrue(result.isComplete); XCTAssertEqual(result.rowsRead, 3)
        try writer.read { db in
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT revision FROM cloudMutableRevision WHERE rangeKey='d:2020-01-01'"), prior)
            let seeded = try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT revision FROM cloudMutableRevision WHERE rangeKey='d:2020-01-02'"))
            XCTAssertGreaterThan(seeded, prior)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT revision FROM cloudMutableRevision WHERE tableName='workout'"), seeded)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncJob WHERE kind='cloudPush'"), 1)
        }
        try writer.write { try $0.execute(sql: "DELETE FROM journal WHERE day='2020-01-02'") }
        XCTAssertGreaterThan(try writer.read { try Int64.fetchOne($0, sql: "SELECT revision FROM cloudMutableRevision WHERE rangeKey='d:2020-01-02'")! }, prior)
    }

    func testBootstrapFailureRollsBackMembershipProgressRevisionAndDebtWithoutChangingSource() throws {
        let writer = try writer(upTo: "v55-quarantine-maintenance")
        try writer.write { try $0.execute(sql: "INSERT INTO journal(deviceId,day,question,answeredYes) VALUES('synthetic','2020-01-01','fixture',1)") }
        try WhoopStore.makeMigrator().migrate(writer)
        XCTAssertThrowsError(try writer.write { db in
            _ = try WhoopStore.advanceCloudSourceBootstrap(db, tables: [.journal])
            throw CocoaError(.fileWriteOutOfSpace)
        })
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloudSourceMembership"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloudSourceBootstrap WHERE complete=1 OR lastRowId IS NOT NULL"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT revision FROM cloudMutableSequence"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloudMutableRevision"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncJob"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM journal"), 1)
        }
        XCTAssertTrue(try bootstrap(writer, [.journal]).isComplete)
    }

    func testMembershipFailureAbortsSourceWriteAndRetainsPriorSourceState() throws {
        let writer = try writer()
        try writer.write { try $0.execute(sql: "CREATE TRIGGER rejectMembership BEFORE INSERT ON cloudSourceMembership BEGIN SELECT RAISE(ABORT,'fixture membership failure'); END") }
        XCTAssertThrowsError(try writer.write { try $0.execute(sql: "INSERT INTO journal(deviceId,day,question,answeredYes) VALUES('synthetic','2020-01-01','fixture',1)") })
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM journal"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloudMutableRevision"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncJob"), 0)
        }
    }

    func testSourceUpsertConflictPolicyCannotTurnDuplicateMembershipIntoFailure() throws {
        let writer = try writer()
        try writer.write { db in
            for answer in [1,0,1] {
                try db.execute(sql: """
                    INSERT INTO journal(deviceId,day,question,answeredYes) VALUES('synthetic','2020-01-01','fixture',?)
                    ON CONFLICT(deviceId,day,question) DO UPDATE SET answeredYes=excluded.answeredYes
                    """, arguments: [answer])
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloudSourceMembership WHERE tableName='journal'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT answeredYes FROM journal"), 1)
        }
    }

    func testBootstrapReadsOnlyIdentityAndRangeMetadataAndMembershipLookupNeedsNoSourceTables() throws {
        let writer = try writer(upTo: "v55-quarantine-maintenance")
        try writer.write { db in
            try db.execute(sql: "INSERT INTO event(deviceId,ts,kind,payloadJSON) VALUES('synthetic',1,'fixture',?)", arguments: [String(repeating: "x", count: 1_000_000)])
            try db.execute(sql: "INSERT INTO journal(deviceId,day,question,answeredYes) VALUES('synthetic','2020-01-01','fixture',1)")
        }
        try WhoopStore.makeMigrator().migrate(writer)
        let audit = MembershipReadAudit(permitted: ["rowid","deviceid","day","startts"])
        try writer.writeWithoutTransaction { audit.install($0) }
        XCTAssertTrue(try bootstrap(writer, [.event,.journal]).isComplete)
        try writer.writeWithoutTransaction { sqlite3_set_authorizer($0.sqliteConnection, nil, nil) }
        XCTAssertFalse(audit.reads.isEmpty)
        try writer.write { try $0.execute(sql: "DROP TABLE event; DROP TABLE journal") }
        XCTAssertEqual(try membership(writer, [.event,.journal]).deviceIDs, ["synthetic"])
        XCTAssertTrue(try membership(writer, [.event,.journal]).isComplete)
    }

    func testBoundsMissingProgressAndRevisionExhaustionFailClosed() throws {
        let writer = try writer()
        for count in [0,2001] { XCTAssertThrowsError(try bootstrap(writer, [.event], limit: count)) }
        XCTAssertThrowsError(try writer.writeWithoutTransaction { try WhoopStore.advanceCloudSourceBootstrap($0, tables: [.event]) })
        XCTAssertTrue(try bootstrap(writer, []).isComplete)
        try writer.write { try $0.execute(sql: "DELETE FROM cloudSourceBootstrap WHERE tableName='event'") }
        XCTAssertFalse(try membership(writer, [.event]).isComplete)
        XCTAssertThrowsError(try bootstrap(writer, [.event]))
        let legacy = try self.writer(upTo: "v55-quarantine-maintenance")
        try legacy.write { try $0.execute(sql: "INSERT INTO journal(deviceId,day,question,answeredYes) VALUES('synthetic','2020-01-01','fixture',1)") }
        try WhoopStore.makeMigrator().migrate(legacy)
        try legacy.write { try $0.execute(sql: "UPDATE cloudMutableSequence SET revision=9223372036854775807") }
        XCTAssertThrowsError(try bootstrap(legacy, [.journal]))
        XCTAssertEqual(try membership(legacy, [.journal]).deviceIDs, [])
        XCTAssertFalse(try membership(legacy, [.journal]).isComplete)
    }

    func testEmptyBootstrapMetadataAllowsOwnerBindingButRetainedMembershipDoesNot() async throws {
        let fresh = try await WhoopStore.inMemory()
        _ = try await fresh.registryWriter.write { try WhoopStore.advanceCloudSourceBootstrap($0, tables: Set(CloudSourceTable.allCases)) }
        try await fresh.bindAccountOwner(projectURL: "https://owner.invalid", userID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let unowned = try await WhoopStore.inMemory()
        try await unowned.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO event(deviceId,ts,kind,payloadJSON) VALUES('synthetic',1,'fixture','{}'); DELETE FROM event; DELETE FROM syncJob")
        }
        do {
            try await unowned.bindAccountOwner(projectURL: "https://owner.invalid", userID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
            XCTFail("retained unassigned source membership was rebound")
        } catch { XCTAssertEqual(error as? LocalAccountOwnershipError, .unassignedExistingData) }
    }
}
