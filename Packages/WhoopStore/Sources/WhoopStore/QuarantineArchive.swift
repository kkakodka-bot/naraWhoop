import Foundation
import GRDB
import WhoopProtocol

/// Provenance carried by the existing rawBatch codec, not a synthetic BLE frame. Its one
/// member is the exact captured frame. The enclosing object carries device/account/source.
public struct QuarantineArchiveIdentity: Equatable, Sendable {
    public let recordID: String
    public let family: String
    public let trim: UInt32

    /// New history membership retains order/multiplicity, while v49 digest-only ids remain readable.
    public var chunkSHA256: String? {
        let parts = recordID.split(separator: "-")
        return parts.count == 4 && parts[0] == "h1" ? String(parts[2]) : nil
    }
    public var ordinal: Int? {
        let parts = recordID.split(separator: "-")
        return parts.count == 4 && parts[0] == "h1" ? Int(parts[3]) : nil
    }

    private static func validRecordID(_ id: Substring) -> Bool {
        func digest(_ part: Substring) -> Bool {
            part.count == 64 && part.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        if digest(id) { return true }
        let parts = id.split(separator: "-")
        guard parts.count == 4, parts[0] == "h1", digest(parts[1]), digest(parts[2]),
              let ordinal = Int(parts[3]), ordinal >= 0, String(ordinal) == parts[3] else { return false }
        return true
    }

    public init(recordID: String, family: String, trim: UInt32) {
        self.recordID = recordID; self.family = family; self.trim = trim
    }

    public var batchID: String {
        "sq1.\(Data(family.utf8).base64EncodedString()).\(trim).\(recordID)"
    }

    public init?(batchID: String) {
        let parts = batchID.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "sq1", let trim = UInt32(parts[2]),
              let bytes = Data(base64Encoded: String(parts[1])),
              let family = String(data: bytes, encoding: .utf8), !family.isEmpty,
              Self.validRecordID(parts[3]) else { return nil }
        self.init(recordID: String(parts[3]), family: family, trim: trim)
        guard self.batchID == batchID else { return nil }
    }
}

extension WhoopStore {
    /// Transactional with quarantine admission. No runtime schema changes. Legacy records are
    /// promoted using their stored provenance, never the active login. Unknown legacy clocks use
    /// an identity reference; capturedAt is explicitly host time, not a guessed sensor timestamp.
    @discardableResult
    nonisolated static func enqueueQuarantineArchive(_ db: Database, row: Row,
                                                     clockRef: ClockRef? = nil) throws -> Bool {
        let scope = DurableIngestScope(environment: row["environment"], accountID: row["accountId"], deviceID: row["deviceId"])
        guard (row["scopeKey"] as String) == scope.key,
              try captureScope(db, deviceID: scope.deviceID) == scope else { throw DurableIngestError.identityConflict }
        guard let trim = UInt32(exactly: row["trim"] as Int64) else { throw DurableIngestError.identityConflict }
        let identity = QuarantineArchiveIdentity(recordID: row["id"], family: row["family"], trim: trim)
        guard QuarantineArchiveIdentity(batchID: identity.batchID) != nil else { throw DurableIngestError.identityConflict }
        let frame: Data = row["frame"]
        let packed = packFrames([[UInt8](frame)])
        // A ledger surviving receipt-gated pruning is an already archived member, not new work.
        if let resource = try Row.fetchOne(db, sql: "SELECT scopeKey, contentSHA256 FROM ingestRawResource WHERE lane = 'rawBatch' AND deviceId = ? AND resourceKey = ?",
                                          arguments: [scope.deviceID, identity.batchID]) {
            guard (resource["scopeKey"] as String) == scope.key,
                  (resource["contentSHA256"] as String) == DurableIngestScope.sha256(packed) else { throw DurableIngestError.identityConflict }
            if let source = try Row.fetchOne(db, sql: "SELECT deviceId, framesBlob FROM rawBatch WHERE batchId = ?", arguments: [identity.batchID]) {
                guard (source["deviceId"] as String) == scope.deviceID,
                      try zlibDecompressWithLength(source["framesBlob"]) == packed else { throw DurableIngestError.identityConflict }
            } else {
                // Only receipt-gated deletion can explain a missing source row. A dangling
                // ledger alone is not durable archival proof and must not silently unlock ACK.
                guard try rawResourceCanPrune(db, lane: "rawBatch", deviceID: scope.deviceID,
                                              key: identity.batchID, now: Int.max) else { throw DurableIngestError.identityConflict }
            }
            return false
        }
        let captured: Int = row["capturedAt"]
        guard captured > 0, captured < Int.max else { throw DurableIngestError.identityConflict }
        let ref = clockRef ?? ClockRef(device: captured, wall: captured)
        let blob = try zlibCompressWithLength(packed)
        try db.execute(sql: """
            INSERT INTO rawBatch(batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, NULL)
            """, arguments: [identity.batchID, scope.deviceID, captured, ref.device, ref.wall,
                              captured, captured + 1, frame.count, blob])
        try registerRawResource(db, scope: scope, lane: "rawBatch", key: identity.batchID, bytes: packed)
        try markRawUploadOwed(db)
        return true
    }

    /// Bounded upgrade of previously local-only v49 rows. A non-nil result is the next page's
    /// afterID. No network access or owner reassignment occurs here.
    public func enqueuePendingQuarantineArchives(afterID: String? = nil, limit: Int = 256) async throws -> String? {
        try syncWrite { db in
            let pageSize = min(max(1, limit), 500)
            let ids = try String.fetchAll(db, sql: "SELECT id FROM sensorQuarantine WHERE id > ? ORDER BY id LIMIT ?",
                                         arguments: [afterID ?? "", pageSize])
            for id in ids {
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sensorQuarantine WHERE id = ?", arguments: [id]) else { continue }
                try Self.enqueueQuarantineArchive(db, row: row)
            }
            return ids.count == pageSize ? ids.last : nil
        }
    }

    /// A receipt for another row, another owner, or another byte sequence never releases this
    /// member. Works even after the parent's rawBatch row was receipt-pruned: its immutable
    /// source ledger and verified receipt remain. No fabricated child receipt is necessary.
    nonisolated static func quarantineArchiveCanPrune(_ db: Database, row: Row, now: Int) throws -> Bool {
        let scope = DurableIngestScope(environment: row["environment"], accountID: row["accountId"], deviceID: row["deviceId"])
        guard scope.isAssigned, (row["scopeKey"] as String) == scope.key,
              let trim = UInt32(exactly: row["trim"] as Int64) else { return false }
        let identity = QuarantineArchiveIdentity(recordID: row["id"], family: row["family"], trim: trim)
        let frame: Data = row["frame"]
        let digest = DurableIngestScope.sha256(packFrames([[UInt8](frame)]))
        return try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM ingestRawResource r JOIN rawDurabilityReceipt a
              ON a.lane = r.lane AND a.deviceId = r.deviceId AND a.resourceKey = r.resourceKey
                AND a.scopeKey = r.scopeKey AND a.contentSHA256 = r.contentSHA256
              WHERE r.lane = 'rawBatch' AND r.deviceId = ? AND r.resourceKey = ?
                AND r.scopeKey = ? AND r.contentSHA256 = ? AND a.retainUntil <= ?)
            """, arguments: [scope.deviceID, identity.batchID, scope.key, digest, now]) ?? false
    }
}
