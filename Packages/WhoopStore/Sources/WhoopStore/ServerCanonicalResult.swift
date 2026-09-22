import Foundation

public enum ServerJSONValue: Codable, Equatable, Sendable {
    case null, number(Double), string(String), bool(Bool), array([Self]), object([String: Self])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([Self].self) { self = .array(value) }
        else { self = .object(try c.decode([String: Self].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public var number: Double? { if case .number(let value) = self { return value }; return nil }
}

public struct ServerCanonicalFamilyResult: Codable, Equatable, Sendable {
    public let owner: String
    public let metrics: [String]
    public let status: String
    public let reason: String?
    public let resultRevision: String?
    public let inputRevision: Int64?
    public let algorithmVersion: String?
    public let configurationVersion: String?
    public let modelVersion: String?
    public let preprocessingVersion: String?
    public let qualityVersion: String?
    public let manifestHash: String?
    public let featureManifestHash: String?
    public let canonicalQualification: String?
    public let project: String
    public let ownerID: String
    public let sourceID: String
    public let deviceID: String
    public let window: String
    public let timezoneID: String?
    public let computedAt: String?
    public let observedThrough: String?
    public let freshness: String
    public let expiresAt: String?
    public let decisionID: String?
    public let values: [String: ServerJSONValue]
    public let details: [String: ServerJSONValue]

    enum CodingKeys: String, CodingKey {
        case owner, metrics, status, reason, project, window, freshness, values, details
        case resultRevision = "result_revision", inputRevision = "input_revision"
        case algorithmVersion = "algorithm_version", configurationVersion = "configuration_version"
        case modelVersion = "model_version", preprocessingVersion = "preprocessing_version", qualityVersion = "quality_version"
        case manifestHash = "manifest_hash", featureManifestHash = "feature_manifest_hash"
        case canonicalQualification = "canonical_qualification"
        case ownerID = "owner_id", sourceID = "source_id", deviceID = "device_id", timezoneID = "timezone_id"
        case computedAt = "computed_at", observedThrough = "observed_through", expiresAt = "expires_at", decisionID = "decision_id"
    }

    public var hasCanonicalAuthorization: Bool {
        guard owner == "server", Self.isResultRevision(resultRevision),
              let inputRevision, inputRevision >= 0, Self.timestamp(computedAt) != nil,
              UUID(uuidString: deviceID) != nil, algorithmVersion?.isEmpty == false,
              Self.isHash(manifestHash) else { return false }
        return algorithmVersion == "frwhoop-server-1" && canonicalQualification == "retained_legacy" ||
            canonicalQualification == "signed_reference_approval" && Self.isHash(featureManifestHash)
    }
    public func admitsCanonicalPublication(at now: Date = Date()) -> Bool {
        ["available", "stale"].contains(status) && ["current", "stale"].contains(freshness) &&
            hasCanonicalAuthorization && !isExpired(at: now)
    }
    public func number(_ metric: String, now: Date = Date()) -> Double? {
        guard metrics.contains(metric), admitsCanonicalPublication(at: now) else { return nil }
        return values[metric]?.number
    }
    public func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        guard let expiry = Self.timestamp(expiresAt) else { return true }
        return expiry <= now
    }
    static func timestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
    static func isResultRevision(_ value: String?) -> Bool {
        guard let value else { return false }
        if value.hasPrefix("sha256:") { return isHash(String(value.dropFirst(7))) }
        for prefix in ["compute:", "session:"] where value.hasPrefix(prefix) {
            let number = value.dropFirst(prefix.count)
            return !number.isEmpty && number.allSatisfy { "0123456789".contains($0) }
        }
        return false
    }
    public static func isHash(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

public struct ServerCanonicalResults: Codable, Equatable, Sendable {
    public let mode: String
    public let policyVersion: String
    public let project: String
    public let ownerID: String
    public let sourceID: String
    public let deviceID: String
    public let day: String
    public let families: [String: ServerCanonicalFamilyResult]
    enum CodingKeys: String, CodingKey {
        case mode, project, day, families
        case policyVersion = "policy_version", ownerID = "owner_id", sourceID = "source_id", deviceID = "device_id"
    }
    public static let familyMetrics: [String: Set<String>] = [
        "live_hr_selection": ["live_hr_bpm"],
        "night_hrv": ["hrv_rmssd_ms", "hrv_sdnn_ms", "resting_hr_bpm"],
        "current_hrv": ["current_hrv"],
        "spot_hrv": ["spot_hrv_rmssd_ms", "spot_hrv_sdnn_ms"],
        "sleep": ["sleep_total_min", "sleep_in_bed_min", "sleep_awake_min", "sleep_light_min", "sleep_deep_min", "sleep_rem_min", "sleep_efficiency", "disturbances", "sleep_sessions"],
        "sleep_history": ["sleep_performance", "hours_vs_needed_pct", "sleep_consistency", "restorative_pct", "restorative_min", "sleep_need_min", "sleep_debt_min"],
        "respiration": ["resp_rate_bpm"], "recovery": ["recovery"],
        "strain_energy": ["strain", "active_kcal_est", "avg_hr", "max_hr", "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min", "strength_min"],
        "steps": ["steps", "steps_est"],
        "workouts": ["exercise_count", "workouts", "workout_strain", "workout_kcal", "workout_hr_recovery"],
        "live_workout": ["live_workout_effort"],
        "oxygen": ["spo2_pct", "spo2_red", "spo2_ir", "spo2_candidate"],
        "temperature": ["skin_temp_c", "skin_temp_dev_c"], "intraday_temperature": ["temperature_5min_c"],
        "ppg_hr": ["derived_ppg_hr"],
        "stress": ["stress", "daytime_stress_mean", "daytime_stress_high_min", "baevsky_stress_index", "frequency_hrv"],
        "stress_events": ["stress_onset"], "illness": ["illness_score", "illness_distance"],
        "cycle": ["cycle_phase", "cycle_index"], "circadian": ["circadian_phase_hour", "circadian_offset_min"],
        "readiness_load": ["readiness", "training_load", "acute_load", "chronic_load", "training_balance", "acwr", "training_monotony"],
        "fitness_longevity": ["fitness_age", "vo2max_est", "vitality", "body_age"],
        "baselines": ["historical_baselines", "recovery_drivers", "recovery_forecast"],
        "biofeedback": ["resonance_frequency", "resonance_pace"],
        "live_coaching": ["coaching_hr_band", "coaching_decision"], "insights": ["insights"],
    ]
    public static let allMetrics = familyMetrics.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    public static let states: Set<String> = ["available", "unsupported", "insufficient_input", "insufficient_quality", "unqualified", "processing", "failed", "unavailable", "stale", "revoked"]
    public static let freshnessStates: Set<String> = ["current", "stale", "expired", "unavailable"]

    public func validate(owner: String, day: String, project expectedProject: String? = nil,
                         source: String? = nil, device: String? = nil) throws {
        guard mode == "final_hosted", policyVersion == "vps-only-1", ownerID == owner.lowercased(), self.day == day,
              Self.isProject(project), UUID(uuidString: ownerID) != nil,
              UUID(uuidString: sourceID) != nil, UUID(uuidString: deviceID) != nil,
              expectedProject == nil || Self.projectKey(project) == Self.projectKey(expectedProject!),
              source == nil || sourceID == source, device == nil || deviceID == device,
              Set(families.keys) == Set(Self.familyMetrics.keys) else { throw ServerScoreCacheCodec.DecodeError.invalidScope }
        for (key, result) in families {
            guard result.owner == "server", Set(result.metrics) == Self.familyMetrics[key],
                  Self.states.contains(result.status), result.ownerID == ownerID,
                  result.project == project, result.sourceID == sourceID, result.deviceID == deviceID,
                  result.window == day, result.inputRevision == nil || result.inputRevision! >= 0,
                  Set(result.values.keys).isSubset(of: Self.familyMetrics[key]!),
                  Self.freshnessStates.contains(result.freshness),
                  result.timezoneID == nil || TimeZone(identifier: result.timezoneID!) != nil,
                  result.resultRevision == nil || (ServerCanonicalFamilyResult.isResultRevision(result.resultRevision) && result.computedAt != nil && result.algorithmVersion?.isEmpty == false && result.inputRevision != nil),
                  [result.computedAt, result.observedThrough, result.expiresAt].allSatisfy({ $0 == nil || ServerCanonicalFamilyResult.timestamp($0) != nil }),
                  !["available", "stale"].contains(result.status) || result.hasCanonicalAuthorization,
                  ["available", "stale"].contains(result.status) || result.values.values.allSatisfy({ $0 == .null })
            else { throw ServerScoreCacheCodec.DecodeError.invalidPayload }
        }
    }
    public func result(for metric: String) -> ServerCanonicalFamilyResult? {
        guard let family = Self.familyMetrics.first(where: { $0.value.contains(metric) })?.key else { return nil }
        return families[family]
    }
    public static func projectKey(_ project: String) -> String { project.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    private static func isProject(_ project: String) -> Bool {
        guard let url = URLComponents(string: project), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.host != nil else { return false }
        return url.scheme == "https" || url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(url.host!)
    }
}
