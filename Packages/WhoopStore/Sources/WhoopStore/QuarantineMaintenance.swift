import Foundation
import GRDB

extension WhoopStore {
    nonisolated static func installQuarantineMaintenanceSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE quarantineMaintenance (
                singleton INTEGER PRIMARY KEY NOT NULL CHECK(singleton = 1),
                retainedBytes INTEGER NOT NULL CHECK(retainedBytes >= 0),
                retainedRecords INTEGER NOT NULL CHECK(retainedRecords >= 0),
                pruneAfterID TEXT NOT NULL DEFAULT '');
            INSERT INTO quarantineMaintenance(singleton,retainedBytes,retainedRecords)
                SELECT 1,COALESCE(SUM(length(frame)),0),COUNT(*) FROM sensorQuarantine;
            CREATE TABLE quarantineArchiveMembership (
                recordID TEXT PRIMARY KEY NOT NULL REFERENCES sensorQuarantine(id) ON DELETE CASCADE,
                scopeKey TEXT NOT NULL, deviceID TEXT NOT NULL,
                frameSHA256 TEXT NOT NULL, archiveBatchID TEXT NOT NULL,
                archiveSHA256 TEXT NOT NULL, assigned INTEGER NOT NULL CHECK(assigned IN (0,1)));
            CREATE TRIGGER quarantineAccountingInsert AFTER INSERT ON sensorQuarantine BEGIN
                UPDATE quarantineMaintenance SET retainedBytes=retainedBytes+length(NEW.frame),
                    retainedRecords=retainedRecords+1 WHERE singleton=1;
            END;
            CREATE TRIGGER quarantineAccountingDelete AFTER DELETE ON sensorQuarantine BEGIN
                UPDATE quarantineMaintenance SET retainedBytes=retainedBytes-length(OLD.frame),
                    retainedRecords=retainedRecords-1 WHERE singleton=1;
            END;
            CREATE TRIGGER quarantineAccountingUpdate AFTER UPDATE OF frame ON sensorQuarantine BEGIN
                UPDATE quarantineMaintenance SET retainedBytes=retainedBytes+length(NEW.frame)-length(OLD.frame)
                    WHERE singleton=1;
            END;
            CREATE TRIGGER quarantineMembershipInvalidate BEFORE UPDATE OF
                id,scopeKey,environment,accountId,deviceId,family,trim,frame ON sensorQuarantine BEGIN
                DELETE FROM quarantineArchiveMembership WHERE recordID=OLD.id;
            END;
            """)
        // Existing membership is validated lazily by bounded maintenance. Bootstrap does not hash
        // retained frames, create archive jobs, or decompress existing raw batches.
    }

    /// Cached only after exact identity/byte validation. Any source mutation invalidates the cache.
    nonisolated static func cacheQuarantineMembership(_ db: Database, row: Row) throws {
        let scope = DurableIngestScope(environment: row["environment"], accountID: row["accountId"], deviceID: row["deviceId"])
        guard (row["scopeKey"] as String) == scope.key,
              let trim = UInt32(exactly: row["trim"] as Int64) else { return }
        let id: String = row["id"]
        let identity = QuarantineArchiveIdentity(recordID: id, family: row["family"], trim: trim)
        guard QuarantineArchiveIdentity(batchID: identity.batchID) != nil else { return }
        let frame: Data = row["frame"]
        let frameDigest = DurableIngestScope.sha256(frame)
        // A migrated damaged row must remain retained, even when its old ledger has a receipt.
        guard let source = try Row.fetchOne(db, sql: """
            SELECT scopeKey,contentSHA256 FROM ingestRawResource
            WHERE lane='sensorQuarantine' AND deviceId=? AND resourceKey=?
            """, arguments: [scope.deviceID,id]),
              (source["scopeKey"] as String) == scope.key,
              (source["contentSHA256"] as String) == frameDigest else { return }
        try db.execute(sql: """
            INSERT INTO quarantineArchiveMembership(recordID,scopeKey,deviceID,frameSHA256,
                archiveBatchID,archiveSHA256,assigned) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(recordID) DO NOTHING
            """, arguments: [id,scope.key,scope.deviceID,frameDigest,identity.batchID,
                              DurableIngestScope.sha256(packFrames([[UInt8](frame)])),scope.isAssigned ? 1 : 0])
    }

    nonisolated static func quarantineAccounting(_ db: Database) throws -> (bytes: Int, records: Int) {
        guard let row = try Row.fetchOne(db, sql: "SELECT retainedBytes,retainedRecords FROM quarantineMaintenance WHERE singleton=1") else {
            throw DurableIngestError.identityConflict
        }
        return (row["retainedBytes"],row["retainedRecords"])
    }

    /// At most one indexed page per maintenance call. Receipt association and deletion share a tx.
    nonisolated static func pruneQuarantinePage(_ db: Database, now: Int, limit: Int) throws -> Int {
        let pageSize = min(max(limit,1),2_048)
        var after = try String.fetchOne(db, sql: "SELECT pruneAfterID FROM quarantineMaintenance WHERE singleton=1") ?? ""
        var ids = try String.fetchAll(db, sql: "SELECT id FROM sensorQuarantine WHERE id > ? ORDER BY id LIMIT ?",
                                     arguments: [after,pageSize])
        if ids.isEmpty && !after.isEmpty {
            after = ""
            ids = try String.fetchAll(db, sql: "SELECT id FROM sensorQuarantine WHERE id > ? ORDER BY id LIMIT ?",
                                     arguments: [after,pageSize])
        }
        guard let last = ids.last else {
            try db.execute(sql: "UPDATE quarantineMaintenance SET pruneAfterID='' WHERE singleton=1 AND pruneAfterID<>''")
            return 0
        }
        let missing = try Row.fetchAll(db, sql: """
            SELECT q.* FROM sensorQuarantine q
            WHERE q.id > ? AND q.id <= ? AND NOT EXISTS (
                SELECT 1 FROM quarantineArchiveMembership m WHERE m.recordID=q.id)
            ORDER BY q.id
            """, arguments: [after,last])
        for row in missing { try cacheQuarantineMembership(db, row: row) }
        try db.execute(sql: quarantinePageDeleteSQL, arguments: [after,last,now,now])
        let deleted = db.changesCount
        try db.execute(sql: "UPDATE quarantineMaintenance SET pruneAfterID=? WHERE singleton=1", arguments: [last])
        return deleted
    }

    nonisolated static let quarantinePageDeleteSQL = """
        DELETE FROM sensorQuarantine WHERE id IN (
            SELECT m.recordID FROM quarantineArchiveMembership m
            WHERE m.recordID > ? AND m.recordID <= ? AND m.assigned=1 AND (
                EXISTS(SELECT 1 FROM ingestRawResource r JOIN rawDurabilityReceipt a
                    ON a.lane=r.lane AND a.deviceId=r.deviceId AND a.resourceKey=r.resourceKey
                    AND a.scopeKey=r.scopeKey AND a.contentSHA256=r.contentSHA256
                    WHERE r.lane='sensorQuarantine' AND r.deviceId=m.deviceID
                    AND r.resourceKey=m.recordID AND r.scopeKey=m.scopeKey
                    AND r.contentSHA256=m.frameSHA256 AND a.retainUntil<=?)
                OR EXISTS(SELECT 1 FROM ingestRawResource r JOIN rawDurabilityReceipt a
                    ON a.lane=r.lane AND a.deviceId=r.deviceId AND a.resourceKey=r.resourceKey
                    AND a.scopeKey=r.scopeKey AND a.contentSHA256=r.contentSHA256
                    WHERE r.lane='rawBatch' AND r.deviceId=m.deviceID
                    AND r.resourceKey=m.archiveBatchID AND r.scopeKey=m.scopeKey
                    AND r.contentSHA256=m.archiveSHA256 AND a.retainUntil<=?)
            )
        )
        """
}
