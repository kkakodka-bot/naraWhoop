import Foundation
import CryptoKit
import GRDB
import NoopPush
import WhoopStore

struct ScoringInputChange: Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case profile, config, sleepEdit = "sleep_edit", context, period, importedDaily = "imported_daily", manualWorkout = "manual_workout" }
    let device: String
    let kind: Kind
    let entity: String
    let effectiveDay: String
    let payload: Data
    let deleted: Bool

    init(device: String, kind: Kind, entity: String, effectiveDay: String, payload: Data, deleted: Bool = false) throws {
        guard let uuid = UUID(uuidString: device), !entity.isEmpty, entity.utf8.count <= 128,
              ServerScoreDate.isDay(effectiveDay), effectiveDay >= "1900-01-01", effectiveDay <= "2200-12-31",
              payload.count <= 65536,
              let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw ScoringInputJournal.Failure.invalidInput
        }
        self.device = uuid.uuidString.lowercased(); self.kind = kind; self.entity = entity
        self.effectiveDay = effectiveDay; self.deleted = deleted
        self.payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    var digest: String {
        var data = Data("\(effectiveDay):\(deleted):".utf8); data.append(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The v3 RPC receipt is useful only for the exact durable mutation that was sent.
struct ScoringInputReceipt: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let userId: UUID
    let sourceDeviceId: UUID
    let kind: ScoringInputChange.Kind
    let entity: String
    let revision: Int64
    let clientId: UUID
    let clientMutationId: UUID
    let clientRevision: Int64
    let effectiveDay: String
    let deleted: Bool
    let invalidatedFrom: String

    func matches(_ pending: ScoringInputJournal.Pending) -> Bool {
        schemaVersion == 1 && userId == UUID(uuidString: pending.scope.userID) &&
        sourceDeviceId == UUID(uuidString: pending.change.device) &&
        kind == pending.change.kind && entity == pending.change.entity &&
        revision > pending.expectedRevision && clientId == pending.clientID &&
        clientMutationId == UUID(uuidString: pending.id) && clientRevision == pending.clientRevision &&
        effectiveDay == pending.change.effectiveDay && deleted == pending.change.deleted &&
        ServerScoreDate.isDay(invalidatedFrom) && invalidatedFrom <= effectiveDay
    }
}

struct ScoringInputHead: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let userId: UUID
    let sourceDeviceId: UUID
    let kind: ScoringInputChange.Kind
    let entity: String
    let headRevision: Int64

    func matches(scope: AccountScope, change: ScoringInputChange) -> Bool {
        schemaVersion == 1 && userId == UUID(uuidString: scope.userID) &&
        sourceDeviceId == UUID(uuidString: change.device) && kind == change.kind &&
        entity == change.entity && headRevision >= 0
    }
}

private final class ScoringInputCommitFence: TransactionObserver {
    let fence: StoreWriteFence
    let current: @Sendable () -> Bool
    init(_ fence: StoreWriteFence, current: @escaping @Sendable () -> Bool) { self.fence = fence; self.current = current }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseWillCommit() throws {
        do { try fence.check() } catch { throw ScoringInputJournal.Failure.retired }
        guard current() else { throw ScoringInputJournal.Failure.retired }
    }
    func databaseDidCommit(_ db: Database) {}
    func databaseDidRollback(_ db: Database) {}
}

private final class ScoringPreferenceCommitPermit: TransactionObserver {
    let allowing: @Sendable () -> Bool
    init(allowing: @escaping @Sendable () -> Bool) { self.allowing = allowing }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseWillCommit() throws {
        try Task.checkCancellation()
        guard allowing() else { throw ScoringInputJournal.Failure.held }
        try Task.checkCancellation()
    }
    func databaseDidCommit(_ db: Database) {}
    func databaseDidRollback(_ db: Database) {}
}

/// A small, independent account journal; it is not part of the physiological GRDB/Room schema.
/// The expected server revision commits BEFORE the request, so a lost response repeats exact input.
actor ScoringInputJournal {
    enum Failure: Error, Equatable { case invalidInput, wrongOwner, retired, storageLimit, invalidReceipt, headRequired, staleReview, held, relayCapacity, retiredOrigin, stalePreferenceIntent }
    /// Consent's durable AUTOINCREMENT position, not the input journal's client revision.
    /// The high-water mark rejects replay after an acknowledged origin has been compacted.
    struct OriginPosition: Sendable, Equatable {
        let source: UUID
        let sequence: Int64
    }
    struct Pending: Sendable, Equatable {
        let scope: AccountScope
        let clientID: UUID
        let sequence: Int64
        let id: String
        let change: ScoringInputChange
        let expectedRevision: Int64
        let failures: Int
        var clientRevision: Int64 { sequence }
    }
    struct Status: Sendable, Equatable { let pending: Int; let conflicts: Int }
    struct Conflict: Sendable, Equatable {
        let pending: Pending
        let queuedMutationIDs: [String]
        let queuedChanges: [ScoringInputChange]
    }
    enum OriginProgress: Sendable, Equatable {
        case queued(String)
        case accepted(ScoringInputReceipt)
        case resolved(String)
    }
    private let db: DatabaseQueue
    nonisolated let scope: AccountScope
    nonisolated let clientID: UUID
    nonisolated let writeFence: StoreWriteFence
    private var active = true
    private var closed = false
    private let preferenceContext: AccountSessionContext?
    private let isPreferenceContextCurrent: @Sendable (AccountSessionContext) -> Bool

    /// Construct on the storage worker, never a SwiftUI/main-actor initializer.
    init(layout: AccountStorageLayout, fence: StoreWriteFence = StoreWriteFence(),
         preferenceContext: AccountSessionContext? = nil,
         isPreferenceContextCurrent: @escaping @Sendable (AccountSessionContext) -> Bool = { _ in false }) throws {
        guard let scope = layout.scope else { throw Failure.wrongOwner }
        guard preferenceContext == nil || preferenceContext?.scope == scope else { throw Failure.wrongOwner }
        guard fence.isValid else { throw Failure.retired }
        guard preferenceContext.map(isPreferenceContextCurrent) ?? true else { throw Failure.retired }
        self.scope = scope
        self.writeFence = fence
        self.preferenceContext = preferenceContext
        self.isPreferenceContextCurrent = isPreferenceContextCurrent
        try layout.prepare()
        let path = layout.directory.appendingPathComponent("history-inputs.sqlite")
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        db = try DatabaseQueue(path: path.path, configuration: configuration)
        db.add(transactionObserver: ScoringInputCommitFence(fence, current: {
            preferenceContext.map(isPreferenceContextCurrent) ?? true
        }), extent: .databaseLifetime)
        try db.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA journal_mode = WAL")
            try database.execute(sql: "PRAGMA synchronous = FULL")
            guard try Int.fetchOne(database, sql: "PRAGMA synchronous") == 2 else { throw Failure.storageLimit }
        }
        clientID = try db.write { database in
            let tables = try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            let knownTables: Set<String> = ["input_owner", "input_head", "input_change", "input_resolution", "input_origin", "input_relay", "input_control",
                "preference_state", "preference_intent", "preference_projection"]
            guard Set(tables).isSubset(of: knownTables), tables.isEmpty || tables.contains("input_owner") else { throw Failure.wrongOwner }
            // A partial or newer preference schema is not an invitation to silently repair/rebind it.
            let preferenceTables = Set(tables).filter { $0.hasPrefix("preference_") }
            guard preferenceTables.isEmpty || preferenceTables.count == 3 else { throw Failure.invalidInput }
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS input_owner(singleton INTEGER PRIMARY KEY CHECK(singleton=1), project TEXT NOT NULL, user TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS input_head(device TEXT NOT NULL, kind TEXT NOT NULL, entity TEXT NOT NULL,
                    revision INTEGER NOT NULL, digest TEXT NOT NULL, PRIMARY KEY(device,kind,entity));
                CREATE TABLE IF NOT EXISTS input_change(sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                    device TEXT NOT NULL, kind TEXT NOT NULL, entity TEXT NOT NULL, day TEXT NOT NULL,
                    payload BLOB NOT NULL, deleted INTEGER NOT NULL, digest TEXT NOT NULL, expected_revision INTEGER,
                    failures INTEGER NOT NULL DEFAULT 0, retry_at REAL NOT NULL DEFAULT 0, conflict INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX IF NOT EXISTS input_change_entity ON input_change(device,kind,entity,sequence);
                """)
            if let owner = try Row.fetchOne(database, sql: "SELECT project,user FROM input_owner WHERE singleton=1") {
                guard owner["project"] as String == scope.projectURL, owner["user"] as String == scope.userID else { throw Failure.wrongOwner }
            } else {
                guard tables.isEmpty else { throw Failure.wrongOwner }
                guard try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM input_change") == 0,
                      try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM input_head") == 0 else { throw Failure.wrongOwner }
                for table in knownTables.subtracting(["input_owner", "input_head", "input_change"]) where tables.contains(table) {
                    guard try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") == 0 else { throw Failure.wrongOwner }
                }
                try database.execute(sql: "INSERT INTO input_owner(singleton,project,user) VALUES(1,?,?)", arguments: [scope.projectURL, scope.userID])
            }
            // Additive upgrade preserves already-admitted mutation IDs and AUTOINCREMENT revisions.
            if try !database.columns(in: "input_owner").contains(where: { $0.name == "client_id" }) {
                try database.execute(sql: "ALTER TABLE input_owner ADD COLUMN client_id TEXT")
            }
            if try !database.columns(in: "input_head").contains(where: { $0.name == "receipt" }) {
                try database.execute(sql: "ALTER TABLE input_head ADD COLUMN receipt BLOB")
            }
            if try !database.columns(in: "input_head").contains(where: { $0.name == "effective_day" }) {
                try database.execute(sql: "ALTER TABLE input_head ADD COLUMN effective_day TEXT")
            }
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS input_resolution(
                    id TEXT PRIMARY KEY, original_sequence INTEGER NOT NULL,
                    device TEXT NOT NULL,kind TEXT NOT NULL,entity TEXT NOT NULL,day TEXT NOT NULL,
                    payload BLOB NOT NULL,deleted INTEGER NOT NULL,digest TEXT NOT NULL,expected_revision INTEGER,
                    replacement_id TEXT NOT NULL,reviewed_head INTEGER NOT NULL,settled_revision INTEGER);
                CREATE INDEX IF NOT EXISTS input_resolution_entity ON input_resolution(device,kind,entity);
                CREATE TABLE IF NOT EXISTS input_origin(
                    origin_id TEXT PRIMARY KEY,mutation_id TEXT NOT NULL UNIQUE,
                    device TEXT NOT NULL,kind TEXT NOT NULL,entity TEXT NOT NULL,day TEXT NOT NULL,
                    digest TEXT NOT NULL,receipt BLOB);
                CREATE TABLE IF NOT EXISTS input_relay(singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                    source TEXT NOT NULL,last_sequence INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS input_control(
                    purpose TEXT PRIMARY KEY NOT NULL CHECK(purpose IN('journal_context','cycle_context','imported_metrics','manual_workouts')),
                    origin_id TEXT NOT NULL UNIQUE);
                """)
            if try !database.columns(in: "input_origin").contains(where: { $0.name == "source_sequence" }) {
                try database.execute(sql: "ALTER TABLE input_origin ADD COLUMN source_sequence INTEGER")
            }
            try Self.preparePreferenceSchema(database)
            if let saved = try String.fetchOne(database, sql: "SELECT client_id FROM input_owner WHERE singleton=1") {
                guard let id = UUID(uuidString: saved) else { throw Failure.invalidInput }
                return id
            }
            let id = UUID()
            try database.execute(sql: "UPDATE input_owner SET client_id=? WHERE singleton=1", arguments: [id.uuidString.lowercased()])
            return id
        }
        #if os(iOS)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path.path + suffix) {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: path.path + suffix)
        }
        #endif
    }

    func retire() { writeFence.invalidate(); active = false }

    func close() throws {
        retire()
        guard !closed else { return }
        try db.close()
        closed = true
    }

    private static func preparePreferenceSchema(_ database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE IF NOT EXISTS preference_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                version INTEGER NOT NULL,sequence INTEGER NOT NULL CHECK(sequence>=0),last_id TEXT);
            CREATE TABLE IF NOT EXISTS preference_intent(sequence INTEGER PRIMARY KEY,id TEXT NOT NULL UNIQUE,
                digest TEXT NOT NULL,body BLOB NOT NULL,profile_id TEXT UNIQUE,config_id TEXT UNIQUE,
                profile_sequence INTEGER,config_sequence INTEGER,
                profile_settled INTEGER NOT NULL DEFAULT 0,config_settled INTEGER NOT NULL DEFAULT 0,
                byte_count INTEGER NOT NULL CHECK(byte_count>=0));
            CREATE TABLE IF NOT EXISTS preference_projection(key TEXT PRIMARY KEY,value BLOB NOT NULL,
                sequence INTEGER NOT NULL,intent_id TEXT NOT NULL,generation TEXT NOT NULL,disposition TEXT NOT NULL);
            """)
        let expected: [String: Set<String>] = [
            "preference_state": ["singleton", "version", "sequence", "last_id"],
            "preference_intent": ["sequence", "id", "digest", "body", "profile_id", "config_id", "profile_sequence", "config_sequence",
                                  "profile_settled", "config_settled", "byte_count"],
            "preference_projection": ["key", "value", "sequence", "intent_id", "generation", "disposition"]
        ]
        for (table, columns) in expected {
            let actual = try database.columns(in: table)
            let integers: Set<String> = ["singleton", "version", "sequence", "profile_sequence", "config_sequence", "profile_settled", "config_settled", "byte_count"]
            let blobs: Set<String> = ["body", "value"]
            let primary = table == "preference_state" ? "singleton" : table == "preference_intent" ? "sequence" : "key"
            guard Set(actual.map(\.name)) == columns,
                  actual.allSatisfy({ $0.type.uppercased() == (integers.contains($0.name) ? "INTEGER" : blobs.contains($0.name) ? "BLOB" : "TEXT") }),
                  actual.filter({ $0.primaryKeyIndex > 0 }).map(\.name) == [primary] else { throw Failure.invalidInput }
        }
        guard try Int.fetchOne(database, sql: """
            SELECT COUNT(*) FROM preference_state WHERE typeof(singleton)<>'integer' OR typeof(version)<>'integer'
                OR typeof(sequence)<>'integer' OR (last_id IS NOT NULL AND typeof(last_id)<>'text')
            """) == 0 else { throw Failure.invalidInput }
        let states = try Row.fetchAll(database, sql: "SELECT * FROM preference_state")
        if states.isEmpty {
            guard try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM preference_intent") == 0,
                  try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM preference_projection") == 0 else { throw Failure.invalidInput }
            try database.execute(sql: "INSERT INTO preference_state VALUES(1,1,0,NULL)")
        } else {
            guard states.count == 1, states[0]["singleton"] as Int == 1, states[0]["version"] as Int == 1 else { throw Failure.invalidInput }
            _ = try preferencePosition(database)
        }
        guard try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM preference_intent") ?? 0 <= 4096,
              try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM preference_projection") ?? 0 <= ScoringPreferenceKey.allCases.count else {
            throw Failure.storageLimit
        }
    }

    private static func preferencePosition(_ database: Database) throws -> ScoringPreferencePosition {
        guard let row = try Row.fetchOne(database, sql: "SELECT sequence,last_id FROM preference_state WHERE singleton=1") else { throw Failure.invalidInput }
        let rawID: String? = row["last_id"]
        let id = rawID.flatMap(UUID.init(uuidString:))
        let position = ScoringPreferencePosition(sequence: row["sequence"], id: id)
        guard position.isValid, rawID == nil || id != nil else { throw Failure.invalidInput }
        return position
    }

    private func checkPreferenceContext(_ expected: AccountSessionContext? = nil) throws {
        guard active, writeFence.isValid, let context = preferenceContext,
              expected == nil || expected == context, isPreferenceContextCurrent(context) else { throw Failure.retired }
        guard context.scope == scope else { throw Failure.wrongOwner }
    }

    func preferencePosition() throws -> ScoringPreferencePosition {
        try checkPreferenceContext()
        return try db.read { try Self.preferencePosition($0) }
    }

    enum PreferenceCommitPoint: Sendable { case intentInserted, firstChildInserted, projectionWritten, beforeCommit, afterCommit }

    private func writePreferenceTransaction<T>(allowing: @Sendable () -> Bool,
                                               _ updates: (Database) throws -> T) throws -> T {
        try withoutActuallyEscaping(allowing) { permit in
            let observer = ScoringPreferenceCommitPermit(allowing: permit)
            // Register after the lifetime owner/generation fence. The same permit is checked at
            // SQLite's commit hook, then removed on both commit and rollback before it can escape.
            db.add(transactionObserver: observer, extent: .observerLifetime)
            defer { db.remove(transactionObserver: observer) }
            return try db.write(updates)
        }
    }

    /// The sole local acceptance point is this FULL-synchronous transaction. Hooks are deterministic
    /// crash/fault seams; an afterCommit interruption must recover the same immutable receipt.
    func admitPreferenceIntent(_ intent: ScoringPreferenceIntent,
                               allowing: @Sendable () -> Bool,
                               at: (@Sendable (PreferenceCommitPoint) -> Void)? = nil) throws -> ScoringPreferenceAdmission {
        guard intent.context.scope == scope else { throw Failure.wrongOwner }
        try checkPreferenceContext(intent.context)
        let body = try intent.encoded()
        guard body.count <= 192 * 1024 else { throw Failure.invalidInput }
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let result = try writePreferenceTransaction(allowing: allowing) { database in
            try Task.checkCancellation()
            try checkPreferenceContext(intent.context)
            guard allowing() else { throw Failure.held }
            let current = try Self.preferencePosition(database)
            if intent.position.sequence <= current.sequence {
                guard let existing = try Row.fetchOne(database, sql: "SELECT * FROM preference_intent WHERE sequence=?", arguments: [intent.position.sequence]) else {
                    throw Failure.stalePreferenceIntent
                }
                guard existing["id"] as String == intent.id.uuidString.lowercased(), existing["digest"] as String == digest,
                      existing["body"] as Data == body else { throw Failure.stalePreferenceIntent }
                return try preferenceAdmission(existing)
            }
            guard intent.predecessor == current else { throw Failure.stalePreferenceIntent }
            guard try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM preference_intent") ?? 0 < 4096 else { throw Failure.storageLimit }
            let childBytes = (intent.profile?.payload.count ?? 0) + (intent.config?.payload.count ?? 0)
            // Reserve another child-payload copy for conflict archival. Settlement/compaction can
            // release this conservative charge; moving a child to input_resolution cannot evade it.
            let metadataBytes = body.count + childBytes + 1024
            guard try ordinaryPendingFits(childBytes + metadataBytes,
                additionalCount: intent.disposition == .serverCoupled ? 2 : 0,
                includingPreferenceProjection: true, database: database) else { throw Failure.storageLimit }
            let id = intent.id.uuidString.lowercased()
            let profileID = intent.profileMutationID?.uuidString.lowercased()
            let configID = intent.configMutationID?.uuidString.lowercased()
            try database.execute(sql: """
                INSERT INTO preference_intent(sequence,id,digest,body,profile_id,config_id,byte_count)
                VALUES(?,?,?,?,?,?,?)
                """, arguments: [intent.position.sequence, id, digest, body, profileID, configID, metadataBytes])
            at?(.intentInserted)
            var revisions: [Int64] = []
            for (index, member) in [(intent.profile, profileID), (intent.config, configID)].enumerated() {
                guard let change = member.0, let mutationID = member.1 else { continue }
                // Never rewrite/relabel a caller-supplied mutation identity or coalesce away a child.
                guard try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM input_change WHERE id=?", arguments: [mutationID]) == 0,
                      try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM input_resolution WHERE id=? OR replacement_id=?", arguments: [mutationID, mutationID]) == 0,
                      try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM input_origin WHERE mutation_id=?", arguments: [mutationID]) == 0 else { throw Failure.invalidInput }
                try database.execute(sql: """
                    INSERT INTO input_change(id,device,kind,entity,day,payload,deleted,digest) VALUES(?,?,?,?,?,?,0,?)
                    """, arguments: [mutationID, change.device, change.kind.rawValue, change.entity, change.effectiveDay, change.payload, change.digest])
                revisions.append(database.lastInsertedRowID)
                if index == 0 { at?(.firstChildInserted) }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            for item in intent.patch {
                let value = try encoder.encode(item.value)
                guard value.count <= 1024 else { throw Failure.storageLimit }
                try database.execute(sql: """
                    INSERT INTO preference_projection(key,value,sequence,intent_id,generation,disposition) VALUES(?,?,?,?,?,?)
                    ON CONFLICT(key) DO UPDATE SET value=excluded.value,sequence=excluded.sequence,
                        intent_id=excluded.intent_id,generation=excluded.generation,disposition=excluded.disposition
                    """, arguments: [item.key.rawValue, value, intent.position.sequence, id,
                        intent.context.generation.uuidString.lowercased(), intent.disposition.rawValue])
            }
            let profileRevision = revisions.first
            let configRevision = revisions.count == 2 ? revisions[1] : nil
            try database.execute(sql: "UPDATE preference_intent SET profile_sequence=?,config_sequence=? WHERE sequence=?",
                arguments: [profileRevision, configRevision, intent.position.sequence])
            try database.execute(sql: "UPDATE preference_state SET sequence=?,last_id=? WHERE singleton=1", arguments: [intent.position.sequence, id])
            at?(.projectionWritten)
            at?(.beforeCommit)
            try Task.checkCancellation()
            try checkPreferenceContext(intent.context)
            guard allowing() else { throw Failure.held }
            return ScoringPreferenceAdmission(position: intent.position, profileMutationID: intent.profileMutationID,
                configMutationID: intent.configMutationID, profileClientRevision: profileRevision, configClientRevision: configRevision)
        }
        at?(.afterCommit)
        return result
    }

    private func preferenceAdmission(_ row: Row) throws -> ScoringPreferenceAdmission {
        let intent = try ScoringPreferenceIntent(encoded: row["body"])
        guard intent.context.scope == scope, intent.position.sequence == (row["sequence"] as Int64),
              intent.id.uuidString.lowercased() == (row["id"] as String) else { throw Failure.invalidInput }
        return .init(position: intent.position, profileMutationID: intent.profileMutationID, configMutationID: intent.configMutationID,
            profileClientRevision: row["profile_sequence"], configClientRevision: row["config_sequence"])
    }

    func committedPreferenceProjection() throws -> ScoringPreferenceProjection {
        try checkPreferenceContext()
        return try db.read { database in
            let position = try Self.preferencePosition(database)
            let rows = try Row.fetchAll(database, sql: "SELECT * FROM preference_projection ORDER BY key")
            guard rows.count <= ScoringPreferenceKey.allCases.count else { throw Failure.storageLimit }
            let entries = try rows.map { row -> ScoringPreferenceProjection.Entry in
                guard let key = ScoringPreferenceKey(rawValue: row["key"]),
                      let id = UUID(uuidString: row["intent_id"]), let generation = UUID(uuidString: row["generation"]),
                      let disposition = ScoringPreferenceIntent.Disposition(rawValue: row["disposition"]) else { throw Failure.invalidInput }
                let sequence: Int64 = row["sequence"]
                let bytes: Data = row["value"]
                guard sequence > 0, sequence <= position.sequence, bytes.count <= 1024,
                      sequence != position.sequence || id == position.id else { throw Failure.invalidInput }
                let value = try JSONDecoder().decode(ScoringPreferenceValue.self, from: bytes)
                try value.validate(for: key)
                return .init(key: key, value: value, position: .init(sequence: sequence, id: id), originGeneration: generation, disposition: disposition)
            }
            return .init(scope: scope, position: position, entries: entries)
        }
    }

    /// Only terminal children (exact settlement or explicitly resolved and settled) permit removal.
    /// preference_state never moves backwards; a removed old position is permanently non-admissible.
    @discardableResult
    func compactPreferenceIntents(limit: Int = 128) throws -> Int {
        try checkPreferenceContext()
        return try db.write { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT sequence FROM preference_intent p WHERE
                  (profile_id IS NULL OR profile_settled=1 OR EXISTS(SELECT 1 FROM input_resolution r WHERE r.id=p.profile_id AND r.settled_revision IS NOT NULL))
                  AND (config_id IS NULL OR config_settled=1 OR EXISTS(SELECT 1 FROM input_resolution r WHERE r.id=p.config_id AND r.settled_revision IS NOT NULL))
                  AND NOT EXISTS(SELECT 1 FROM input_change c WHERE c.id=p.profile_id OR c.id=p.config_id)
                ORDER BY sequence LIMIT ?
                """, arguments: [max(1, min(128, limit))])
            for row in rows { try database.execute(sql: "DELETE FROM preference_intent WHERE sequence=?", arguments: [row["sequence"] as Int64]) }
            try checkPreferenceContext()
            return rows.count
        }
    }

    /// The durable origin is committed with its mutation. Retrying a cross-journal relay cannot
    /// append an older configuration after a newer one, even after the original mutation settled.
    func importOrigin(_ origin: UUID, change: ScoringInputChange, position: OriginPosition,
                      denialPurpose: ScoringContextPurpose? = nil,
                      beforeCommit: (@Sendable () -> Void)? = nil) throws -> OriginProgress {
        guard active, writeFence.isValid else { throw Failure.retired }
        guard change.kind == .config, !change.deleted, position.sequence > 0 else { throw Failure.invalidInput }
        let id = origin.uuidString.lowercased()
        return try db.write { database in
            let highWater = try relayPosition(position, database: database)
            if let saved = try Row.fetchOne(database, sql: "SELECT * FROM input_origin WHERE origin_id=?", arguments: [id]) {
                guard saved["device"] as String == change.device, saved["kind"] as String == change.kind.rawValue,
                      saved["entity"] as String == change.entity, saved["day"] as String == change.effectiveDay,
                      saved["digest"] as String == change.digest,
                      (saved["source_sequence"] as Int64?).map({ $0 == position.sequence }) ?? true else { throw Failure.invalidInput }
                // Bind pre-upgrade origins in place, including receipts lost at the cross-DB boundary.
                try database.execute(sql: "UPDATE input_origin SET source_sequence=? WHERE origin_id=?", arguments: [position.sequence, id])
                try advanceRelay(position, database: database)
                return try originProgress(saved, database: database)
            }
            guard position.sequence > highWater else { throw Failure.retiredOrigin }
            let originCount = try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM input_origin o
                WHERE NOT EXISTS(SELECT 1 FROM input_control c WHERE c.origin_id=o.origin_id)
                """) ?? 0
            let ordinary = try ordinaryPendingFits(change.payload.count, database: database) && originCount < 4096
            if !ordinary {
                // Only a persisted denial's typed purpose can use the bounded control reserve.
                // Never reclassify old debt, overwrite another denial, or let an ordinary config
                // consume it. Bound canonical bytes as JSON escaping can expand the input.
                guard let denialPurpose, change.entity == "primary", change.payload.count <= 65536,
                      try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM input_control WHERE purpose=?",
                        arguments: [denialPurpose.rawValue]) == 0 else { throw Failure.storageLimit }
                try database.execute(sql: "INSERT INTO input_control(purpose,origin_id) VALUES(?,?)",
                    arguments: [denialPurpose.rawValue, id])
            }
            try database.execute(sql: """
                INSERT INTO input_change(id,device,kind,entity,day,payload,deleted,digest) VALUES(?,?,?,?,?,?,?,?);
                """, arguments: [id, change.device, change.kind.rawValue, change.entity, change.effectiveDay,
                                  change.payload, change.deleted, change.digest])
            try database.execute(sql: "INSERT INTO input_origin(origin_id,mutation_id,device,kind,entity,day,digest,source_sequence) VALUES(?,?,?,?,?,?,?,?)",
                arguments: [id, id, change.device, change.kind.rawValue, change.entity, change.effectiveDay, change.digest, position.sequence])
            try advanceRelay(position, database: database)
            beforeCommit?()
            return .queued(id)
        }
    }

    private func relayPosition(_ position: OriginPosition, database: Database) throws -> Int64 {
        if let row = try Row.fetchOne(database, sql: "SELECT source,last_sequence FROM input_relay WHERE singleton=1") {
            guard row["source"] as String == position.source.uuidString.lowercased() else { throw Failure.wrongOwner }
            return row["last_sequence"]
        }
        try database.execute(sql: "INSERT INTO input_relay VALUES(1,?,0)", arguments: [position.source.uuidString.lowercased()])
        return 0
    }

    private func advanceRelay(_ position: OriginPosition, database: Database) throws {
        try database.execute(sql: "UPDATE input_relay SET last_sequence=MAX(last_sequence,?) WHERE singleton=1", arguments: [position.sequence])
    }

    /// Only after consent has durably copied the exact accepted receipt. The input high-water
    /// mark and origin deletion commit together; a crash before consent deletion is replay-safe.
    func retireOrigin(_ origin: UUID, change: ScoringInputChange, position: OriginPosition,
                      receipt: ScoringInputReceipt, beforeCommit: (@Sendable () -> Void)? = nil) throws {
        guard active, writeFence.isValid else { throw Failure.retired }
        guard position.sequence > 0 else { throw Failure.invalidInput }
        let id = origin.uuidString.lowercased()
        try db.write { database in
            let highWater = try relayPosition(position, database: database)
            if let row = try Row.fetchOne(database, sql: "SELECT * FROM input_origin WHERE origin_id=?", arguments: [id]) {
                guard row["digest"] as String == change.digest,
                      row["device"] as String == change.device, row["kind"] as String == change.kind.rawValue,
                      row["entity"] as String == change.entity, row["day"] as String == change.effectiveDay,
                      (row["source_sequence"] as Int64?).map({ $0 == position.sequence }) ?? true,
                      try originProgress(row, database: database) == .accepted(receipt),
                      try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM input_change WHERE id=?", arguments: [id]) == 0 else {
                    throw Failure.invalidReceipt
                }
                try advanceRelay(position, database: database)
                try database.execute(sql: "DELETE FROM input_origin WHERE origin_id=?", arguments: [id])
                // Receipt copying precedes this transaction. Settlement alone cannot release a
                // slot: the exact accepted origin must survive a crash until this handshake.
                try database.execute(sql: "DELETE FROM input_control WHERE origin_id=?", arguments: [id])
            } else {
                guard position.sequence <= highWater else { throw Failure.invalidReceipt }
            }
            beforeCommit?()
        }
    }

    func originProgress(_ origin: UUID) throws -> OriginProgress? {
        guard active, writeFence.isValid else { throw Failure.retired }
        return try db.read { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM input_origin WHERE origin_id=?",
                arguments: [origin.uuidString.lowercased()]) else { return nil }
            return try originProgress(row, database: database)
        }
    }

    private func originProgress(_ row: Row, database: Database) throws -> OriginProgress {
        let id: String = row["mutation_id"]
        if let data: Data = row["receipt"] {
            let receipt = try JSONDecoder().decode(ScoringInputReceipt.self, from: data)
            guard receipt.userId == UUID(uuidString: scope.userID), receipt.clientId == clientID,
                  receipt.clientMutationId == UUID(uuidString: id), receipt.kind.rawValue == (row["kind"] as String),
                  receipt.sourceDeviceId == UUID(uuidString: row["device"]), receipt.entity == (row["entity"] as String),
                  receipt.effectiveDay == (row["day"] as String) else { throw Failure.invalidReceipt }
            return .accepted(receipt)
        }
        if let replacement = try String.fetchOne(database, sql: "SELECT replacement_id FROM input_resolution WHERE id=?", arguments: [id]) {
            return .resolved(replacement)
        }
        guard try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM input_change WHERE id=?)", arguments: [id]) == true else {
            throw Failure.invalidReceipt
        }
        return .queued(id)
    }

    @discardableResult
    func enqueue(_ input: ScoringInputChange,
                 allowing: @Sendable (ScoringInputChange) -> Bool = { _ in true },
                 beforeCommit: (@Sendable () -> Void)? = nil) throws -> String? {
        guard active, writeFence.isValid else { throw Failure.retired }
        return try db.write { database in
            try Task.checkCancellation()
            guard allowing(input) else { throw Failure.held }
            let change = try preservingSleepDay(input, database: database)
            let key: StatementArguments = [change.device, change.kind.rawValue, change.entity]
            if let last = try Row.fetchOne(database, sql: "SELECT id,digest FROM input_change WHERE device=? AND kind=? AND entity=? ORDER BY sequence DESC LIMIT 1", arguments: key) {
                if last["digest"] as String == change.digest { return last["id"] as String }
            } else if try String.fetchOne(database, sql: "SELECT digest FROM input_head WHERE device=? AND kind=? AND entity=?", arguments: key) == change.digest {
                return nil
            }
            // Refuse new admission instead of deleting an older pending edit to satisfy a cap.
            guard try ordinaryPendingFits(change.payload.count, database: database) else { throw Failure.storageLimit }
            let id = UUID().uuidString.lowercased()
            guard allowing(change) else { throw Failure.held }
            try database.execute(sql: """
                INSERT INTO input_change(id,device,kind,entity,day,payload,deleted,digest) VALUES(?,?,?,?,?,?,?,?)
                """, arguments: [id, change.device, change.kind.rawValue, change.entity, change.effectiveDay,
                                  change.payload, change.deleted, change.digest])
            beforeCommit?()
            try Task.checkCancellation()
            return id
        }
    }

    /// The four immutable overflow denials have their own count and payload budget. Keeping
    /// their allocation through origin retirement also bounds accepted/resolved control debt.
    // Reserved within the ordinary 16 MiB ceiling, including after intent compaction. Value bytes
    // are capped at 1024/key; 256/key plus 128 covers fixed projection/head metadata.
    static let preferenceProjectionBudget = ScoringPreferenceKey.allCases.count * (1024 + 256) + 128

    private func ordinaryPendingFits(_ additionalBytes: Int, additionalCount: Int = 1,
                                     includingPreferenceProjection: Bool = false, database: Database) throws -> Bool {
        let usage = try Row.fetchOne(database, sql: """
            SELECT COUNT(*) AS count,COALESCE(SUM(length(payload)),0) AS bytes FROM input_change p
            WHERE NOT EXISTS(SELECT 1 FROM input_control c WHERE c.origin_id=p.id)
            """)!
        let preferenceBytes = try Int.fetchOne(database, sql: "SELECT COALESCE(SUM(byte_count),0) FROM preference_intent") ?? 0
        let hasProjection = try Self.preferencePosition(database).sequence > 0
        let projectionBytes = includingPreferenceProjection || hasProjection ? Self.preferenceProjectionBudget : 0
        return additionalBytes >= 0 && additionalCount >= 0 && (usage["count"] as Int) + additionalCount <= 4096
            && (usage["bytes"] as Int) + preferenceBytes + projectionBytes + additionalBytes <= 16 * 1_048_576
    }

    private func preservingSleepDay(_ change: ScoringInputChange, database: Database) throws -> ScoringInputChange {
        guard change.kind == .sleepEdit else { return change }
        let key: [String] = [change.device, change.kind.rawValue, change.entity]
        let earliest = try String.fetchOne(database, sql: """
            SELECT MIN(day) FROM (
              SELECT day FROM input_change WHERE device=? AND kind=? AND entity=?
              UNION ALL SELECT effective_day AS day FROM input_head WHERE device=? AND kind=? AND entity=?
              UNION ALL SELECT day FROM input_resolution WHERE device=? AND kind=? AND entity=?)
            """, arguments: StatementArguments(key + key + key))
        guard let earliest, earliest < change.effectiveDay else { return change }
        return try ScoringInputChange(device: change.device, kind: change.kind, entity: change.entity,
            effectiveDay: earliest, payload: change.payload, deleted: change.deleted)
    }

    private func readyRow(_ database: Database, now: Date,
                          allowing: @Sendable (ScoringInputChange) -> Bool) throws -> Row? {
        let cursor = try Row.fetchCursor(database, sql: """
            SELECT c.* FROM input_change c WHERE c.conflict=0 AND c.retry_at<=?
              AND NOT EXISTS(SELECT 1 FROM input_change prior WHERE prior.device=c.device
                AND prior.kind=c.kind AND prior.entity=c.entity AND prior.sequence<c.sequence)
            ORDER BY c.sequence
            """, arguments: [now.timeIntervalSince1970])
        while let row = try cursor.next() {
            if try allowing(pending(row, expected: 0).change) { return row.copy() }
        }
        return nil
    }

    private func pending(_ row: Row, expected: Int64) throws -> Pending {
        guard let kind = ScoringInputChange.Kind(rawValue: row["kind"]) else { throw Failure.invalidInput }
        return Pending(scope: scope, clientID: clientID, sequence: row["sequence"], id: row["id"],
            change: try ScoringInputChange(device: row["device"], kind: kind, entity: row["entity"],
                effectiveDay: row["day"], payload: row["payload"], deleted: row["deleted"]),
            expectedRevision: expected, failures: row["failures"])
    }

    /// Metadata lookup never mutates an already-frozen request, including pre-upgrade debt.
    func initialHeadRequest(now: Date = Date(), allowing: @Sendable (ScoringInputChange) -> Bool = { _ in true }) throws -> Pending? {
        guard active, writeFence.isValid else { throw Failure.retired }
        return try db.read { database in
            guard let row = try readyRow(database, now: now, allowing: allowing), row["expected_revision"] as Int64? == nil,
                  try Int64.fetchOne(database, sql: "SELECT revision FROM input_head WHERE device=? AND kind=? AND entity=?",
                    arguments: [row["device"] as String, row["kind"] as String, row["entity"] as String]) == nil else { return nil }
            return try pending(row, expected: 0)
        }
    }

    func freezeInitialHead(_ head: ScoringInputHead, for request: Pending,
                           allowing: @Sendable (ScoringInputChange) -> Bool = { _ in true }) throws {
        guard active, writeFence.isValid else { throw Failure.retired }
        guard request.scope == scope, request.clientID == clientID, head.matches(scope: scope, change: request.change) else {
            throw Failure.invalidReceipt
        }
        try db.write { database in
            guard allowing(request.change) else { return }
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM input_change WHERE sequence=? AND id=?",
                arguments: [request.sequence, request.id]), try pending(row, expected: 0).change == request.change else { throw Failure.staleReview }
            // Another opener may have frozen or settled work while metadata was in flight.
            // Never replace that expected revision with a newly fetched one.
            guard row["expected_revision"] as Int64? == nil else { return }
            try database.execute(sql: "UPDATE input_change SET expected_revision=? WHERE sequence=? AND expected_revision IS NULL",
                arguments: [head.headRevision, request.sequence])
        }
    }

    /// requireKnownHead is used by the network coordinator. Direct callers with a known empty
    /// fixture/legacy head retain the existing zero-head journal API.
    func next(now: Date = Date(), requireKnownHead: Bool = false,
              allowing: @Sendable (ScoringInputChange) -> Bool = { _ in true }) throws -> Pending? {
        guard active, writeFence.isValid else { throw Failure.retired }
        return try db.write { database in
            // A conflict blocks only its entity; unrelated profile/config/edits may progress.
            guard let row = try readyRow(database, now: now, allowing: allowing) else { return nil }
            let sequence: Int64 = row["sequence"]
            let expected = try (row["expected_revision"] as Int64?) ?? (Int64.fetchOne(database,
                sql: "SELECT revision FROM input_head WHERE device=? AND kind=? AND entity=?",
                arguments: [row["device"] as String, row["kind"] as String, row["entity"] as String]))
            guard expected != nil || !requireKnownHead else { throw Failure.headRequired }
            try database.execute(sql: "UPDATE input_change SET expected_revision=? WHERE sequence=?", arguments: [expected ?? 0, sequence])
            return try pending(row, expected: expected ?? 0)
        }
    }

    func settle(_ pending: Pending, receipt: ScoringInputReceipt, beforeCommit: (@Sendable () -> Void)? = nil) throws {
        guard active, writeFence.isValid else { throw Failure.retired }
        guard pending.scope == scope, pending.clientID == clientID, receipt.matches(pending) else { throw Failure.invalidReceipt }
        try db.write { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM input_change WHERE sequence=?", arguments: [pending.sequence]),
                  row["id"] as String == pending.id, row["expected_revision"] as Int64 == pending.expectedRevision,
                  row["digest"] as String == pending.change.digest,
                  row["device"] as String == pending.change.device, row["kind"] as String == pending.change.kind.rawValue,
                  row["entity"] as String == pending.change.entity, row["day"] as String == pending.change.effectiveDay,
                  row["payload"] as Data == pending.change.payload, row["deleted"] as Bool == pending.change.deleted
            else { throw Failure.invalidReceipt }
            let known = try Int64.fetchOne(database, sql: "SELECT revision FROM input_head WHERE device=? AND kind=? AND entity=?",
                arguments: [pending.change.device, pending.change.kind.rawValue, pending.change.entity]) ?? 0
            guard receipt.revision >= known else { throw Failure.invalidReceipt }
            try database.execute(sql: """
                INSERT INTO input_head(device,kind,entity,revision,digest,receipt,effective_day) VALUES(?,?,?,?,?,?,?)
                ON CONFLICT(device,kind,entity) DO UPDATE SET revision=excluded.revision,digest=excluded.digest,receipt=excluded.receipt,
                  effective_day=CASE WHEN excluded.kind='sleep_edit' THEN MIN(COALESCE(input_head.effective_day,excluded.effective_day),excluded.effective_day)
                                     ELSE excluded.effective_day END
                """, arguments: [pending.change.device, pending.change.kind.rawValue, pending.change.entity,
                                   receipt.revision, pending.change.digest, try JSONEncoder().encode(receipt), pending.change.effectiveDay])
            try database.execute(sql: "UPDATE input_resolution SET settled_revision=? WHERE replacement_id=?",
                arguments: [receipt.revision, pending.id])
            try database.execute(sql: "UPDATE input_origin SET receipt=? WHERE mutation_id=?",
                arguments: [try JSONEncoder().encode(receipt), pending.id])
            try database.execute(sql: "UPDATE preference_intent SET profile_settled=1 WHERE profile_id=?", arguments: [pending.id])
            try database.execute(sql: "UPDATE preference_intent SET config_settled=1 WHERE config_id=?", arguments: [pending.id])
            try database.execute(sql: "DELETE FROM input_change WHERE sequence=?", arguments: [pending.sequence])
            beforeCommit?()
        }
    }

    func retry(_ pending: Pending, conflict: Bool, now: Date = Date()) throws {
        guard active, writeFence.isValid else { throw Failure.retired }
        guard pending.scope == scope, pending.clientID == clientID else { throw Failure.wrongOwner }
        let delay = min(300.0, pow(2, Double(min(8, pending.failures))))
        try db.write { database in
            try database.execute(sql: "UPDATE input_change SET failures=failures+1,retry_at=?,conflict=? WHERE sequence=? AND id=?",
                arguments: [now.timeIntervalSince1970 + delay, conflict, pending.sequence, pending.id])
        }
    }

    func status() throws -> Status {
        try db.read { database in
            Status(pending: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM input_change") ?? 0,
                   conflicts: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM input_change WHERE conflict=1") ?? 0)
        }
    }

    func conflict(id: String) throws -> Conflict? {
        guard active, writeFence.isValid else { throw Failure.retired }
        return try db.read { database in try conflict(id: id, database: database) }
    }

    func conflicts(limit: Int = 32) throws -> [Conflict] {
        guard active, writeFence.isValid else { throw Failure.retired }
        return try db.read { database in
            let ids = try String.fetchAll(database, sql: "SELECT id FROM input_change WHERE conflict=1 ORDER BY sequence LIMIT ?",
                arguments: [max(1, min(128, limit))])
            return try ids.compactMap { try conflict(id: $0, database: database) }
        }
    }

    private func conflict(id: String, database: Database) throws -> Conflict? {
        guard let row = try Row.fetchOne(database, sql: "SELECT * FROM input_change WHERE id=? AND conflict=1", arguments: [id]),
              let expected = row["expected_revision"] as Int64? else { return nil }
        let first = try pending(row, expected: expected)
        let queued = try Row.fetchAll(database, sql: "SELECT * FROM input_change WHERE device=? AND kind=? AND entity=? ORDER BY sequence",
            arguments: [first.change.device, first.change.kind.rawValue, first.change.entity])
        guard queued.first?["id"] as String? == id else { return nil }
        return Conflict(pending: first, queuedMutationIDs: queued.map { $0["id"] },
            queuedChanges: try queued.map { try pending($0, expected: ($0["expected_revision"] as Int64?) ?? 0).change })
    }

    /// Explicitly replace the entire reviewed entity queue, never just its first row: otherwise
    /// pre-existing followers would carry lower client revisions than the rebased mutation.
    /// Original intents remain in the owner-bound resolution archive; no reconciliation calls this.
    @discardableResult
    func resolveConflict(_ review: Conflict, head: ScoringInputHead, replacement: ScoringInputChange,
                         allowing: @Sendable (ScoringInputChange) -> Bool = { _ in true }) throws -> String {
        guard active, writeFence.isValid else { throw Failure.retired }
        guard review.pending.scope == scope, review.pending.clientID == clientID,
              head.matches(scope: scope, change: review.pending.change), head.headRevision >= review.pending.expectedRevision,
              replacement.device == review.pending.change.device, replacement.kind == review.pending.change.kind,
              replacement.entity == review.pending.change.entity else { throw Failure.invalidReceipt }
        return try db.write { database in
            guard allowing(replacement) else { throw Failure.held }
            guard try conflict(id: review.pending.id, database: database) == review else { throw Failure.staleReview }
            let replacement = try preservingSleepDay(replacement, database: database)
            let archiveCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM input_resolution") ?? 0
            guard archiveCount + review.queuedMutationIDs.count <= 4096 else { throw Failure.storageLimit }
            let key: StatementArguments = [replacement.device, replacement.kind.rawValue, replacement.entity]
            let id = UUID().uuidString.lowercased()
            guard allowing(replacement) else { throw Failure.held }
            try database.execute(sql: """
                INSERT INTO input_resolution(id,original_sequence,device,kind,entity,day,payload,deleted,digest,expected_revision,replacement_id,reviewed_head)
                SELECT id,sequence,device,kind,entity,day,payload,deleted,digest,expected_revision,?,?
                  FROM input_change WHERE device=? AND kind=? AND entity=?
                """, arguments: [id, head.headRevision, replacement.device, replacement.kind.rawValue, replacement.entity])
            try database.execute(sql: "DELETE FROM input_change WHERE device=? AND kind=? AND entity=?", arguments: key)
            // An explicit replacement is ordinary admission, not a new control reservation.
            // Failure rolls back both the archive and deletion; reviewed debt remains intact.
            guard try ordinaryPendingFits(replacement.payload.count, database: database) else { throw Failure.storageLimit }
            try database.execute(sql: """
                INSERT INTO input_change(id,device,kind,entity,day,payload,deleted,digest,expected_revision) VALUES(?,?,?,?,?,?,?,?,?)
                """, arguments: [id, replacement.device, replacement.kind.rawValue, replacement.entity, replacement.effectiveDay,
                                  replacement.payload, replacement.deleted, replacement.digest, head.headRevision])
            return id
        }
    }
}
