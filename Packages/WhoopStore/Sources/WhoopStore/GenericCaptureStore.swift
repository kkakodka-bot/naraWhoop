import Foundation
import GRDB
import WhoopProtocol

public enum StandardHRCaptureError: Error, Equatable, Sendable {
    case unassignedOwner, ownerMismatch, invalidIntent, identityConflict
    case capacity, closedSession, sequenceGap, unsupportedVersion, integrityFailure
    case concurrentCapture, storageUnavailable
}

public struct StandardHRCaptureOwner: Equatable, Sendable {
    public let projectURL: String
    public let userID: String

    public init(projectURL: String, userID: String) throws {
        guard (1...2048).contains(projectURL.utf8.count), !projectURL.contains("\0"),
              let url = URL(string: projectURL), url.host != nil,
              userID.utf8.count == 36, UUID(uuidString: userID) != nil else {
            throw StandardHRCaptureError.invalidIntent
        }
        // Ownership uses the exact strings already bound to the account file.
        self.projectURL = projectURL
        self.userID = userID
    }
}

public struct StandardHRCaptureID: Hashable, Sendable {
    public let sessionID: UUID
    public let sequence: Int64

    public init(sessionID: UUID, sequence: Int64) throws {
        guard sequence >= 0 else { throw StandardHRCaptureError.invalidIntent }
        self.sessionID = sessionID
        self.sequence = sequence
    }
}

public struct StandardHRCaptureSession: Equatable, Sendable {
    public let owner: StandardHRCaptureOwner
    public let sessionID: UUID
    public let runtimeGeneration: UUID
    fileprivate init(owner: StandardHRCaptureOwner, sessionID: UUID, runtimeGeneration: UUID) {
        self.owner = owner; self.sessionID = sessionID; self.runtimeGeneration = runtimeGeneration
    }
}

public struct StandardHRFrozenBatch: Equatable, Sendable {
    public let id: StandardHRCaptureID
    public let scope: DurableIngestScope
    public let hostTimestampSeconds: Int64
    public let rawBytes: Data
    public let projectionJSON: Data
    public let rawSHA256: String
    public let intentSHA256: String
    public let chargeBytes: Int64

    public init(id: StandardHRCaptureID, scope: DurableIngestScope,
                hostTimestampSeconds: Int64, rawBytes: Data, projectionJSON: Data) throws {
        guard let project = scope.environment, let user = scope.accountID else {
            throw StandardHRCaptureError.unassignedOwner
        }
        _ = try StandardHRCaptureOwner(projectURL: project, userID: user)
        guard (1...256).contains(scope.deviceID.utf8.count), !scope.deviceID.contains("\0"),
              (1...512).contains(rawBytes.count), (1...12288).contains(projectionJSON.count),
              Int(exactly: hostTimestampSeconds) != nil else {
            throw StandardHRCaptureError.invalidIntent
        }
        _ = try Self.decodeProjection(projectionJSON, timestamp: hostTimestampSeconds)
        self.id = id; self.scope = scope; self.hostTimestampSeconds = hostTimestampSeconds
        self.rawBytes = rawBytes; self.projectionJSON = projectionJSON
        self.rawSHA256 = DurableIngestScope.sha256(rawBytes)
        self.chargeBytes = Int64(rawBytes.count + projectionJSON.count + scope.deviceID.utf8.count + 256)
        let strings = ["standard-hr-capture-v1", project, user, scope.deviceID,
            id.sessionID.uuidString.lowercased(), String(id.sequence), String(hostTimestampSeconds),
            "standard-hr-current-v1", "standard-hr-one-notification-v1"]
        var tuple = Data()
        for part in strings.map({ Data($0.utf8) }) + [rawBytes, projectionJSON] {
            var length = UInt64(part.count).bigEndian
            withUnsafeBytes(of: &length) { tuple.append(contentsOf: $0) }
            tuple.append(part)
        }
        self.intentSHA256 = DurableIngestScope.sha256(tuple)
    }

    fileprivate static func decodeProjection(_ bytes: Data, timestamp: Int64) throws -> Streams {
        do {
            let streams = try JSONDecoder().decode(Streams.self, from: bytes)
            guard streams.hr.count == 1, streams.hr[0].ts == timestamp,
                  streams.rr.allSatisfy({ $0.ts == timestamp && $0.srcChannel == nil && $0.ord == nil && $0.seq == 0 }),
                  streams.events.count == 1, streams.events[0].ts == timestamp,
                  streams.events[0].kind == StandardHRMapping.contactEventKind,
                  streams.events[0].payload.count == 1,
                  case let .string(contact)? = streams.events[0].payload["contact"],
                  StandardHRContact(rawValue: contact) != nil,
                  streams.battery.isEmpty, streams.spo2.isEmpty, streams.skinTemp.isEmpty,
                  streams.resp.isEmpty, streams.gravity.isEmpty, streams.steps.isEmpty,
                  streams.sleepState.isEmpty, streams.ppgHr.isEmpty,
                  streams.ppgWaveform.isEmpty, streams.v18Aux.isEmpty else {
                throw StandardHRCaptureError.invalidIntent
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            // Re-encoding rejects missing arrays, unknown keys, explicit nils, duplicate keys,
            // alternate number spellings, and whitespace that the permissive Streams reader accepts.
            guard try encoder.encode(streams) == bytes else { throw StandardHRCaptureError.invalidIntent }
            return streams
        } catch { throw StandardHRCaptureError.invalidIntent }
    }
}

/// Local T1 commit witness only. Not a receiver receipt or permission to prune.
public struct StandardHRLocalReceipt: Equatable, Sendable {
    public let id: StandardHRCaptureID
    public let intentSHA256: String
    fileprivate init(_ batch: StandardHRFrozenBatch) {
        id = batch.id; intentSHA256 = batch.intentSHA256
    }
}

public enum StandardHRProjectionStep: Equatable, Sendable {
    case empty
    case completed(id: StandardHRCaptureID, intentSHA256: String)
}

private struct StandardHRStoredBatch: Decodable, FetchableRecord {
    let sessionID: String
    let sequence: Int64
    let deviceID: String
    let hostTimestampSeconds: Int64
    let schemaVersion: Int64
    let decoderVersion: String
    let mappingVersion: String
    let rawBytes: Data
    let projectionJSON: Data
    let rawSHA256: String
    let intentSHA256: String
    let chargeBytes: Int64
}

private struct StandardHRProjectionKey: Hashable, Sendable {
    let path: String
    let project: String
    let user: String
}

/// Package-test observation of actual gate decisions, not a replacement admission policy.
enum StandardHRProjectionGateEvent: Equatable, Sendable {
    case registered(waiting: Bool)
    case acquired
}

typealias StandardHRProjectionGateObserver = @Sendable (StandardHRProjectionGateEvent) -> Void

/// Serializes the complete T2/T3 pair across actor reentrancy and separate handles.
/// This is process-local; it is not a cross-process lease or a three-transaction atomic commit.
private actor StandardHRProjectionGate {
    static let shared = StandardHRProjectionGate()
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
        let observer: StandardHRProjectionGateObserver?
    }
    private var queues: [StandardHRProjectionKey: [Waiter]] = [:]

    func acquire(_ key: StandardHRProjectionKey, observer: StandardHRProjectionGateObserver? = nil) async {
        if queues[key] == nil {
            queues[key] = []
            observer?(.registered(waiting: false))
            observer?(.acquired)
            return
        }
        await withCheckedContinuation {
            queues[key, default: []].append(Waiter(continuation: $0, observer: observer))
            observer?(.registered(waiting: true))
        }
    }

    func release(_ key: StandardHRProjectionKey) {
        guard var waiters = queues[key], !waiters.isEmpty else { queues.removeValue(forKey: key); return }
        let next = waiters.removeFirst()
        queues[key] = waiters
        // Report the grant before resuming the waiter, so task scheduling cannot hide an early grant.
        next.observer?(.acquired)
        next.continuation.resume()
    }
}

extension WhoopStore {
    /// Root registers this additive, empty schema as v53. No capture-time installation or adoption.
    nonisolated static func installStandardHRCaptureSchema(_ db: Database) throws {
        guard db.isInsideTransaction else { throw StandardHRCaptureError.storageUnavailable }
        func uuidCheck(_ column: String) -> String {
            "length(\(column)) = 36 AND substr(\(column),9,1) = '-' AND substr(\(column),14,1) = '-' AND substr(\(column),19,1) = '-' AND substr(\(column),24,1) = '-' AND length(replace(\(column),'-','')) = 32 AND lower(replace(\(column),'-','')) NOT GLOB '*[^0-9a-f]*'"
        }
        try db.execute(sql: """
            CREATE TABLE standardHRCaptureSession (
              ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
              sessionID TEXT NOT NULL UNIQUE CHECK(\(uuidCheck("sessionID")) AND sessionID = lower(sessionID)),
              projectURL TEXT NOT NULL CHECK(length(CAST(projectURL AS BLOB)) BETWEEN 1 AND 2048),
              userID TEXT NOT NULL CHECK(\(uuidCheck("userID"))),
              runtimeGeneration TEXT NOT NULL CHECK(\(uuidCheck("runtimeGeneration"))),
              openedAt INTEGER NOT NULL CHECK(typeof(openedAt)='integer'),
              sealed INTEGER NOT NULL DEFAULT 0 CHECK(typeof(sealed)='integer' AND sealed IN (0,1)),
              nextSequence INTEGER NOT NULL DEFAULT 0 CHECK(typeof(nextSequence)='integer' AND nextSequence BETWEEN 0 AND 300000),
              retainedCount INTEGER NOT NULL DEFAULT 0 CHECK(typeof(retainedCount)='integer' AND retainedCount BETWEEN 0 AND 300000),
              retainedBytes INTEGER NOT NULL DEFAULT 0 CHECK(typeof(retainedBytes)='integer' AND retainedBytes BETWEEN 0 AND 268435456),
              sessionChargeBytes INTEGER NOT NULL CHECK(typeof(sessionChargeBytes)='integer' AND sessionChargeBytes =
                512 + length(CAST(projectURL AS BLOB)) + length(CAST(userID AS BLOB)))
            );
            CREATE TABLE standardHRCaptureOccurrence (
              sessionID TEXT NOT NULL REFERENCES standardHRCaptureSession(sessionID) ON DELETE RESTRICT,
              sequence INTEGER NOT NULL CHECK(typeof(sequence)='integer' AND sequence>=0),
              deviceID TEXT NOT NULL CHECK(length(CAST(deviceID AS BLOB)) BETWEEN 1 AND 256),
              hostTimestampSeconds INTEGER NOT NULL CHECK(typeof(hostTimestampSeconds)='integer'),
              schemaVersion INTEGER NOT NULL CHECK(typeof(schemaVersion)='integer' AND schemaVersion=1),
              decoderVersion TEXT NOT NULL CHECK(decoderVersion='standard-hr-current-v1'),
              mappingVersion TEXT NOT NULL CHECK(mappingVersion='standard-hr-one-notification-v1'),
              rawBytes BLOB NOT NULL CHECK(typeof(rawBytes)='blob' AND length(rawBytes) BETWEEN 1 AND 512),
              projectionJSON BLOB NOT NULL CHECK(typeof(projectionJSON)='blob' AND length(projectionJSON) BETWEEN 1 AND 12288),
              rawSHA256 TEXT NOT NULL CHECK(length(rawSHA256)=64 AND rawSHA256 NOT GLOB '*[^0-9a-f]*'),
              intentSHA256 TEXT NOT NULL CHECK(length(intentSHA256)=64 AND intentSHA256 NOT GLOB '*[^0-9a-f]*'),
              chargeBytes INTEGER NOT NULL CHECK(typeof(chargeBytes)='integer' AND chargeBytes =
                length(rawBytes)+length(projectionJSON)+length(CAST(deviceID AS BLOB))+256),
              projectionState INTEGER NOT NULL DEFAULT 0 CHECK(typeof(projectionState)='integer' AND projectionState IN (0,1)),
              attempts INTEGER NOT NULL DEFAULT 0 CHECK(typeof(attempts)='integer' AND attempts>=0),
              lastFailureCode TEXT CHECK(lastFailureCode IS NULL OR
                (typeof(lastFailureCode)='text' AND length(CAST(lastFailureCode AS BLOB))<=64)),
              projectedAt INTEGER CHECK(projectedAt IS NULL OR typeof(projectedAt)='integer'),
              PRIMARY KEY(sessionID,sequence),
              CHECK((projectionState=0 AND projectedAt IS NULL) OR (projectionState=1 AND projectedAt IS NOT NULL))
            );
            CREATE INDEX standardHRCaptureOccurrence_pending ON standardHRCaptureOccurrence(projectionState,sessionID,sequence);

            CREATE TRIGGER standardHRCaptureSession_owner BEFORE INSERT ON standardHRCaptureSession BEGIN
              SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM localAccountOwner WHERE singleton=1
                AND projectURL=NEW.projectURL AND userID=NEW.userID) THEN RAISE(ABORT,'standardHR.owner') END;
              SELECT CASE WHEN NEW.sealed!=0 OR NEW.nextSequence!=0 OR NEW.retainedCount!=0 OR NEW.retainedBytes!=0
                THEN RAISE(ABORT,'standardHR.identity') END;
            END;
            CREATE TRIGGER standardHRCaptureSession_identity BEFORE UPDATE OF ordinal,sessionID,projectURL,userID,
              runtimeGeneration,openedAt,sessionChargeBytes ON standardHRCaptureSession BEGIN
              SELECT RAISE(ABORT,'standardHR.identity');
            END;
            CREATE TRIGGER standardHRCaptureSession_state BEFORE UPDATE ON standardHRCaptureSession BEGIN
              SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM localAccountOwner WHERE singleton=1
                AND projectURL=OLD.projectURL AND userID=OLD.userID) THEN RAISE(ABORT,'standardHR.owner') END;
              SELECT CASE WHEN OLD.sealed=1 AND NEW.sealed!=1 THEN RAISE(ABORT,'standardHR.closed') END;
            END;
            CREATE TRIGGER standardHRCaptureSession_capacity BEFORE INSERT ON standardHRCaptureSession BEGIN
              SELECT CASE WHEN (SELECT COUNT(*) FROM standardHRCaptureSession)>=1024 OR
                (SELECT COALESCE(SUM(sessionChargeBytes+retainedBytes),0) FROM standardHRCaptureSession)>
                  268435456-NEW.sessionChargeBytes THEN RAISE(ABORT,'standardHR.capacity') END;
            END;
            CREATE TRIGGER standardHRCaptureSession_counters BEFORE UPDATE OF nextSequence,retainedCount,retainedBytes
              ON standardHRCaptureSession BEGIN
              SELECT CASE WHEN OLD.sealed!=0 OR NEW.nextSequence!=OLD.nextSequence+1
                OR NEW.retainedCount!=OLD.retainedCount+1 OR NEW.nextSequence!=NEW.retainedCount
                OR NOT EXISTS(SELECT 1 FROM standardHRCaptureOccurrence o WHERE o.sessionID=OLD.sessionID
                  AND o.sequence=OLD.nextSequence AND NEW.retainedBytes=OLD.retainedBytes+o.chargeBytes)
                THEN RAISE(ABORT,'standardHR.integrity') END;
            END;
            CREATE TRIGGER standardHRCaptureOccurrence_admission BEFORE INSERT ON standardHRCaptureOccurrence BEGIN
              SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM standardHRCaptureSession s JOIN localAccountOwner a
                ON a.singleton=1 AND a.projectURL=s.projectURL AND a.userID=s.userID
                WHERE s.sessionID=NEW.sessionID) THEN RAISE(ABORT,'standardHR.owner') END;
              SELECT CASE WHEN (SELECT sealed FROM standardHRCaptureSession WHERE sessionID=NEW.sessionID)!=0
                THEN RAISE(ABORT,'standardHR.closed') END;
              SELECT CASE WHEN NEW.sequence!=(SELECT nextSequence FROM standardHRCaptureSession WHERE sessionID=NEW.sessionID)
                THEN RAISE(ABORT,'standardHR.sequence') END;
              SELECT CASE WHEN NEW.projectionState!=0 OR NEW.attempts!=0 OR NEW.lastFailureCode IS NOT NULL OR NEW.projectedAt IS NOT NULL
                THEN RAISE(ABORT,'standardHR.identity') END;
              SELECT CASE WHEN (SELECT COALESCE(SUM(retainedCount),0) FROM standardHRCaptureSession)>=300000
                OR (SELECT COALESCE(SUM(sessionChargeBytes+retainedBytes),0) FROM standardHRCaptureSession)>268435456-NEW.chargeBytes
                OR NEW.sequence>=9223372036854775807 THEN RAISE(ABORT,'standardHR.capacity') END;
            END;
            CREATE TRIGGER standardHRCaptureOccurrence_count AFTER INSERT ON standardHRCaptureOccurrence BEGIN
              UPDATE standardHRCaptureSession SET nextSequence=nextSequence+1, retainedCount=retainedCount+1,
                retainedBytes=retainedBytes+NEW.chargeBytes WHERE sessionID=NEW.sessionID;
            END;
            CREATE TRIGGER standardHRCaptureOccurrence_identity BEFORE UPDATE OF sessionID,sequence,deviceID,
              hostTimestampSeconds,schemaVersion,decoderVersion,mappingVersion,rawBytes,projectionJSON,
              rawSHA256,intentSHA256,chargeBytes ON standardHRCaptureOccurrence BEGIN
              SELECT RAISE(ABORT,'standardHR.identity');
            END;
            CREATE TRIGGER standardHRCaptureOccurrence_state BEFORE UPDATE ON standardHRCaptureOccurrence BEGIN
              SELECT CASE WHEN OLD.projectionState=1 THEN RAISE(ABORT,'standardHR.identity') END;
              SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM standardHRCaptureSession s JOIN localAccountOwner a
                ON a.singleton=1 AND a.projectURL=s.projectURL AND a.userID=s.userID WHERE s.sessionID=OLD.sessionID)
                THEN RAISE(ABORT,'standardHR.owner') END;
              SELECT CASE WHEN NEW.attempts<OLD.attempts THEN RAISE(ABORT,'standardHR.integrity') END;
            END;
            CREATE TRIGGER standardHRCaptureOccurrence_retain BEFORE DELETE ON standardHRCaptureOccurrence BEGIN
              SELECT RAISE(ABORT,'standardHR.retain');
            END;
            CREATE TRIGGER standardHRCaptureSession_retain BEFORE DELETE ON standardHRCaptureSession BEGIN
              SELECT RAISE(ABORT,'standardHR.retain');
            END;
            """)
    }

    /// Caller must hold J's exclusive live-journal slot and finish recovery before a NEW session.
    /// Store cannot infer whether another source still owns RAM-only reservations.
    public func beginStandardHRCapture(owner: StandardHRCaptureOwner, sessionID: UUID,
        runtimeGeneration: UUID, openedAtUnixSeconds: Int64) async throws -> StandardHRCaptureSession {
        try Task.checkCancellation()
        do {
            return try standardHRWrite { db in
                try Self.standardHROwner(db, owner)
                let id = sessionID.uuidString.lowercased()
                if let row = try Row.fetchOne(db, sql: "SELECT * FROM standardHRCaptureSession WHERE sessionID=?", arguments: [id]) {
                    guard (row["projectURL"] as String) == owner.projectURL, (row["userID"] as String) == owner.userID,
                          (row["runtimeGeneration"] as String) == runtimeGeneration.uuidString.lowercased(),
                          (row["openedAt"] as Int64) == openedAtUnixSeconds else { throw StandardHRCaptureError.identityConflict }
                } else {
                    guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM standardHRCaptureOccurrence WHERE projectionState=0)") == false else {
                        throw StandardHRCaptureError.concurrentCapture
                    }
                    // Under the caller's exclusive restart lease, prior committed prefixes are
                    // abandoned. This does not claim their lost, uncommitted callbacks survived.
                    try db.execute(sql: "UPDATE standardHRCaptureSession SET sealed=1 WHERE sealed=0")
                    try db.execute(sql: """
                        INSERT INTO standardHRCaptureSession(sessionID,projectURL,userID,runtimeGeneration,openedAt,sessionChargeBytes)
                        VALUES (?,?,?,?,?,?)
                        """, arguments: [id, owner.projectURL, owner.userID, runtimeGeneration.uuidString.lowercased(),
                            openedAtUnixSeconds, 512 + owner.projectURL.utf8.count + owner.userID.utf8.count])
                }
                return StandardHRCaptureSession(owner: owner, sessionID: sessionID, runtimeGeneration: runtimeGeneration)
            }
        } catch { throw Self.standardHRError(error) }
    }

    public func appendStandardHRCapture(_ batch: StandardHRFrozenBatch,
                                      session: StandardHRCaptureSession) async throws -> StandardHRLocalReceipt {
        try Task.checkCancellation()
        guard batch.id.sessionID == session.sessionID else { throw StandardHRCaptureError.identityConflict }
        guard batch.scope.environment == session.owner.projectURL, batch.scope.accountID == session.owner.userID else {
            throw StandardHRCaptureError.ownerMismatch
        }
        do {
            try standardHRWrite { db in
                try Self.standardHROwner(db, session.owner)
                try Self.standardHRSession(db, session)
                if let row = try Self.standardHRRow(db, id: batch.id) {
                    // Exact retries precede both sealed-session and capacity checks.
                    guard try Self.standardHRBatch(row, owner: session.owner) == batch else {
                        throw StandardHRCaptureError.identityConflict
                    }
                    return
                }
                try db.execute(sql: """
                    INSERT INTO standardHRCaptureOccurrence(sessionID,sequence,deviceID,hostTimestampSeconds,
                        schemaVersion,decoderVersion,mappingVersion,rawBytes,projectionJSON,rawSHA256,intentSHA256,chargeBytes)
                    VALUES (?,?,?,?,1,'standard-hr-current-v1','standard-hr-one-notification-v1',?,?,?,?,?)
                    """, arguments: [batch.id.sessionID.uuidString.lowercased(), batch.id.sequence, batch.scope.deviceID,
                        batch.hostTimestampSeconds, batch.rawBytes, batch.projectionJSON, batch.rawSHA256,
                        batch.intentSHA256, batch.chargeBytes])
            }
            return StandardHRLocalReceipt(batch)
        } catch { throw Self.standardHRError(error) }
    }

    public func sealStandardHRCapture(_ session: StandardHRCaptureSession) async throws {
        do {
            try standardHRWrite { db in
                try Self.standardHROwner(db, session.owner)
                try Self.standardHRSession(db, session)
                try db.execute(sql: "UPDATE standardHRCaptureSession SET sealed=1 WHERE sessionID=? AND sealed=0",
                    arguments: [session.sessionID.uuidString.lowercased()])
            }
        } catch { throw Self.standardHRError(error) }
    }

    public func projectNextStandardHRCapture(owner: StandardHRCaptureOwner) async throws -> StandardHRProjectionStep {
        let key = standardHRGateKey(owner)
        await StandardHRProjectionGate.shared.acquire(key)
        do {
            let result = try await standardHRProjectLocked(owner)
            await StandardHRProjectionGate.shared.release(key)
            return result
        } catch {
            await StandardHRProjectionGate.shared.release(key)
            throw Self.standardHRError(error)
        }
    }

    public func recoverStandardHRCapture(owner: StandardHRCaptureOwner, limit: Int = 64) async throws -> Int {
        try await recoverStandardHRCapture(owner: owner, limit: limit, gateObserver: nil)
    }

    func recoverStandardHRCapture(owner: StandardHRCaptureOwner, limit: Int = 64,
                                 gateObserver: StandardHRProjectionGateObserver?) async throws -> Int {
        guard (1...64).contains(limit) else { throw StandardHRCaptureError.invalidIntent }
        let key = standardHRGateKey(owner)
        await StandardHRProjectionGate.shared.acquire(key, observer: gateObserver)
        do {
            var completed = 0
            while completed < limit {
                if try await standardHRProjectLocked(owner) == .empty { break }
                completed += 1
            }
            await StandardHRProjectionGate.shared.release(key)
            return completed
        } catch {
            await StandardHRProjectionGate.shared.release(key)
            throw Self.standardHRError(error)
        }
    }

    private func standardHRGateKey(_ owner: StandardHRCaptureOwner) -> StandardHRProjectionKey {
        let path = dbWriter.path
        let canonical = path == ":memory:" || path.isEmpty
            ? "memory:\(ObjectIdentifier(dbWriter))"
            : URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return StandardHRProjectionKey(path: canonical, project: owner.projectURL, user: owner.userID)
    }

    private func standardHRProjectLocked(_ owner: StandardHRCaptureOwner) async throws -> StandardHRProjectionStep {
        try Task.checkCancellation()
        let row = try syncRead { db -> Row? in
            try Self.standardHROwner(db, owner)
            // Each session contributes one indexed pending lookup, at most 1024 sessions.
            return try Row.fetchOne(db, sql: """
                SELECT o.* FROM standardHRCaptureSession s JOIN standardHRCaptureOccurrence o
                  ON o.sessionID=s.sessionID AND o.sequence=(SELECT MIN(p.sequence)
                    FROM standardHRCaptureOccurrence p WHERE p.sessionID=s.sessionID AND p.projectionState=0)
                WHERE s.projectURL=? AND s.userID=? ORDER BY s.ordinal LIMIT 1
                """, arguments: [owner.projectURL, owner.userID])
        }
        guard let row else { return .empty }
        do {
            let batch = try Self.standardHRBatch(row, owner: owner)
            let streams = try StandardHRFrozenBatch.decodeProjection(batch.projectionJSON, timestamp: batch.hostTimestampSeconds)
            try Task.checkCancellation()
            // T2: existing canonical insertion and upload debt, one immutable notification.
            _ = try await insertAndMarkJobsOwed(streams, deviceId: batch.scope.deviceID,
                postOffloadJobKinds: [], note: nil, captureScope: batch.scope)
            // T3 is deliberately separate. A failure here retains T1 and replays T2 idempotently.
            try standardHRWrite { db in
                try Self.standardHROwner(db, owner)
                guard let current = try Self.standardHRRow(db, id: batch.id),
                      try Self.standardHRBatch(current, owner: owner) == batch else {
                    throw StandardHRCaptureError.integrityFailure
                }
                if (current["projectionState"] as Int) == 1 { return }
                try db.execute(sql: """
                    UPDATE standardHRCaptureOccurrence SET projectionState=1,projectedAt=?,lastFailureCode=NULL
                    WHERE sessionID=? AND sequence=? AND intentSHA256=? AND projectionState=0
                    """, arguments: [Int64(Date().timeIntervalSince1970), batch.id.sessionID.uuidString.lowercased(),
                        batch.id.sequence, batch.intentSHA256])
                guard db.changesCount == 1 else { throw StandardHRCaptureError.integrityFailure }
            }
            return .completed(id: batch.id, intentSHA256: batch.intentSHA256)
        } catch {
            // Bookkeeping must never turn a failed projection into a completed receipt.
            let code: String
            switch error {
            case StandardHRCaptureError.unsupportedVersion: code = "unsupported_version"
            case StandardHRCaptureError.integrityFailure, StandardHRCaptureError.invalidIntent: code = "integrity_failure"
            case is CancellationError: code = "cancelled"
            default: code = "projection_failed"
            }
            do {
                let witness = try StandardHRStoredBatch(row: row)
                try standardHRWrite { db in
                    try Self.standardHROwner(db, owner)
                    try db.execute(sql: """
                        UPDATE standardHRCaptureOccurrence
                        SET attempts=CASE WHEN attempts<9223372036854775807 THEN attempts+1 ELSE attempts END,lastFailureCode=?
                        WHERE sessionID=? AND sequence=? AND intentSHA256=? AND projectionState=0
                        """, arguments: [code, witness.sessionID, witness.sequence, witness.intentSHA256])
                }
            } catch { /* The committed pending row remains authoritative even if this write fails. */ }
            throw error
        }
    }

    /// Deferred read-then-write transactions can fail their WAL snapshot upgrade when two
    /// handles offer the same occurrence. Acquire SQLite's writer reservation before reading.
    private func standardHRWrite<T>(_ body: (Database) throws -> T) throws -> T {
        try dbWriter.writeWithoutTransaction { db in
            var result: T?
            try db.inTransaction(.immediate) {
                result = try body(db)
                return .commit
            }
            return result!
        }
    }

    private nonisolated static func standardHROwner(_ db: Database, _ owner: StandardHRCaptureOwner) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT projectURL,userID FROM localAccountOwner WHERE singleton=1") else {
            throw StandardHRCaptureError.unassignedOwner
        }
        guard (row["projectURL"] as String) == owner.projectURL, (row["userID"] as String) == owner.userID else {
            throw StandardHRCaptureError.ownerMismatch
        }
    }

    private nonisolated static func standardHRSession(_ db: Database, _ session: StandardHRCaptureSession) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM standardHRCaptureSession WHERE sessionID=?",
            arguments: [session.sessionID.uuidString.lowercased()]),
              (row["projectURL"] as String) == session.owner.projectURL, (row["userID"] as String) == session.owner.userID,
              (row["runtimeGeneration"] as String) == session.runtimeGeneration.uuidString.lowercased() else {
            throw StandardHRCaptureError.identityConflict
        }
    }

    private nonisolated static func standardHRRow(_ db: Database, id: StandardHRCaptureID) throws -> Row? {
        try Row.fetchOne(db, sql: "SELECT * FROM standardHRCaptureOccurrence WHERE sessionID=? AND sequence=?",
            arguments: [id.sessionID.uuidString.lowercased(), id.sequence])
    }

    private nonisolated static func standardHRBatch(_ row: Row, owner: StandardHRCaptureOwner) throws -> StandardHRFrozenBatch {
        let stored: StandardHRStoredBatch
        do { stored = try StandardHRStoredBatch(row: row) }
        catch { throw StandardHRCaptureError.integrityFailure }
        guard stored.schemaVersion == 1, stored.decoderVersion == "standard-hr-current-v1",
              stored.mappingVersion == "standard-hr-one-notification-v1" else {
            throw StandardHRCaptureError.unsupportedVersion
        }
        do {
            let text = stored.sessionID
            guard let uuid = UUID(uuidString: text), uuid.uuidString.lowercased() == text else {
                throw StandardHRCaptureError.integrityFailure
            }
            let batch = try StandardHRFrozenBatch(id: StandardHRCaptureID(sessionID: uuid, sequence: stored.sequence),
                scope: DurableIngestScope(environment: owner.projectURL, accountID: owner.userID, deviceID: stored.deviceID),
                hostTimestampSeconds: stored.hostTimestampSeconds, rawBytes: stored.rawBytes, projectionJSON: stored.projectionJSON)
            guard batch.rawSHA256 == stored.rawSHA256, batch.intentSHA256 == stored.intentSHA256,
                  batch.chargeBytes == stored.chargeBytes else { throw StandardHRCaptureError.integrityFailure }
            return batch
        } catch { throw StandardHRCaptureError.integrityFailure }
    }

    private nonisolated static func standardHRError(_ error: Error) -> Error {
        if error is StandardHRCaptureError || error is CancellationError { return error }
        if let db = error as? DatabaseError {
            switch db.message {
            case "standardHR.capacity": return StandardHRCaptureError.capacity
            case "standardHR.closed": return StandardHRCaptureError.closedSession
            case "standardHR.sequence": return StandardHRCaptureError.sequenceGap
            case "standardHR.owner": return StandardHRCaptureError.ownerMismatch
            case "standardHR.identity": return StandardHRCaptureError.identityConflict
            case "standardHR.integrity": return StandardHRCaptureError.integrityFailure
            default: break
            }
        }
        return StandardHRCaptureError.storageUnavailable
    }
}
