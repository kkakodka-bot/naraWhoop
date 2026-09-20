import Foundation
import GRDB

/// Last-known server-computed HRV/sleep scores for a local day (Phase 4 read cache).
public struct ServerScoreCacheRow: Equatable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "serverScoreCache"

    public let day: String
    public let algorithmVersion: String
    public let dailyJson: String?
    public let nightsJson: String
    public let computedAt: String?
    public let stale: Bool
    public let fetchedAt: Int

    public init(
        day: String,
        algorithmVersion: String,
        dailyJson: String?,
        nightsJson: String,
        computedAt: String?,
        stale: Bool,
        fetchedAt: Int
    ) {
        self.day = day
        self.algorithmVersion = algorithmVersion
        self.dailyJson = dailyJson
        self.nightsJson = nightsJson
        self.computedAt = computedAt
        self.stale = stale
        self.fetchedAt = fetchedAt
    }

    public enum Columns: String, ColumnExpression {
        case day, algorithmVersion, dailyJson, nightsJson, computedAt, stale, fetchedAt
    }
}

public struct ServerScoreDailyCache: Equatable, Codable {
    public let hrvRmssdMs: Double?
    public let restingHrBpm: Int?
    public let sleepTotalMin: Double?
    public let sleepInBedMin: Double?
    public let sleepAwakeMin: Double?
    public let sleepLightMin: Double?
    public let sleepDeepMin: Double?
    public let sleepRemMin: Double?
    public let sleepEfficiency: Double?
    public let respRateBpm: Double?
    public let computedAt: String?

    public init(
        hrvRmssdMs: Double? = nil,
        restingHrBpm: Int? = nil,
        sleepTotalMin: Double? = nil,
        sleepInBedMin: Double? = nil,
        sleepAwakeMin: Double? = nil,
        sleepLightMin: Double? = nil,
        sleepDeepMin: Double? = nil,
        sleepRemMin: Double? = nil,
        sleepEfficiency: Double? = nil,
        respRateBpm: Double? = nil,
        computedAt: String? = nil
    ) {
        self.hrvRmssdMs = hrvRmssdMs
        self.restingHrBpm = restingHrBpm
        self.sleepTotalMin = sleepTotalMin
        self.sleepInBedMin = sleepInBedMin
        self.sleepAwakeMin = sleepAwakeMin
        self.sleepLightMin = sleepLightMin
        self.sleepDeepMin = sleepDeepMin
        self.sleepRemMin = sleepRemMin
        self.sleepEfficiency = sleepEfficiency
        self.respRateBpm = respRateBpm
        self.computedAt = computedAt
    }
}

public struct ServerScoreNightCache: Equatable, Codable {
    public init(
        id: String,
        startAt: String,
        endAt: String,
        isNap: Bool,
        asleepMin: Double? = nil,
        inBedMin: Double? = nil,
        lightMin: Double? = nil,
        deepMin: Double? = nil,
        remMin: Double? = nil,
        awakeMin: Double? = nil,
        efficiency: Double? = nil,
        hrvRmssdMs: Double? = nil,
        restingHrBpm: Int? = nil
    ) {
        self.id = id
        self.startAt = startAt
        self.endAt = endAt
        self.isNap = isNap
        self.asleepMin = asleepMin
        self.inBedMin = inBedMin
        self.lightMin = lightMin
        self.deepMin = deepMin
        self.remMin = remMin
        self.awakeMin = awakeMin
        self.efficiency = efficiency
        self.hrvRmssdMs = hrvRmssdMs
        self.restingHrBpm = restingHrBpm
    }

    public let id: String
    public let startAt: String
    public let endAt: String
    public let isNap: Bool
    public let asleepMin: Double?
    public let inBedMin: Double?
    public let lightMin: Double?
    public let deepMin: Double?
    public let remMin: Double?
    public let awakeMin: Double?
    public let efficiency: Double?
    public let hrvRmssdMs: Double?
    public let restingHrBpm: Int?
}

public struct ServerScoreDayCache: Equatable {
    public init(
        day: String,
        algorithmVersion: String,
        daily: ServerScoreDailyCache?,
        nights: [ServerScoreNightCache],
        computedAt: String?,
        stale: Bool,
        fetchedAt: Date
    ) {
        self.day = day
        self.algorithmVersion = algorithmVersion
        self.daily = daily
        self.nights = nights
        self.computedAt = computedAt
        self.stale = stale
        self.fetchedAt = fetchedAt
    }

    public let day: String
    public let algorithmVersion: String
    public let daily: ServerScoreDailyCache?
    public let nights: [ServerScoreNightCache]
    public let computedAt: String?
    public let stale: Bool
    public let fetchedAt: Date
}

public enum ServerScoreCacheCodec {
    public static let algorithmVersion = "frwhoop-server-1"

    public static func encodeDaily(_ daily: ServerScoreDailyCache?) -> String? {
        guard let daily else { return nil }
        return String(data: try! JSONEncoder().encode(daily), encoding: .utf8)
    }

    public static func decodeDaily(_ json: String?) -> ServerScoreDailyCache? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ServerScoreDailyCache.self, from: data)
    }

    public static func encodeNights(_ nights: [ServerScoreNightCache]) -> String {
        let data = (try? JSONEncoder().encode(nights)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    public static func decodeNights(_ json: String) -> [ServerScoreNightCache] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ServerScoreNightCache].self, from: data)) ?? []
    }
}

public struct ServerScoreCacheStore {
    private let db: DatabaseWriter

    public init(db: DatabaseWriter) {
        self.db = db
    }

    public func upsert(
        day: String,
        daily: ServerScoreDailyCache?,
        nights: [ServerScoreNightCache],
        computedAt: String?,
        stale: Bool,
        fetchedAt: Int = Int(Date().timeIntervalSince1970)
    ) throws {
        let row = ServerScoreCacheRow(
            day: day,
            algorithmVersion: ServerScoreCacheCodec.algorithmVersion,
            dailyJson: ServerScoreCacheCodec.encodeDaily(daily),
            nightsJson: ServerScoreCacheCodec.encodeNights(nights),
            computedAt: computedAt,
            stale: stale,
            fetchedAt: fetchedAt
        )
        try db.write { db in
            try row.insert(db, onConflict: .replace)
        }
    }

    public func load(day: String) throws -> ServerScoreDayCache? {
        try db.read { db in
            guard let row = try ServerScoreCacheRow.fetchOne(db, key: day) else { return nil }
            return ServerScoreDayCache(
                day: row.day,
                algorithmVersion: row.algorithmVersion,
                daily: ServerScoreCacheCodec.decodeDaily(row.dailyJson),
                nights: ServerScoreCacheCodec.decodeNights(row.nightsJson),
                computedAt: row.computedAt,
                stale: row.stale,
                fetchedAt: Date(timeIntervalSince1970: TimeInterval(row.fetchedAt))
            )
        }
    }
}

// MARK: - Account-scoped immutable snapshot cache

/// Identity is supplied by the app's validated account facade, never inferred from legacy rows.
public struct ServerScoreCacheOwner: Hashable, Sendable {
    public let projectURL: String
    public let userID: String

    public init(projectURL: String, userID: String) {
        self.projectURL = projectURL
        self.userID = userID
    }
}

public struct ServerScoreCacheSession: Equatable, Sendable {
    public let owner: ServerScoreCacheOwner
    public let generation: UUID

    public init(owner: ServerScoreCacheOwner, generation: UUID) {
        self.owner = owner
        self.generation = generation
    }
}

public struct ServerScoreCacheKey: Hashable, Sendable {
    public let owner: ServerScoreCacheOwner
    public let sourceDeviceID: String
    public let day: String
    public let timeZoneID: String
    public let schemaVersion: Int
    public let algorithmVersion: String

    public init(owner: ServerScoreCacheOwner, sourceDeviceID: String, day: String,
                timeZoneID: String, schemaVersion: Int, algorithmVersion: String) {
        self.owner = owner
        self.sourceDeviceID = sourceDeviceID
        self.day = day
        self.timeZoneID = timeZoneID
        self.schemaVersion = schemaVersion
        self.algorithmVersion = algorithmVersion
    }

    fileprivate var arguments: StatementArguments {
        [owner.projectURL, owner.userID, sourceDeviceID, day, timeZoneID,
         schemaVersion, algorithmVersion]
    }

    fileprivate static let predicate = """
        projectURL = ? AND userID = ? AND sourceDeviceID = ? AND day = ? AND
        timeZoneID = ? AND schemaVersion = ? AND algorithmVersion = ?
        """
}

/// Payload is the complete validated immutable result, including the replacement sleep set.
/// The app canonicalizes encoding and excludes mutable RPC fields (pending/requested revision/archive status).
/// Pending/unsupported responses do not have a result revision and must not replace this cache.
public struct ServerScoreCachedSnapshot: Equatable, Sendable {
    public enum State: String, Sendable { case available, partial, noData = "no_data" }

    public let key: ServerScoreCacheKey
    public let inputRevision: Int64
    public let resultRevision: Int64
    public let state: State
    public let payload: Data
    public let fetchedAt: Date

    public init(key: ServerScoreCacheKey, inputRevision: Int64, resultRevision: Int64,
                state: State, payload: Data, fetchedAt: Date) {
        self.key = key
        self.inputRevision = inputRevision
        self.resultRevision = resultRevision
        self.state = state
        self.payload = payload
        self.fetchedAt = fetchedAt
    }
}

public enum ServerScoreSnapshotCacheError: Error, Equatable {
    case staleSession, invalidKey, invalidSnapshot, payloadTooLarge, revisionConflict, corruptRow
}

/// All SQLite access is actor-isolated, including decode admission and LRU eviction.
/// The app must fence its own publication against the same session after every await.
public actor ServerScoreSnapshotCache {
    public struct Limits: Sendable {
        public let daysPerNamespace: Int
        public let totalRows: Int
        public let payloadBytes: Int
        public let totalBytes: Int

        public init(daysPerNamespace: Int = 14, totalRows: Int = 112,
                    payloadBytes: Int = 512 * 1024, totalBytes: Int = 8 * 1024 * 1024) {
            precondition(daysPerNamespace > 0 && totalRows > 0 && payloadBytes > 0 && totalBytes >= payloadBytes)
            self.daysPerNamespace = daysPerNamespace
            self.totalRows = totalRows
            self.payloadBytes = payloadBytes
            self.totalBytes = totalBytes
        }
    }

    public enum WriteResult: Equatable, Sendable { case inserted, refreshed, ignoredOlderRevision }

    private let db: DatabaseWriter
    private let limits: Limits
    private var activeSession: ServerScoreCacheSession?
    private var establishedBounds: BoundsProof?

    public init(db: DatabaseWriter, limits: Limits = Limits()) {
        self.db = db
        self.limits = limits
    }

    /// Revokes previous in-flight work, including a later login to the same account.
    /// Logout hides rows; it does not delete another account's retained offline cache.
    public func activate(_ session: ServerScoreCacheSession?) {
        activeSession = session
    }

    /// Last observed server-selected source/version per day, for offline launch before the RPC returns.
    /// This does not choose a source by computation order; fetchedAt records the accepted readback.
    public func loadRecent(session: ServerScoreCacheSession, timeZoneID: String,
                           now: Date = Date()) throws -> [ServerScoreCachedSnapshot] {
        guard session == activeSession else { throw ServerScoreSnapshotCacheError.staleSession }
        guard now.timeIntervalSince1970.isFinite else { throw ServerScoreSnapshotCacheError.invalidSnapshot }
        let loaded: [LoadedSnapshot] = try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT sourceDeviceID, day, timeZoneID, schemaVersion, algorithmVersion FROM serverScoreSnapshotCache
                WHERE projectURL=? AND userID=? AND timeZoneID=?
                ORDER BY fetchedAt DESC, resultRevision DESC LIMIT ?
                """, arguments: [session.owner.projectURL, session.owner.userID, timeZoneID, limits.totalRows])
            var seen: Set<String> = []
            return try rows.compactMap { row in
                let day: String = row["day"]
                guard seen.count < limits.daysPerNamespace, seen.insert(day).inserted else { return nil }
                let key = ServerScoreCacheKey(owner: session.owner, sourceDeviceID: row["sourceDeviceID"], day: day,
                                             timeZoneID: row["timeZoneID"], schemaVersion: row["schemaVersion"],
                                             algorithmVersion: row["algorithmVersion"])
                try validate(key, session: session)
                return try readSnapshot(db, key: key)
            }
        }
        // Hydration reads one bounded snapshot, then commits all LRU touches together.
        // A corrupt selected row fails before any access metadata changes.
        try touch(loaded, now: now.timeIntervalSince1970)
        return loaded.map(\.snapshot)
    }

    public func load(_ key: ServerScoreCacheKey, session: ServerScoreCacheSession,
                     now: Date = Date()) throws -> ServerScoreCachedSnapshot? {
        try validate(key, session: session)
        guard now.timeIntervalSince1970.isFinite else { throw ServerScoreSnapshotCacheError.invalidSnapshot }
        guard let loaded = try db.read({ try readSnapshot($0, key: key) }) else { return nil }
        try touch([loaded], now: now.timeIntervalSince1970)
        return loaded.snapshot
    }

    @discardableResult
    public func store(_ snapshot: ServerScoreCachedSnapshot, session: ServerScoreCacheSession,
                      now: Date = Date()) throws -> WriteResult {
        try validate(snapshot.key, session: session)
        guard snapshot.inputRevision >= 0 && snapshot.resultRevision > 0,
              snapshot.fetchedAt.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite,
              !snapshot.payload.isEmpty else { throw ServerScoreSnapshotCacheError.invalidSnapshot }
        guard snapshot.payload.count <= limits.payloadBytes else { throw ServerScoreSnapshotCacheError.payloadTooLarge }
        let (result, proof): (WriteResult, BoundsProof?) = try db.write { db in
            guard let dataVersion = try Int.fetchOne(db, sql: "PRAGMA data_version") else {
                throw ServerScoreSnapshotCacheError.corruptRow
            }
            let unchangedBounds = establishedBounds?.matches(snapshot.key, changes: db.totalChangesCount,
                                                              dataVersion: dataVersion) == true
            if let row = try Row.fetchOne(db, sql: "SELECT inputRevision, resultRevision, state, length(payload) AS payloadBytes, fetchedAt, accessedAt FROM serverScoreSnapshotCache WHERE \(ServerScoreCacheKey.predicate)",
                                         arguments: snapshot.key.arguments) {
                let previousInput: Int64 = row["inputRevision"]
                let previousResult: Int64 = row["resultRevision"]
                if snapshot.resultRevision < previousResult || snapshot.inputRevision < previousInput {
                    return (.ignoredOlderRevision, nil)
                }
                if snapshot.resultRevision == previousResult {
                    guard snapshot.inputRevision == previousInput,
                          snapshot.state.rawValue == (row["state"] as String) else {
                        throw ServerScoreSnapshotCacheError.revisionConflict
                    }
                    let size: Int = row["payloadBytes"]
                    guard size > 0 && size <= limits.payloadBytes else { throw ServerScoreSnapshotCacheError.corruptRow }
                    guard let payload = try Data.fetchOne(db, sql: "SELECT payload FROM serverScoreSnapshotCache WHERE \(ServerScoreCacheKey.predicate)",
                                                         arguments: snapshot.key.arguments), payload == snapshot.payload else {
                        throw ServerScoreSnapshotCacheError.revisionConflict
                    }
                    if (row["fetchedAt"] as Double) != snapshot.fetchedAt.timeIntervalSince1970
                        || (row["accessedAt"] as Double) != now.timeIntervalSince1970 {
                        try db.execute(sql: "UPDATE serverScoreSnapshotCache SET fetchedAt = ?, accessedAt = ? WHERE \(ServerScoreCacheKey.predicate)",
                                       arguments: [snapshot.fetchedAt.timeIntervalSince1970, now.timeIntervalSince1970] + snapshot.key.arguments)
                    }
                    // Skip eviction only with a current proof for this namespace. Another cache
                    // instance, connection, or namespace may have used different limits.
                    if !unchangedBounds { try evict(db, key: snapshot.key) }
                    return (.refreshed, BoundsProof(key: snapshot.key, changes: db.totalChangesCount,
                                                    dataVersion: dataVersion))
                }
            }
            try db.execute(sql: """
                INSERT INTO serverScoreSnapshotCache
                (projectURL, userID, sourceDeviceID, day, timeZoneID, schemaVersion, algorithmVersion,
                 inputRevision, resultRevision, state, payload, fetchedAt, accessedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(projectURL, userID, sourceDeviceID, day, timeZoneID, schemaVersion, algorithmVersion)
                DO UPDATE SET inputRevision=excluded.inputRevision, resultRevision=excluded.resultRevision,
                    state=excluded.state, payload=excluded.payload, fetchedAt=excluded.fetchedAt, accessedAt=excluded.accessedAt
                """, arguments: snapshot.key.arguments + [snapshot.inputRevision, snapshot.resultRevision,
                    snapshot.state.rawValue, snapshot.payload, snapshot.fetchedAt.timeIntervalSince1970, now.timeIntervalSince1970])
            try evict(db, key: snapshot.key)
            return (.inserted, BoundsProof(key: snapshot.key, changes: db.totalChangesCount,
                                          dataVersion: dataVersion))
        }
        // A failed commit cannot establish bounds for the next call.
        if let proof { establishedBounds = proof }
        return result
    }

    private struct BoundsProof {
        let key: ServerScoreCacheKey
        let changes: Int
        let dataVersion: Int

        func matches(_ other: ServerScoreCacheKey, changes: Int, dataVersion: Int) -> Bool {
            self.changes == changes && self.dataVersion == dataVersion
                && key.owner == other.owner && key.sourceDeviceID == other.sourceDeviceID
                && key.timeZoneID == other.timeZoneID && key.schemaVersion == other.schemaVersion
                && key.algorithmVersion == other.algorithmVersion
        }
    }

    private struct LoadedSnapshot {
        let snapshot: ServerScoreCachedSnapshot
        let accessedAt: Double
    }

    private func readSnapshot(_ db: Database, key: ServerScoreCacheKey) throws -> LoadedSnapshot? {
        // Check the stored size before materializing a potentially corrupt blob.
        guard let size = try Int.fetchOne(db, sql: "SELECT length(payload) FROM serverScoreSnapshotCache WHERE \(ServerScoreCacheKey.predicate)",
                                         arguments: key.arguments) else { return nil }
        guard size > 0 && size <= limits.payloadBytes else { throw ServerScoreSnapshotCacheError.corruptRow }
        guard let row = try Row.fetchOne(db, sql: "SELECT inputRevision, resultRevision, state, payload, fetchedAt, accessedAt FROM serverScoreSnapshotCache WHERE \(ServerScoreCacheKey.predicate)",
                                        arguments: key.arguments),
              let state = ServerScoreCachedSnapshot.State(rawValue: row["state"]) else {
            throw ServerScoreSnapshotCacheError.corruptRow
        }
        let input: Int64 = row["inputRevision"]
        let result: Int64 = row["resultRevision"]
        let fetched: Double = row["fetchedAt"]
        let accessed: Double = row["accessedAt"]
        guard input >= 0 && result > 0 && fetched.isFinite && accessed.isFinite else {
            throw ServerScoreSnapshotCacheError.corruptRow
        }
        return LoadedSnapshot(snapshot: ServerScoreCachedSnapshot(key: key, inputRevision: input, resultRevision: result,
                              state: state, payload: row["payload"], fetchedAt: Date(timeIntervalSince1970: fetched)),
                              accessedAt: accessed)
    }

    private func touch(_ loaded: [LoadedSnapshot], now: Double) throws {
        let changed = loaded.filter { $0.accessedAt != now }
        guard !changed.isEmpty else { return }
        try db.write { db in
            for row in changed {
                // Another cache owner can use the same writer between the read and this transaction.
                // Do not touch a replacement revision or overwrite a newer access timestamp.
                try db.execute(sql: """
                    UPDATE serverScoreSnapshotCache SET accessedAt = ? WHERE \(ServerScoreCacheKey.predicate)
                    AND inputRevision = ? AND resultRevision = ? AND accessedAt = ?
                    """, arguments: [now] + row.snapshot.key.arguments
                        + [row.snapshot.inputRevision, row.snapshot.resultRevision, row.accessedAt])
            }
        }
    }

    private func validate(_ key: ServerScoreCacheKey, session: ServerScoreCacheSession) throws {
        guard session == activeSession, key.owner == session.owner else { throw ServerScoreSnapshotCacheError.staleSession }
        let fields = [key.owner.projectURL, key.owner.userID, key.sourceDeviceID, key.day,
                      key.timeZoneID, key.algorithmVersion]
        guard key.schemaVersion > 0, fields.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\u{0}") }),
              TimeZone(identifier: key.timeZoneID) != nil, Self.isDayKey(key.day) else {
            throw ServerScoreSnapshotCacheError.invalidKey
        }
    }

    private static func isDayKey(_ day: String) -> Bool {
        let bytes = Array(day.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }) else {
            return false
        }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 0 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let wanted = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: wanted) else { return false }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        return actual.year == wanted.year && actual.month == wanted.month && actual.day == wanted.day
    }

    private func evict(_ db: Database, key: ServerScoreCacheKey) throws {
        try db.execute(sql: """
            DELETE FROM serverScoreSnapshotCache WHERE rowid IN (
                SELECT rowid FROM serverScoreSnapshotCache
                WHERE projectURL=? AND userID=? AND sourceDeviceID=? AND timeZoneID=? AND schemaVersion=? AND algorithmVersion=?
                ORDER BY accessedAt DESC, resultRevision DESC, rowid DESC LIMIT -1 OFFSET ?)
            """, arguments: [key.owner.projectURL, key.owner.userID, key.sourceDeviceID,
                              key.timeZoneID, key.schemaVersion, key.algorithmVersion, limits.daysPerNamespace])
        let rows = try Row.fetchAll(db, sql: "SELECT rowid, length(payload) AS bytes FROM serverScoreSnapshotCache ORDER BY accessedAt DESC, resultRevision DESC, rowid DESC")
        var bytes = 0
        for (index, row) in rows.enumerated() {
            bytes += row["bytes"] as Int
            if index >= limits.totalRows || bytes > limits.totalBytes {
                try db.execute(sql: "DELETE FROM serverScoreSnapshotCache WHERE rowid=?", arguments: [row["rowid"] as Int64])
            }
        }
    }
}
