import Foundation
import GRDB
import XCTest
@testable import WhoopStore

final class CloudMutableJournalTests: XCTestCase {
    private var utc: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
    private func writer() throws -> DatabaseQueue {
        let writer = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(writer)
        return writer
    }
    private func revisions(_ writer: DatabaseQueue, table: CloudMutableTable = .journal,
                           device: String = "synthetic", calendar: Calendar? = nil) throws -> [String: Int64] {
        try writer.read { try WhoopStore.cloudMutableDayRevisions($0, table: table, deviceID: device,
            fromDay: "2026-09-21", toDay: "2026-09-22", calendar: calendar ?? utc) }
    }

    func testInsertCorrectionDeletionCoalesceAndKeepDebtInSameTransaction() throws {
        let writer = try writer()
        XCTAssertEqual(try revisions(writer).values.sorted(), [0,0])
        try writer.write { try $0.execute(sql: "INSERT INTO journal(deviceId,day,question,answeredYes) VALUES('synthetic','2026-09-21','fixture',1)") }
        let inserted = try revisions(writer)
        try writer.write { try $0.execute(sql: "UPDATE journal SET answeredYes=0 WHERE deviceId='synthetic'") }
        let corrected = try revisions(writer)
        XCTAssertGreaterThan(corrected["2026-09-21"]!, inserted["2026-09-21"]!)
        try writer.write { try $0.execute(sql: "DELETE FROM journal") }
        let deleted = try revisions(writer)
        XCTAssertGreaterThan(deleted["2026-09-21"]!, corrected["2026-09-21"]!)
        XCTAssertEqual(deleted["2026-09-22"],0)
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql:"SELECT COUNT(*) FROM cloudMutableRevision"),1)
            XCTAssertEqual(try Int.fetchOne(db, sql:"SELECT COUNT(*) FROM syncJob WHERE kind='cloudPush'"),1)
        }
    }

    func testKeyMoveMarksBothDaysAndDevicesAndRollbackRestoresMarkersAndDebt() throws {
        let writer = try writer()
        try writer.write { try $0.execute(sql: "INSERT INTO dailyMetric(deviceId,day,strain) VALUES('synthetic','2026-09-21',1)") }
        let before = try revisions(writer,table:.dailyMetric)
        do {
            try writer.write { db in
                try db.execute(sql:"UPDATE dailyMetric SET day='2026-09-22',deviceId='second'")
                throw CocoaError(.fileWriteOutOfSpace)
            }
            XCTFail("rollback was not injected")
        } catch {}
        XCTAssertEqual(try revisions(writer,table:.dailyMetric),before)
        XCTAssertEqual(try revisions(writer,table:.dailyMetric,device:"second").values.sorted(),[0,0])
        try writer.write { try $0.execute(sql:"UPDATE dailyMetric SET day='2026-09-22',deviceId='second'") }
        XCTAssertGreaterThan(try revisions(writer,table:.dailyMetric)["2026-09-21"]!,before["2026-09-21"]!)
        XCTAssertGreaterThan(try revisions(writer,table:.dailyMetric,device:"second")["2026-09-22"]!,0)
    }

    func testLegacyMigrationPreservesRowsWithoutScanningOrInventingReceipt() throws {
        let writer = try DatabaseQueue(), migrator = WhoopStore.makeMigrator()
        try migrator.migrate(writer,upTo:"v55-quarantine-maintenance")
        try writer.write { try $0.execute(sql:"INSERT INTO journal(deviceId,day,question,answeredYes) VALUES('synthetic','2026-09-21','fixture',1)") }
        let before = try writer.read { try Row.fetchAll($0,sql:"SELECT * FROM journal") }
        try migrator.migrate(writer)
        XCTAssertEqual(try writer.read { try Row.fetchAll($0,sql:"SELECT * FROM journal") },before)
        XCTAssertEqual(try revisions(writer).values.sorted(),[0,0])
        try writer.write { try $0.execute(sql:"UPDATE journal SET answeredYes=0") }
        XCTAssertGreaterThan(try revisions(writer)["2026-09-21"]!,0)
    }

    func testTimestampBucketsCoverLocalDayAndSurviveTimestampMove() throws {
        let writer = try writer()
        var local = utc; local.timeZone = TimeZone(identifier:"America/Los_Angeles")!
        let formatter = ISO8601DateFormatter()
        let earlyUTC = Int(formatter.date(from:"2026-09-22T01:00:00Z")!.timeIntervalSince1970)
        let laterUTC = earlyUTC + 86400
        try writer.write { db in
            try db.execute(sql:"INSERT INTO workout(deviceId,startTs,endTs,sport,source) VALUES('synthetic',?,?,'fixture','fixture')",arguments:[earlyUTC,earlyUTC+1])
        }
        let old = try revisions(writer,table:.workout,calendar:local)
        XCTAssertGreaterThan(old["2026-09-21"]!,0)
        // Coarse UTC buckets intentionally dirty both overlapping local days.
        XCTAssertGreaterThan(old["2026-09-22"]!,0)
        try writer.write { try $0.execute(sql:"UPDATE workout SET startTs=?,endTs=?",arguments:[laterUTC,laterUTC+1]) }
        let new = try revisions(writer,table:.workout,calendar:local)
        XCTAssertGreaterThan(new["2026-09-21"]!,old["2026-09-21"]!)
        XCTAssertGreaterThan(new["2026-09-22"]!,old["2026-09-22"]!)
    }

    func testRevisionExhaustionFailsClosedWithoutResetOrSourceMutation() throws {
        let writer = try writer()
        try writer.write { try $0.execute(sql:"UPDATE cloudMutableSequence SET revision=9223372036854775807") }
        XCTAssertThrowsError(try writer.write { try $0.execute(sql:"INSERT INTO dailyMetric(deviceId,day) VALUES('synthetic','2026-09-21')") })
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM dailyMetric"),0)
            XCTAssertEqual(try Int64.fetchOne(db,sql:"SELECT revision FROM cloudMutableSequence"),Int64.max)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM syncJob"),0)
        }
    }

    func testBoundedReadUsesOnlyMetadataAndInvalidRangeFailsClosed() throws {
        let writer = try writer()
        try writer.write { try $0.execute(sql:"DROP TABLE journal") }
        XCTAssertEqual(try revisions(writer).values.sorted(),[0,0],"revision lookup read source rows")
        XCTAssertThrowsError(try writer.read { try WhoopStore.cloudMutableDayRevisions($0,table:.journal,deviceID:"synthetic",
            fromDay:"2026-01-01",toDay:"2026-09-22",calendar:utc) })
    }

    func testDirtyPagesIncludeOldDaysAndDoNotSkipSameRevisionMove() throws {
        let writer = try writer()
        try writer.write { db in
            try db.execute(sql: "INSERT INTO journal(deviceId,day,question,answeredYes) VALUES('synthetic','2024-01-01','fixture',1)")
            try db.execute(sql: "UPDATE journal SET day='2024-02-01'")
        }
        func page(_ revision: Int64 = 0, _ key: String = "") throws -> CloudMutableDirtyPage {
            try writer.read { try WhoopStore.cloudMutableDirtyRanges($0, table: .journal, deviceID: "synthetic",
                afterRevision: revision, afterKey: key, limit: 1, calendar: utc) }
        }
        let first = try page(), a = try XCTUnwrap(first.ranges.first)
        XCTAssertEqual(a.fromDay, "2024-01-01"); XCTAssertEqual(a.toDay, a.fromDay)
        XCTAssertTrue(first.hasMore)
        let second = try page(a.revision, a.key), b = try XCTUnwrap(second.ranges.first)
        XCTAssertEqual(b.fromDay, "2024-02-01"); XCTAssertEqual(b.revision, a.revision)
        XCTAssertFalse(second.hasMore)
        XCTAssertTrue(try page(b.revision, b.key).ranges.isEmpty)
        // The source does not erase markers on read; another receiver retains its own frontier.
        XCTAssertEqual(try page(), first)
        try writer.write { try $0.execute(sql: "UPDATE journal SET day='2024-01-01'") }
        let changed = try page(b.revision, b.key)
        XCTAssertEqual(changed.ranges.first?.fromDay, "2024-01-01")
        XCTAssertGreaterThan(try XCTUnwrap(changed.ranges.first?.revision), b.revision)
    }

    func testDirtyTimestampBucketIncludesLocalDaysAcrossDSTAndStaysMetadataOnly() throws {
        let writer = try writer()
        var local = utc; local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let timestamp = Int(ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!.timeIntervalSince1970)
        try writer.write { db in
            try db.execute(sql: "INSERT INTO workout(deviceId,startTs,endTs,sport,source) VALUES('synthetic',?,?,'fixture','fixture')", arguments: [timestamp,timestamp+1])
            try db.execute(sql: "DROP TABLE workout")
        }
        let page = try writer.read { try WhoopStore.cloudMutableDirtyRanges($0, table: .workout, deviceID: "synthetic",
            afterRevision: 0, afterKey: "", limit: 1, calendar: local) }
        XCTAssertEqual(page.ranges.first?.fromDay, "2026-10-31")
        XCTAssertEqual(page.ranges.first?.toDay, "2026-11-01")
        XCTAssertFalse(page.hasMore)
    }

    func testDirtyRangeBoundsMalformedKeysAndIndexedPlan() throws {
        let writer = try writer()
        for limit in [0, 33] {
            XCTAssertThrowsError(try writer.read { try WhoopStore.cloudMutableDirtyRanges($0, table: .journal,
                deviceID: "synthetic", afterRevision: 0, afterKey: "", limit: limit, calendar: utc) })
        }
        try writer.write { try $0.execute(sql: "INSERT INTO cloudMutableRevision VALUES('journal','synthetic','d:invalid',1)") }
        XCTAssertThrowsError(try writer.read { try WhoopStore.cloudMutableDirtyRanges($0, table: .journal,
            deviceID: "synthetic", afterRevision: 0, afterKey: "", limit: 1, calendar: utc) })
        let plan = try writer.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT revision,rangeKey FROM cloudMutableRevision WHERE tableName=? AND deviceId=? AND (revision,rangeKey)>(?,?) ORDER BY revision,rangeKey LIMIT ?",
                arguments: ["journal","synthetic",0,"",2]).map { $0["detail"] as String }.joined(separator: " ")
        }
        XCTAssertTrue(plan.contains("cloudMutableRevision_order"))
        XCTAssertFalse(plan.contains("TEMP B-TREE"))
    }
}
