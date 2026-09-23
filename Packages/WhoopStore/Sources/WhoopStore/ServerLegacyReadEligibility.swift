import Foundation

/// Read eligibility for the retained v1 producer. Its former RR input did not carry
/// qualified beat timing. This withholds dependent results without changing stored
/// immutable results, numerical kernels, scope validation, or qualified v2 output.
enum ServerLegacyReadEligibility {
    static let algorithm = "frwhoop-server-1"
    static let reason = "beat_timing_unverified"
    static let marker: ServerJSONValue = .object([
        "policy_version": .string("legacy-rr-excluded-1"), "rr_input": .string("excluded")
    ])
    static let always: Set<String> = ["hrv_rmssd_ms", "hrv_sdnn_ms", "current_hrv", "spot_hrv_rmssd_ms",
        "spot_hrv_sdnn_ms", "resp_rate_bpm", "recovery"]
    static let sleep: Set<String> = ["sleep_total_min", "sleep_awake_min", "sleep_light_min", "sleep_deep_min",
        "sleep_rem_min", "sleep_efficiency", "disturbances", "rest", "sleep_performance", "sleep_onset_at", "wake_onset_at",
        "sleep_unstaged_min", "state_unknown_min", "off_body_min"]
    static let nightAlways = always.union(["hrv_summary", "respiration_summary", "avg_hrv", "avg_hrv_ms", "sdnn_ms"])
    static let nightSleep: Set<String> = ["asleep_min", "awake_min", "light_min", "deep_min", "rem_min",
        "efficiency", "disturbances", "rest", "sleep_unstaged_min", "state_unknown_min", "off_body_min", "state_coverage"]
    static let missing: ServerJSONValue = .object(["status": .string("unqualified"), "reason": .string(reason)])

    static func excluded(_ value: ServerJSONValue?) -> Bool { value == marker }
    static func helperMarker(_ raw: String?) -> ServerJSONValue? {
        guard let data = raw?.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let overlay = root["server_scoring"] as? [String: Any],
              root["compute"] == nil, overlay["compute"] == nil,
              let features = overlay["features"] as? [String: [String: Any]],
              let value = features["sleep"]?["input_eligibility"] else { return nil }
        return try? ServerScoreCacheCodec.semanticJSON(value)
    }
    private static func clear(_ object: inout [String: ServerJSONValue], _ keys: Set<String>, existingOnly: Bool = false) {
        for key in keys where !existingOnly || object[key] != nil { object[key] = .null }
    }
    private static func nights(_ value: ServerJSONValue?, marked: Bool) -> ServerJSONValue? {
        guard case .array(let rows) = value else { return value }
        return .array(rows.map { row in
            guard case .object(var n) = row else { return row }
            clear(&n, nightAlways)
            n["respiration_unavailable_reason"] = .string(reason)
            if !marked {
                clear(&n, nightSleep)
                n["stages"] = .array([]); n["hypnogram"] = .array([])
                n["measurement_available"] = .bool(false)
                n["measurement_unavailable_reason"] = .string(reason)
            }
            return .object(n)
        })
    }
    static func values(_ original: [String: ServerJSONValue], algorithm version: String?,
                       details: [String: ServerJSONValue]) -> [String: ServerJSONValue] {
        guard version == algorithm else { return original }
        let marked = excluded(details["input_eligibility"])
        var result = original
        clear(&result, always.union(marked ? [] : sleep), existingOnly: true)
        result["sleep_sessions"] = nights(original["sleep_sessions"], marked: marked)
        return result
    }
    static func details(_ original: [String: ServerJSONValue], values: [String: ServerJSONValue],
                        algorithm version: String?) -> [String: ServerJSONValue] {
        guard version == algorithm else { return original }
        let marked = excluded(original["input_eligibility"])
        var result = original
        var availability: [String: ServerJSONValue] = [:]
        if case .object(let existing) = result["metric_availability"] { availability = existing }
        for key in values.keys where always.contains(key) || (!marked && sleep.contains(key)) {
            availability[key] = missing
        }
        result["metric_availability"] = .object(availability)
        result["input_eligibility"] = marked ? marker : .null
        result["read_eligibility_policy"] = .string("legacy-beat-read-1")
        if values["hrv_rmssd_ms"] != nil || values["resp_rate_bpm"] != nil { result["summary"] = .null }
        if values["current_hrv"] != nil {
            result["measurements"] = .array([]); result.removeValue(forKey: "selected_window")
        }
        if values["sleep_sessions"] != nil {
            result["nights"] = nights(result["nights"], marked: marked)
            if !marked, case .object(var compatibility) = result["daily_compatibility"] {
                clear(&compatibility, sleep, existingOnly: true)
                compatibility["full_day_sleep_epochs"] = .array([])
                result["daily_compatibility"] = .object(compatibility)
            }
        }
        return result
    }

    /// Apply before compatibility equality checks so immutable old duplicate fields
    /// are compared under the same read rule. All retained fields still undergo the
    /// original scope, qualification, revision and duplicate-value validation.
    static func snapshot(_ root: [String: Any]) throws -> [String: Any] {
        guard case .object(var result) = try ServerScoreCacheCodec.semanticJSON(root),
              case .object(var overlay) = result["server_scoring"],
              case .object(let features) = overlay["features"] else { return root }
        func legacy(_ feature: String) -> Bool {
            guard case .object(let f) = features[feature] else { return false }
            return f["algorithm_version"] == .string(algorithm)
        }
        guard ["hrv", "sleep", "respiration"].contains(where: legacy) else { return root }
        let nestedCompute = overlay["compute"] != nil
        var compute: [String: ServerJSONValue] = [:]
        if case .object(let object) = overlay["compute"] ?? result["compute"] { compute = object }
        var families: [String: ServerJSONValue] = [:]
        if case .object(let object) = compute["families"] { families = object }
        var sleepMarker: ServerJSONValue?
        if case .object(let family) = families["sleep"], case .object(let d) = family["details"] {
            sleepMarker = d["input_eligibility"]
        }
        if overlay["compute"] == nil, result["compute"] == nil,
           case .object(let feature) = features["sleep"] {
            sleepMarker = feature["input_eligibility"]
        }
        let marked = excluded(sleepMarker)
        if case .object(var daily) = overlay["daily"] {
            if legacy("hrv") { clear(&daily, ["hrv_rmssd_ms", "hrv_sdnn_ms", "hrv_summary", "recovery"]) }
            if legacy("respiration") {
                clear(&daily, ["resp_rate_bpm", "respiration_summary"])
                daily["respiration_unavailable_reason"] = .string(reason)
            }
            if legacy("sleep") && !marked {
                clear(&daily, sleep); daily["full_day_sleep_epochs"] = .array([])
            }
            overlay["daily"] = .object(daily)
        }
        if legacy("sleep") { overlay["nights"] = nights(overlay["nights"], marked: marked) }
        if legacy("hrv"), case .array(let measurements) = overlay["measurements"] {
            overlay["measurements"] = .array(measurements.filter {
                guard case .object(let row) = $0 else { return true }
                return row["feature"] != .string("hrv")
            })
        }
        for (name, value) in families {
            guard case .object(var family) = value, family["algorithm_version"] == .string(algorithm),
                  case .object(let v) = family["values"], case .object(let d) = family["details"] else { continue }
            let eligibleValues = values(v, algorithm: algorithm, details: d)
            family["values"] = .object(eligibleValues)
            family["details"] = .object(details(d, values: v, algorithm: algorithm))
            families[name] = .object(family)
        }
        if !compute.isEmpty {
            compute["families"] = .object(families)
            if nestedCompute { overlay["compute"] = .object(compute) } else { result["compute"] = .object(compute) }
        }
        result["server_scoring"] = .object(overlay)
        return ServerScoreCacheCodec.foundationJSON(.object(result)) as! [String: Any]
    }

    // These projections also cover Codable caches without rawSnapshotJSON and
    // directly constructed caches; a decoded old object cannot bypass the rule.
    static func daily(_ d: ServerScoreDailyCache?, hrv: Bool, respiration: Bool, sleep: Bool) -> ServerScoreDailyCache? {
        guard let d, hrv || respiration || sleep else { return d }
        return ServerScoreDailyCache(sleepUnstagedMin: sleep ? nil : d.sleepUnstagedMin,
            stateUnknownMin: sleep ? nil : d.stateUnknownMin, offBodyMin: sleep ? nil : d.offBodyMin,
            opportunityKind: d.opportunityKind, recovery: hrv ? nil : d.recovery, rest: sleep ? nil : d.rest,
            strain: d.strain, spo2Pct: d.spo2Pct, skinTempC: d.skinTempC, skinTempDevC: d.skinTempDevC,
            hrvRmssdMs: hrv ? nil : d.hrvRmssdMs, restingHrBpm: d.restingHrBpm,
            sleepTotalMin: sleep ? nil : d.sleepTotalMin, sleepInBedMin: d.sleepInBedMin,
            sleepAwakeMin: sleep ? nil : d.sleepAwakeMin, sleepLightMin: sleep ? nil : d.sleepLightMin,
            sleepDeepMin: sleep ? nil : d.sleepDeepMin, sleepRemMin: sleep ? nil : d.sleepRemMin,
            sleepEfficiency: sleep ? nil : d.sleepEfficiency, respRateBpm: respiration ? nil : d.respRateBpm,
            computedAt: d.computedAt)
    }
    static func night(_ n: ServerScoreNightCache, sleepWithheld: Bool,
                      hrvWithheld: Bool, respirationWithheld: Bool) -> ServerScoreNightCache {
        var result = ServerScoreNightCache(id: n.id, startAt: n.startAt, endAt: n.endAt, isNap: n.isNap,
            asleepMin: sleepWithheld ? nil : n.asleepMin, inBedMin: n.inBedMin,
            lightMin: sleepWithheld ? nil : n.lightMin, deepMin: sleepWithheld ? nil : n.deepMin,
            remMin: sleepWithheld ? nil : n.remMin, awakeMin: sleepWithheld ? nil : n.awakeMin,
            efficiency: sleepWithheld ? nil : n.efficiency, hrvRmssdMs: hrvWithheld ? nil : n.hrvRmssdMs,
            restingHrBpm: n.restingHrBpm)
        result.respRateBpm = respirationWithheld ? nil : n.respRateBpm
        result.startTimezoneId = n.startTimezoneId; result.endTimezoneId = n.endTimezoneId
        result.stages = sleepWithheld ? [] : n.stages; result.deviceId = n.deviceId
        result.episodeType = n.episodeType; result.mainSleepGroupId = n.mainSleepGroupId
        result.boundaryProvenance = n.boundaryProvenance; result.opportunityKind = n.opportunityKind
        result.measurementAvailable = sleepWithheld ? false : n.measurementAvailable
        result.sleepUnstagedMin = sleepWithheld ? nil : n.sleepUnstagedMin
        result.stateUnknownMin = sleepWithheld ? nil : n.stateUnknownMin
        result.offBodyMin = sleepWithheld ? nil : n.offBodyMin
        result.stateCoverage = sleepWithheld ? nil : n.stateCoverage; result.manualEdit = n.manualEdit
        return result
    }
}
