import Foundation
import CoreFoundation
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
    public var sleepUnstagedMin: Double?
    public var stateUnknownMin: Double?
    public var offBodyMin: Double?
    public var opportunityKind: String?
    public var recovery: Double?
    public var strain: Double?
    public var spo2Pct: Double?
    public var skinTempC: Double?
    public var skinTempDevC: Double?
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
    public var startTimezoneId: String?
    public var endTimezoneId: String?
    public var stages: [ServerScoreStageCache] = []
    public var deviceId: String?
    public var episodeType: String?
    public var mainSleepGroupId: String?
    public var boundaryProvenance: String?
    public var opportunityKind: String?
    public var measurementAvailable: Bool?
    public var sleepUnstagedMin: Double?
    public var stateUnknownMin: Double?
    public var offBodyMin: Double?
    public var stateCoverage: Double?
    public var manualEdit: Bool?
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

public struct ServerScoreDayCache: Equatable, Codable {
    public var ownerId: String = ""
    public var schemaVersion: Int = 2
    public var features: [String: ServerScoreFeatureCache] = [:]
    public var rawSnapshotJSON: String?
    public var measurementsJSON: String? {
        guard let data = rawSnapshotJSON?.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let overlay = root["server_scoring"] as? [String: Any], let values = overlay["measurements"] as? [Any],
              let encoded = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return nil }
        return String(data: encoded, encoding: .utf8)
    }
    public var scopeKey: String {
        let pairs = features.keys.sorted().map { [$0, features[$0]?.deviceId ?? "", features[$0]?.algorithmVersion ?? ""] }
        return String(data: (try? JSONSerialization.data(withJSONObject: pairs)) ?? Data(), encoding: .utf8) ?? ""
    }
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
    public static let algorithmVersion = "frwhoop-physiology-2"
    public static let schemaVersion = 2
    public enum DecodeError: Error { case invalidScope, invalidPayload }

    public static func parseSnapshot(_ data: Data, day: String, ownerId: String,
                                     fetchedAt: Date = Date()) throws -> ServerScoreDayCache {
        guard !ownerId.isEmpty,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = root["server_scoring"] as? [String: Any],
              (o["schema_version"] as? NSNumber)?.intValue == schemaVersion,
              (o["user_id"] as? String)?.lowercased() == ownerId.lowercased(),
              o["day"] as? String == day,
              let version = o["algorithm_version"] as? String,
              let rawFeatures = o["features"] as? [String: [String: Any]], !rawFeatures.isEmpty
        else { throw DecodeError.invalidScope }
        func number(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        func integer(_ value: Any?) -> Int? {
            guard let n = number(value), n >= Double(Int.min), n < Double(Int.max) else { return nil }
            return Int(n)
        }
        var features: [String: ServerScoreFeatureCache] = [:]
        for (key, f) in rawFeatures {
            let status = f["status"] as? String ?? "unavailable"
            let device = f["device_id"] as? String, algorithm = f["algorithm_version"] as? String
            if status != "unavailable", device?.isEmpty != false || algorithm?.isEmpty != false { throw DecodeError.invalidScope }
            features[key] = ServerScoreFeatureCache(status: status, reason: f["reason"] as? String,
                deviceId: device, algorithmVersion: algorithm, inputRevision: (f["input_revision"] as? NSNumber)?.int64Value,
                requiredRevision: (f["required_revision"] as? NSNumber)?.int64Value,
                computedAt: f["computed_at"] as? String, observedThrough: f["observed_through"] as? String,
                publicationStatus: f["publication_status"] as? String, archiveStatus: f["archive_status"] as? String,
                manifestHash: f["manifest_hash"] as? String, supportsBoundaryOverrides: f["supports_boundary_overrides"] as? Bool,
                processingStatus: f["processing_status"] as? String, timezoneId: f["timezone_id"] as? String,
                timezoneIds: f["timezone_ids"] as? [String])
        }
        var daily: ServerScoreDailyCache?
        if let d = o["daily"] as? [String: Any] {
            daily = ServerScoreDailyCache(hrvRmssdMs: number(d["hrv_rmssd_ms"]), restingHrBpm: integer(d["resting_hr_bpm"]),
                sleepTotalMin: number(d["sleep_total_min"]), sleepInBedMin: number(d["sleep_in_bed_min"]),
                sleepAwakeMin: number(d["sleep_awake_min"]), sleepLightMin: number(d["sleep_light_min"]),
                sleepDeepMin: number(d["sleep_deep_min"]), sleepRemMin: number(d["sleep_rem_min"]),
                sleepEfficiency: number(d["sleep_efficiency"]), respRateBpm: number(d["resp_rate_bpm"]), computedAt: d["computed_at"] as? String)
            daily?.sleepUnstagedMin = number(d["sleep_unstaged_min"])
            daily?.stateUnknownMin = number(d["state_unknown_min"])
            daily?.offBodyMin = number(d["off_body_min"])
            daily?.opportunityKind = d["opportunity_kind"] as? String
            daily?.recovery = number(d["recovery"])
            daily?.strain = number(d["strain"])
            daily?.spo2Pct = number(d["spo2_pct"])
            daily?.skinTempC = number(d["skin_temp_c"])
            daily?.skinTempDevC = number(d["skin_temp_dev_c"])
        }
        var nights: [ServerScoreNightCache] = []
        for n in (o["nights"] as? [[String: Any]]) ?? [] {
            guard let id = n["id"] as? String, !id.isEmpty,
                  let start = n["start_at"] as? String, let end = n["end_at"] as? String else { throw DecodeError.invalidPayload }
            let device = n["device_id"] as? String
            if let selectedDevice = features["sleep"]?.deviceId, device != selectedDevice { throw DecodeError.invalidScope }
            let sourceVersion = (n["algorithm_version"] as? String) ?? features["sleep"]?.algorithmVersion
            let legacy = sourceVersion == "frwhoop-server-1"
            var night = ServerScoreNightCache(id: id, startAt: start, endAt: end, isNap: n["is_nap"] as? Bool ?? false,
                asleepMin: number(n["asleep_min"]), inBedMin: number(n["in_bed_min"]), lightMin: number(n["light_min"]),
                deepMin: number(n["deep_min"]), remMin: number(n["rem_min"]), awakeMin: number(n["awake_min"]),
                efficiency: number(n["efficiency"]), hrvRmssdMs: number(n["hrv_rmssd_ms"]), restingHrBpm: integer(n["resting_hr_bpm"]))
            night.deviceId = device; night.episodeType = (n["episode_type"] as? String) ?? (legacy ? (night.isNap ? "nap" : "main_sleep") : nil)
            night.mainSleepGroupId = n["main_sleep_group_id"] as? String
            night.boundaryProvenance = n["boundary_provenance"] as? String
            night.opportunityKind = n["opportunity_kind"] as? String
            night.startTimezoneId = n["start_timezone_id"] as? String
            night.endTimezoneId = n["end_timezone_id"] as? String
            night.measurementAvailable = (n["measurement_available"] as? Bool) ?? (legacy ? night.asleepMin.map { $0 >= 0 } : nil)
            night.sleepUnstagedMin = number(n["sleep_unstaged_min"]); night.stateUnknownMin = number(n["state_unknown_min"])
            night.offBodyMin = number(n["off_body_min"]); night.stateCoverage = number(n["state_coverage"])
            night.manualEdit = n["manual_edit"] as? Bool
            for s in (n["stages"] as? [[String: Any]]) ?? (n["hypnogram"] as? [[String: Any]]) ?? [] {
                guard let lo = number(s["start"]), let hi = number(s["end"]), hi > lo,
                      lo >= -62135596800, hi <= 253402300799 else { throw DecodeError.invalidPayload }
                let stage = s["stage"] as? String ?? "unknown"
                let stageLegacy = legacy && ((s["algorithm_version"] as? String) ?? sourceVersion) == "frwhoop-server-1"
                let legacyState = ["light", "deep", "rem"].contains(stage) ? "sleep" : ["wake", "awake"].contains(stage) ? "awake" : "state_unknown"
                night.stages.append(ServerScoreStageCache(start: Int(lo), end: Int(hi), stage: stage,
                    state: (s["state"] as? String) ?? (stageLegacy ? legacyState : "state_unknown"), sleepProbability: number(s["p_sleep"]),
                    pWake: number(s["p_wake"]), pLight: number(s["p_light"]), pDeep: number(s["p_deep"]), pRem: number(s["p_rem"]),
                    evidenceCoverage: number(s["evidence_coverage"]), reason: (s["reason"] as? String) ?? (stageLegacy ? "legacy_quality_unavailable" : nil),
                    calibrationStatus: (s["calibration_status"] as? String) ?? (stageLegacy ? "legacy_unvalidated" : nil), algorithmVersion: (s["algorithm_version"] as? String) ?? (stageLegacy ? sourceVersion : nil),
                    computationMode: s["computation_mode"] as? String))
            }
            nights.append(night)
        }
        var result = ServerScoreDayCache(day: day, algorithmVersion: version, daily: daily, nights: nights,
            computedAt: o["computed_at"] as? String, stale: o["stale"] as? Bool ?? true, fetchedAt: fetchedAt)
        result.ownerId = ownerId.lowercased(); result.features = features
        result.rawSnapshotJSON = String(data: data, encoding: .utf8)
        return result
    }

    public static func encodeDaily(_ daily: ServerScoreDailyCache?) -> String? {
        guard let daily else { return nil }
        return (try? JSONEncoder().encode(daily)).flatMap { String(data: $0, encoding: .utf8) }
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

    public func upsert(_ cache: ServerScoreDayCache) throws {
        guard !cache.ownerId.isEmpty, cache.schemaVersion == ServerScoreCacheCodec.schemaVersion,
              !cache.features.isEmpty else { throw ServerScoreCacheCodec.DecodeError.invalidScope }
        let payload = String(data: try JSONEncoder().encode(cache), encoding: .utf8)!
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO serverPhysiologyCacheV2 (ownerId, day, scopeKey, schemaVersion, payloadJson, fetchedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(ownerId, day, scopeKey) DO UPDATE SET payloadJson=excluded.payloadJson,
                  schemaVersion=excluded.schemaVersion, fetchedAt=excluded.fetchedAt
                """, arguments: [cache.ownerId.lowercased(), cache.day, cache.scopeKey, cache.schemaVersion, payload, cache.fetchedAt.timeIntervalSince1970])
        }
    }

    public func load(ownerId: String, day: String, scopeKey: String? = nil,
                     deviceId: String? = nil) throws -> ServerScoreDayCache? {
        guard !ownerId.isEmpty else { return nil }
        return try db.read { db in
            let sql = "SELECT payloadJson FROM serverPhysiologyCacheV2 WHERE ownerId=? AND day=? AND schemaVersion=?" +
                (scopeKey == nil ? "" : " AND scopeKey=?") + " ORDER BY fetchedAt DESC" +
                (deviceId == nil ? " LIMIT 1" : "")
            var args: StatementArguments = [ownerId.lowercased(), day, ServerScoreCacheCodec.schemaVersion]
            if let scopeKey { args += [scopeKey] }
            let rows = try String.fetchCursor(db, sql: sql, arguments: args)
            while let payload = try rows.next() {
                guard let data = payload.data(using: .utf8),
                      var cache = try? JSONDecoder().decode(ServerScoreDayCache.self, from: data),
                      cache.ownerId == ownerId.lowercased(), cache.day == day,
                      cache.schemaVersion == ServerScoreCacheCodec.schemaVersion,
                      scopeKey == nil || scopeKey == cache.scopeKey else { continue }
                if let raw = cache.rawSnapshotJSON?.data(using: .utf8) {
                    guard let reparsed = try? ServerScoreCacheCodec.parseSnapshot(raw, day: day, ownerId: ownerId, fetchedAt: cache.fetchedAt),
                          reparsed.scopeKey == cache.scopeKey else { continue }
                    cache = reparsed
                }
                if let deviceId {
                    guard cache.features.values.contains(where: { $0.deviceId == deviceId }),
                          cache.features.values.allSatisfy({
                              $0.deviceId == deviceId || ($0.deviceId == nil && $0.status == "unavailable")
                          }) else { continue }
                }
                return cache
            }
            return nil
        }
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
        // Pre-v2 cache rows have no authenticated owner; they must never be displayed.
        nil
    }
}

public struct ServerScoreStageCache: Equatable, Codable {
    public let start: Int, end: Int
    public let stage: String, state: String
    public let sleepProbability: Double?, pWake: Double?, pLight: Double?, pDeep: Double?, pRem: Double?
    public let evidenceCoverage: Double?
    public let reason: String?, calibrationStatus: String?, algorithmVersion: String?, computationMode: String?
}

public struct ServerScoreFeatureCache: Equatable, Codable {
    public let status: String, reason: String?
    public let deviceId: String?, algorithmVersion: String?
    public let inputRevision: Int64?, requiredRevision: Int64?
    public let computedAt: String?, observedThrough: String?, publicationStatus: String?, archiveStatus: String?, manifestHash: String?
    public var supportsBoundaryOverrides: Bool? = nil
    public var processingStatus: String? = nil
    public var timezoneId: String? = nil
    public var timezoneIds: [String]? = nil
}

public extension ServerScoreDayCache {
    var sleepMetadataLines: [String] {
        guard let feature = features["sleep"] else { return [] }
        var lines = ["Device: \(feature.deviceId ?? "unavailable")", "Model: \(feature.algorithmVersion ?? "unavailable")"]
        if feature.algorithmVersion == "frwhoop-server-1" {
            lines.append("Legacy baseline · quality and evidence coverage unavailable")
        }
        lines.append("Observed through: \(feature.observedThrough ?? "unavailable")")
        lines.append("Computed: \(feature.computedAt ?? "unavailable")")
        lines.append("Fetched: \(ISO8601DateFormatter().string(from: fetchedAt))")
        lines.append("Revision: \(feature.inputRevision.map(String.init) ?? "unavailable") · required: \(feature.requiredRevision.map(String.init) ?? "unavailable")")
        lines.append("Processing: \(feature.processingStatus ?? "unavailable") · archive: \(feature.archiveStatus ?? "unavailable")")
        let zones = feature.timezoneIds?.filter { !$0.isEmpty } ?? feature.timezoneId.map { [$0] } ?? []
        lines.append("Time zones: \(zones.isEmpty ? "unavailable" : zones.joined(separator: " · "))")
        return lines
    }
}

public extension ServerScoreNightCache {
    var stateCoverageDescription: String {
        guard let coverage = stateCoverage, coverage.isFinite, (0...1).contains(coverage) else { return "State coverage: unavailable" }
        return String(format: "State coverage: %.0f%%", coverage * 100)
    }
}
