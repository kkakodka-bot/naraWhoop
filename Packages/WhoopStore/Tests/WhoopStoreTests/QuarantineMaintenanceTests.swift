import Foundation
import GRDB
import XCTest
import WhoopProtocol
@testable import WhoopStore

final class QuarantineMaintenanceTests: XCTestCase {
    private let scope = DurableIngestScope(environment: "https://fixture.invalid",
        accountID: "11111111-1111-4111-8111-111111111111", deviceID: "synthetic")

    private func makeStore() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.bindAccountOwner(projectURL: scope.environment!, userID: scope.accountID!)
        try await store.upsertDevice(id: scope.deviceID, mac: nil, name: nil)
        return store
    }

    private func assertAccounting(_ store: WhoopStore, bytes: Int, records: Int,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        try await store.registryWriter.read { db in
            let counters = try WhoopStore.quarantineAccounting(db)
            XCTAssertEqual(counters.bytes, bytes, file: file, line: line)
            XCTAssertEqual(counters.records, records, file: file, line: line)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(frame)),0) FROM sensorQuarantine"), bytes, file: file, line: line)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sensorQuarantine"), records, file: file, line: line)
        }
    }

    private func receipt(_ store: WhoopStore, row: SensorQuarantineRecord, parent: Bool) async throws {
        let lane = parent ? "rawBatch" : "sensorQuarantine"
        let key = parent ? QuarantineArchiveIdentity(recordID: row.id, family: row.family, trim: row.trim).batchID : row.id
        let saved = try await store.rawResourceIdentity(scope: scope, lane: lane, resourceKey: key)
        let identity = try XCTUnwrap(saved)
        try await store.recordRawDurabilityReceipt(RawDurabilityReceipt(scope: scope, lane: lane,
            resourceKey: key, contentSHA256: identity.contentSHA256, objectKey: "synthetic/object",
            receiptID: "synthetic-receipt", verifiedAt: 1, retainUntil: 10))
    }

    func testAdditiveMigrationPreservesEvidenceAndDefersMatchingBytesCacheUntilMaintenance() throws {
        let writer = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(writer, upTo: "v54-workout-preference-evaluation")
        try writer.write { db in
            for index in 0..<2 {
                let id = DurableIngestScope.sha256(Data("legacy-\(index)".utf8))
                let original = Data([UInt8(index),2])
                try db.execute(sql: """
                    INSERT INTO sensorQuarantine(id,scopeKey,environment,accountId,deviceId,family,trim,frame,capturedAt)
                    VALUES(?,?,?,?,?,'whoop5',42,?,100)
                    """, arguments: [id,scope.key,scope.environment,scope.accountID,scope.deviceID,
                                      index == 0 ? original : Data([9,9,9])])
                try WhoopStore.registerRawResource(db, scope: scope, lane: "sensorQuarantine", key: id, bytes: original)
            }
        }
        let before = try writer.read { try Row.fetchAll($0, sql: "SELECT * FROM sensorQuarantine ORDER BY id") }
        try migrator.migrate(writer)
        try writer.read { db in
            XCTAssertEqual(try Row.fetchAll(db, sql: "SELECT * FROM sensorQuarantine ORDER BY id"), before)
            let accounting = try WhoopStore.quarantineAccounting(db)
            XCTAssertEqual(accounting.bytes,5)
            XCTAssertEqual(accounting.records,2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM quarantineArchiveMembership"),0)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"),"ok")
        }
        try migrator.migrate(writer)
        try writer.write { db in
            XCTAssertEqual(try WhoopStore.pruneQuarantinePage(db, now: 200, limit: 2),0)
        }
        try writer.read { db in
            XCTAssertEqual(try WhoopStore.quarantineAccounting(db).records,2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM quarantineArchiveMembership"),1)
        }
    }

    func testCountersFollowInsertReplayUpdateDeleteAndRollback() async throws {
        let store = try await makeStore()
        let frames: [[UInt8]] = [[1,2],[3,4,5]]
        try await store.persistSensorQuarantine(frames, scope: scope, family: "whoop5", trim: 1)
        try await assertAccounting(store,bytes:5,records:2)
        try await store.persistSensorQuarantine(frames, scope: scope, family: "whoop5", trim: 1)
        try await assertAccounting(store,bytes:5,records:2)
        let rows = try await store.pendingSensorQuarantine(scope: scope)
        let first = try XCTUnwrap(rows.first)
        try await store.registryWriter.write { db in
            try db.execute(sql: "UPDATE sensorQuarantine SET frame=? WHERE id=?", arguments:[Data([1]),first.id])
        }
        try await assertAccounting(store,bytes:6-first.frame.count,records:2)
        do {
            try await store.registryWriter.write { db in
                try db.execute(sql:"DELETE FROM sensorQuarantine")
                throw CocoaError(.fileWriteOutOfSpace)
            }
            XCTFail("Synthetic rollback was not raised")
        } catch {}
        try await assertAccounting(store,bytes:6-first.frame.count,records:2)
        try await store.registryWriter.write { try $0.execute(sql:"DELETE FROM sensorQuarantine") }
        try await assertAccounting(store,bytes:0,records:0)
    }

    func testMembershipFailureRollsBackChunkAccountingRowsDebtAndCursor() async throws {
        let store = try await makeStore()
        try await store.registryWriter.write { db in
            try db.execute(sql:"CREATE TEMP TRIGGER reject_membership BEFORE INSERT ON quarantineArchiveMembership BEGIN SELECT RAISE(ABORT,'synthetic membership failure'); END")
        }
        do {
            _ = try await store.commitHistoricalChunk(Streams(hr:[HRSample(ts:100,bpm:60)]),scope:scope,
                family:"whoop5",trim:42,recoveryFrames:[[1,2]],clockRef:ClockRef(device:100,wall:100),
                postOffloadJobKinds:["cloudPush"])
            XCTFail("Failed membership authorized ACK")
        } catch {}
        try await assertAccounting(store,bytes:0,records:0)
        let jobs = try await store.owedJobs()
        let cursor = try await store.cursor("strap_trim:\(scope.key)")
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertNil(cursor)
        try await store.registryWriter.read { db in
            for table in ["hrSample","sensorQuarantine","rawBatch","quarantineArchiveMembership"] {
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM \(table)"),0)
            }
        }
    }

    func testIndexedPrunePagesKeepUnreceiptedMembersAndMaintainAccounting() async throws {
        let store = try await makeStore()
        try await store.persistSensorQuarantine((0..<12).map { [UInt8($0)] },scope:scope,family:"whoop5",trim:1)
        let rows = try await store.pendingSensorQuarantine(scope:scope)
        for (index,row) in rows.enumerated().dropFirst() {
            try await receipt(store,row:row,parent:index.isMultiple(of:2))
        }
        let beforeGrace = try await store.pruneSensorQuarantine(now:9,limit:2)
        XCTAssertEqual(beforeGrace,0)
        var total=0
        for _ in 0..<9 {
            let deleted = try await store.pruneSensorQuarantine(now:10,limit:2)
            XCTAssertLessThanOrEqual(deleted,2)
            total += deleted
        }
        XCTAssertEqual(total,11)
        let remaining = try await store.pendingSensorQuarantine(scope:scope)
        XCTAssertEqual(remaining.map(\.id),[rows[0].id])
        try await assertAccounting(store,bytes:1,records:1)
        let memberships = try await store.registryWriter.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM quarantineArchiveMembership") }
        XCTAssertEqual(memberships,1)
    }

    func testSourceMutationInvalidatesBothReceiptRoutesUntilMaintenanceRevalidatesExactBytes() async throws {
        let store = try await makeStore()
        try await store.persistSensorQuarantine([[1,2]],scope:scope,family:"whoop5",trim:1)
        let rows = try await store.pendingSensorQuarantine(scope:scope)
        let row = try XCTUnwrap(rows.first)
        try await receipt(store,row:row,parent:false)
        try await receipt(store,row:row,parent:true)
        try await store.registryWriter.write { db in
            try db.execute(sql:"UPDATE sensorQuarantine SET frame=? WHERE id=?",arguments:[Data([3,4,5]),row.id])
        }
        let changed = try await store.pruneSensorQuarantine(now:11)
        XCTAssertEqual(changed,0,"Old child or parent receipts cannot release modified bytes")
        try await assertAccounting(store,bytes:3,records:1)
        try await store.registryWriter.write { db in
            try db.execute(sql:"UPDATE sensorQuarantine SET frame=? WHERE id=?",arguments:[row.frame,row.id])
        }
        let restored = try await store.pruneSensorQuarantine(now:11)
        XCTAssertEqual(restored,1)
        try await assertAccounting(store,bytes:0,records:0)
    }

    func testPrunePlanUsesBoundedMembershipRangeAndExactLedgerReceiptIndexes() async throws {
        let store = try await makeStore()
        let details = try await store.registryWriter.read { db in
            try Row.fetchAll(db,sql:"EXPLAIN QUERY PLAN \(WhoopStore.quarantinePageDeleteSQL)",
                arguments:["","z",100,100]).map { $0["detail"] as String }
        }
        for alias in ["m","r","a"] {
            XCTAssertTrue(details.contains { $0.contains("SEARCH \(alias) USING") },details.joined(separator:"\n"))
            XCTAssertFalse(details.contains { $0.contains("SCAN \(alias)") },details.joined(separator:"\n"))
        }
    }

    func testAckAdmissionDoesNotAggregateTheRetainedQuarantine() async throws {
        let store = try await makeStore()
        let trace = QuarantineTrace()
        try await store.registryWriter.writeWithoutTransaction { db in
            db.trace { trace.append($0.description) }
        }
        _ = try await store.commitHistoricalChunk(Streams(),scope:scope,family:"whoop5",trim:42,
            recoveryFrames:[[1,2]],clockRef:ClockRef(device:100,wall:100),postOffloadJobKinds:[])
        try await store.registryWriter.writeWithoutTransaction { $0.trace(nil) }
        let statements = trace.statements.map { $0.uppercased() }
        XCTAssertFalse(statements.contains { $0.contains("SENSORQUARANTINE") && ($0.contains("SUM(") || $0.contains("COUNT(")) })
        XCTAssertTrue(statements.contains { $0.contains("SELECT RETAINEDBYTES,RETAINEDRECORDS FROM QUARANTINEMAINTENANCE WHERE SINGLETON=1") })
    }
}

private final class QuarantineTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var statements: [String] { lock.lock(); defer { lock.unlock() }; return values }
}
