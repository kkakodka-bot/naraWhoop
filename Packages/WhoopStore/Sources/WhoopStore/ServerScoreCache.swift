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
    public var rest: Double?
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
        sleepUnstagedMin: Double? = nil,
        stateUnknownMin: Double? = nil,
        offBodyMin: Double? = nil,
        opportunityKind: String? = nil,
        recovery: Double? = nil,
        rest: Double? = nil,
        strain: Double? = nil,
        spo2Pct: Double? = nil,
        skinTempC: Double? = nil,
        skinTempDevC: Double? = nil,
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
        self.sleepUnstagedMin = sleepUnstagedMin
        self.stateUnknownMin = stateUnknownMin
        self.offBodyMin = offBodyMin
        self.opportunityKind = opportunityKind
        self.recovery = recovery
        self.rest = rest
        self.strain = strain
        self.spo2Pct = spo2Pct
        self.skinTempC = skinTempC
        self.skinTempDevC = skinTempDevC
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
    public var respRateBpm: Double?
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

public struct ServerSignalWindowCache: Equatable {
    public let windowId: String, kind: String, modality: String, unit: String
    public let start: Int64, end: Int64, inputRevision: Int64
    public let measurementStatus: String, reason: String?, freshnessStatus: String
    public let observedFraction: Double?

    init?(_ row: [String: Any], owner: String, device: String) {
        guard !owner.isEmpty, !device.isEmpty, Self.integer(row["schema_version"]) == 1,
              row["algorithm_version"] as? String == "sensor-windows-1", row["user_id"] as? String == owner,
              row["device_id"] as? String == device, let kind = row["kind"] as? String,
              ["hrv", "ppg", "imu", "temperature", "spo2"].contains(kind),
              let start = Self.integer(row["start"]), let end = Self.integer(row["end"]),
              let duration = Self.integer(row["duration_seconds"]), Self.integer(row["stride_seconds"]) == duration,
              duration == (kind == "spo2" ? 900 : 300), start >= 0, end <= 4_102_444_800, start % duration == 0,
              end > start, end - start == duration, row["publication_status"] as? String == "shadow",
              row["values"] is NSNull, let state = row["measurement_status"] as? String,
              ["unavailable", "unqualified", "blocked"].contains(state),
              let revisionText = row["input_revision"] as? String, let revision = Self.revision(revisionText),
              row["result_revision"] as? String == revisionText,
              let identifier = row["window_id"] as? String, UUID(uuidString: identifier) != nil,
              let modality = row["modality"] as? String, let unit = row["unit"] as? String,
              let freshness = row["freshness_status"] as? String,
              let reason = row["reason"] as? String, reason.range(of: "^[a-z][a-z0-9_]{0,95}\\z", options: .regularExpression) != nil,
              row["quality"] is [String: Any], row["computation_mode"] as? String == "retrospective",
              row["provenance"] as? String == "vps_estimate", row["calibration_status"] as? String == "not_reference_validated",
              Self.nonemptyString(row["computed_at"]), Self.nonemptyString(row["quality_policy_version"]),
              Self.nonemptyString(row["preprocess_version"]),
              row["published_at"] is NSNull || Self.nonemptyString(row["published_at"]),
              row["source"] is NSNull || Self.nonemptyString(row["source"]),
              Self.nullableNumber(row["observed_fraction"], within: 0...1),
              Self.nullableNumber(row["maximum_gap_seconds"], within: 0...Double(duration)),
              Self.nullableNumber(row["observed_through"], within: Double(start)...Double(end)) else { return nil }
        let required: Int64?
        if row["required_revision"] is NSNull { required = nil }
        else {
            guard let value = Self.integer(row["required_revision"]), value > 0 else { return nil }
            required = value
        }
        guard freshness == (required.map { $0 > revision } == true ? "stale" : "snapshot") else { return nil }
        let units = ["hrv": "ms", "ppg": "bpm", "imu": "m_s2_and_rad_s", "temperature": "degC_skin", "spo2": "percent"]
        guard unit == units[kind], kind == "hrv" ? ["unknown", "ppg_ibi", "ecg_nn"].contains(modality) : modality == (kind == "spo2" ? "unknown" : kind),
              kind != "spo2" || state == "blocked" else { return nil }
        let fraction = Self.number(row["observed_fraction"])
        self.windowId = identifier; self.kind = kind; self.start = start; self.end = end
        self.modality = modality; self.unit = unit; self.measurementStatus = state
        self.reason = reason; self.inputRevision = revision
        self.freshnessStatus = freshness; self.observedFraction = fraction
    }

    private static func nonemptyString(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int64(number.stringValue)
    }
    private static func revision(_ text: String) -> Int64? {
        guard text.range(of: "^[1-9][0-9]{0,18}$", options: .regularExpression) != nil else { return nil }
        return Int64(text)
    }
    private static func nullableNumber(_ value: Any?, within range: ClosedRange<Double>) -> Bool {
        if value is NSNull { return true }
        guard let value = number(value) else { return false }
        return range.contains(value)
    }
}

public struct ServerScoreDayCache: Equatable, Codable {
    public var canonicalResults: ServerCanonicalResults?
    public var pendingCanonicalResults: ServerPendingCanonicalResults?
    /// Populated from the separate account/device cutover ledger at read time.
    public var ownedMetrics: Set<String>? = nil
    /// Transport state is separate from the server's processing/publication status.
    public var readFailure: String? = nil
    public var ownerId: String = ""
    public var schemaVersion: Int = 2
    public var features: [String: ServerScoreFeatureCache] = [:]
    private var storedRawSnapshotJSON: String?
    private var storedFullDaySleepEpochs: [ServerScoreStageCache]?
    public var rawSnapshotJSON: String? {
        get {
            guard let raw = storedRawSnapshotJSON, features.values.contains(where: {
                $0.algorithmVersion == ServerLegacyReadEligibility.algorithm
            }) else { return storedRawSnapshotJSON }
            guard let data = raw.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eligible = try? ServerLegacyReadEligibility.snapshot(root),
                  let encoded = try? JSONSerialization.data(withJSONObject: eligible, options: [.sortedKeys]) else { return nil }
            return String(data: encoded, encoding: .utf8)
        }
        set { storedRawSnapshotJSON = newValue }
    }
    public var fullDaySleepEpochs: [ServerScoreStageCache]? {
        get { legacySleepWithheld ? [] : storedFullDaySleepEpochs }
        set { storedFullDaySleepEpochs = newValue }
    }
    var legacySleepWithheld: Bool {
        isLegacyFeature("sleep", family: "sleep") &&
            !ServerLegacyReadEligibility.excluded(canonicalResults != nil
                ? canonicalResults?.families["sleep"]?.details["input_eligibility"]
                : ServerLegacyReadEligibility.helperMarker(storedRawSnapshotJSON))
    }
    func isLegacyFeature(_ feature: String, family: String) -> Bool {
        (features[feature]?.algorithmVersion ?? canonicalResults?.families[family]?.algorithmVersion ?? algorithmVersion)
            == ServerLegacyReadEligibility.algorithm
    }
    enum CodingKeys: String, CodingKey {
        case canonicalResults, pendingCanonicalResults, ownedMetrics, readFailure, ownerId, schemaVersion, features
        case day, algorithmVersion, computedAt, stale, fetchedAt
        case storedRawSnapshotJSON = "rawSnapshotJSON", storedFullDaySleepEpochs = "fullDaySleepEpochs"
        case storedDaily = "daily", storedNights = "nights"
    }
    public var measurementsJSON: String? {
        guard let data = rawSnapshotJSON?.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let overlay = root["server_scoring"] as? [String: Any], let values = overlay["measurements"] as? [Any],
              let encoded = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return nil }
        return String(data: encoded, encoding: .utf8)
    }
    /// Missingness from the separate shadow diagnostic contract never authorizes a headline value.
    public var signalWindows: [ServerSignalWindowCache] {
        guard let data = rawSnapshotJSON?.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let overlay = root["server_scoring"] as? [String: Any],
              overlay["user_id"] as? String == ownerId, overlay["day"] as? String == day,
              let device = overlay["signal_windows_device_id"] as? String,
              let rows = overlay["signal_windows"] as? [[String: Any]], rows.count <= 4096 else { return [] }
        return rows.compactMap { ServerSignalWindowCache($0, owner: ownerId, device: device) }
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
        self.storedDaily = daily
        self.storedNights = nights
        self.computedAt = computedAt
        self.stale = stale
        self.fetchedAt = fetchedAt
    }

    public let day: String
    public let algorithmVersion: String
    private let storedDaily: ServerScoreDailyCache?
    private let storedNights: [ServerScoreNightCache]
    public var daily: ServerScoreDailyCache? {
        ServerLegacyReadEligibility.daily(storedDaily, hrv: isLegacyFeature("hrv", family: "night_hrv"),
            respiration: isLegacyFeature("respiration", family: "respiration"), sleep: legacySleepWithheld)
    }
    public var nights: [ServerScoreNightCache] {
        let legacySleep = isLegacyFeature("sleep", family: "sleep")
        let legacyHrv = legacySleep || isLegacyFeature("hrv", family: "night_hrv")
        let legacyRespiration = legacySleep || isLegacyFeature("respiration", family: "respiration")
        guard legacySleep || legacyHrv || legacyRespiration else { return storedNights }
        return storedNights.map { ServerLegacyReadEligibility.night($0, sleepWithheld: legacySleepWithheld,
            hrvWithheld: legacyHrv, respirationWithheld: legacyRespiration) }
    }
    public let computedAt: String?
    public var stale: Bool
    public let fetchedAt: Date
}

public enum ServerScoreCacheCodec {
    public static let algorithmVersion = "frwhoop-physiology-2"
    public static let schemaVersion = 2
    public enum DecodeError: Error { case invalidScope, invalidPayload }

    private struct DailyBinding {
        let topLevel: String
        let family: String
        let metric: String
        let canonicalScale: Double
    }

    private static let dailyBindings = [
        DailyBinding(topLevel: "hrv_rmssd_ms", family: "night_hrv", metric: "hrv_rmssd_ms", canonicalScale: 1),
        DailyBinding(topLevel: "hrv_sdnn_ms", family: "night_hrv", metric: "hrv_sdnn_ms", canonicalScale: 1),
        DailyBinding(topLevel: "resting_hr_bpm", family: "night_hrv", metric: "resting_hr_bpm", canonicalScale: 1),
        DailyBinding(topLevel: "sleep_total_min", family: "sleep", metric: "sleep_total_min", canonicalScale: 1),
        DailyBinding(topLevel: "sleep_in_bed_min", family: "sleep", metric: "sleep_in_bed_min", canonicalScale: 1),
        DailyBinding(topLevel: "sleep_awake_min", family: "sleep", metric: "sleep_awake_min", canonicalScale: 1),
        DailyBinding(topLevel: "sleep_light_min", family: "sleep", metric: "sleep_light_min", canonicalScale: 1),
        DailyBinding(topLevel: "sleep_deep_min", family: "sleep", metric: "sleep_deep_min", canonicalScale: 1),
        DailyBinding(topLevel: "sleep_rem_min", family: "sleep", metric: "sleep_rem_min", canonicalScale: 1),
        // The compatibility payload stores a fraction. The canonical family stores percent.
        DailyBinding(topLevel: "sleep_efficiency", family: "sleep", metric: "sleep_efficiency", canonicalScale: 100),
        DailyBinding(topLevel: "disturbances", family: "sleep", metric: "disturbances", canonicalScale: 1),
        DailyBinding(topLevel: "resp_rate_bpm", family: "respiration", metric: "resp_rate_bpm", canonicalScale: 1),
        DailyBinding(topLevel: "recovery", family: "recovery", metric: "recovery", canonicalScale: 1),
        DailyBinding(topLevel: "strain", family: "strain_energy", metric: "strain", canonicalScale: 1),
        DailyBinding(topLevel: "spo2_pct", family: "oxygen", metric: "spo2_pct", canonicalScale: 1),
        DailyBinding(topLevel: "skin_temp_c", family: "temperature", metric: "skin_temp_c", canonicalScale: 1),
        DailyBinding(topLevel: "skin_temp_dev_c", family: "temperature", metric: "skin_temp_dev_c", canonicalScale: 1),
    ]

    private static let featureBackedFamilies = [
        "night_hrv": "hrv", "current_hrv": "hrv", "recovery": "hrv", "strain_energy": "hrv",
        "oxygen": "hrv", "temperature": "hrv", "sleep": "sleep", "respiration": "respiration",
    ]

    private static let sleepCompatibilityKeys: Set<String> = [
        "sleep_onset_at", "wake_onset_at", "sleep_unstaged_min", "state_unknown_min", "off_body_min",
        "main_sleep_group_id", "opportunity_kind", "full_day_sleep_epochs",
    ]

    static func semanticJSON(_ value: Any) throws -> ServerJSONValue {
        if value is NSNull { return .null }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            guard number.doubleValue.isFinite else { throw DecodeError.invalidPayload }
            return .number(number.doubleValue)
        }
        if let string = value as? String { return .string(string) }
        if let array = value as? [Any] { return .array(try array.map(semanticJSON)) }
        if let object = value as? [String: Any] {
            return .object(try object.mapValues(semanticJSON))
        }
        throw DecodeError.invalidPayload
    }

    static func foundationJSON(_ value: ServerJSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .number(let value): return value
        case .string(let value): return value
        case .bool(let value): return value
        case .array(let value): return value.map(foundationJSON)
        case .object(let value): return value.mapValues(foundationJSON)
        }
    }

    private static func requireProjectionIdentity(
        _ family: ServerCanonicalFamilyResult,
        feature key: String,
        features: [String: ServerScoreFeatureCache]
    ) throws {
        guard let feature = features[key], feature.hasCanonicalAuthorization,
              family.deviceID == feature.deviceId,
              family.algorithmVersion == feature.algorithmVersion,
              family.inputRevision == feature.inputRevision,
              family.manifestHash == feature.manifestHash,
              family.featureManifestHash == feature.featureManifestHash,
              family.canonicalQualification == feature.canonicalQualification else {
            throw DecodeError.invalidScope
        }
    }

    private static func admitsCompatibilityProjection(
        _ family: ServerCanonicalFamilyResult,
        family name: String,
        at now: Date
    ) -> Bool {
        guard family.hasCanonicalAuthorization, !family.isExpired(at: now),
              ["current", "stale"].contains(family.freshness) else { return false }
        if ["available", "stale"].contains(family.status) { return true }
        // A selected closed HRV window can carry immutable measurement details while
        // intentionally withholding the scalar current-HRV value.
        return name == "current_hrv" && family.status == "insufficient_quality"
    }

    /// Compatibility fields remain for older presentation call sites, but final-hosted responses may
    /// only populate them from the same immutable family result consumed by the canonical adapters.
    private static func reconcileCanonicalCompatibility(
        _ overlay: [String: Any],
        canonical: ServerCanonicalResults,
        features: [String: ServerScoreFeatureCache],
        at now: Date
    ) throws -> [String: Any] {
        var result = overlay
        let rawDaily = overlay["daily"] as? [String: Any]
        var daily: [String: Any] = [:]
        var hasDailyProjection = false

        for (familyName, featureKey) in featureBackedFamilies {
            if let family = canonical.families[familyName], family.hasCanonicalAuthorization {
                try requireProjectionIdentity(family, feature: featureKey, features: features)
            }
        }

        for binding in dailyBindings {
            guard let family = canonical.families[binding.family], family.hasCanonicalAuthorization else { continue }
            guard let raw = rawDaily?[binding.topLevel], let expected = family.values[binding.metric] else {
                throw DecodeError.invalidPayload
            }
            var observed = try semanticJSON(raw)
            if binding.canonicalScale != 1, case .number(let value) = observed {
                observed = .number(value * binding.canonicalScale)
            }
            guard observed == expected else { throw DecodeError.invalidPayload }
            guard admitsCompatibilityProjection(family, family: binding.family, at: now) else { continue }
            let projected: ServerJSONValue
            if binding.canonicalScale != 1, case .number(let value) = expected {
                projected = .number(value / binding.canonicalScale)
            } else {
                projected = expected
            }
            daily[binding.topLevel] = foundationJSON(projected)
            hasDailyProjection = true
        }

        if let family = canonical.families["night_hrv"], family.hasCanonicalAuthorization {
            for (topLevel, detail) in [("hrv_summary", "summary"), ("heart_rate_windows", "heart_rate_windows")] {
                guard let raw = rawDaily?[topLevel], let expected = family.details[detail],
                      try semanticJSON(raw) == expected else { throw DecodeError.invalidPayload }
                if admitsCompatibilityProjection(family, family: "night_hrv", at: now) {
                    daily[topLevel] = foundationJSON(expected)
                    hasDailyProjection = true
                }
            }
        }
        if let family = canonical.families["respiration"], family.hasCanonicalAuthorization {
            guard let raw = rawDaily?["respiration_summary"], let expected = family.details["summary"],
                  try semanticJSON(raw) == expected else { throw DecodeError.invalidPayload }
            if admitsCompatibilityProjection(family, family: "respiration", at: now) {
                daily["respiration_summary"] = foundationJSON(expected)
                hasDailyProjection = true
            }
        }

        if let family = canonical.families["sleep"], family.hasCanonicalAuthorization {
            guard let rawNights = overlay["nights"], let valueNights = family.values["sleep_sessions"],
                  let detailNights = family.details["nights"],
                  try semanticJSON(rawNights) == valueNights, valueNights == detailNights,
                  let rawOverrides = overlay["sleep_overrides"], let detailOverrides = family.details["sleep_overrides"],
                  try semanticJSON(rawOverrides) == detailOverrides else { throw DecodeError.invalidPayload }
            let admitted = admitsCompatibilityProjection(family, family: "sleep", at: now)
            result["nights"] = admitted ? foundationJSON(valueNights) : [Any]()
            result["sleep_overrides"] = admitted ? foundationJSON(detailOverrides) : [Any]()

            if let compatibility = family.details["daily_compatibility"] {
                guard case .object(let values) = compatibility,
                      Set(values.keys) == sleepCompatibilityKeys else { throw DecodeError.invalidPayload }
                for key in sleepCompatibilityKeys {
                    guard let raw = rawDaily?[key], let expected = values[key],
                          try semanticJSON(raw) == expected else { throw DecodeError.invalidPayload }
                    if admitted { daily[key] = foundationJSON(expected) }
                }
                if admitted { hasDailyProjection = true }
            }
        } else {
            result["nights"] = [Any]()
            result["sleep_overrides"] = [Any]()
        }

        if let family = canonical.families["current_hrv"], family.hasCanonicalAuthorization {
            guard let rows = overlay["measurements"] as? [Any], let expected = family.details["measurements"] else {
                throw DecodeError.invalidPayload
            }
            let hrvRows = rows.filter { ($0 as? [String: Any])?["feature"] as? String == "hrv" }
            guard try semanticJSON(hrvRows) == expected else { throw DecodeError.invalidPayload }
            result["measurements"] = admitsCompatibilityProjection(family, family: "current_hrv", at: now)
                ? foundationJSON(expected) : [Any]()
        } else {
            result["measurements"] = [Any]()
        }

        let admittedFamilies = canonical.families.filter {
            admitsCompatibilityProjection($0.value, family: $0.key, at: now)
        }.map(\.value)
        let computed = admittedFamilies.compactMap(\.computedAt).max { lhs, rhs in
            guard let left = ServerCanonicalFamilyResult.timestamp(lhs),
                  let right = ServerCanonicalFamilyResult.timestamp(rhs) else { return lhs < rhs }
            return left < right
        }
        let stale = admittedFamilies.isEmpty || admittedFamilies.contains {
            $0.status == "stale" || $0.freshness != "current"
        }
        result["computed_at"] = computed ?? NSNull()
        result["stale"] = stale

        if hasDailyProjection {
            daily["day"] = canonical.day
            daily["source_device_id"] = canonical.deviceID
            daily["computed_at"] = computed ?? NSNull()
            result["daily"] = daily
        } else {
            result["daily"] = NSNull()
        }
        return result
    }

    public static func parseSnapshot(_ data: Data, day: String, ownerId: String,
                                     fetchedAt: Date = Date()) throws -> ServerScoreDayCache {
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.invalidPayload
        }
        var root = try ServerLegacyReadEligibility.snapshot(decoded)
        guard !ownerId.isEmpty,
              var o = root["server_scoring"] as? [String: Any],
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
                timezoneIds: f["timezone_ids"] as? [String],
                canonicalQualification: f["canonical_qualification"] as? String,
                featureManifestHash: f["feature_manifest_hash"] as? String)
        }
        var canonicalResults: ServerCanonicalResults?
        var pendingCanonicalResults: ServerPendingCanonicalResults?
        if let compute = o["compute"] ?? root["compute"] {
            let encoded = try JSONSerialization.data(withJSONObject: compute)
            if (compute as? [String: Any])?["device_id"] is NSNull {
                let pending = try JSONDecoder().decode(ServerPendingCanonicalResults.self, from: encoded)
                try pending.validate(owner: ownerId, day: day)
                guard o["daily"] is NSNull, (o["nights"] as? [Any])?.isEmpty == true,
                      o["computed_at"] is NSNull,
                      features.values.allSatisfy({ $0.deviceId == nil && $0.status == "unavailable" }) else {
                    throw DecodeError.invalidPayload
                }
                pendingCanonicalResults = pending
            } else {
                let canonical = try JSONDecoder().decode(ServerCanonicalResults.self, from: encoded)
                try canonical.validate(owner: ownerId, day: day)
                guard features.values.allSatisfy({ $0.deviceId == nil || $0.deviceId == canonical.deviceID }) else {
                    throw DecodeError.invalidScope
                }
                o = try reconcileCanonicalCompatibility(o, canonical: canonical, features: features, at: fetchedAt)
                canonicalResults = canonical
            }
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
            daily?.rest = number(d["rest"])
            daily?.strain = number(d["strain"])
            daily?.spo2Pct = number(d["spo2_pct"])
            daily?.skinTempC = number(d["skin_temp_c"])
            daily?.skinTempDevC = number(d["skin_temp_dev_c"])
        }
        let sleep = features["sleep"]
        let nestedHrv = features["hrv"]?.matchesCanonicalSnapshot(sleep) == true
        let nestedRespiration = features["respiration"]?.matchesCanonicalSnapshot(sleep) == true
        var nights: [ServerScoreNightCache] = []
        var authorizedNights: [[String: Any]] = []
        for var n in (o["nights"] as? [[String: Any]]) ?? [] {
            guard let id = n["id"] as? String, !id.isEmpty,
                  let start = n["start_at"] as? String, let end = n["end_at"] as? String else { throw DecodeError.invalidPayload }
            let device = n["device_id"] as? String
            if let selectedDevice = features["sleep"]?.deviceId, device != selectedDevice { throw DecodeError.invalidScope }
            if let episodeOwner = n["user_id"] as? String, episodeOwner.lowercased() != ownerId.lowercased() { throw DecodeError.invalidScope }
            let sourceVersion = (n["algorithm_version"] as? String) ?? features["sleep"]?.algorithmVersion
            if let selectedVersion = sleep?.algorithmVersion, sourceVersion != selectedVersion { throw DecodeError.invalidScope }
            if !nestedHrv {
                for key in ["hrv_rmssd_ms", "hrv_sdnn_ms", "resting_hr_bpm", "overnight_hr_bpm", "hrv_summary", "heart_rate_windows",
                            "recovery", "strain", "spo2_pct", "skin_temp_c", "skin_temp_dev_c"] {
                    n.removeValue(forKey: key)
                }
            }
            if !nestedRespiration {
                for key in ["resp_rate_bpm", "respiration_summary", "respiration_unavailable_reason"] { n.removeValue(forKey: key) }
            }
            authorizedNights.append(n)
            let legacy = sourceVersion == "frwhoop-server-1"
            var night = ServerScoreNightCache(id: id, startAt: start, endAt: end, isNap: n["is_nap"] as? Bool ?? false,
                asleepMin: number(n["asleep_min"]), inBedMin: number(n["in_bed_min"]), lightMin: number(n["light_min"]),
                deepMin: number(n["deep_min"]), remMin: number(n["rem_min"]), awakeMin: number(n["awake_min"]),
                efficiency: number(n["efficiency"]), hrvRmssdMs: number(n["hrv_rmssd_ms"]), restingHrBpm: integer(n["resting_hr_bpm"]))
            night.deviceId = device; night.episodeType = (n["episode_type"] as? String) ?? (legacy ? (night.isNap ? "nap" : "main_sleep") : nil)
            night.respRateBpm = number(n["resp_rate_bpm"])
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
                    computationMode: s["computation_mode"] as? String,
                    contextKind: s["context_kind"] as? String, contextProvenance: s["context_provenance"] as? String))
            }
            nights.append(night)
        }
        var result = ServerScoreDayCache(day: day, algorithmVersion: version, daily: daily, nights: nights,
            computedAt: o["computed_at"] as? String, stale: o["stale"] as? Bool ?? true, fetchedAt: fetchedAt)
        result.ownerId = ownerId.lowercased(); result.features = features
        if let pendingCanonicalResults {
            result.pendingCanonicalResults = pendingCanonicalResults
            result.ownedMetrics = pendingCanonicalResults.ownedMetrics
        } else if let canonicalResults {
            result.canonicalResults = canonicalResults
        }
        if let epochs = (o["daily"] as? [String: Any])?["full_day_sleep_epochs"] as? [[String: Any]] {
            result.fullDaySleepEpochs = try epochs.map { s in
                guard let lo = number(s["start"]), let hi = number(s["end"]), hi > lo,
                      lo.rounded() == lo, hi.rounded() == hi, lo >= -62135596800, hi <= 253402300799 else {
                    throw DecodeError.invalidPayload
                }
                return ServerScoreStageCache(start: Int(lo), end: Int(hi), stage: s["stage"] as? String ?? "unknown",
                    state: s["state"] as? String ?? "state_unknown", sleepProbability: number(s["p_sleep"]),
                    pWake: number(s["p_wake"]), pLight: number(s["p_light"]), pDeep: number(s["p_deep"]), pRem: number(s["p_rem"]),
                    evidenceCoverage: number(s["evidence_coverage"]), reason: s["reason"] as? String,
                    calibrationStatus: s["calibration_status"] as? String, algorithmVersion: s["algorithm_version"] as? String,
                    computationMode: s["computation_mode"] as? String,
                    contextKind: s["context_kind"] as? String, contextProvenance: s["context_provenance"] as? String)
            }
        }
        if canonicalResults == nil {
            o["nights"] = authorizedNights
        } else if case .array = canonicalResults?.families["sleep"]?.values["sleep_sessions"] {
            // Parsing can strip nested fields owned by a different family, but preserves
            // the selected sleep family's array order exactly.
            o["nights"] = authorizedNights
        }
        root["server_scoring"] = o
        result.rawSnapshotJSON = String(data: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), encoding: .utf8)
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
    public var contextKind: String? = nil, contextProvenance: String? = nil
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
    public var canonicalQualification: String? = nil
    public var featureManifestHash: String? = nil
    public var hasCanonicalAuthorization: Bool {
        if ["shadow", "revoked"].contains(publicationStatus ?? "") { return false }
        if algorithmVersion == "frwhoop-server-1" { return true }
        guard canonicalQualification == "signed_reference_approval", let featureManifestHash else { return false }
        return featureManifestHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
    public var isCanonicalAvailable: Bool {
        ["available", "fresh", "stale"].contains(status) && hasCanonicalAuthorization
    }
    public func matchesCanonicalSnapshot(_ other: ServerScoreFeatureCache?) -> Bool {
        guard let other, isCanonicalAvailable, other.isCanonicalAvailable else { return false }
        return deviceId == other.deviceId && algorithmVersion == other.algorithmVersion && inputRevision == other.inputRevision
    }
    public var decodeDiagnostic: ServerScoreStageDiagnostic {
        ServerScoreStageDiagnostic(stage: "decoded", status: isCanonicalAvailable ? "available" : "unavailable",
            reason: ["shadow", "revoked"].contains(publicationStatus ?? "") ? "publication_not_canonical" :
                !hasCanonicalAuthorization ? "canonical_qualification_missing" : reason)
    }
}

/// Local stage metadata intentionally excludes identities, credentials and physiological values.
public struct ServerScoreStageDiagnostic: Equatable, Codable {
    public let stage: String, status: String
    public let reason: String?
    public init(stage: String, status: String, reason: String?) {
        self.stage = stage; self.status = status
        self.reason = reason.map { $0.range(of: "^[a-z0-9_]{1,96}$", options: .regularExpression) == nil ? "unclassified_reason" : $0 }
    }
}

public extension ServerScoreDayCache {
    var sleepMetadataLines: [String] {
        guard let feature = features["sleep"] else { return [] }
        var lines = ["Device: \(feature.deviceId ?? "unavailable")", "Model: \(feature.algorithmVersion ?? "unavailable")"]
        if feature.algorithmVersion == "frwhoop-server-1" {
            lines.append("Legacy baseline · quality and evidence coverage unavailable")
        }
        if !feature.hasCanonicalAuthorization { lines.append("Unavailable: signed feature qualification missing") }
        if legacySleepWithheld { lines.append("Sleep staging unavailable: beat timing unverified") }
        if let epochs = fullDaySleepEpochs, feature.hasCanonicalAuthorization, !legacySleepWithheld {
            let unknown = epochs.filter { $0.state == "state_unknown" }.reduce(0) { $0 + $1.end - $1.start }
            let offBody = epochs.filter { $0.state == "off_body" }.reduce(0) { $0 + $1.end - $1.start }
            lines.append("Full-day unknown: \(unknown / 60) min · off body: \(offBody / 60) min")
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
