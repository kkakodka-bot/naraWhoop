import Combine
import Foundation
import GRDB
import NoopPush
import WhoopStore

enum ScoringContextPurpose: String, Codable, CaseIterable, Sendable {
    case journal = "journal_context"
    case cycle = "cycle_context"
    case imports = "imported_metrics"
    case workouts = "manual_workouts"

    static func required(for kind: ScoringInputChange.Kind) -> Self? {
        switch kind {
        case .context: return .journal
        case .period: return .cycle
        case .importedDaily: return .imports
        case .manualWorkout: return .workouts
        default: return nil
        }
    }
}

struct ScoringContextDecision: Equatable, Sendable {
    let purpose: ScoringContextPurpose
    let id: UUID
    let enabled: Bool
    let decidedAt: Date

    var payload: [String: Any] {
        ["purpose": purpose.rawValue, "policyVersion": 1, "decisionId": id.uuidString.lowercased()]
    }
}

struct ScoringConsentConfiguration: Sendable, Equatable {
    let change: ScoringInputChange
    let timezone: String
}

/// The request boundary checks this same captured gate before and after authorization.
/// Re-enabling is a new decision: it cannot silently release old held sensitive inputs.
final class ScoringConsentGate: @unchecked Sendable {
    let writeFence = StoreWriteFence()
    private let lock = NSLock()
    private var decisions: [ScoringContextPurpose: ScoringContextDecision] = [:]
    private var admissionEpoch: UInt64 = 0
    private var admissionReady = false

    func holdAdmission() { lock.lock(); admissionEpoch &+= 1; admissionReady = false; lock.unlock() }
    func epoch() -> UInt64 { lock.lock(); defer { lock.unlock() }; return admissionEpoch }
    func releaseAdmission(_ epoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if writeFence.isValid, epoch == admissionEpoch { admissionReady = true }
    }
    func captureAdmission() throws -> ScoringInputCoordinator.AdmissionCheck {
        lock.lock(); let epoch = admissionEpoch; let ready = admissionReady; lock.unlock()
        guard ready, writeFence.isValid else { throw ScoringInputJournal.Failure.held }
        return { [self] in
            lock.lock(); defer { lock.unlock() }
            return writeFence.isValid && admissionReady && admissionEpoch == epoch
        }
    }

    func replace(_ decisions: [ScoringContextPurpose: ScoringContextDecision]) {
        lock.lock(); defer { lock.unlock() }
        guard writeFence.isValid else { return }
        self.decisions = decisions
    }

    func pause(_ purpose: ScoringContextPurpose) {
        lock.lock(); decisions.removeValue(forKey: purpose); lock.unlock()
    }

    func retire() { writeFence.invalidate(); lock.lock(); decisions = [:]; lock.unlock() }

    func allows(_ change: ScoringInputChange) -> Bool {
        guard writeFence.isValid else { return false }
        guard let purpose = ScoringContextPurpose.required(for: change.kind) else { return true }
        lock.lock(); let decision = decisions[purpose]; lock.unlock()
        guard let decision, decision.enabled else { return false }
        // Retraction is an explicit operation, not an inferred deletion when a choice is revoked.
        // While sharing is paused, even retained tombstones wait for explicit review.
        if change.deleted { return true }
        guard let body = try? JSONSerialization.jsonObject(with: change.payload) as? [String: Any],
              let consent = body["consent"] as? [String: Any], consent.count == 3,
              consent["purpose"] as? String == purpose.rawValue,
              let version = consent["policyVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let id = consent["decisionId"] as? String, UUID(uuidString: id) == decision.id else { return false }
        return writeFence.isValid
    }
}

private final class ScoringConsentCommitFence: TransactionObserver {
    let fence: StoreWriteFence
    init(_ fence: StoreWriteFence) { self.fence = fence }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseWillCommit() throws { try fence.check() }
    func databaseDidCommit(_ db: Database) {}
    func databaseDidRollback(_ db: Database) {}
}

/// A separate FULL-synchronous account journal. No legacy global/local-feature choice is imported.
actor ScoringContextConsentStore {
    struct Intent: Sendable, Equatable {
        let id: UUID
        let configuration: ScoringConsentConfiguration
        let position: ScoringInputJournal.OriginPosition
        /// Derived from the persisted decision, never guessed from current UI/config flags.
        let denialPurpose: ScoringContextPurpose?
    }
    private let database: DatabaseQueue
    private let fence: StoreWriteFence
    private let scope: AccountScope
    nonisolated let sourceID: UUID

    init(layout: AccountStorageLayout, fence: StoreWriteFence) throws {
        guard let scope = layout.scope else { throw ScoringInputJournal.Failure.wrongOwner }
        self.scope = scope
        try fence.check()
        self.fence = fence
        try layout.prepare()
        let path = layout.directory.appendingPathComponent("scoring-context-consent.sqlite")
        database = try DatabaseQueue(path: path.path)
        database.add(transactionObserver: ScoringConsentCommitFence(fence), extent: .databaseLifetime)
        try database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=FULL")
            guard try Int.fetchOne(db, sql: "PRAGMA synchronous") == 2 else { throw ScoringInputJournal.Failure.storageLimit }
        }
        try database.write { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            let known: Set<String> = ["consent_owner", "consent_decision", "consent_barrier", "consent_intent", "consent_pause"]
            guard tables.isEmpty || (Set(tables).isSubset(of: known) && tables.contains("consent_owner") && tables.contains("consent_decision")) else {
                throw ScoringInputJournal.Failure.wrongOwner
            }
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS consent_owner(singleton INTEGER PRIMARY KEY CHECK(singleton=1),project TEXT NOT NULL,user TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS consent_decision(purpose TEXT PRIMARY KEY,decision_id TEXT NOT NULL,enabled INTEGER NOT NULL CHECK(enabled IN(0,1)),decided_at REAL NOT NULL);
                """)
            if let owner = try Row.fetchOne(db, sql: "SELECT project,user FROM consent_owner WHERE singleton=1") {
                guard owner["project"] as String == scope.projectURL, owner["user"] as String == scope.userID else {
                    throw ScoringInputJournal.Failure.wrongOwner
                }
            } else {
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM consent_decision") == 0 else {
                    throw ScoringInputJournal.Failure.wrongOwner
                }
                for table in ["consent_intent", "consent_barrier", "consent_pause"] where tables.contains(table) {
                    guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0 else {
                        throw ScoringInputJournal.Failure.wrongOwner
                    }
                }
                try db.execute(sql: "INSERT INTO consent_owner VALUES(1,?,?)", arguments: [scope.projectURL, scope.userID])
            }
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS consent_intent(
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT UNIQUE NOT NULL,
                    purpose TEXT NOT NULL,enabled INTEGER NOT NULL,decided_at REAL NOT NULL,
                    completed INTEGER NOT NULL DEFAULT 0,
                    device TEXT,day TEXT,payload BLOB,timezone TEXT,
                    imported_id TEXT,receipt BLOB,resolution_id TEXT);
                CREATE TABLE IF NOT EXISTS consent_barrier(purpose TEXT PRIMARY KEY,intent_id TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS consent_pause(purpose TEXT PRIMARY KEY,decision_id TEXT NOT NULL,decided_at REAL NOT NULL);
                """)
            if try !db.columns(in: "consent_intent").contains(where: { $0.name == "reserved" }) {
                try db.execute(sql: "ALTER TABLE consent_intent ADD COLUMN reserved INTEGER NOT NULL DEFAULT 0")
            }
            if try !db.columns(in: "consent_owner").contains(where: { $0.name == "source_id" }) {
                try db.execute(sql: "ALTER TABLE consent_owner ADD COLUMN source_id TEXT")
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM consent_barrier b LEFT JOIN consent_intent i ON i.id=b.intent_id WHERE i.id IS NULL") == 0 else {
                throw ScoringInputJournal.Failure.invalidInput
            }
            try db.execute(sql: """
                INSERT OR IGNORE INTO consent_pause(purpose,decision_id,decided_at)
                SELECT b.purpose,b.intent_id,i.decided_at FROM consent_barrier b JOIN consent_intent i ON i.id=b.intent_id;
                """)
        }
        sourceID = try database.write { db in
            if let value = try String.fetchOne(db, sql: "SELECT source_id FROM consent_owner WHERE singleton=1") {
                guard let id = UUID(uuidString: value) else { throw ScoringInputJournal.Failure.invalidInput }
                return id
            }
            let id = UUID()
            try db.execute(sql: "UPDATE consent_owner SET source_id=? WHERE singleton=1", arguments: [id.uuidString.lowercased()])
            return id
        }
        #if os(iOS)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path.path + suffix) {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: path.path + suffix)
        }
        #endif
    }

    func read() throws -> [ScoringContextPurpose: ScoringContextDecision] {
        try fence.check()
        return try database.read { db in
            var result: [ScoringContextPurpose: ScoringContextDecision] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM consent_decision") {
                guard let purpose = ScoringContextPurpose(rawValue: row["purpose"]),
                      let id = UUID(uuidString: row["decision_id"]) else { throw ScoringInputJournal.Failure.invalidInput }
                result[purpose] = .init(purpose: purpose, id: id, enabled: row["enabled"],
                                       decidedAt: Date(timeIntervalSince1970: row["decided_at"]))
            }
            for row in try Row.fetchAll(db, sql: "SELECT purpose,decision_id AS id,decided_at FROM consent_pause") {
                guard let purpose = ScoringContextPurpose(rawValue: row["purpose"]),
                      let text: String = row["id"], let id = UUID(uuidString: text),
                      let time: Double = row["decided_at"] else { throw ScoringInputJournal.Failure.invalidInput }
                result[purpose] = .init(purpose: purpose, id: id, enabled: false, decidedAt: Date(timeIntervalSince1970: time))
            }
            return result
        }
    }

    func blockedPurposes() throws -> Set<ScoringContextPurpose> {
        try fence.check()
        return try database.read { db in
            try Set(String.fetchAll(db, sql: "SELECT purpose FROM consent_pause").map {
                guard let value = ScoringContextPurpose(rawValue: $0) else { throw ScoringInputJournal.Failure.invalidInput }
                return value
            })
        }
    }

    func set(_ purpose: ScoringContextPurpose, enabled: Bool, now: Date = Date(),
             configuration: ScoringConsentConfiguration? = nil,
             configurationUnavailable: Bool = false,
             beforeCommit: (@Sendable () -> Void)? = nil) throws -> ScoringContextDecision {
        try fence.check()
        // Canonicalize once before storage. Date's reference-epoch/Unix-epoch conversion can
        // otherwise differ by a fraction of a microsecond and fail the post-commit readback.
        let timestamp = (now.timeIntervalSince1970 * 1000).rounded(.down) / 1000
        let decision = ScoringContextDecision(purpose: purpose, id: UUID(), enabled: enabled,
                                              decidedAt: Date(timeIntervalSince1970: timestamp))
        let id = decision.id.uuidString.lowercased()
        // Four fixed-size rows, independent of history count/bytes and remote outbox capacity.
        // Even a refused new grant leaves the previous decision paused after process death.
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO consent_pause VALUES(?,?,?) ON CONFLICT(purpose)
                DO UPDATE SET decision_id=excluded.decision_id,decided_at=excluded.decided_at
                """, arguments: [purpose.rawValue, id, timestamp])
        }
        if let configuration {
            guard configuration.change.kind == .config, configuration.change.entity == "primary",
                  !configuration.change.deleted, TimeZone(identifier: configuration.timezone) != nil else {
                throw ScoringInputJournal.Failure.invalidInput
            }
        }
        // Commit the denial barrier before touching a prior grant. If the second transaction
        // fails, a fresh runtime still sees this purpose paused and retains the dated intent.
        try database.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM consent_intent WHERE reserved=0") ?? 0
            let bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(payload)),0) FROM consent_intent WHERE reserved=0") ?? 0
            let ordinary = count < 4096 && bytes + (configuration?.change.payload.count ?? 0) <= 16 * 1_048_576
            if !ordinary {
                // One immutable overflow denial per purpose. Never overwrite earlier debt to
                // admit another transition; the independent pause above still survives failure.
                guard !enabled, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM consent_intent WHERE reserved=1 AND purpose=?",
                    arguments: [purpose.rawValue]) == 0 else { throw ScoringInputJournal.Failure.storageLimit }
            }
            try db.execute(sql: """
                INSERT INTO consent_intent(id,purpose,enabled,decided_at,device,day,payload,timezone,reserved) VALUES(?,?,?,?,?,?,?,?,?);
                """, arguments: [id, purpose.rawValue, enabled, timestamp, configuration?.change.device,
                    configuration?.change.effectiveDay, configuration?.change.payload, configuration?.timezone, !ordinary])
            try db.execute(sql: "INSERT INTO consent_barrier VALUES(?,?) ON CONFLICT(purpose) DO UPDATE SET intent_id=excluded.intent_id",
                arguments: [purpose.rawValue, id])
        }
        // An invalid unrelated preference must not resurrect a previous grant on restart.
        // No remote configuration is invented when its immutable snapshot could not be built.
        guard !configurationUnavailable else { throw ScoringInputJournal.Failure.invalidInput }
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO consent_decision(purpose,decision_id,enabled,decided_at) VALUES(?,?,?,?)
                ON CONFLICT(purpose) DO UPDATE SET decision_id=excluded.decision_id,enabled=excluded.enabled,decided_at=excluded.decided_at
                """, arguments: [purpose.rawValue, id, enabled, timestamp])
            try db.execute(sql: "UPDATE consent_intent SET completed=1 WHERE id=?", arguments: [id])
            try db.execute(sql: "DELETE FROM consent_barrier WHERE purpose=? AND intent_id=?", arguments: [purpose.rawValue, id])
            try db.execute(sql: "DELETE FROM consent_pause WHERE purpose=? AND decision_id=?", arguments: [purpose.rawValue, id])
            beforeCommit?()
        }
        return decision
    }

    /// Failed grants never relay. A persisted denial may relay even if updating the old grant
    /// failed: the barrier itself already records that explicit denial and keeps local access off.
    func pendingIntents(limit: Int = 64, includeImported: Bool = true, importedOnly: Bool = false,
                        after: Int64 = 0) throws -> [Intent] {
        try fence.check()
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM consent_intent WHERE payload IS NOT NULL AND (completed=1 OR enabled=0)
                  AND receipt IS NULL AND resolution_id IS NULL AND (? OR imported_id IS NULL)
                  AND (NOT ? OR imported_id IS NOT NULL) AND sequence>?
                ORDER BY (imported_id IS NOT NULL),sequence LIMIT ?
                """, arguments: [includeImported, importedOnly, after, max(1, min(128, limit))])
            return try rows.map(intent)
        }
    }

    private func intent(_ row: Row) throws -> Intent {
        guard let id = UUID(uuidString: row["id"]),
              let purpose = ScoringContextPurpose(rawValue: row["purpose"]) else { throw ScoringInputJournal.Failure.invalidInput }
        return Intent(id: id, configuration: .init(change: try ScoringInputChange(device: row["device"],
            kind: .config, entity: "primary", effectiveDay: row["day"], payload: row["payload"]), timezone: row["timezone"]),
            position: .init(source: sourceID, sequence: row["sequence"]),
            denialPurpose: (row["enabled"] as Bool) ? nil : purpose)
    }

    func acceptedIntents(limit: Int = 64) throws -> [(Intent, ScoringInputReceipt)] {
        try fence.check()
        return try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM consent_intent WHERE receipt IS NOT NULL ORDER BY sequence LIMIT ?",
                arguments: [max(1, min(128, limit))]).map {
                    (try intent($0), try JSONDecoder().decode(ScoringInputReceipt.self, from: $0["receipt"]))
                }
        }
    }

    /// Called only after the input store has committed origin retirement. Repeating either
    /// half after a crash is harmless; the input store's position fence rejects old re-imports.
    func finishRetirement(_ intent: Intent, receipt: ScoringInputReceipt,
                          beforeCommit: (@Sendable () -> Void)? = nil) throws {
        try fence.check()
        guard intent.position.source == sourceID else { throw ScoringInputJournal.Failure.wrongOwner }
        try database.write { db in
            let id = intent.id.uuidString.lowercased()
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM consent_intent WHERE id=?", arguments: [id]) else { return }
            guard try self.intent(row) == intent, let bytes: Data = row["receipt"],
                  try JSONDecoder().decode(ScoringInputReceipt.self, from: bytes) == receipt else { throw ScoringInputJournal.Failure.invalidReceipt }
            // A failed visible-decision transaction remains paused independently of this row.
            try db.execute(sql: "DELETE FROM consent_barrier WHERE intent_id=?", arguments: [id])
            try db.execute(sql: "DELETE FROM consent_intent WHERE id=?", arguments: [id])
            beforeCommit?()
        }
    }

    func recordProgress(_ progress: ScoringInputJournal.OriginProgress, for intent: Intent) throws {
        try fence.check()
        guard intent.position.source == sourceID else { throw ScoringInputJournal.Failure.wrongOwner }
        let id = intent.id.uuidString.lowercased()
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM consent_intent WHERE id=?", arguments: [id]),
                  try self.intent(row) == intent else { throw ScoringInputJournal.Failure.invalidInput }
            switch progress {
            case .queued(let mutation):
                guard mutation == id else { throw ScoringInputJournal.Failure.invalidReceipt }
                try db.execute(sql: "UPDATE consent_intent SET imported_id=? WHERE id=?", arguments: [mutation, id])
            case .accepted(let receipt):
                guard receipt.userId == UUID(uuidString: scope.userID), receipt.clientMutationId == intent.id,
                      receipt.sourceDeviceId == UUID(uuidString: intent.configuration.change.device),
                      receipt.kind == .config, receipt.entity == "primary", !receipt.deleted,
                      receipt.effectiveDay == intent.configuration.change.effectiveDay else { throw ScoringInputJournal.Failure.invalidReceipt }
                try db.execute(sql: "UPDATE consent_intent SET imported_id=?,receipt=? WHERE id=?",
                    arguments: [id, try JSONEncoder().encode(receipt), id])
            case .resolved(let replacement):
                guard UUID(uuidString: replacement) != nil else { throw ScoringInputJournal.Failure.invalidReceipt }
                // A reviewed replacement is not evidence that this original choice was accepted.
                try db.execute(sql: "UPDATE consent_intent SET imported_id=?,resolution_id=? WHERE id=?", arguments: [id, replacement, id])
            }
        }
    }
}

@MainActor
final class ScoringContextConsent: ObservableObject {
    @Published private(set) var decisions: [ScoringContextPurpose: ScoringContextDecision] = [:]
    @Published private(set) var loaded = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    let gate = ScoringConsentGate()
    private let layout: AccountStorageLayout
    private var preparation: Task<ScoringContextConsentStore, Error>?
    private var store: ScoringContextConsentStore?
    private var transition: UInt64 = 0
    private var unsavedPurposes: Set<ScoringContextPurpose> = []
    private var relayTask: Task<UInt64, Error>?
    private var relayRefreshAfter: Int64 = 0
    private(set) var relayWaiterCount = 0
    var didChange: (() -> Void)?
    var willChange: (() -> Void)?
    var configuration: ((ScoringContextPurpose, Bool, Date) throws -> ScoringConsentConfiguration)?

    init(layout: AccountStorageLayout) { self.layout = layout }
    func enabled(_ purpose: ScoringContextPurpose) -> Bool { gate.writeFence.isValid && decisions[purpose]?.enabled == true }

    private func ready() async throws -> ScoringContextConsentStore {
        try gate.writeFence.check()
        if let store { return store }
        let pending: Task<ScoringContextConsentStore, Error>
        if let preparation { pending = preparation }
        else {
            let layout = layout, fence = gate.writeFence
            pending = Task.detached(priority: .utility) { try ScoringContextConsentStore(layout: layout, fence: fence) }
            preparation = pending
        }
        do {
            let opened = try await pending.value
            try gate.writeFence.check()
            store = opened; preparation = nil
            return opened
        } catch { preparation = nil; throw error }
    }

    func load() async {
        let revision = transition
        do {
            let store = try await ready()
            let values = try await store.read()
            let blocked = try await store.blockedPurposes()
            try gate.writeFence.check()
            guard !saving, revision == transition else { return }
            unsavedPurposes.formUnion(blocked)
            publish(values)
            didChange?()
        } catch {
            guard gate.writeFence.isValid else { return }
            decisions = [:]; gate.replace([:])
            self.error = "Sharing choices could not be loaded. Optional context upload is paused."
        }
    }

    private func publish(_ values: [ScoringContextPurpose: ScoringContextDecision]) {
        // A failed change remains paused across view reloads and changes to other purposes.
        // Only a successful explicit retry may release that purpose in this runtime.
        let allowed = values.filter { !unsavedPurposes.contains($0.key) }
        decisions = allowed; gate.replace(allowed); loaded = true
        error = unsavedPurposes.isEmpty ? nil
            : "A sharing change needs retry. That context remains paused. Server acceptance is not confirmed."
    }

    func setEnabled(_ enabled: Bool, purpose: ScoringContextPurpose, now: Date = Date()) async {
        guard gate.writeFence.isValid, !saving else { return }
        transition &+= 1
        gate.holdAdmission()
        saving = true
        // Stop this purpose synchronously, including an in-flight authorization continuation.
        gate.pause(purpose)
        unsavedPurposes.insert(purpose)
        willChange?()
        defer {
            saving = false
            // Presentation and admission observers must see the settled transition.
            // A retired account cannot publish a late completion.
            if gate.writeFence.isValid { didChange?() }
        }
        do {
            let captured = Result { try configuration?(purpose, enabled, now) }
            let frozen = try? captured.get()
            let unavailable: Bool
            if case .failure = captured { unavailable = true } else { unavailable = false }
            let store = try await ready()
            let decision = try await store.set(purpose, enabled: enabled, now: now, configuration: frozen,
                                               configurationUnavailable: unavailable)
            let values = try await store.read()
            try gate.writeFence.check()
            guard values[purpose] == decision else { throw ScoringInputJournal.Failure.invalidInput }
            unsavedPurposes.remove(purpose)
            publish(values)
        } catch {
            guard gate.writeFence.isValid else { return }
            // Never reopen the gate after a failed write. The user must retry a failed revocation.
            decisions.removeValue(forKey: purpose)
            self.error = "The sharing change could not be completed. Upload is paused; retry to confirm storage and server acceptance."
        }
    }

    /// Run before fresh input admission and before network draining. A crash at either journal
    /// boundary repeats the same origin/mutation rather than generating another configuration.
    func relay(to inputs: ScoringInputCoordinator) async throws {
        guard layout.scope == inputs.context.scope else { throw ScoringInputJournal.Failure.wrongOwner }
        guard !saving else { throw ScoringInputJournal.Failure.held }
        relayWaiterCount += 1
        defer { relayWaiterCount -= 1 }
        inputs.captureAdmission = { [gate] in try gate.captureAdmission() }
        if let relayTask {
            let revision = try await relayTask.value
            guard revision == transition, !saving else { throw ScoringInputJournal.Failure.held }
            try gate.writeFence.check()
            return
        }
        let revision = transition, epoch = gate.epoch()
        let task = Task<UInt64, Error> { [weak self, weak inputs] in
            guard let self, let inputs else { throw ScoringInputJournal.Failure.retired }
            let store = try await self.ready()
            func compactAccepted() async throws {
                for (intent, receipt) in try await store.acceptedIntents(limit: 128) {
                    try self.gate.writeFence.check()
                    try await inputs.retireOrigin(intent.id, change: intent.configuration.change,
                        position: intent.position, receipt: receipt)
                    try await store.finishRetirement(intent, receipt: receipt)
                }
            }
            try await compactAccepted()
            // Rotate through imported debt; a held oldest entry must not starve later receipts.
            let imported = try await store.pendingIntents(importedOnly: true, after: self.relayRefreshAfter)
            self.relayRefreshAfter = imported.last?.position.sequence ?? 0
            for intent in imported {
                let progress = try await inputs.importOrigin(intent.id, change: intent.configuration.change,
                    position: intent.position, denialPurpose: intent.denialPurpose)
                try await store.recordProgress(progress, for: intent)
            }
            try await compactAccepted()
            for _ in 0..<8 {
                let pending = try await store.pendingIntents(includeImported: false)
                if pending.isEmpty { break }
                for intent in pending {
                    try self.gate.writeFence.check()
                    let progress: ScoringInputJournal.OriginProgress
                    do {
                        progress = try await inputs.importOrigin(intent.id, change: intent.configuration.change,
                            position: intent.position, denialPurpose: intent.denialPurpose)
                    } catch ScoringInputJournal.Failure.storageLimit {
                        // Admission remains blocked, but the coordinator may drain older debt.
                        throw ScoringInputJournal.Failure.relayCapacity
                    }
                    try await store.recordProgress(progress, for: intent)
                }
            }
            guard try await store.pendingIntents(limit: 1, includeImported: false).isEmpty else {
                throw ScoringInputJournal.Failure.relayCapacity
            }
            // No awaits after this validation: a transition during any cross-DB wait requires
            // another pass. Joined callers cannot treat an older relay snapshot as admission.
            guard self.transition == revision, !self.saving else { throw ScoringInputJournal.Failure.held }
            try self.gate.writeFence.check()
            self.gate.releaseAdmission(epoch)
            return revision
        }
        relayTask = task
        defer { relayTask = nil }
        let completed = try await task.value
        guard completed == transition, !saving else { throw ScoringInputJournal.Failure.held }
        try gate.writeFence.check()
    }

    func retire() {
        transition &+= 1; gate.retire(); preparation?.cancel(); relayTask?.cancel()
        decisions = [:]; didChange = nil; willChange = nil; configuration = nil
    }
}
