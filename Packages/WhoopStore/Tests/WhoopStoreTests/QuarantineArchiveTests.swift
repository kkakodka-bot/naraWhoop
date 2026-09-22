import XCTest
import GRDB
@testable import WhoopStore

final class QuarantineArchiveTests: XCTestCase {
    private let scope = DurableIngestScope(environment: "https://fixture.invalid", accountID: "11111111-1111-4111-8111-111111111111", deviceID: "strap")

    private func store() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.bindAccountOwner(projectURL: scope.environment!, userID: scope.accountID!)
        try await store.upsertDevice(id: scope.deviceID, mac: nil, name: nil)
        return store
    }

    private func batchID(_ row: SensorQuarantineRecord) -> String {
        QuarantineArchiveIdentity(recordID: row.id, family: row.family, trim: row.trim).batchID
    }

    private func receipt(_ resource: RawResourceIdentity, grace: Int = 20) -> RawDurabilityReceipt {
        RawDurabilityReceipt(scope: resource.scope, lane: resource.lane, resourceKey: resource.resourceKey,
            contentSHA256: resource.contentSHA256, objectKey: "verified/object", receiptID: "receipt-a",
            verifiedAt: 10, retainUntil: grace)
    }

    func testExactBytesProvenanceAndRepeatedMembershipSurviveReplay() async throws {
        let s = try await store()
        let frames: [[UInt8]] = [[0, 255, 0, 4], [0, 255, 0, 4]]
        let inserted = try await s.persistSensorQuarantine(frames, scope: scope, family: "whoop5", trim: 42,
            clockRef: ClockRef(device: 100, wall: 200), preserveOccurrences: true)
        let replay = try await s.persistSensorQuarantine(frames, scope: scope, family: "whoop5", trim: 42,
            clockRef: ClockRef(device: 300, wall: 400), preserveOccurrences: true)
        XCTAssertEqual(inserted, 2)
        XCTAssertEqual(replay, 0)
        let rows = try await s.pendingSensorQuarantine(scope: scope)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(rows[0].id, rows[1].id)
        for row in rows {
            let id = batchID(row)
            let descriptor = try XCTUnwrap(QuarantineArchiveIdentity(batchID: id))
            XCTAssertEqual(descriptor.recordID, row.id)
            XCTAssertEqual(descriptor.family, "whoop5")
            XCTAssertEqual(descriptor.trim, 42)
            XCTAssertNotNil(descriptor.chunkSHA256)
            XCTAssertNotNil(descriptor.ordinal)
            let raw = try await s.rawFrames(batchId: id)
            XCTAssertEqual(raw, [frames[0]])
            let meta = try await s.registryWriter.read { db in
                try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM rawBatch WHERE batchId = ?", arguments: [id]))
            }
            XCTAssertEqual(meta["deviceClockRef"] as Int, 100)
            XCTAssertEqual(meta["wallClockRef"] as Int, 200)
            XCTAssertEqual((meta["endTs"] as Int) - (meta["startTs"] as Int), 1)
        }
        let newTrim = try await s.persistSensorQuarantine(frames, scope: scope, family: "whoop5", trim: 43, preserveOccurrences: true)
        XCTAssertEqual(newTrim, 2)
    }

    func testOutboxFailureRollsBackQuarantineLedgerAndDebt() async throws {
        let s = try await store()
        try await s.registryWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_archive BEFORE INSERT ON rawBatch BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        }
        do {
            try await s.persistSensorQuarantine([[1]], scope: scope, family: "whoop5", trim: 1)
            XCTFail("outbox failure must hold ACK")
        } catch { }
        let rows = try await s.pendingSensorQuarantine(scope: scope)
        let jobs = try await s.owedJobs()
        let count = try await s.registryWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ingestRawResource") }
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertEqual(count, 0)
    }

    func testWrongCapturedOwnerCannotAdmitQuarantineOrCreateOutbox() async throws {
        let s = try await store()
        let wrong = DurableIngestScope(environment: scope.environment,
            accountID: "22222222-2222-4222-8222-222222222222", deviceID: scope.deviceID)
        do {
            try await s.persistSensorQuarantine([[1]], scope: wrong, family: "whoop5", trim: 1)
            XCTFail("must retain the store's immutable owner")
        } catch { XCTAssertEqual(error as? DurableIngestError, .identityConflict) }
        let count = try await s.registryWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rawBatch") }
        XCTAssertEqual(count, 0)
    }

    func testDanglingOutboxLedgerCannotMasqueradeAsDurableReplay() async throws {
        let s = try await store()
        try await s.persistSensorQuarantine([[1]], scope: scope, family: "whoop5", trim: 1)
        try await s.registryWriter.write { try $0.execute(sql: "DELETE FROM rawBatch") }
        do {
            try await s.persistSensorQuarantine([[1]], scope: scope, family: "whoop5", trim: 1)
            XCTFail("a ledger without bytes or a verified receipt cannot satisfy archive admission")
        } catch { XCTAssertEqual(error as? DurableIngestError, .identityConflict) }
    }

    func testOnlyExactParentReceiptReleasesMemberAfterGraceEvenIfParentPruned() async throws {
        let s = try await store()
        try await s.persistSensorQuarantine([[1], [2]], scope: scope, family: "whoop5", trim: 2, preserveOccurrences: true)
        let rows = try await s.pendingSensorQuarantine(scope: scope)
        let id = batchID(rows[0])
        let identity = try await s.rawResourceIdentity(scope: scope, lane: "rawBatch", resourceKey: id)
        let resource = try XCTUnwrap(identity)
        let noReceipt = try await s.pruneSensorQuarantine(now: 100)
        XCTAssertEqual(noReceipt, 0)
        try await s.recordRawDurabilityReceipt(receipt(resource))
        let early = try await s.pruneSensorQuarantine(now: 19)
        XCTAssertEqual(early, 0)
        let removedParent = try await s.pruneRaw(now: Int(Date().timeIntervalSince1970) + 100,
            keepWindowSeconds: 0, maxUnsyncedBytes: 0)
        XCTAssertEqual(removedParent, 1)
        let removedMember = try await s.pruneSensorQuarantine(now: 20)
        XCTAssertEqual(removedMember, 1)
        let remaining = try await s.pendingSensorQuarantine(scope: scope)
        XCTAssertEqual(remaining.map(\.id), [rows[1].id])
    }

    func testReceiptCannotReleaseChangedBytesOrProvenance() async throws {
        let s = try await store()
        try await s.persistSensorQuarantine([[9]], scope: scope, family: "whoop5", trim: 3)
        let rows = try await s.pendingSensorQuarantine(scope: scope)
        let id = batchID(rows[0])
        let identity = try await s.rawResourceIdentity(scope: scope, lane: "rawBatch", resourceKey: id)
        try await s.recordRawDurabilityReceipt(receipt(XCTUnwrap(identity)))
        try await s.registryWriter.write { db in
            try db.execute(sql: "UPDATE sensorQuarantine SET frame = ?", arguments: [Data([8])])
        }
        let changedBytes = try await s.pruneSensorQuarantine(now: 100)
        XCTAssertEqual(changedBytes, 0)
        try await s.registryWriter.write { db in
            try db.execute(sql: "UPDATE sensorQuarantine SET frame = ?, trim = 4", arguments: [Data([9])])
        }
        let changedTrim = try await s.pruneSensorQuarantine(now: 100)
        XCTAssertEqual(changedTrim, 0)
    }

    func testCapacityReclaimsOnlyReceiptedMembersBeforeAdmittingNextChunk() async throws {
        let s = try await store()
        try await s.persistSensorQuarantine([[1]], scope: scope, family: "whoop5", trim: 1, maxRecords: 1)
        let rows = try await s.pendingSensorQuarantine(scope: scope)
        let identity = try await s.rawResourceIdentity(scope: scope, lane: "rawBatch", resourceKey: batchID(rows[0]))
        try await s.recordRawDurabilityReceipt(receipt(XCTUnwrap(identity)))
        let inserted = try await s.persistSensorQuarantine([[2]], scope: scope, family: "whoop5", trim: 2, maxRecords: 1)
        XCTAssertEqual(inserted, 1)
        let remaining = try await s.pendingSensorQuarantine(scope: scope)
        XCTAssertEqual(remaining.map(\.frame), [Data([2])])
        do {
            try await s.persistSensorQuarantine([[3]], scope: scope, family: "whoop5", trim: 3, maxRecords: 1)
            XCTFail("unsent evidence must stay")
        } catch { XCTAssertEqual(error as? DurableIngestError, .capacityExceeded) }
        let afterFailure = try await s.pendingSensorQuarantine(scope: scope)
        XCTAssertEqual(afterFailure.map(\.frame), [Data([2])])
    }

    func testBoundedLegacyPromotionUsesStoredOwnerAndIsIdempotent() async throws {
        let s = try await store()
        try await s.persistSensorQuarantine([[1], [2]], scope: scope, family: "whoop5", trim: 5)
        // A v49 local-only fixture: keep original quarantine ownership/provenance, remove only
        // the archive records introduced by this implementation.
        try await s.registryWriter.write { db in
            try db.execute(sql: "DELETE FROM rawBatch")
            try db.execute(sql: "DELETE FROM ingestRawResource WHERE lane = 'rawBatch'")
        }
        let firstPage = try await s.enqueuePendingQuarantineArchives(limit: 1)
        XCTAssertNotNil(firstPage)
        let count = try await s.registryWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rawBatch") }
        XCTAssertEqual(count, 1)
        _ = try await s.enqueuePendingQuarantineArchives(afterID: firstPage, limit: 1)
        _ = try await s.enqueuePendingQuarantineArchives()
        let finalCount = try await s.registryWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rawBatch") }
        XCTAssertEqual(finalCount, 2)
    }

    func testInvalidStoredTrimFailsReadArchiveAndReplayWithoutPruningEvidence() async throws {
        for invalid in [Int64(-1), Int64(UInt32.max) + 1, Int64.min, Int64.max] {
            let s = try await store()
            let frames: [[UInt8]] = [[0, 255, 4]]
            try await s.persistSensorQuarantine(frames, scope: scope, family: "whoop5", trim: 7)
            let records = try await s.pendingSensorQuarantine(scope: scope)
            let record = try XCTUnwrap(records.first)
            let child = try await s.rawResourceIdentity(scope: scope, lane: "sensorQuarantine", resourceKey: record.id)
            try await s.recordRawDurabilityReceipt(receipt(XCTUnwrap(child)))
            try await s.registryWriter.write { db in
                try db.execute(sql: "UPDATE sensorQuarantine SET trim = ?", arguments: [invalid])
                try db.execute(sql: "DELETE FROM rawBatch")
                try db.execute(sql: "DELETE FROM ingestRawResource WHERE lane = 'rawBatch'")
            }
            let before = try await s.registryWriter.read { db in
                try Row.fetchAll(db, sql: "SELECT rowid,* FROM sensorQuarantine")
            }
            do {
                _ = try await s.pendingSensorQuarantine(scope: scope)
                XCTFail("bad stored trim must not trap or truncate on read")
            } catch { XCTAssertEqual(error as? DurableIngestError, .identityConflict) }
            do {
                _ = try await s.enqueuePendingQuarantineArchives()
                XCTFail("legacy archive promotion must refuse invalid provenance")
            } catch { XCTAssertEqual(error as? DurableIngestError, .identityConflict) }
            do {
                _ = try await s.persistSensorQuarantine(frames, scope: scope, family: "whoop5", trim: 7)
                XCTFail("a replay must not repair or silently bypass bad stored trim")
            } catch { XCTAssertEqual(error as? DurableIngestError, .identityConflict) }
            let removed = try await s.pruneSensorQuarantine(now: 100)
            XCTAssertEqual(removed, 0, "even a child receipt cannot release invalid stored provenance")
            try await s.registryWriter.read { db in
                let after = try Row.fetchAll(db, sql: "SELECT rowid,* FROM sensorQuarantine")
                XCTAssertEqual(after, before)
                XCTAssertEqual(after.first?["trim"] as Int64?, invalid)
                XCTAssertEqual(after.first?["frame"] as Data?, Data(frames[0]))
                XCTAssertFalse(try WhoopStore.quarantineArchiveCanPrune(db, row: XCTUnwrap(after.first), now: 100))
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawBatch"), 0)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawDurabilityReceipt"), 1)
            }
        }
    }
}
