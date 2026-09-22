import Foundation
import WhoopProtocol
@testable import StrandAnalytics

/// Serialization vocabulary, not a scoring implementation or a full-server-day envelope.
enum ServerDaySwiftV3Metadata {
    typealias C = ServerDaySwiftContract
    typealias V = ServerDaySwiftV3Contract
    typealias X = ServerDaySwiftV3Context
    typealias P = ServerDaySwiftV3CoreProbe

    struct Scope: Codable, Equatable {
        let identity: C.Identity
        let day: String
        let timezone: String
        let asOfExclusive: Int
        let contextDigest: String
        init(_ execution: X.Execution) {
            let input = execution.observation.input
            identity = input.identity; day = input.day; timezone = input.timezone
            asOfExclusive = input.asOfExclusive; contextDigest = execution.digest
        }
        func validate() throws {
            guard !identity.algorithmVersion.isEmpty, try C.dayBounds(day, timezone).upperBound == asOfExclusive,
                  contextDigest.count == 64, contextDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw failure("sidecar_scope")
            }
        }
    }
    enum Status: String, Codable { case available, unavailable, experimental }
    enum Method: Equatable {
        case native(String)
        case imported(String, String)
        var text: String {
            switch self {
            case .native(let method): return method
            case .imported(let kind, let method): return "imported:\(kind):\(method)"
            }
        }
        func validate() throws {
            switch self {
            case .native(let method): guard nativeMethods.contains(method) else { throw failure("unknown_method:\(method)") }
            case .imported(let kind, let method):
                guard ServerDaySwiftV3Imports.Kind(rawValue: kind) != nil, (1...128).contains(method.count) else {
                    throw failure("import_method")
                }
            }
        }
    }
    struct Reading: Encodable, Equatable {
        let value: Double?
        let unit: String
        let status: Status
        let method: Method
        init(value: Double?, unit: String, status: Status? = nil, method: Method) throws {
            let actualStatus = status ?? (value == nil ? .unavailable : .available)
            guard units.contains(unit), value.map(\.isFinite) ?? true,
                  actualStatus != .experimental,
                  value == nil ? actualStatus == .unavailable : actualStatus != .unavailable else { throw failure("metric_reading") }
            try method.validate()
            self.value = value; self.unit = unit; self.status = actualStatus; self.method = method
        }
        func encode(to encoder: Encoder) throws {
            try C.JSON.object(["value": number(value), "unit": .string(unit), "status": .string(status.rawValue),
                               "method": .string(method.text)]).encode(to: encoder)
        }
    }
    struct Projection: Encodable, Equatable {
        let metrics: [String: Reading]
        let details: [String: C.JSON]
        let charts: [String: C.JSON]
        let chartMetadata: [String: C.JSON]
        let capabilities: [String]
        let gaps: [String]
    }
    struct Bucket: Encodable, Equatable {
        let start: Int
        let end: Int
        let value: Double
        let count: Int
        let min: Double
        let max: Double
    }

    static let units: Set<String> = ["ms", "bpm", "breaths/min", "score_0_100", "score_0_3", "count", "kcal",
        "percent", "adc", "C", "min", "ratio", "score_delta", "years", "mL/kg/min", "kg", "kg/m2", "degC",
        "vendor_points", "vendor_score_0_100", "local_hour", "dimensionless", "distance"]
    static let nativeMethods: Set<String> = [
        "nightly_rr_rmssd", "nightly_rr_sdnn", "nightly_rolling_floor", "nightly_respiration", "charge_ewma_asof",
        "daily_edwards", "daily_banister", "asof_cycle_edwards", "asof_cycle_banister", "resolved_workout_set",
        "strap_counter_calibrated_ticks", "asof_cycle_sleep_aware_counter", "hr_energy_estimate", "asof_cycle_hr_energy_estimate",
        "measured_percentage", "raw_red_adc", "raw_ir_adc", "whoop4_worn_skin", "whoop5_worn_skin", "oura_worn_skin",
        "personal_skin_baseline_deviation", "main_night_stages", "observed_asleep_over_in_bed", "rest_composite_asof",
        "normative_upper_quartile_age_floor", "descriptive_mean_need_floor_450", "observed_asleep_over_imported_need",
        "deep_plus_rem", "deep_plus_rem_over_asleep", "sleep_debt_14_usable_nights", "rolling_14_bedtime_spread",
        "readiness_7_28_calendar_suffix", "foster_calendar_suffix_week", "ewma_42d_edwards", "ewma_42d_banister",
        "ewma_7d_edwards", "ewma_7d_banister", "chronic_minus_acute", "nes_hunt_activity", "nes_waist", "uth_hr_ratio",
        "vitality_existing_hazard_model", "calendar_day_observed_hr", "hrmax_display_zones", "explicit_strength_workout_bounds",
        "personal_motion_phone_steps_calibration", "daily_prior30_rhr_hrv_zsum", "IllnessSignalEngine", "IllnessDistance_identity_correlation",
        "CircadianEngine_observed_hourly_hr_proxy", "CircadianEngine", "DaytimeStress", "DaytimeStress_hourly_approximation", "StressIndex"
    ]
    static let nativeKeys: Set<String> = [
        "hrv_rmssd_ms", "hrv_sdnn_ms", "resting_hr_bpm", "resp_rate_bpm", "recovery", "strain", "exercise_count", "steps",
        "active_kcal_est", "spo2_pct", "spo2_red", "spo2_ir", "skin_temp_c", "skin_temp_dev_c", "sleep_total_min",
        "sleep_light_min", "sleep_deep_min", "sleep_rem_min", "disturbances", "sleep_efficiency", "sleep_performance",
        "sleep_need_min", "hours_vs_needed_pct", "restorative_min", "restorative_pct", "sleep_debt_min", "sleep_consistency",
        "acwr", "training_monotony", "chronic_load", "acute_load", "training_balance", "fitness_age", "vo2max_est", "vitality",
        "body_age", "avg_hr", "max_hr", "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min", "strength_min", "steps_est", "stress",
        "illness_score", "illness_distance", "circadian_phase_hour", "circadian_offset_min", "daytime_stress_mean",
        "daytime_stress_high_min", "baevsky_stress_index"
    ]
    static let importedKeys: Set<String> = Set(ServerDaySwiftV3Imports.sourceOnly.map { "imported_" + $0 }).union([
        "basal_energy_kcal", "vo2max_measured", "body_mass_kg", "lean_mass_kg", "body_fat_pct", "bmi_kg_m2",
        "imported_calendar_steps_count", "imported_calendar_active_energy_kcal"
    ])
    static let detailKeys: Set<String> = ["baselines", "charge", "effort", "rest", "sleep_ledger", "sleep_typicals",
        "sleep_sessions", "readiness", "training_load", "fitness_age", "vitality", "hr_zones", "workouts", "workout_detection",
        "activity_cost", "step_calibration", "imported_provenance", "skin_calibration", "input_provenance", "derived_ppg_hr",
        "day_cycle", "contextPolicy", "illness", "cycle", "circadian", "daytimeStress", "frequencyHrv"]

    static func project(metrics: [String: Reading], details: [String: C.JSON], charts: [String: C.JSON],
                        chartMetadata: [String: C.JSON], capabilities: [String], gaps: [String]) throws -> Projection {
        guard Set(metrics.keys).isSubset(of: nativeKeys.union(importedKeys)), Set(details.keys).isSubset(of: detailKeys),
              Set(charts.keys) == Set(chartMetadata.keys) else { throw failure("projection_inventory") }
        return Projection(metrics: metrics, details: details, charts: charts, chartMetadata: chartMetadata,
                          capabilities: Array(Set(capabilities)).sorted(), gaps: Array(Set(gaps)).sorted())
    }

    static func insert<T>(_ key: String, _ value: T, into dictionary: inout [String: T]) throws {
        guard dictionary.updateValue(value, forKey: key) == nil else { throw failure("duplicate_output_owner:\(key)") }
    }

    static func number(_ value: Double?) -> C.JSON { value.map(C.JSON.number) ?? .null }
    static func integer(_ value: Int?) -> C.JSON { number(value.map(Double.init)) }
    static func failure(_ value: String) -> C.Failure { .invalid("s14_" + value) }

    static func consent(_ value: C.JSON?, purpose: String) throws {
        guard let value else { throw failure("consent_missing") }
        let object = try V.object(value)
        try V.keys(object, required: "purpose policyVersion decisionId")
        let id = try V.string(object["decisionId"])
        guard object["purpose"] == .string(purpose), object["policyVersion"] == .number(1),
              let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else { throw failure("consent") }
    }

    static func buckets(_ rows: [(ts: Int, value: Double)], from: Int, to: Int, seconds: Int = 300) throws -> [Bucket] {
        guard to > from, seconds > 0, rows.allSatisfy({ $0.value.isFinite }) else { throw failure("chart_input") }
        let selected = rows.filter { $0.ts >= from && $0.ts < to }
        let grouped = Dictionary(grouping: selected) { from + (($0.ts - from) / seconds) * seconds }
        return grouped.keys.sorted().map { start in
            let values = grouped[start]!.map(\.value)
            return Bucket(start: start, end: min(to, start + seconds), value: DailyPresentationMath.mean(values)!,
                          count: values.count, min: values.min()!, max: values.max()!)
        }
    }

    static func chartMetadata(unit: String, method: String = "observed_mean_min_max", session: String? = nil,
                              signal: String? = nil) -> C.JSON {
        var value: [String: C.JSON] = ["schemaVersion": .number(1), "unit": .string(unit),
                                     "bucketSeconds": .number(300), "method": .string(method)]
        if let session { value["sessionId"] = .string(session) }
        if let signal { value["signal"] = .string(signal) }
        return .object(value)
    }

    static func charge(_ drivers: [ChargeDriver], values: [String: (Double?, Double?)], confidence: String) throws -> C.JSON {
        let labels = ["Heart rate variability": ("heart_rate_variability", "milliseconds"),
            "Resting heart rate": ("resting_heart_rate", "beats_per_minute"), "Sleep quality": ("sleep_quality", "percent"),
            "Respiratory rate": ("respiratory_rate", "breaths_per_minute"), "Skin temperature": ("skin_temperature", "celsius_deviation")]
        let verdicts = ["above baseline, supporting recovery": "above_baseline_supporting",
            "below baseline, supporting recovery": "below_baseline_supporting", "above baseline, limiting recovery": "above_baseline_limiting",
            "below baseline, limiting recovery": "below_baseline_limiting", "at baseline": "at_baseline",
            "below baseline, limiting recovery, though low resting HR suggests this may be parasympathetic saturation rather than fatigue": "hrv_saturation_limiting",
            "a strong night, supporting recovery": "strong_night_supporting", "below a good night, limiting recovery": "below_good_night_limiting",
            "a typical night": "typical_night", "near baseline": "near_baseline",
            "warmer than baseline, limiting recovery": "warmer_than_baseline_limiting", "cooler than baseline, limiting recovery": "cooler_than_baseline_limiting"]
        let output = try drivers.map { driver -> C.JSON in
            guard let (key, unit) = labels[driver.label], let verdict = verdicts[driver.verdict], let bound = values[key] else {
                throw failure("charge_metadata_binding")
            }
            return .object(["key": .string(key), "deltaPoints": .number(Double(driver.deltaPoints)),
                            "value": number(bound.0), "baseline": number(bound.1), "unit": .string(unit), "verdict": .string(verdict)])
        }
        return .object(["confidence": .string(confidence), "drivers": .array(output)])
    }

    static func readiness(_ native: ReadinessEngine.Readiness) throws -> C.JSON {
        let headlines = ["Readiness": "today_readiness_title", "Run down": "today_readiness_run_down",
            "Strained": "today_readiness_strained", "Primed": "today_readiness_primed", "Balanced": "today_readiness_balanced"]
        let summaries = ["Wear the strap for a few nights and your readiness read will appear here.": "wear_for_nights",
            "A few more nights of data and your readiness read will sharpen.": "more_nights",
            "Several signals are down at once. Treat today as recovery - easy movement, real sleep tonight.": "run_down_summary",
            "One of your signals is flagging. You can train, but keep it controlled and bank the recovery.": "strained_summary",
            "Your signals are aligned and your load is supported. A harder session is well backed today.": "primed_summary",
            "Nothing's flagging. Train to feel - your body's holding steady.": "balanced_summary"]
        let labels = ["HRV": "signal_hrv", "Resting HR": "signal_resting_hr", "Respiratory rate": "signal_respiratory",
                      "Training load": "signal_training_load", "Training variety": "signal_training_variety"]
        let details = ["above your baseline - well recovered": "hrv_good", "in your normal range": "normal_range",
            "a touch below baseline": "hrv_watch", "suppressed - a sign of autonomic fatigue": "hrv_bad",
            "at or below baseline": "rhr_good", "running a little high": "rhr_watch",
            "elevated - overtraining or illness can do this": "rhr_bad", "up vs baseline - sometimes an early sign of getting sick": "resp_bad",
            "slightly raised vs baseline": "resp_watch", "low - similar strain every day raises strain/illness risk": "monotony_watch"]
        guard let headline = headlines[native.headline], let summary = summaries[native.summary] else { throw failure("readiness_copy") }
        let signals = try native.signals.map { signal -> C.JSON in
            guard let label = labels[signal.label] else { throw failure("readiness_label") }
            var detail = details[signal.detail]
            let evidence: C.JSON
            switch signal.evidenceData {
            case .none: evidence = .null
            case .metric(let value, let baseline, let unit, let decimals):
                let units = ["ms": "ms", "bpm": "bpm", "rpm": "rpm"]
                guard let wire = units[unit] else { throw failure("readiness_unit") }
                evidence = .object(["kind": .string("metric_vs_baseline"), "value": number(value), "baseline": number(baseline),
                                    "unit": .string(wire), "decimals": .number(Double(decimals))])
            case .monotony(let value): evidence = .object(["kind": .string("monotony"), "value": number(value)])
            case .trainingLoad(let acute, let chronic):
                guard let ratio = native.acwr, chronic > 0, ratio == acute / chronic else { throw failure("readiness_load_binding") }
                let formatted = String(format: "%.2f", ratio)
                let candidates = [
                    ("ramping down (acute:chronic \(formatted)) - room to build", "load_ramping_down", ReadinessEngine.Flag.watch),
                    ("in the sweet spot (acute:chronic \(formatted))", "load_sweet_spot", .good),
                    ("building fast (acute:chronic \(formatted)) - watch fatigue", "load_building_fast", .watch),
                    ("spiking (acute:chronic \(formatted)) - higher injury risk", "load_spiking", .bad)]
                guard let candidate = candidates.first(where: { $0.0 == signal.detail && $0.2 == signal.flag }) else {
                    throw failure("readiness_load_copy")
                }
                detail = candidate.1
                evidence = .object(["kind": .string("training_load"), "acute": number(acute), "chronic": number(chronic)])
            }
            guard let detail else { throw failure("readiness_detail") }
            return .object(["key": .string(signal.key), "flag": .string(signal.flag.rawValue), "label": .string("today_readiness_" + label),
                            "detail": .string("today_readiness_" + detail), "evidence": evidence])
        }
        return .object(["level": .string(native.level.rawValue), "confidence": .string(native.confidence.rawValue),
                        "headline": .string(headline), "summary": .string("today_readiness_" + summary), "signals": .array(signals)])
    }

    static func training(_ native: TrainingLoadEngine.Result) throws -> C.JSON {
        let reasons: [TrainingLoadEngine.UnavailableReason: String] = [.noData: "no_data", .missingTargetDay: "missing_target_day",
            .notEnoughContiguousDays: "not_enough_contiguous_days", .invalidConfiguration: "invalid_configuration",
            .invalidDay: "invalid_day", .duplicateDay: "duplicate_day", .invalidLoad: "invalid_load"]
        return .object(["state": .string(native.state.rawValue),
            "unavailableReason": native.unavailableReason.map { .string(reasons[$0]!) } ?? .null,
            "contiguousDays": integer(native.contiguousDays), "points": .array(native.points.suffix(180).map {
                .object(["day": .string($0.day), "load": number($0.load), "chronic": number($0.chronicLoad),
                         "acute": number($0.acuteLoad), "balance": number($0.balance)])
            })])
    }
}
