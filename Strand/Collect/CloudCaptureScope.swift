import Foundation
import GRDB
import NoopPush
import WhoopStore

/// A process never changes the owner of open SQLite handles or file-backed recordings.
enum CloudCaptureScope {
    struct Identity: Equatable { let ownerId: String; let sourceId: String }
    final class Pin: @unchecked Sendable {
        private let lock = NSLock()
        private var identity: Identity?
        func resolve(_ candidate: Identity?) -> Identity? {
            lock.withLock {
                if identity == nil, let candidate { identity = candidate }
                return identity
            }
        }
    }
    private static let pin = Pin()
    private static var identity: Identity? {
        let credential = CloudEnrollment.currentCredential()
        return pin.resolve(credential.map { Identity(ownerId: $0.userId, sourceId: $0.sourceId) })
    }
    static var processSourceId: String { identity?.sourceId ?? "" }
    static var processOwnerId: String? { identity?.ownerId }

    static func isActive(for ownerId: String) -> Bool {
        processOwnerId == ownerId
            && CloudPushSettings.sourceId() == processSourceId
    }

    static var ready: Bool {
        guard let credential = CloudEnrollment.currentCredential() else { return false }
        return isActive(for: credential.userId)
    }

    static func component(_ original: String) -> String {
        component(original, ownerId: processOwnerId, sourceId: processSourceId)
    }

    static func component(_ original: String, ownerId: String?, sourceId: String) -> String {
        let owner = ownerId.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() } ?? "unenrolled"
        let source = UUID(uuidString: sourceId)?.uuidString.lowercased() ?? "unavailable"
        return "CloudAccounts/\(owner)/\(source)/\(original)"
    }

    enum ScopeError: Error { case ownerMismatch, unownedHistory, enrollmentRequired }

    /// Enrollment stores already contain an explicit owner/source witness. Upgrade only that
    /// exact witnessed store; ordinary legacy and unassigned history cannot acquire an owner here.
    static func bindRuntimeOwner(_ store: WhoopStore, scope: AccountScope) async throws {
        if let credential = CloudEnrollment.currentCredential(),
           CloudRuntimeIdentity.currentEnrollmentSnapshot()?.scope == scope {
            try await bindEnrolledOwner(store.registryWriter, scope: scope, ownerId: credential.userId,
                                        sourceId: credential.sourceId)
        }
        try await store.bindAccountOwner(projectURL: scope.projectURL, userID: scope.userID)
    }

    static func bindEnrolledOwner(_ writer: any DatabaseWriter, scope: AccountScope,
                                  ownerId: String, sourceId: String) async throws {
        guard scope.userID == ownerId, UUID(uuidString: sourceId) != nil else { throw ScopeError.ownerMismatch }
        try await writer.write { db in
            guard try db.tableExists("cloudCaptureIdentity"),
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cloudCaptureIdentity WHERE id=1 AND ownerId=? AND sourceId=?)",
                                    arguments: [ownerId, sourceId]) == true else { throw ScopeError.ownerMismatch }
            if let row = try Row.fetchOne(db, sql: "SELECT projectURL,userID FROM localAccountOwner WHERE singleton=1") {
                guard row["projectURL"] as String == scope.projectURL,
                      row["userID"] as String == scope.userID else { throw ScopeError.ownerMismatch }
            } else {
                try db.execute(sql: "INSERT INTO localAccountOwner(singleton,projectURL,userID) VALUES(1,?,?)",
                               arguments: [scope.projectURL, scope.userID])
            }
        }
    }

    /// Copy pairing metadata once. Health rows, read caches, upload cursors and sync debt stay
    /// in the original file; their historical owner cannot be established from a fleet token.
    static func prepareStore(_ writer: any DatabaseWriter, legacyPath: String?) async throws {
        let mayImportPairing = (try? CloudInstallationRetirementStore.system.hasRetiredInstallation()) == false
        try await prepareStore(writer, legacyPath: mayImportPairing ? legacyPath : nil,
                               ownerId: processOwnerId, sourceId: processSourceId)
    }

    static func prepareStore(_ writer: any DatabaseWriter, legacyPath: String?,
                             ownerId: String?, sourceId: String) async throws {
        let owner = ownerId ?? "unenrolled"
        let existing = try await writer.read { db -> String? in
            guard try db.tableExists("cloudCaptureIdentity") else { return nil }
            return try String.fetchOne(db, sql: "SELECT ownerId || '/' || sourceId FROM cloudCaptureIdentity WHERE id = 1")
        }
        if let existing {
            guard existing == "\(owner)/\(sourceId)" else { throw ScopeError.ownerMismatch }
            return
        }
        var pairing: [Row] = []
        if let legacyPath, FileManager.default.fileExists(atPath: legacyPath) {
            var configuration = Configuration()
            configuration.readonly = true
            let legacy = try DatabaseQueue(path: legacyPath, configuration: configuration)
            pairing = try await legacy.read { db in
                guard try db.tableExists("pairedDevice") else { return [] }
                // Import sources and historical day ownership are deliberately excluded.
                return try Row.fetchAll(db, sql: """
                    SELECT id, brand, model, nickname, sourceKind, capabilities,
                           status, addedAt, lastSeenAt, peripheralId
                    FROM pairedDevice
                    WHERE sourceKind IN ('liveBLE', 'historyBLE') AND peripheralId IS NOT NULL
                    """)
            }
        }
        let registry = pairing
        try await writer.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS cloudCaptureIdentity (
                    id INTEGER PRIMARY KEY CHECK (id = 1), ownerId TEXT NOT NULL, sourceId TEXT NOT NULL
                )
                """)
            if let saved = try String.fetchOne(db, sql: "SELECT ownerId || '/' || sourceId FROM cloudCaptureIdentity WHERE id = 1") {
                guard saved == "\(owner)/\(sourceId)" else { throw ScopeError.ownerMismatch }
                return
            }
            for table in ["hrSample", "rrInterval", "rawBatch", "ppgWaveformSample", "metricSeries", "dailyMetric"] {
                guard try db.tableExists(table) else { continue }
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) LIMIT 1)") == true {
                    throw ScopeError.unownedHistory
                }
            }
            if !registry.isEmpty {
                // Only replace the empty database's migration seed, never a recorded strap.
                try db.execute(sql: "DELETE FROM pairedDevice WHERE id = 'my-whoop' AND peripheralId IS NULL")
                for row in registry {
                    let id: String = row["id"]
                    let model: String = row["model"]
                    try db.execute(sql: "INSERT OR IGNORE INTO device (id, name) VALUES (?, ?)", arguments: [id, model])
                    let columns = ["id", "brand", "model", "nickname", "sourceKind", "capabilities", "status", "addedAt", "lastSeenAt", "peripheralId"]
                    let values = columns.map { row[$0] as DatabaseValue }
                    try db.execute(sql: "INSERT OR IGNORE INTO pairedDevice (\(columns.joined(separator: ","))) VALUES (?,?,?,?,?,?,?,?,?,?)",
                                   arguments: StatementArguments(values))
                }
            }
            try db.execute(sql: "INSERT INTO cloudCaptureIdentity (id, ownerId, sourceId) VALUES (1, ?, ?)", arguments: [owner, sourceId])
        }
    }

    static func verifyDatabase(_ writer: any DatabaseWriter, ownerId: String) async -> Bool {
        guard isActive(for: ownerId) else { return false }
        return (try? await writer.read { db in
            guard try db.tableExists("cloudCaptureIdentity") else { return false }
            return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cloudCaptureIdentity WHERE id = 1 AND ownerId = ? AND sourceId = ?)",
                                     arguments: [ownerId, processSourceId]) == true
        }) == true
    }
}
