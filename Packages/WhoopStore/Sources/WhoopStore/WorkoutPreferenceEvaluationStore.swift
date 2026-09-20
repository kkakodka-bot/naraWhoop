import Foundation
import CryptoKit
import GRDB

public enum WorkoutPreferenceEvaluation {
    public enum Failure: Error, Equatable {
        case invalidTarget, unboundOwner, wrongOwner, retired, cancelled
        case staleHead, stalePreference, conflictingPreferenceIdentity
        case unsupportedFormat, invalidState, unsupportedSchema, counterExhausted
    }

    public struct Digest: Codable, Equatable, Sendable {
        public let bytes: Data
        public init(bytes: Data) throws {
            guard bytes.count == 32 else { throw Failure.invalidTarget }
            self.bytes = bytes
        }
        public init(hex: String) throws {
            let characters = Array(hex.utf8)
            guard characters.count == 64 else { throw Failure.invalidTarget }
            func nibble(_ value: UInt8) throws -> UInt8 {
                switch value {
                case 48...57: return value - 48
                case 65...70: return value - 55
                case 97...102: return value - 87
                default: throw Failure.invalidTarget
                }
            }
            var result = Data()
            for index in stride(from: 0, to: 64, by: 2) {
                result.append(try nibble(characters[index]) * 16 + nibble(characters[index + 1]))
            }
            try self.init(bytes: result)
        }
        public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
        fileprivate static func hash(_ bytes: Data) -> Self { Self(unchecked: Data(SHA256.hash(data: bytes))) }
        private init(unchecked bytes: Data) { self.bytes = bytes }
    }

    public struct Owner: Codable, Equatable, Sendable {
        public let projectURL: String
        public let userID: String
        public init(projectURL: String, userID: String) throws {
            guard !projectURL.isEmpty, projectURL.utf8.count <= 2048,
                  URL(string: projectURL)?.host != nil, !projectURL.contains("\0"),
                  userID.utf8.count == 36, UUID(uuidString: userID) != nil else { throw Failure.invalidTarget }
            self.projectURL = projectURL
            self.userID = userID
        }
    }

    public struct Preference: Codable, Equatable, Sendable {
        public let sequence: Int64
        public let id: UUID?
        public let identity: Digest
        public init(sequence: Int64, id: UUID?, identity: Digest) throws {
            guard sequence >= 0, (sequence == 0) == (id == nil), identity.bytes.count == 32 else {
                throw Failure.invalidTarget
            }
            self.sequence = sequence
            self.id = id
            self.identity = identity
        }
    }

    public struct Request: Codable, Equatable, Sendable {
        public let owner: Owner
        public let preference: Preference
        public let canonicalWriter: String
        public let requestedDays: Int
        public let localDayAnchor: String
        public let timezoneID: String
        public let offsetSeconds: Int
        public let dependencyDigest: Digest

        public init(owner: Owner, preference: Preference, canonicalWriter: String,
                    requestedDays: Int, localDayAnchor: String, timezoneID: String,
                    offsetSeconds: Int, dependencyDigest: Digest) throws {
            // Codable input does not pass through the checked public initializers.
            _ = try Owner(projectURL: owner.projectURL, userID: owner.userID)
            _ = try Preference(sequence: preference.sequence, id: preference.id, identity: preference.identity)
            guard !canonicalWriter.isEmpty, canonicalWriter.utf8.count <= 1024,
                  !canonicalWriter.contains("\0"), requestedDays >= 21,
                  requestedDays <= Int(Int64.max / 86400),
                  !localDayAnchor.isEmpty, localDayAnchor.utf8.count <= 64,
                  timezoneID.utf8.count <= 128, TimeZone(identifier: timezoneID) != nil,
                  (-86400...86400).contains(offsetSeconds), dependencyDigest.bytes.count == 32 else {
                throw Failure.invalidTarget
            }
            self.owner = owner
            self.preference = preference
            self.canonicalWriter = canonicalWriter
            self.requestedDays = requestedDays
            self.localDayAnchor = localDayAnchor
            self.timezoneID = timezoneID
            self.offsetSeconds = offsetSeconds
            self.dependencyDigest = dependencyDigest
        }
    }

    public struct Target: Codable, Equatable, Sendable {
        public let request: Request
        public let lowerTs: Int64
        public let upperTs: Int64
        public let version: Int
        public let sourcePolicy: String
        public init(request: Request, lowerTs: Int64, upperTs: Int64) throws {
            _ = try Request(owner: request.owner, preference: request.preference,
                            canonicalWriter: request.canonicalWriter, requestedDays: request.requestedDays,
                            localDayAnchor: request.localDayAnchor, timezoneID: request.timezoneID,
                            offsetSeconds: request.offsetSeconds, dependencyDigest: request.dependencyDigest)
            let (span, overflow) = upperTs.subtractingReportingOverflow(lowerTs)
            guard !overflow, span >= Int64(request.requestedDays) * 86400 else { throw Failure.invalidTarget }
            self.request = request
            self.lowerTs = lowerTs
            self.upperTs = upperTs
            self.version = 1
            self.sourcePolicy = "all-store-owners-start-inclusive-v1"
            guard try WPECodec.encode(self).count <= 4096 else { throw Failure.invalidTarget }
        }
        public var digest: Digest { get throws { .hash(try WPECodec.encode(self)) } }
    }

    public struct CorePassWitness: Codable, Equatable, Sendable {
        public let targetDigest: Digest
        public let dependencyDigest: Digest
        public let capturedRescoreJobToken: String?
        public let legacyAttemptToken: String?
        public init(targetDigest: Digest, dependencyDigest: Digest,
                    capturedRescoreJobToken: String?, legacyAttemptToken: String?) throws {
            guard targetDigest.bytes.count == 32, dependencyDigest.bytes.count == 32 else { throw Failure.invalidTarget }
            for token in [capturedRescoreJobToken, legacyAttemptToken].compactMap({ $0 }) {
                guard !token.isEmpty, token.utf8.count <= 128 else { throw Failure.invalidTarget }
            }
            self.targetDigest = targetDigest
            self.dependencyDigest = dependencyDigest
            self.capturedRescoreJobToken = capturedRescoreJobToken
            self.legacyAttemptToken = legacyAttemptToken
        }
    }

    public struct Counts: Codable, Equatable, Sendable {
        public fileprivate(set) var totalRows: Int64 = 0
        public fileprivate(set) var manualPopulatedUnknown: Int64 = 0
        public fileprivate(set) var manualNilDeferred: Int64 = 0
        public fileprivate(set) var potentialRealBackfillDeferred: Int64 = 0
        public fileprivate(set) var unknownSource: Int64 = 0
        public fileprivate(set) var retainedNonmanual: Int64 = 0
        public fileprivate(set) var managedDetected: Int64 = 0
        public var hasBlockers: Bool {
            manualPopulatedUnknown > 0 || manualNilDeferred > 0 || potentialRealBackfillDeferred > 0 || unknownSource > 0
        }
    }

    public enum HoldReason: String, Codable, Sendable {
        case oversizedRow, oversizedKey, malformedRow, metadataCapacity
        case unsupportedMetadata, revisionExhausted
    }
    public enum RetryReason: String, Codable, Sendable { case requiredRead, requiredWrite, transientBusy, interruption }
    public enum AdmissionMode: Sendable { case automatic, explicitRetry, refreshCore }
    public enum Disposition: Equatable, Sendable {
        case needsCorePass, needsEvaluation, needsValidation, continuation, evaluatedPartial, complete
        case held(HoldReason), retryAfter(Int64)
    }
    public enum Outcome: String, Codable, Sendable { case evaluatedPartial, complete }

    public struct Head: Equatable, Sendable {
        public let storeID: UUID
        public let stateSerial: Int64
        public let workoutRevision: Int64
        public let revisionOverflow: Bool
        public let evaluationID: UUID?
        fileprivate let stateDigest: Digest
    }
    public struct Lease: Sendable {
        public let head: Head
        public let target: Target
        public let evaluationID: UUID
        public let rescoreJobToken: String?
        fileprivate let instance: String
    }
    public struct Receipt: Sendable {
        public let target: Target
        public let coreWitness: CorePassWitness
        public let revision: Int64
        public let digest: Digest
        public let counts: Counts
        public let outcome: Outcome
    }
    public struct ValidatedReceipt: Sendable {
        public let receipt: Receipt
        public let head: Head
        fileprivate let instance: String
    }
    public struct View: Sendable {
        public let head: Head
        public let lease: Lease?
        public let disposition: Disposition
        public let counts: Counts
        public let validatedReceipt: ValidatedReceipt?
        public var hasUnresolvedWork: Bool { disposition != .complete }
        public var membershipComplete: Bool { validatedReceipt != nil }
        public func hasRunnableWork(at now: Int64) -> Bool {
            switch disposition {
            case .held, .evaluatedPartial, .complete: return false
            case .retryAfter(let deadline): return now >= deadline
            default: return true
            }
        }
    }
    public struct Step: Sendable {
        public let view: View
        public let rowsProcessed: Int
        public let bytesProcessed: Int
        public let yielded: Bool
    }
}

public final class WorkoutEvaluationPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    public init() {}
    public func invalidate() { lock.lock(); valid = false; lock.unlock() }
    fileprivate func check() throws {
        lock.lock(); defer { lock.unlock() }
        if !valid { throw WorkoutPreferenceEvaluation.Failure.retired }
    }
}

public final class WorkoutEvaluationSession: @unchecked Sendable {
    fileprivate let owner: WorkoutPreferenceEvaluation.Owner
    fileprivate let runtimeFence: StoreWriteFence
    fileprivate let instance: String
    private let lock = NSLock()
    private var valid = true
    private var trusted: WorkoutPreferenceEvaluation.Head?
    private var validation: WPEValidation?
    fileprivate init(owner: WorkoutPreferenceEvaluation.Owner, runtimeFence: StoreWriteFence, instance: String) {
        self.owner = owner; self.runtimeFence = runtimeFence; self.instance = instance
    }
    public func invalidate() { lock.lock(); valid = false; lock.unlock() }
    fileprivate func check(instance: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard valid, self.instance == instance, runtimeFence.isValid else {
            throw WorkoutPreferenceEvaluation.Failure.retired
        }
    }
    fileprivate func trustedHead() -> WorkoutPreferenceEvaluation.Head? {
        lock.lock(); defer { lock.unlock() }; return trusted
    }
    fileprivate func trust(_ head: WorkoutPreferenceEvaluation.Head) {
        lock.lock(); defer { lock.unlock() }; trusted = head; validation = nil
    }
    fileprivate func validationProgress() -> WPEValidation? {
        lock.lock(); defer { lock.unlock() }; return validation
    }
    fileprivate func saveValidation(_ progress: WPEValidation?) {
        lock.lock(); defer { lock.unlock() }; validation = progress
    }
    fileprivate func checkpoint() -> (WorkoutPreferenceEvaluation.Head?, WPEValidation?) {
        lock.lock(); defer { lock.unlock() }; return (trusted, validation)
    }
    fileprivate func restore(_ checkpoint: (WorkoutPreferenceEvaluation.Head?, WPEValidation?)) {
        lock.lock(); defer { lock.unlock() }; (trusted, validation) = checkpoint
    }
}

private enum WPECodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decodeState(_ bytes: Data) throws -> WPEState {
        guard bytes.count <= 32768 else { throw WPE.Failure.invalidState }
        let state = try JSONDecoder().decode(WPEState.self, from: bytes)
        guard try encode(state) == bytes else { throw WPE.Failure.invalidState }
        return state
    }
}

private typealias WPE = WorkoutPreferenceEvaluation

private struct WPECursor: Codable, Equatable, Sendable {
    let startTs: Int64
    let deviceId: String
    let sport: String
}

private struct WPEProgress: Codable, Equatable, Sendable {
    var cursor: WPECursor?
    var digest: WPE.Digest
    var counts = WPE.Counts()
    static func empty(target: WPE.Target) throws -> Self {
        Self(digest: .hash(Data("WPE-members-v1".utf8) + (try target.digest.bytes)))
    }
    func finalDigest() throws -> WPE.Digest {
        .hash(Data("WPE-eof-v1".utf8) + digest.bytes + (try WPECodec.encode(counts)))
    }
}

private struct WPERetry: Codable, Equatable, Sendable {
    let reason: WPE.RetryReason
    let attempt: Int
    let notBefore: Int64
}

private struct WPEState: Codable, Equatable, Sendable {
    enum Phase: String, Codable { case needsCore, scanning, sealed, resourceHeld }
    var version = 1
    var target: WPE.Target?
    var evaluationID: UUID?
    var phase = Phase.needsCore
    var expectedRevision: Int64 = 0
    var rescoreToken: String?
    var rescoreSettled = false
    var core: WPE.CorePassWitness?
    var progress: WPEProgress?
    var resource: WPE.HoldReason?
    var retry: WPERetry?
}

private struct WPEControl {
    var head: WPE.Head
    var state: WPEState
}

private struct WPEValidation: Sendable {
    let head: WPE.Head
    var progress: WPEProgress
}

private struct WPEPage {
    var progress: WPEProgress
    var rows: Int = 0
    var bytes: Int = 0
    var eof = false
    var resource: WPE.HoldReason?
}

private final class WPECommitObserver: TransactionObserver {
    let check: () throws -> Void
    init(check: @escaping () throws -> Void) { self.check = check }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseWillCommit() throws { try check() }
    func databaseDidCommit(_ db: Database) {}
    func databaseDidRollback(_ db: Database) {}
}

private enum WPEStorage {
    static let columns = ["deviceId", "startTs", "endTs", "sport", "source", "durationS", "energyKcal",
                          "avgHr", "maxHr", "strain", "distanceM", "zonesJSON", "notes", "steps"]

    static func triggerSQL(suffix: String, event: String) -> String {
        """
        CREATE TRIGGER workout_preference_\(suffix)_v1 AFTER \(event) ON workout BEGIN
            UPDATE workoutPreferenceEvaluation SET
                revisionOverflow = CASE WHEN workoutRevision = 9223372036854775807
                                       THEN 1 ELSE revisionOverflow END,
                workoutRevision = CASE WHEN workoutRevision < 9223372036854775807
                                       THEN workoutRevision + 1 ELSE workoutRevision END
            WHERE singleton = 1;
        END;
        """
    }

    static func checkSchema(_ db: Database) throws {
        func normalized(_ sql: String) -> String {
            sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "; "))
        }
        for (suffix, event) in [("insert", "INSERT"), ("update", "UPDATE"), ("delete", "DELETE")] {
            guard let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_schema WHERE type='trigger' AND name=?",
                                               arguments: ["workout_preference_\(suffix)_v1"]),
                  normalized(sql) == normalized(triggerSQL(suffix: suffix, event: event)) else {
                throw WPE.Failure.unsupportedSchema
            }
        }
        guard let index = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_schema WHERE type='index' AND name='workout_preference_window_v1'"),
              normalized(index) == normalized("CREATE INDEX workout_preference_window_v1 ON workout(startTs, deviceId COLLATE BINARY, sport COLLATE BINARY)") else {
            throw WPE.Failure.unsupportedSchema
        }
        let names = try Row.fetchAll(db, sql: "PRAGMA table_info(workoutPreferenceEvaluation)").map { $0["name"] as String }
        guard names == ["singleton", "formatVersion", "storeID", "workoutRevision", "revisionOverflow", "stateSerial", "stateBytes", "stateSHA256"] else {
            throw WPE.Failure.unsupportedSchema
        }
    }

    static func checkOwner(_ db: Database, _ owner: WPE.Owner) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT projectURL,userID FROM localAccountOwner WHERE singleton=1") else {
            throw WPE.Failure.unboundOwner
        }
        guard row["projectURL"] as String == owner.projectURL, row["userID"] as String == owner.userID else {
            throw WPE.Failure.wrongOwner
        }
    }

    static func token(_ db: Database) throws -> String? {
        let token = try String.fetchOne(db, sql: "SELECT token FROM syncJob WHERE kind='rescore'")
        if let token, token.isEmpty || token.utf8.count > 128 { throw WPE.Failure.invalidState }
        return token
    }

    static func tokenMatches(_ state: WPEState, _ current: String?) -> Bool {
        state.rescoreToken == current || (state.rescoreSettled && current == nil)
    }

    static func uuidBytes(_ value: UUID) -> Data {
        var tuple = value.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }
    static func uuid(_ bytes: Data) throws -> UUID {
        guard bytes.count == 16 else { throw WPE.Failure.invalidState }
        let b = Array(bytes)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    static func load(_ db: Database) throws -> WPEControl {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT storeID,formatVersion,workoutRevision,revisionOverflow,stateSerial,stateSHA256,
                   typeof(formatVersion) AS formatType,typeof(workoutRevision) AS revisionType,
                   typeof(revisionOverflow) AS overflowType,typeof(stateSerial) AS serialType,
                   length(stateBytes) AS size,
                   CASE WHEN length(stateBytes)<=32768 THEN stateBytes ELSE NULL END AS stateBytes
            FROM workoutPreferenceEvaluation WHERE singleton=1
            """) else { throw WPE.Failure.invalidState }
        guard ["formatType", "revisionType", "overflowType", "serialType"].allSatisfy({ row[$0] as String == "integer" }) else {
            throw WPE.Failure.invalidState
        }
        guard row["formatVersion"] as Int64 == 1 else { throw WPE.Failure.unsupportedFormat }
        guard let bytes: Data = row["stateBytes"], bytes.count <= 32768,
              let digest: Data = row["stateSHA256"], digest == WPE.Digest.hash(bytes).bytes else {
            throw WPE.Failure.invalidState
        }
        let state: WPEState
        do {
            state = try WPECodec.decodeState(bytes)
            guard try WPECodec.encode(state) == bytes else { throw WPE.Failure.invalidState }
            try validate(state)
        } catch { throw WPE.Failure.invalidState }
        let revision: Int64 = row["workoutRevision"]
        let serial: Int64 = row["stateSerial"]
        guard revision >= 0, serial >= 0, [Int64(0), 1].contains(row["revisionOverflow"] as Int64) else { throw WPE.Failure.invalidState }
        let head = WPE.Head(storeID: try uuid(row["storeID"]), stateSerial: serial, workoutRevision: revision,
                            revisionOverflow: (row["revisionOverflow"] as Int) != 0,
                            evaluationID: state.evaluationID, stateDigest: try .init(bytes: digest))
        return WPEControl(head: head, state: state)
    }

    static func validate(_ state: WPEState) throws {
        guard state.version == 1, state.expectedRevision >= 0 else { throw WPE.Failure.invalidState }
        guard let target = state.target else {
            guard state == WPEState() else { throw WPE.Failure.invalidState }
            return
        }
        let request = target.request
        _ = try WPE.Owner(projectURL: request.owner.projectURL, userID: request.owner.userID)
        _ = try WPE.Preference(sequence: request.preference.sequence, id: request.preference.id, identity: request.preference.identity)
        _ = try WPE.Request(owner: request.owner, preference: request.preference,
                            canonicalWriter: request.canonicalWriter, requestedDays: request.requestedDays,
                            localDayAnchor: request.localDayAnchor, timezoneID: request.timezoneID,
                            offsetSeconds: request.offsetSeconds, dependencyDigest: request.dependencyDigest)
        guard try WPE.Target(request: request, lowerTs: target.lowerTs, upperTs: target.upperTs) == target,
              state.evaluationID != nil, let progress = state.progress, progress.digest.bytes.count == 32 else {
            throw WPE.Failure.invalidState
        }
        let c = progress.counts
        let primary = [c.manualPopulatedUnknown, c.manualNilDeferred, c.unknownSource, c.retainedNonmanual, c.managedDetected]
        guard c.totalRows >= 0, primary.allSatisfy({ $0 >= 0 && $0 <= c.totalRows }),
              c.potentialRealBackfillDeferred >= 0, c.potentialRealBackfillDeferred <= c.totalRows else {
            throw WPE.Failure.invalidState
        }
        var total: Int64 = 0
        for count in primary {
            let (sum, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { throw WPE.Failure.invalidState }; total = sum
        }
        guard total == c.totalRows, (c.totalRows == 0) == (progress.cursor == nil) else { throw WPE.Failure.invalidState }
        if let cursor = progress.cursor {
            guard (target.lowerTs...target.upperTs).contains(cursor.startTs),
                  cursor.deviceId.utf8.count <= 1024, cursor.sport.utf8.count <= 1024 else { throw WPE.Failure.invalidState }
        }
        if state.phase == .scanning || state.phase == .sealed || state.phase == .resourceHeld {
            guard let core = state.core, try core.targetDigest == target.digest,
                  core.dependencyDigest == request.dependencyDigest, core.capturedRescoreJobToken == state.rescoreToken else {
                throw WPE.Failure.invalidState
            }
        }
        if let core = state.core {
            _ = try WPE.CorePassWitness(targetDigest: core.targetDigest, dependencyDigest: core.dependencyDigest,
                                        capturedRescoreJobToken: core.capturedRescoreJobToken, legacyAttemptToken: core.legacyAttemptToken)
        }
        if let retry = state.retry {
            guard (1...64).contains(retry.attempt) else { throw WPE.Failure.invalidState }
        }
        guard (state.phase == .resourceHeld) == (state.resource != nil) else { throw WPE.Failure.invalidState }
    }

    static func save(_ db: Database, state: WPEState, previous: WPEControl) throws -> WPEControl {
        try validate(state)
        guard previous.head.stateSerial < Int64.max else { throw WPE.Failure.counterExhausted }
        let bytes = try WPECodec.encode(state)
        guard bytes.count <= 32768 else { throw WPE.Failure.invalidState }
        try db.execute(sql: """
            UPDATE workoutPreferenceEvaluation SET stateSerial=?,stateBytes=?,stateSHA256=?
            WHERE singleton=1 AND storeID=? AND stateSerial=? AND workoutRevision=? AND revisionOverflow=0
            """, arguments: [previous.head.stateSerial + 1, bytes, WPE.Digest.hash(bytes).bytes,
                               uuidBytes(previous.head.storeID), previous.head.stateSerial, previous.head.workoutRevision])
        guard db.changesCount == 1 else { throw WPE.Failure.staleHead }
        return try load(db)
    }

    static func compatible(_ stored: WPE.Request, _ requested: WPE.Request) -> Bool {
        stored.owner == requested.owner && stored.preference == requested.preference &&
        stored.canonicalWriter.utf8.elementsEqual(requested.canonicalWriter.utf8) && stored.requestedDays >= requested.requestedDays &&
        stored.localDayAnchor == requested.localDayAnchor && stored.timezoneID == requested.timezoneID &&
        stored.offsetSeconds == requested.offsetSeconds && stored.dependencyDigest == requested.dependencyDigest
    }

    static func checkPreference(_ stored: WPE.Preference?, _ requested: WPE.Preference) throws {
        guard let stored else { return }
        guard requested.sequence >= stored.sequence else { throw WPE.Failure.stalePreference }
        if requested.sequence == stored.sequence, requested != stored { throw WPE.Failure.conflictingPreferenceIdentity }
    }

    static func lease(_ control: WPEControl, instance: String) -> WPE.Lease? {
        guard let target = control.state.target, let id = control.state.evaluationID else { return nil }
        return WPE.Lease(head: control.head, target: target, evaluationID: id,
                          rescoreJobToken: control.state.rescoreToken, instance: instance)
    }

    static func matchesCoreLease(_ control: WPEControl, lease: WPE.Lease,
                                 session: WorkoutEvaluationSession) -> Bool {
        lease.instance == session.instance && control.head.storeID == lease.head.storeID &&
        control.head.stateSerial == lease.head.stateSerial && control.head.stateDigest == lease.head.stateDigest &&
        control.head.workoutRevision >= lease.head.workoutRevision && !control.head.revisionOverflow &&
        control.state.phase == .needsCore && control.state.evaluationID == lease.evaluationID &&
        control.state.target == lease.target && control.state.rescoreToken == lease.rescoreJobToken
    }

    static func receipt(_ control: WPEControl, instance: String) throws -> WPE.ValidatedReceipt {
        guard let target = control.state.target, let core = control.state.core,
              let progress = control.state.progress, control.state.phase == .sealed,
              control.head.workoutRevision == control.state.expectedRevision,
              !control.head.revisionOverflow else { throw WPE.Failure.invalidState }
        let receipt = WPE.Receipt(target: target, coreWitness: core, revision: control.head.workoutRevision,
                                  digest: try progress.finalDigest(), counts: progress.counts,
                                  outcome: progress.counts.hasBlockers ? .evaluatedPartial : .complete)
        return WPE.ValidatedReceipt(receipt: receipt, head: control.head, instance: instance)
    }

    static func view(_ control: WPEControl, session: WorkoutEvaluationSession,
                     request: WPE.Request, token: String?, now: Int64) throws -> WPE.View {
        var disposition = WPE.Disposition.needsCorePass
        var validated: WPE.ValidatedReceipt?
        var usableLease: WPE.Lease?
        if control.head.revisionOverflow || control.head.stateSerial == Int64.max {
            disposition = .held(.revisionExhausted)
        } else if let target = control.state.target, compatible(target.request, request),
                  tokenMatches(control.state, token) {
            usableLease = lease(control, instance: session.instance)
            if let retry = control.state.retry, now < retry.notBefore {
                disposition = .retryAfter(retry.notBefore)
            } else if control.state.phase == .needsCore || control.state.expectedRevision != control.head.workoutRevision {
                disposition = .needsCorePass
            } else if control.state.phase == .resourceHeld {
                disposition = .held(control.state.resource ?? .unsupportedMetadata)
            } else if session.trustedHead() != control.head {
                disposition = .needsValidation
            } else if control.state.phase == .sealed {
                validated = try receipt(control, instance: session.instance)
                disposition = validated?.receipt.outcome == .complete ? .complete : .evaluatedPartial
            } else {
                disposition = .continuation
            }
        }
        return WPE.View(head: control.head, lease: usableLease, disposition: disposition,
                         counts: control.state.progress?.counts ?? .init(), validatedReceipt: validated)
    }

    static func page(_ db: Database, target: WPE.Target, progress: WPEProgress,
                     through: WPECursor? = nil) throws -> WPEPage {
        var sql = "SELECT rowid"
        for (i, column) in columns.enumerated() {
            sql += ",typeof(\(column)) AS t\(i),CASE WHEN typeof(\(column)) IN ('text','blob') "
                + "THEN length(CAST(\(column) AS BLOB)) ELSE 0 END AS n\(i)"
        }
        sql += " FROM workout WHERE startTs>=? AND startTs<=?"
        var arguments: [DatabaseValue] = [target.lowerTs.databaseValue, target.upperTs.databaseValue]
        if let cursor = progress.cursor {
            sql += " AND (startTs,deviceId COLLATE BINARY,sport COLLATE BINARY)>(?,CAST(? AS TEXT),CAST(? AS TEXT))"
            arguments += [cursor.startTs.databaseValue, Data(cursor.deviceId.utf8).databaseValue, Data(cursor.sport.utf8).databaseValue]
        }
        if let cursor = through {
            sql += " AND (startTs,deviceId COLLATE BINARY,sport COLLATE BINARY)<=(?,CAST(? AS TEXT),CAST(? AS TEXT))"
            arguments += [cursor.startTs.databaseValue, Data(cursor.deviceId.utf8).databaseValue, Data(cursor.sport.utf8).databaseValue]
        }
        sql += " ORDER BY startTs,deviceId COLLATE BINARY,sport COLLATE BINARY LIMIT 129"
        let metadata = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        var page = WPEPage(progress: progress)
        let textColumns: Set<Int> = [0, 3, 4, 11, 12]
        let integerColumns: Set<Int> = [1, 2, 7, 8, 13]
        let mandatory: Set<Int> = [0, 1, 2, 3, 4]
        for meta in metadata {
            if page.rows == 128 { break }
            var estimated = 5
            for i in columns.indices {
                let type: String = meta["t\(i)"]
                let length: Int64 = meta["n\(i)"]
                guard length >= 0, length <= 65536 else { page.resource = .oversizedRow; return page }
                if (i == 0 || i == 3), length > 1024 { page.resource = .oversizedKey; return page }
                let valid: Bool
                if type == "null" { valid = !mandatory.contains(i) }
                else if textColumns.contains(i) { valid = type == "text" }
                else if integerColumns.contains(i) { valid = type == "integer" }
                else { valid = type == "real" || type == "integer" }
                guard valid else { page.resource = .malformedRow; return page }
                estimated += type == "null" ? 1 : 9 + Int(length)
            }
            guard estimated <= 65536 else { page.resource = .oversizedRow; return page }
            if page.bytes + estimated > 262144 { break }
            // CAST text to BLOB: GRDB 6's String(cString:) read would truncate embedded NUL.
            let selections = columns.enumerated().map { i, name in
                textColumns.contains(i) ? "CAST(\(name) AS BLOB) AS c\(i)" : "\(name) AS c\(i)"
            }.joined(separator: ",")
            guard let row = try Row.fetchOne(db, sql: "SELECT \(selections) FROM workout WHERE rowid=?",
                                            arguments: [meta["rowid"] as Int64]) else { throw WPE.Failure.staleHead }
            var frame = Data("WER1".utf8)
            func append64(_ number: UInt64) {
                var number = number.bigEndian
                withUnsafeBytes(of: &number) { frame.append(contentsOf: $0) }
            }
            var text: [Int: String] = [:]
            var nulls = Set<Int>()
            for i in columns.indices {
                let type: String = meta["t\(i)"]
                switch type {
                case "null": frame.append(0); nulls.insert(i)
                case "integer": frame.append(1); append64(UInt64(bitPattern: row["c\(i)"] as Int64))
                case "real":
                    let value: Double = row["c\(i)"]
                    guard value.isFinite else { page.resource = .malformedRow; return page }
                    frame.append(2); append64(value.bitPattern)
                case "text":
                    let bytes: Data = row["c\(i)"]
                    guard Int64(bytes.count) == meta["n\(i)"] as Int64,
                          let string = String(data: bytes, encoding: .utf8) else { page.resource = .malformedRow; return page }
                    frame.append(3); append64(UInt64(bytes.count)); frame.append(bytes); text[i] = string
                default: page.resource = .malformedRow; return page
                }
            }
            guard let owner = text[0], let sport = text[3], let source = text[4] else { throw WPE.Failure.invalidState }
            let computed = target.request.canonicalWriter + "-noop"
            var counts = page.progress.counts
            guard counts.totalRows < Int64.max else { throw WPE.Failure.counterExhausted }
            counts.totalRows += 1
            var flags: UInt8 = 0
            if source == "manual" {
                if nulls.contains(9) { counts.manualNilDeferred += 1; flags = 2 }
                else { counts.manualPopulatedUnknown += 1; flags = 1 }
            } else if owner.utf8.elementsEqual(computed.utf8), source.utf8.elementsEqual(computed.utf8), sport == "detected" {
                counts.managedDetected += 1; flags = 4
            } else if ["whoop", "apple-health", "apple_health", "lifting", "activity-file"].contains(source) {
                counts.retainedNonmanual += 1; flags = 8
            } else { counts.unknownSource += 1; flags = 16 }
            if flags != 4, !nulls.isDisjoint(with: [6, 7, 8, 9]) {
                counts.potentialRealBackfillDeferred += 1; flags |= 32
            }
            frame.append(flags)
            guard frame.count <= 65536, page.bytes + frame.count <= 262144 else { throw WPE.Failure.invalidState }
            page.progress.digest = .hash(Data("WPE-link-v1".utf8) + page.progress.digest.bytes + WPE.Digest.hash(frame).bytes)
            page.progress.counts = counts
            page.progress.cursor = WPECursor(startTs: row["c1"], deviceId: owner, sport: sport)
            page.rows += 1; page.bytes += frame.count
        }
        page.eof = page.rows == metadata.count
        return page
    }
}

extension WhoopStore {
    private func evaluationWrite<T>(session: WorkoutEvaluationSession, permit: WorkoutEvaluationPermit?,
                                    cancellation: StoreWriteFence, _ body: (Database) throws -> T) throws -> T {
        let instance = revisionInstanceToken
        try session.check(instance: instance)
        try permit?.check()
        let cache = session.checkpoint()
        do { return try dbWriter.writeWithoutTransaction { db in
            let observer = WPECommitObserver {
                try session.check(instance: instance)
                try permit?.check()
                guard cancellation.isValid else { throw WPE.Failure.cancelled }
            }
            db.add(transactionObserver: observer, extent: .observerLifetime)
            defer { db.remove(transactionObserver: observer) }
            var output: Result<T, Error>?
            try db.inTransaction(.immediate) {
                try session.check(instance: instance)
                try permit?.check()
                guard cancellation.isValid else { throw WPE.Failure.cancelled }
                try WPEStorage.checkOwner(db, session.owner)
                output = .success(try body(db))
                return .commit
            }
            guard let output else { throw WPE.Failure.invalidState }
            return try output.get()
        } } catch {
            // No cancelled/rolled-back transaction may publish session-local proof.
            // Store serializes these closures; retirement never reactivates this cache.
            session.restore(cache)
            throw error
        }
    }

    public func openWorkoutPreferenceEvaluation(owner: WorkoutPreferenceEvaluation.Owner,
                                                runtimeFence: StoreWriteFence) async throws -> WorkoutEvaluationSession {
        let session = WorkoutEvaluationSession(owner: owner, runtimeFence: runtimeFence, instance: revisionInstanceToken)
        let cancellation = StoreWriteFence()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try evaluationWrite(session: session, permit: nil, cancellation: cancellation) { db in
                try WPEStorage.checkSchema(db)
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM workoutPreferenceEvaluation)") == true
                if !exists {
                    let bytes = try WPECodec.encode(WPEState())
                    try db.execute(sql: """
                        INSERT INTO workoutPreferenceEvaluation
                        (singleton,formatVersion,storeID,workoutRevision,revisionOverflow,stateSerial,stateBytes,stateSHA256)
                        VALUES(1,1,?,0,0,0,?,?)
                        """, arguments: [WPEStorage.uuidBytes(UUID()), bytes, WPE.Digest.hash(bytes).bytes])
                }
            }
            return session
        } onCancel: { cancellation.invalidate() }
    }

    public func inspectWorkoutPreferenceEvaluation(session: WorkoutEvaluationSession,
                                                    request: WorkoutPreferenceEvaluation.Request,
                                                    now: Int64) async throws -> WorkoutPreferenceEvaluation.View {
        try Task.checkCancellation()
        try session.check(instance: revisionInstanceToken)
        guard request.owner == session.owner else { throw WPE.Failure.wrongOwner }
        let view = try syncRead { db in
            try WPEStorage.checkOwner(db, session.owner)
            let control = try WPEStorage.load(db)
            try WPEStorage.checkPreference(control.state.target?.request.preference, request.preference)
            return try WPEStorage.view(control, session: session, request: request, token: WPEStorage.token(db), now: now)
        }
        try session.check(instance: revisionInstanceToken)
        return view
    }

    public func admitWorkoutPreferenceEvaluation(session: WorkoutEvaluationSession,
                                                 expected: WorkoutPreferenceEvaluation.Head,
                                                 target: WorkoutPreferenceEvaluation.Target,
                                                 permit: WorkoutEvaluationPermit,
                                                 mode: WorkoutPreferenceEvaluation.AdmissionMode = .automatic) async throws -> WorkoutPreferenceEvaluation.Lease {
        guard target.request.owner == session.owner else { throw WPE.Failure.wrongOwner }
        let cancellation = StoreWriteFence()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try evaluationWrite(session: session, permit: permit, cancellation: cancellation) { db in
                let control = try WPEStorage.load(db)
                guard control.head == expected else { throw WPE.Failure.staleHead }
                guard !control.head.revisionOverflow else { throw WPE.Failure.counterExhausted }
                try WPEStorage.checkPreference(control.state.target?.request.preference, target.request.preference)
                let token = try WPEStorage.token(db)
                if let old = control.state.target, WPEStorage.compatible(old.request, target.request),
                   control.state.expectedRevision == control.head.workoutRevision,
                   WPEStorage.tokenMatches(control.state, token),
                   let lease = WPEStorage.lease(control, instance: session.instance) {
                    switch mode {
                    case .automatic: return lease
                    case .explicitRetry:
                        // Only a still-current evaluation is a strict same-target resume.
                        // Job/revision invalidation falls through below, retaining admitted bounds.
                        guard old == target else { throw WPE.Failure.invalidTarget }
                        var state = control.state
                        state.retry = nil
                        if state.phase == .resourceHeld {
                            state.phase = .scanning
                            state.resource = nil
                        }
                        guard state != control.state else { return lease }
                        let saved = try WPEStorage.save(db, state: state, previous: control)
                        // A cold caller still has to prove the saved prefix/terminal rows.
                        if session.trustedHead() == control.head { session.trust(saved.head) }
                        guard let retried = WPEStorage.lease(saved, instance: session.instance) else { throw WPE.Failure.invalidState }
                        return retried
                    case .refreshCore: break
                    }
                }
                // Keep admitted bounds on same-request invalidation. A clock tick is not a new target.
                let chosen = control.state.target.flatMap { WPEStorage.compatible($0.request, target.request) ? $0 : nil } ?? target
                var state = WPEState()
                state.target = chosen; state.evaluationID = UUID(); state.expectedRevision = control.head.workoutRevision
                state.rescoreToken = token; state.progress = try .empty(target: chosen)
                let saved = try WPEStorage.save(db, state: state, previous: control)
                guard let lease = WPEStorage.lease(saved, instance: session.instance) else { throw WPE.Failure.invalidState }
                session.trust(saved.head)
                return lease
            }
        } onCancel: { cancellation.invalidate() }
    }

    public func recordWorkoutPreferenceCorePass(session: WorkoutEvaluationSession,
                                                lease: WorkoutPreferenceEvaluation.Lease,
                                                witness: WorkoutPreferenceEvaluation.CorePassWitness,
                                                permit: WorkoutEvaluationPermit) async throws -> WorkoutPreferenceEvaluation.Lease {
        let cancellation = StoreWriteFence()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try evaluationWrite(session: session, permit: permit, cancellation: cancellation) { db in
                let control = try WPEStorage.load(db)
                // Core computation writes computed workouts. Capture its final revision, not the admission revision.
                guard lease.instance == session.instance, control.head.storeID == lease.head.storeID,
                      control.head.stateSerial == lease.head.stateSerial, control.head.stateDigest == lease.head.stateDigest,
                      control.state.evaluationID == lease.evaluationID, control.state.phase == .needsCore,
                      control.state.target == lease.target, !control.head.revisionOverflow,
                      try witness.targetDigest == lease.target.digest,
                      witness.dependencyDigest == lease.target.request.dependencyDigest,
                      witness.capturedRescoreJobToken == lease.rescoreJobToken,
                      try WPEStorage.token(db) == lease.rescoreJobToken else { throw WPE.Failure.staleHead }
                var state = control.state
                state.core = witness; state.expectedRevision = control.head.workoutRevision
                state.phase = .scanning; state.progress = try .empty(target: lease.target); state.retry = nil
                let saved = try WPEStorage.save(db, state: state, previous: control)
                guard let lease = WPEStorage.lease(saved, instance: session.instance) else { throw WPE.Failure.invalidState }
                session.trust(saved.head)
                return lease
            }
        } onCancel: { cancellation.invalidate() }
    }

    public func advanceWorkoutPreferenceEvaluation(session: WorkoutEvaluationSession,
                                                   lease: WorkoutPreferenceEvaluation.Lease,
                                                   permit: WorkoutEvaluationPermit) async throws -> WorkoutPreferenceEvaluation.Step {
        let cancellation = StoreWriteFence()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation(); try session.check(instance: revisionInstanceToken); try permit.check()
            let read = try syncRead { db -> (WPEControl, WPEPage, Bool) in
                try WPEStorage.checkOwner(db, session.owner)
                let control = try WPEStorage.load(db)
                guard lease.instance == session.instance, control.head == lease.head,
                      control.state.target == lease.target, control.state.evaluationID == lease.evaluationID,
                      control.state.expectedRevision == control.head.workoutRevision,
                      !control.head.revisionOverflow, try WPEStorage.tokenMatches(control.state, WPEStorage.token(db)),
                      control.state.phase == .scanning || control.state.phase == .sealed,
                      let progress = control.state.progress else { throw WPE.Failure.staleHead }
                let validation = session.trustedHead() != control.head
                if validation {
                    let saved = session.validationProgress()
                    let prefix = try (saved?.head == control.head ? saved?.progress : nil) ?? .empty(target: lease.target)
                    // An empty persisted prefix needs no row proof; the subsequent scan still proves EOF.
                    if control.state.phase == .scanning, progress.cursor == nil {
                        return (control, WPEPage(progress: prefix, eof: true), true)
                    }
                    return (control, try WPEStorage.page(db, target: lease.target, progress: prefix,
                               through: control.state.phase == .scanning ? progress.cursor : nil), true)
                }
                guard control.state.phase == .scanning else { throw WPE.Failure.staleHead }
                return (control, try WPEStorage.page(db, target: lease.target, progress: progress), false)
            }
            let (original, page, validating) = read
            let result = try evaluationWrite(session: session, permit: permit, cancellation: cancellation) { db -> WPE.View in
                let current = try WPEStorage.load(db)
                let currentToken = try WPEStorage.token(db)
                guard current.head == original.head, WPEStorage.tokenMatches(current.state, currentToken) else { throw WPE.Failure.staleHead }
                var state = current.state
                if let resource = page.resource {
                    state.phase = .resourceHeld; state.resource = resource
                    // Incomplete validation cannot replace the old prefix with an asserted validated prefix.
                    if !validating { state.progress = page.progress }
                } else if validating {
                    if !page.eof {
                        session.saveValidation(WPEValidation(head: current.head, progress: page.progress))
                        return try WPEStorage.view(current, session: session, request: lease.target.request,
                                                   token: currentToken, now: Int64.max)
                    }
                    if page.progress == state.progress {
                        session.trust(current.head)
                        return try WPEStorage.view(current, session: session, request: lease.target.request,
                                                   token: currentToken, now: Int64.max)
                    }
                    // A copied UUID/revision with different content is not renewed as a successful receipt.
                    state.phase = .needsCore; state.core = nil; state.retry = nil
                    state.progress = try .empty(target: lease.target)
                } else {
                    state.progress = page.progress; state.retry = nil
                    state.phase = page.eof ? .sealed : .scanning
                }
                let saved = try WPEStorage.save(db, state: state, previous: current)
                if validating && page.resource != nil {
                    // Retained durable progress is still unproved. Retry must restart cold proof,
                    // not scan after that cursor or reuse a partially validated session prefix.
                    session.restore((nil, nil))
                } else {
                    session.trust(saved.head)
                }
                return try WPEStorage.view(saved, session: session, request: lease.target.request,
                                           token: currentToken, now: Int64.max)
            }
            return WPE.Step(view: result, rowsProcessed: page.rows, bytesProcessed: page.bytes,
                            yielded: !page.eof && page.resource == nil)
        } onCancel: { cancellation.invalidate() }
    }

    public func deferWorkoutPreferenceEvaluation(session: WorkoutEvaluationSession,
                                                 lease: WorkoutPreferenceEvaluation.Lease,
                                                 failure: WorkoutPreferenceEvaluation.RetryReason,
                                                 now: Int64,
                                                 permit: WorkoutEvaluationPermit) async throws -> WorkoutPreferenceEvaluation.View {
        let cancellation = StoreWriteFence()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try evaluationWrite(session: session, permit: permit, cancellation: cancellation) { db in
                let current = try WPEStorage.load(db)
                let coreLease = WPEStorage.matchesCoreLease(current, lease: lease, session: session)
                guard current.head == lease.head || coreLease,
                      lease.instance == session.instance, current.state.target == lease.target,
                      current.state.evaluationID == lease.evaluationID,
                      !current.head.revisionOverflow,
                      try WPEStorage.token(db) == lease.rescoreJobToken else { throw WPE.Failure.staleHead }
                var state = current.state
                if coreLease { state.expectedRevision = current.head.workoutRevision }
                let attempt = min(64, (state.retry?.attempt ?? 0) + 1)
                let delay: Int64 = [60, 300, 900, 3600, 21600][min(attempt - 1, 4)]
                let (deadline, overflow) = now.addingReportingOverflow(delay)
                guard !overflow else { throw WPE.Failure.invalidTarget }
                state.retry = WPERetry(reason: failure, attempt: attempt, notBefore: deadline)
                let saved = try WPEStorage.save(db, state: state, previous: current)
                if coreLease || session.trustedHead() == current.head { session.trust(saved.head) }
                return try WPEStorage.view(saved, session: session, request: lease.target.request,
                                           token: lease.rescoreJobToken, now: now)
            }
        } onCancel: { cancellation.invalidate() }
    }

    public func replaceManagedDetectedWorkouts(session: WorkoutEvaluationSession,
                                               lease: WorkoutPreferenceEvaluation.Lease,
                                               rows: [WorkoutRow],
                                               permit: WorkoutEvaluationPermit) async throws -> Int {
        let cancellation = StoreWriteFence()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try evaluationWrite(session: session, permit: permit, cancellation: cancellation) { db in
                let control = try WPEStorage.load(db)
                guard WPEStorage.matchesCoreLease(control, lease: lease, session: session),
                      try WPEStorage.token(db) == lease.rescoreJobToken else { throw WPE.Failure.staleHead }
                let computed = lease.target.request.canonicalWriter + "-noop"
                for row in rows {
                    guard row.source.utf8.elementsEqual(computed.utf8), row.sport == "detected",
                          (lease.target.lowerTs...lease.target.upperTs).contains(Int64(row.startTs)),
                          row.endTs >= row.startTs,
                          [row.durationS, row.energyKcal, row.strain, row.distanceM].compactMap({ $0 }).allSatisfy(\.isFinite) else {
                        throw WPE.Failure.invalidTarget
                    }
                }
                try db.execute(sql: """
                    DELETE FROM workout WHERE deviceId=? COLLATE BINARY AND source=? COLLATE BINARY
                    AND sport='detected' COLLATE BINARY AND startTs>=? AND startTs<=?
                    """, arguments: [computed, computed, lease.target.lowerTs, lease.target.upperTs])
                var changed = db.changesCount
                for row in rows {
                    try db.execute(sql: """
                        INSERT INTO workout
                        (deviceId,startTs,endTs,sport,source,durationS,energyKcal,avgHr,maxHr,strain,distanceM,zonesJSON,notes,steps)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?,CAST(? AS TEXT),CAST(? AS TEXT),?)
                        ON CONFLICT(deviceId,startTs,sport) DO UPDATE SET
                            endTs=excluded.endTs,source=excluded.source,durationS=excluded.durationS,
                            energyKcal=excluded.energyKcal,avgHr=excluded.avgHr,maxHr=excluded.maxHr,
                            strain=excluded.strain,distanceM=excluded.distanceM,zonesJSON=excluded.zonesJSON,
                            notes=excluded.notes,steps=excluded.steps
                        WHERE workout.source=excluded.source COLLATE BINARY AND workout.sport='detected' COLLATE BINARY
                        """, arguments: [computed, row.startTs, row.endTs, row.sport, row.source, row.durationS,
                                           row.energyKcal, row.avgHr, row.maxHr, row.strain, row.distanceM,
                                           row.zonesJSON.map { Data($0.utf8) }, row.notes.map { Data($0.utf8) }, row.steps])
                    changed += db.changesCount
                }
                return changed
            }
        } onCancel: { cancellation.invalidate() }
    }

    public func settleWorkoutPreferenceDependentJob(session: WorkoutEvaluationSession,
                                                    receipt: WorkoutPreferenceEvaluation.ValidatedReceipt,
                                                    request: WorkoutPreferenceEvaluation.Request,
                                                    kind: SyncJobKind,
                                                    capturedToken: String,
                                                    permit: WorkoutEvaluationPermit) async throws -> Bool {
        switch kind {
        case .cloudPush, .healthWriteback, .widgetPublish: break
        case .rescore: return false
        }
        let cancellation = StoreWriteFence()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try evaluationWrite(session: session, permit: permit, cancellation: cancellation) { db in
                let control = try WPEStorage.load(db)
                let rescoreToken = try WPEStorage.token(db)
                guard request.owner == session.owner, receipt.instance == session.instance,
                      receipt.head == control.head, session.trustedHead() == control.head,
                      !control.head.revisionOverflow, control.state.phase == .sealed,
                      control.head.workoutRevision == control.state.expectedRevision,
                      WPEStorage.compatible(receipt.receipt.target.request, request),
                      receipt.receipt.outcome == .complete, !receipt.receipt.counts.hasBlockers,
                      rescoreToken == nil, WPEStorage.tokenMatches(control.state, rescoreToken) else { return false }
                let checked = try WPEStorage.receipt(control, instance: session.instance)
                guard checked.receipt.digest == receipt.receipt.digest,
                      checked.receipt.revision == receipt.receipt.revision,
                      checked.receipt.outcome == .complete, !checked.receipt.counts.hasBlockers else { return false }
                // Export settlement consumes only its exact debt; it neither renews membership
                // nor changes the separately settled rescore prerequisite.
                try db.execute(sql: "DELETE FROM syncJob WHERE kind=? AND token=CAST(? AS TEXT) COLLATE BINARY",
                               arguments: [kind.rawValue, Data(capturedToken.utf8)])
                return db.changesCount == 1
            }
        } onCancel: { cancellation.invalidate() }
    }

    public func settleWorkoutPreferenceRescoreJob(session: WorkoutEvaluationSession,
                                                 receipt: WorkoutPreferenceEvaluation.ValidatedReceipt,
                                                 request: WorkoutPreferenceEvaluation.Request,
                                                 capturedToken: String,
                                                 permit: WorkoutEvaluationPermit) async throws -> Bool {
        let cancellation = StoreWriteFence()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try evaluationWrite(session: session, permit: permit, cancellation: cancellation) { db in
                let control = try WPEStorage.load(db)
                guard request.owner == session.owner, receipt.instance == session.instance,
                      receipt.head == control.head, session.trustedHead() == control.head,
                      !control.head.revisionOverflow, control.state.phase == .sealed,
                      control.head.workoutRevision == control.state.expectedRevision,
                      WPEStorage.compatible(receipt.receipt.target.request, request),
                      receipt.receipt.outcome == .complete, !receipt.receipt.counts.hasBlockers,
                      receipt.receipt.coreWitness.capturedRescoreJobToken == capturedToken,
                      try WPEStorage.token(db) == capturedToken else { return false }
                let checked = try WPEStorage.receipt(control, instance: session.instance)
                guard checked.receipt.digest == receipt.receipt.digest,
                      checked.receipt.outcome == .complete else { return false }
                try db.execute(sql: "DELETE FROM syncJob WHERE kind='rescore' AND token=?", arguments: [capturedToken])
                guard db.changesCount == 1 else { return false }
                var settled = control.state
                settled.rescoreSettled = true
                let saved = try WPEStorage.save(db, state: settled, previous: control)
                session.trust(saved.head)
                return true
            }
        } onCancel: { cancellation.invalidate() }
    }
}

extension WhoopStore {
    nonisolated static func installWorkoutPreferenceEvaluationSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE workoutPreferenceEvaluation (
                singleton INTEGER NOT NULL PRIMARY KEY CHECK(singleton = 1),
                formatVersion INTEGER NOT NULL CHECK(formatVersion >= 1),
                storeID BLOB NOT NULL CHECK(typeof(storeID) = 'blob' AND length(storeID) = 16),
                workoutRevision INTEGER NOT NULL CHECK(typeof(workoutRevision) = 'integer' AND workoutRevision >= 0),
                revisionOverflow INTEGER NOT NULL CHECK(revisionOverflow IN (0,1)),
                stateSerial INTEGER NOT NULL CHECK(typeof(stateSerial) = 'integer' AND stateSerial >= 0),
                stateBytes BLOB NOT NULL CHECK(typeof(stateBytes) = 'blob' AND length(stateBytes) <= 32768),
                stateSHA256 BLOB NOT NULL CHECK(typeof(stateSHA256) = 'blob' AND length(stateSHA256) = 32)
            );
            CREATE INDEX workout_preference_window_v1
                ON workout(startTs, deviceId COLLATE BINARY, sport COLLATE BINARY);
            """)
        for (suffix, event) in [("insert", "INSERT"), ("update", "UPDATE"), ("delete", "DELETE")] {
            try db.execute(sql: WPEStorage.triggerSQL(suffix: suffix, event: event))
        }
    }
}
