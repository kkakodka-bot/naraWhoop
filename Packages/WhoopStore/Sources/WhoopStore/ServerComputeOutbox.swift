import Foundation
import GRDB

public struct ServerComputeRequest: Codable, Equatable, Sendable {
    public let id: String
    public let family: String
    public let sessionID: String
    public let eventStart: String
    public let eventEnd: String?
    public let timezoneID: String
    public let inputRevision: Int64
    public let algorithmVersion: String
    public let configurationVersion: String
    public let consent: Bool
    public let expiresAt: String?
    enum CodingKeys: String, CodingKey {
        case id, family, consent
        case sessionID = "session_id", eventStart = "event_start", eventEnd = "event_end", timezoneID = "timezone_id"
        case inputRevision = "input_revision", algorithmVersion = "algorithm_version", configurationVersion = "configuration_version", expiresAt = "expires_at"
    }
    public init(id: UUID = UUID(), family: String, sessionID: UUID, start: Date, end: Date?,
                timezone: TimeZone, inputRevision: Int64, consent: Bool, expiresAt: Date? = nil) {
        self.id = id.uuidString.lowercased(); self.family = family; self.sessionID = sessionID.uuidString.lowercased()
        let format = ISO8601DateFormatter()
        eventStart = format.string(from: start); eventEnd = end.map(format.string)
        timezoneID = timezone.identifier; self.inputRevision = inputRevision
        algorithmVersion = "vps-only-1"; configurationVersion = "vps-only-1"
        self.consent = consent; self.expiresAt = expiresAt.map(format.string)
    }
}

/// A metadata outbox, separate from raw capture and scoring. Requests retain their original body
/// and principal across retries; credential refresh does not rewrite their identity or event clock.
public final class ServerComputeOutbox {
    public struct DraftScope: Codable, Equatable, Sendable {
        public let project: String, owner: String, source: String, localDevice: String
        public init(project: String, owner: String, source: String, localDevice: String) {
            self.project = ServerCanonicalResults.projectKey(project); self.owner = owner
            self.source = source; self.localDevice = localDevice
        }
    }
    /// Registration can be offline on first capture. Persist under the local identity first;
    /// binding to an acknowledged canonical device is a later, idempotent transport operation.
    public static func saveDraft(_ request: ServerComputeRequest, scope: DraftScope, db: any DatabaseWriter) throws {
        guard ServerCanonicalResults.familyMetrics[request.family] != nil, request.inputRevision >= 0,
              UUID(uuidString: request.id) != nil, UUID(uuidString: request.sessionID) != nil,
              !scope.owner.isEmpty, !scope.source.isEmpty, !scope.localDevice.isEmpty else { throw Failure.scope }
        let key = try encoded(scope), body = try encoded(request)
        try db.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS serverComputeDrafts (id TEXT PRIMARY KEY, scope BLOB NOT NULL, payload BLOB NOT NULL, bound INTEGER NOT NULL DEFAULT 0)")
            if let row = try Row.fetchOne(db, sql: "SELECT scope,payload FROM serverComputeDrafts WHERE id=?", arguments: [request.id]) {
                guard row["scope"] as Data == key, row["payload"] as Data == body else { throw Failure.conflict }
            } else {
                try db.execute(sql: "INSERT INTO serverComputeDrafts(id,scope,payload) VALUES(?,?,?)", arguments: [request.id, key, body])
            }
        }
    }
    public func bindDrafts(_ draft: DraftScope) throws {
        guard draft.project == scope.project, draft.owner == scope.owner, draft.source == scope.source else { throw Failure.scope }
        let key = try Self.encoded(draft)
        let requests: [ServerComputeRequest] = try db.read { db in
            guard try db.tableExists("serverComputeDrafts") else { return [] }
            return try Data.fetchAll(db, sql: "SELECT payload FROM serverComputeDrafts WHERE scope=? AND bound=0", arguments: [key])
                .map { try JSONDecoder().decode(ServerComputeRequest.self, from: $0) }
        }
        for request in requests {
            _ = try enqueue(request, localDevice: draft.localDevice)
            try db.write { db in try db.execute(sql: "UPDATE serverComputeDrafts SET bound=1 WHERE id=? AND scope=?", arguments: [request.id, key]) }
        }
    }
    public struct Scope: Codable, Equatable, Sendable {
        public let project: String, owner: String, source: String, device: String
        public init(project: String, owner: String, source: String, device: String) {
            self.project = ServerCanonicalResults.projectKey(project); self.owner = owner; self.source = source; self.device = device
        }
    }
    public struct Item: Codable, Equatable, Sendable {
        public let scope: Scope
        public let localDevice: String
        public let request: ServerComputeRequest
        public var result: ServerCanonicalFamilyResult?
    }
    public enum Failure: Error { case scope, conflict, invalidResult }
    private let db: any DatabaseWriter
    private let scope: Scope
    public init(db: any DatabaseWriter, scope: Scope) throws {
        self.db = db; self.scope = scope
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS serverComputeRequestOutbox (
                    id TEXT PRIMARY KEY NOT NULL, scope BLOB NOT NULL, payload BLOB NOT NULL,
                    result BLOB, createdAt REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS serverComputeDecisionReceipts (
                    decisionID TEXT NOT NULL, scope BLOB NOT NULL, resultRevision TEXT NOT NULL,
                    consumedAt REAL NOT NULL, PRIMARY KEY(decisionID, scope)
                );
                """)
        }
    }
    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public func enqueue(_ request: ServerComputeRequest, localDevice: String) throws -> Item {
        guard ServerCanonicalResults.familyMetrics[request.family] != nil, request.inputRevision >= 0,
              !localDevice.isEmpty, UUID(uuidString: request.id) != nil,
              UUID(uuidString: request.sessionID) != nil, TimeZone(identifier: request.timezoneID) != nil else { throw Failure.scope }
        let item = Item(scope: scope, localDevice: localDevice, request: request)
        let body = try Self.encoded(item), scopeData = try Self.encoded(scope)
        try db.write { db in
            if let old = try Data.fetchOne(db, sql: "SELECT payload FROM serverComputeRequestOutbox WHERE id=?", arguments: [request.id]) {
                guard old == body else { throw Failure.conflict }
                return
            }
            try db.execute(sql: "INSERT INTO serverComputeRequestOutbox(id,scope,payload,createdAt) VALUES(?,?,?,?)",
                arguments: [request.id, scopeData, body, Date().timeIntervalSince1970])
        }
        return item
    }
    public func pending(limit: Int = 20) throws -> [Item] {
        let key = try Self.encoded(scope)
        return try db.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM serverComputeRequestOutbox WHERE scope=? AND result IS NULL ORDER BY createdAt,id LIMIT ?",
                arguments: [key, min(max(limit, 1), 100)]).map { try JSONDecoder().decode(Item.self, from: $0) }
        }
    }
    public func accept(_ result: ServerCanonicalFamilyResult, for item: Item) throws {
        guard item.scope == scope, result.owner == "server", result.ownerID == scope.owner,
              ServerCanonicalResults.projectKey(result.project) == scope.project, result.sourceID == scope.source,
              result.deviceID == scope.device, result.window == item.request.sessionID,
              result.inputRevision == item.request.inputRevision, ServerCanonicalFamilyResult.isResultRevision(result.resultRevision),
              ServerCanonicalFamilyResult.timestamp(result.computedAt) != nil, result.algorithmVersion?.isEmpty == false,
              [result.observedThrough, result.expiresAt].allSatisfy({ $0 == nil || ServerCanonicalFamilyResult.timestamp($0) != nil }),
              Set(result.metrics) == ServerCanonicalResults.familyMetrics[item.request.family],
              Set(result.values.keys).isSubset(of: Set(result.metrics)),
              ServerCanonicalResults.states.contains(result.status),
              !["available", "stale"].contains(result.status) || result.hasCanonicalAuthorization,
              ["available", "stale"].contains(result.status) || result.values.values.allSatisfy({ $0 == .null }) else { throw Failure.invalidResult }
        let body = try Self.encoded(result), key = try Self.encoded(scope)
        try db.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM serverComputeRequestOutbox WHERE id=? AND scope=?)", arguments: [item.request.id, key]) == true else { throw Failure.scope }
            if let prior = try Data.fetchOne(db, sql: "SELECT result FROM serverComputeRequestOutbox WHERE id=? AND scope=?", arguments: [item.request.id, key]) {
                guard prior == body else { throw Failure.conflict }
                return
            }
            try db.execute(sql: "UPDATE serverComputeRequestOutbox SET result=? WHERE id=? AND scope=?", arguments: [body, item.request.id, key])
        }
    }
    public func results() throws -> [String: ServerCanonicalFamilyResult] {
        let key = try Self.encoded(scope)
        return try db.read { db in
            var result: [String: ServerCanonicalFamilyResult] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id,result FROM serverComputeRequestOutbox WHERE scope=? AND result IS NOT NULL", arguments: [key]) {
                let bytes: Data = row["result"]
                result[row["id"]] = try JSONDecoder().decode(ServerCanonicalFamilyResult.self, from: bytes)
            }
            return result
        }
    }
    /// Commit the receipt before dispatch. A crash can drop a cue, never replay it late.
    public func consumeDecision(_ result: ServerCanonicalFamilyResult, now: Date) throws -> Bool {
        guard result.ownerID == scope.owner, result.deviceID == scope.device, result.sourceID == scope.source,
              ServerCanonicalResults.projectKey(result.project) == scope.project,
              result.status == "available", result.hasCanonicalAuthorization,
              let decision = result.decisionID, let revision = result.resultRevision,
              let expires = ServerCanonicalFamilyResult.timestamp(result.expiresAt), expires > now,
              let computed = ServerCanonicalFamilyResult.timestamp(result.computedAt), computed <= now else { return false }
        let key = try Self.encoded(scope)
        return try db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO serverComputeDecisionReceipts(decisionID,scope,resultRevision,consumedAt) VALUES(?,?,?,?)",
                arguments: [decision, key, revision, now.timeIntervalSince1970])
            return db.changesCount == 1
        }
    }
}
