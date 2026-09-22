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
}
