import Foundation
import CryptoKit
import GRDB
import WhoopProtocol

/// Captured by an ingest instance. Nil ownership is retained, never inferred from the next login.
public struct DurableIngestScope: Codable, Equatable, Sendable {
    public let environment: String?
    public let accountID: String?
    public let deviceID: String

    public init(environment: String?, accountID: String?, deviceID: String) {
        self.environment = environment
        self.accountID = accountID
        self.deviceID = deviceID
    }

    public static func unassigned(deviceID: String) -> Self {
        Self(environment: nil, accountID: nil, deviceID: deviceID)
    }

    public func forDevice(_ deviceID: String) -> Self {
        Self(environment: environment, accountID: accountID, deviceID: deviceID)
    }

    public var isAssigned: Bool {
        guard let environment, let accountID else { return false }
        return !environment.isEmpty && !accountID.isEmpty && !deviceID.isEmpty
    }

    public var key: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self.sha256(try! encoder.encode(self))
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum DurableIngestError: Error, Equatable {
    case capacityExceeded
    case identityConflict
    case invalidReceipt
}

/// Only the authenticated transport may construct this after checksum/object/manifest verification.
/// HTTP acceptance alone is not a receipt. The resource digest is over the exact local source bytes.
public struct RawDurabilityReceipt: Codable, Equatable, Sendable {
    public let scope: DurableIngestScope
    public let lane: String
    public let resourceKey: String
    public let contentSHA256: String
    public let objectKey: String
    public let receiptID: String
    public let verifiedAt: Int
    public let retainUntil: Int

    public init(scope: DurableIngestScope, lane: String, resourceKey: String,
                contentSHA256: String, objectKey: String, receiptID: String,
                verifiedAt: Int, retainUntil: Int) {
        self.scope = scope; self.lane = lane; self.resourceKey = resourceKey
        self.contentSHA256 = contentSHA256; self.objectKey = objectKey; self.receiptID = receiptID
        self.verifiedAt = verifiedAt; self.retainUntil = retainUntil
    }

    public var isValid: Bool {
        scope.isAssigned && !lane.isEmpty && !resourceKey.isEmpty && !objectKey.isEmpty
            && !receiptID.isEmpty && verifiedAt > 0 && retainUntil >= verifiedAt
            && contentSHA256.count == 64
            && contentSHA256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct SensorQuarantineRecord: Sendable {
    public let id: String
    public let scope: DurableIngestScope
    public let family: String
    public let trim: UInt32
    public let frame: Data
    public let capturedAt: Int
}

public struct RawResourceIdentity: Sendable {
    public let scope: DurableIngestScope
    public let lane: String
    public let resourceKey: String
    public let contentSHA256: String
    public let byteCount: Int

    public init(scope: DurableIngestScope, lane: String, resourceKey: String,
                contentSHA256: String, byteCount: Int) {
        self.scope = scope; self.lane = lane; self.resourceKey = resourceKey
        self.contentSHA256 = contentSHA256; self.byteCount = byteCount
    }
}

extension WhoopStore {
    /// The database owner is fixed by bindAccountOwner; new rows never consult a global login.
    nonisolated static func captureScope(_ db: Database, deviceID: String) throws -> DurableIngestScope {
        guard let row = try Row.fetchOne(db, sql: "SELECT projectURL, userID FROM localAccountOwner WHERE singleton = 1") else {
            return .unassigned(deviceID: deviceID)
        }
        return DurableIngestScope(environment: row["projectURL"], accountID: row["userID"], deviceID: deviceID)
    }
    /// Receipt association reads the capture identity from this store, never the active login.
    public func rawResourceIdentity(scope: DurableIngestScope, lane: String,
                                    resourceKey: String) async throws -> RawResourceIdentity? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT contentSHA256, byteCount FROM ingestRawResource
                WHERE scopeKey = ? AND lane = ? AND deviceId = ? AND resourceKey = ?
                """, arguments: [scope.key, lane, scope.deviceID, resourceKey]) else { return nil }
            return RawResourceIdentity(scope: scope, lane: lane, resourceKey: resourceKey,
                contentSHA256: row["contentSHA256"], byteCount: row["byteCount"])
        }
    }
    // Identifiers are supplied only by the closed raw-lane writers, never by callers or payloads.
    nonisolated static func rawReceiptPredicate(table: String, keySQL: String) -> String {
        """
        EXISTS (SELECT 1 FROM ingestRawResource r JOIN rawDurabilityReceipt a
            ON a.lane = r.lane AND a.deviceId = r.deviceId AND a.resourceKey = r.resourceKey
            AND a.scopeKey = r.scopeKey AND a.contentSHA256 = r.contentSHA256
            WHERE r.lane = '\(table)' AND r.deviceId = \(table).deviceId
              AND r.resourceKey = \(keySQL) AND r.environment IS NOT NULL
              AND r.accountId IS NOT NULL AND a.retainUntil <= ?)
        """
    }

    /// Root registers this in an additive migration; runtime writers never create/repair schema.
    public nonisolated static func createDurableIngestSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE ingestRawResource (
                lane TEXT NOT NULL, deviceId TEXT NOT NULL, resourceKey TEXT NOT NULL,
                scopeKey TEXT NOT NULL, environment TEXT, accountId TEXT,
                contentSHA256 TEXT NOT NULL, byteCount INTEGER NOT NULL CHECK(byteCount >= 0),
                PRIMARY KEY(lane, deviceId, resourceKey));
            CREATE TABLE sensorQuarantine (
                id TEXT PRIMARY KEY NOT NULL, scopeKey TEXT NOT NULL,
                environment TEXT, accountId TEXT, deviceId TEXT NOT NULL,
                family TEXT NOT NULL, trim INTEGER NOT NULL, frame BLOB NOT NULL,
                capturedAt INTEGER NOT NULL);
            CREATE INDEX sensorQuarantine_scope ON sensorQuarantine(scopeKey, capturedAt, id);
            CREATE TABLE rawDurabilityReceipt (
                lane TEXT NOT NULL, deviceId TEXT NOT NULL, resourceKey TEXT NOT NULL,
                scopeKey TEXT NOT NULL, contentSHA256 TEXT NOT NULL,
                objectKey TEXT NOT NULL, receiptId TEXT NOT NULL,
                verifiedAt INTEGER NOT NULL, retainUntil INTEGER NOT NULL,
                PRIMARY KEY(lane, deviceId, resourceKey, scopeKey, contentSHA256));
            """)
    }

    nonisolated static func registerRawResource(_ db: Database, scope: DurableIngestScope,
                                               lane: String, key: String, bytes: Data) throws {
        let digest = DurableIngestScope.sha256(bytes)
        if let row = try Row.fetchOne(db, sql: """
            SELECT scopeKey, contentSHA256 FROM ingestRawResource
            WHERE lane = ? AND deviceId = ? AND resourceKey = ?
            """, arguments: [lane, scope.deviceID, key]) {
            guard (row["scopeKey"] as String) == scope.key,
                  (row["contentSHA256"] as String) == digest else { throw DurableIngestError.identityConflict }
            return
        }
        try db.execute(sql: """
            INSERT INTO ingestRawResource
                (lane, deviceId, resourceKey, scopeKey, environment, accountId, contentSHA256, byteCount)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [lane, scope.deviceID, key, scope.key, scope.environment,
                              scope.accountID, digest, bytes.count])
    }

    nonisolated static func markRawUploadOwed(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO syncJob(kind, owedAt, token, attempts, lastNote)
            VALUES ('cloudPush', ?, ?, 0, 'durable raw ingest')
            ON CONFLICT(kind) DO UPDATE SET owedAt = excluded.owedAt, token = excluded.token,
                attempts = 0, lastNote = excluded.lastNote
            """, arguments: [Int(Date().timeIntervalSince1970), UUID().uuidString])
    }

    /// Must be called inside the same transaction as deletion. Legacy/unassigned sources fail closed.
    nonisolated static func rawResourceCanPrune(_ db: Database, lane: String, deviceID: String,
                                              key: String, now: Int) throws -> Bool {
        guard try db.tableExists("rawDurabilityReceipt"), try db.tableExists("ingestRawResource") else { return false }
        return try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM ingestRawResource r JOIN rawDurabilityReceipt a
                ON a.lane = r.lane AND a.deviceId = r.deviceId AND a.resourceKey = r.resourceKey
                AND a.scopeKey = r.scopeKey AND a.contentSHA256 = r.contentSHA256
                WHERE r.lane = ? AND r.deviceId = ? AND r.resourceKey = ?
                  AND r.environment IS NOT NULL AND r.accountId IS NOT NULL AND a.retainUntil <= ?)
            """, arguments: [lane, deviceID, key, now]) ?? false
    }

    public func recordRawDurabilityReceipt(_ receipt: RawDurabilityReceipt) async throws {
        guard receipt.isValid else { throw DurableIngestError.invalidReceipt }
        try syncWrite { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT scopeKey, contentSHA256 FROM ingestRawResource
                WHERE lane = ? AND deviceId = ? AND resourceKey = ?
                """, arguments: [receipt.lane, receipt.scope.deviceID, receipt.resourceKey]),
                  (row["scopeKey"] as String) == receipt.scope.key,
                  (row["contentSHA256"] as String) == receipt.contentSHA256 else {
                throw DurableIngestError.invalidReceipt
            }
            try db.execute(sql: """
                INSERT INTO rawDurabilityReceipt
                    (lane, deviceId, resourceKey, scopeKey, contentSHA256, objectKey, receiptId, verifiedAt, retainUntil)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(lane, deviceId, resourceKey, scopeKey, contentSHA256) DO UPDATE SET
                    retainUntil = MAX(retainUntil, excluded.retainUntil)
                """, arguments: [receipt.lane, receipt.scope.deviceID, receipt.resourceKey, receipt.scope.key,
                                  receipt.contentSHA256, receipt.objectKey, receipt.receiptID,
                                  receipt.verifiedAt, receipt.retainUntil])
        }
    }

    @discardableResult
    public func persistSensorQuarantine(_ frames: [[UInt8]], scope: DurableIngestScope,
                                        family: String, trim: UInt32,
                                        clockRef: ClockRef? = nil,
                                        preserveOccurrences: Bool = false,
                                        maxBytes: Int = 64 * 1_048_576,
                                        maxRecords: Int = 100_000) async throws -> Int {
        guard !frames.isEmpty else { return 0 }
        guard frames.count <= maxRecords, maxBytes >= 0 else { throw DurableIngestError.capacityExceeded }
        return try syncWrite { db in
            try Self.persistSensorQuarantine(db, frames: frames, scope: scope, family: family,
                trim: trim, clockRef: clockRef, preserveOccurrences: preserveOccurrences,
                maxBytes: maxBytes, maxRecords: maxRecords, allowPruning: true)
        }
    }

    /// Used by the ordinary historical transaction; never opens a nested transaction.
    @discardableResult
    nonisolated static func persistSensorQuarantine(_ db: Database, frames: [[UInt8]],
        scope: DurableIngestScope, family: String, trim: UInt32, clockRef: ClockRef?,
        preserveOccurrences: Bool, maxBytes: Int, maxRecords: Int, allowPruning: Bool) throws -> Int {
        guard !frames.isEmpty else { return 0 }
        guard frames.count <= maxRecords, maxBytes >= 0 else { throw DurableIngestError.capacityExceeded }
        guard try Self.captureScope(db, deviceID: scope.deviceID) == scope else {
            throw DurableIngestError.identityConflict
        }
        var accounting = try Self.quarantineAccounting(db)
        var retained = accounting.bytes
        var count = accounting.records
        let offeredBytes = frames.reduce(0) { $0 + $1.count }
        if allowPruning && (offeredBytes > maxBytes - retained || frames.count > maxRecords - count) {
            // Recover capacity only from exact verified receipts whose grace elapsed. Never
            // evict unsent evidence to make the current chunk fit; admission remains atomic.
            _ = try Self.pruneSensorQuarantine(db, now: Int(Date().timeIntervalSince1970))
            accounting = try Self.quarantineAccounting(db)
            retained = accounting.bytes
            count = accounting.records
        }
        var inserted = 0
        let chunkDigest = preserveOccurrences ? DurableIngestScope.sha256(Self.packFrames(frames)) : ""
        for (ordinal, frame) in frames.enumerated() {
            let bytes = Data(frame)
            let digest = DurableIngestScope.sha256(bytes)
            let occurrence = preserveOccurrences ? "\n\(trim)\n\(chunkDigest)\n\(ordinal)" : ""
            let memberDigest = DurableIngestScope.sha256(Data("\(scope.key)\n\(family)\n\(digest)\(occurrence)".utf8))
            let id = preserveOccurrences ? "h1-\(memberDigest)-\(chunkDigest)-\(ordinal)" : memberDigest
            if let existing = try Row.fetchOne(db, sql: "SELECT * FROM sensorQuarantine WHERE id = ?", arguments: [id]) {
                try Self.enqueueQuarantineArchive(db, row: existing, clockRef: clockRef)
                continue
            }
            guard bytes.count <= maxBytes - retained, count < maxRecords else { throw DurableIngestError.capacityExceeded }
            try db.execute(sql: """
                INSERT INTO sensorQuarantine
                    (id, scopeKey, environment, accountId, deviceId, family, trim, frame, capturedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, scope.key, scope.environment, scope.accountID, scope.deviceID,
                                  family, Int64(trim), bytes, Int(Date().timeIntervalSince1970)])
            try Self.registerRawResource(db, scope: scope, lane: "sensorQuarantine", key: id, bytes: bytes)
            let row = try Row.fetchOne(db, sql: "SELECT * FROM sensorQuarantine WHERE id = ?", arguments: [id])!
            try Self.enqueueQuarantineArchive(db, row: row, clockRef: clockRef)
            retained += bytes.count; count += 1; inserted += 1
        }
        if inserted > 0 { try Self.markRawUploadOwed(db) }
        return inserted
    }

    public func pendingSensorQuarantine(scope: DurableIngestScope, afterID: String? = nil,
                                        limit: Int = 100) async throws -> [SensorQuarantineRecord] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM sensorQuarantine WHERE scopeKey = ? AND id > ? ORDER BY id LIMIT ?
                """, arguments: [scope.key, afterID ?? "", min(max(1, limit), 500)]).map { row in
                    guard let trim = UInt32(exactly: row["trim"] as Int64) else { throw DurableIngestError.identityConflict }
                    return SensorQuarantineRecord(id: row["id"], scope: scope, family: row["family"],
                                                  trim: trim, frame: row["frame"], capturedAt: row["capturedAt"])
                }
        }
    }

    @discardableResult
    public func pruneSensorQuarantine(now: Int, limit: Int = 512) async throws -> Int {
        try syncWrite { try Self.pruneQuarantinePage($0, now: now, limit: limit) }
    }

    nonisolated static func pruneSensorQuarantine(_ db: Database, now: Int) throws -> Int {
        try Self.pruneQuarantinePage(db, now: now, limit: 512)
    }
}
