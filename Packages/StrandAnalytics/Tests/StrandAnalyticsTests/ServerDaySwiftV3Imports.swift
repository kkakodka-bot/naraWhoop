import Foundation
import WhoopStore
@testable import StrandAnalytics

/// Supplied measurements form a presentation view, never raw physiology or baseline observations.
enum ServerDaySwiftV3Imports {
    typealias C = ServerDaySwiftContract
    typealias V = ServerDaySwiftV3Contract
    typealias M = ServerDaySwiftV3Metadata

    enum Kind: String, Codable, CaseIterable {
        case apple = "apple_health", healthConnect = "health_connect", oura = "oura_import"
        case whoop = "whoop_import", mi = "miband_import"
        var priority: Int { Self.allCases.firstIndex(of: self)! }
    }
    struct Source: Codable, Equatable {
        let kind: Kind
        let externalDeviceId: String
        let method: String
    }
    struct Value: Encodable, Equatable {
        let value: Double?
        let unit: String
        func encode(to encoder: Encoder) throws {
            try C.JSON.object(["value": M.number(value), "unit": .string(unit)]).encode(to: encoder)
        }
    }
    struct Record: Encodable, Equatable {
        let row: C.JournalRow
        let source: Source
        let values: [String: Value]
    }
    struct Reading: Encodable, Equatable {
        let value: Double
        let unit: String
        let source: Source
        let inputRevision: Int64
        let entity: String
    }
    struct Selection: Encodable, Equatable {
        let scope: M.Scope
        let day: String
        let originalRows: [C.JournalRow]
        let records: [Record]
        let selected: [String: Reading]
        let tombstones: [C.JournalRow]
    }
    struct Projection: Encodable, Equatable {
        let metrics: [String: M.Reading]
        let provenance: [String: C.JSON]
        let calendarOverlay: Bool
        // Deliberately no DailyMetric/checkpoint conversion: callers cannot accidentally feed this view to history.
    }

    static let units: [String: String] = [
        "steps_count": "count", "active_energy_kcal": "kcal", "basal_energy_kcal": "kcal",
        "vo2max_ml_kg_min": "mL/kg/min", "body_mass_kg": "kg", "lean_mass_kg": "kg", "body_fat_pct": "%",
        "spo2_pct": "%", "bmi_kg_m2": "kg/m2", "avg_hr_bpm": "bpm", "resting_hr_bpm": "bpm",
        "hrv_rmssd_ms": "ms", "hrv_sdnn_ms": "ms", "resp_rate_bpm": "breaths/min", "skin_temp_c": "degC",
        "sleep_total_min": "min", "sleep_debt_min": "min", "sleep_need_min": "min",
        "sleep_performance_pct": "%", "sleep_consistency_pct": "%",
        "miband_max_hr_bpm": "bpm", "miband_vitality_points": "vendor_points",
        "miband_sleep_deep_min": "min", "miband_sleep_rem_min": "min", "miband_sleep_light_min": "min",
        "miband_sleep_awake_min": "min", "miband_intensity_min": "min",
        "miband_sleep_score_0_100": "vendor_score_0_100", "miband_stress_score_0_100": "vendor_score_0_100"
    ]
    static let sourceOnly: Set<String> = ["avg_hr_bpm", "resting_hr_bpm", "hrv_rmssd_ms", "hrv_sdnn_ms",
        "resp_rate_bpm", "skin_temp_c", "sleep_total_min", "miband_max_hr_bpm", "miband_vitality_points",
        "miband_sleep_deep_min", "miband_sleep_rem_min", "miband_sleep_light_min", "miband_sleep_awake_min",
        "miband_intensity_min", "miband_sleep_score_0_100", "miband_stress_score_0_100"]

    static func resolve(scope: M.Scope, rows: [C.JournalRow], day: String) throws -> Selection {
        try scope.validate()
        _ = try C.dayBounds(day, "UTC")
        guard day <= scope.day, rows.count <= 10_000 else { throw M.failure("import_day_or_limit") }
        let resolution = try C.resolve(C.Input(identity: scope.identity, day: scope.day, timezone: scope.timezone, journal: rows))
        let eligible = rows.filter { $0.kind == .importedDaily && $0.userId == scope.identity.userId &&
            $0.sourceDeviceId == scope.identity.sourceDeviceId && $0.effectiveDay <= scope.day }
        let grouped = Dictionary(grouping: eligible, by: \.entity)
        // The RPC makes source and observation day immutable even across tombstones/restoration.
        for revisions in grouped.values {
            let ordered = revisions.sorted { $0.revision < $1.revision }
            var anchor: Record?
            for row in ordered {
                guard row.entity.hasPrefix("import:"), (1...128).contains(row.entity.count) else { throw M.failure("import_entity") }
                if let anchor, row.effectiveDay != anchor.row.effectiveDay { throw M.failure("import_day_changed") }
                if row.deleted { continue }
                let parsed = try parse(row)
                if let anchor, anchor.source != parsed.source { throw M.failure("import_source_changed") }
                if anchor == nil { anchor = parsed }
            }
        }
        var records = try resolution.rows.filter { $0.kind == .importedDaily && !$0.deleted }.map(parse)
        records = records.filter { $0.row.effectiveDay == day }.sorted {
            ($0.source.kind.priority, $0.source.externalDeviceId, $0.row.entity) <
                ($1.source.kind.priority, $1.source.externalDeviceId, $1.row.entity)
        }
        var selected: [String: Reading] = [:]
        for record in records {
            for key in record.values.keys.sorted() {
                guard selected[key] == nil, let field = record.values[key], let value = field.value else { continue }
                selected[key] = Reading(value: value, unit: field.unit, source: record.source,
                    inputRevision: record.row.revision, entity: record.row.entity)
            }
        }
        return Selection(scope: scope, day: day, originalRows: rows, records: records, selected: selected,
                         tombstones: resolution.rows.filter { $0.kind == .importedDaily && $0.deleted })
    }

    static func parse(_ row: C.JournalRow) throws -> Record {
        let p = row.payload
        try V.keys(p, required: "schemaVersion day timezone source values consent")
        guard row.kind == .importedDaily, !row.deleted, p["schemaVersion"] == .number(1),
              try V.string(p["day"]) == row.effectiveDay else { throw M.failure("import_envelope") }
        let zone = try V.string(p["timezone"])
        _ = try C.dayBounds(row.effectiveDay, zone)
        try M.consent(p["consent"], purpose: "imported_metrics")
        let s = try V.object(p["source"]!)
        try V.keys(s, required: "kind externalDeviceId method")
        guard let kind = Kind(rawValue: try V.string(s["kind"])) else { throw M.failure("import_kind") }
        let external = try V.string(s["externalDeviceId"]), method = try V.string(s["method"])
        guard (1...256).contains(external.count), (1...128).contains(method.count) else { throw M.failure("import_source") }
        let source = Source(kind: kind, externalDeviceId: external, method: method)
        var values: [String: Value] = [:]
        for (key, json) in try V.object(p["values"]!) {
            guard let expected = units[key], !key.hasPrefix("miband_") || kind == .mi else { throw M.failure("import_key_or_source") }
            let field = try V.object(json)
            try V.keys(field, required: "value unit")
            guard field["unit"] == .string(expected) else { throw M.failure("import_unit") }
            let value = field["value"] == .null ? nil : try V.number(field["value"])
            if let value {
                guard value.isFinite, (0...1_000_000).contains(value) else { throw M.failure("import_range") }
                if ["body_fat_pct", "spo2_pct", "sleep_performance_pct", "sleep_consistency_pct"].contains(key), value > 100 {
                    throw M.failure("import_percent")
                }
                if key == "sleep_need_min" || (key.hasPrefix("miband_") && expected == "min"), value > 1_440 {
                    throw M.failure("import_duration")
                }
                if key == "steps_count", value.rounded(.towardZero) != value { throw M.failure("import_count") }
                if key.hasPrefix("miband_"), expected != "min" {
                    guard value > 0, value.rounded(.towardZero) == value,
                          expected != "vendor_score_0_100" || value <= 100 else { throw M.failure("import_mi_unknown_or_range") }
                }
            }
            values[key] = Value(value: value, unit: expected)
        }
        return Record(row: row, source: source, values: values)
    }

    static func project(selection: Selection, native: DailyMetric, cycleUsesCalendar: Bool) throws -> Projection {
        guard native.day == selection.day else { throw M.failure("import_projection_day") }
        var metrics: [String: M.Reading] = [:], provenance: [String: C.JSON] = [:]
        let direct = ["basal_energy_kcal": "basal_energy_kcal", "vo2max_ml_kg_min": "vo2max_measured",
            "body_mass_kg": "body_mass_kg", "lean_mass_kg": "lean_mass_kg", "body_fat_pct": "body_fat_pct", "bmi_kg_m2": "bmi_kg_m2",
            "spo2_pct": "spo2_pct", "sleep_debt_min": "sleep_debt_min", "sleep_need_min": "sleep_need_min",
            "sleep_performance_pct": "sleep_performance", "sleep_consistency_pct": "sleep_consistency"]
        for key in selection.selected.keys.sorted() {
            let reading = selection.selected[key]!
            let output: String
            if key == "steps_count" { output = cycleUsesCalendar ? "steps" : "imported_calendar_steps_count" }
            else if key == "active_energy_kcal" { output = cycleUsesCalendar ? "active_kcal_est" : "imported_calendar_active_energy_kcal" }
            else if let mapped = direct[key] { output = mapped }
            else if sourceOnly.contains(key) { output = "imported_" + key }
            else { throw M.failure("import_output_key") }
            let unit = reading.unit == "%" ? "percent" : reading.unit
            metrics[output] = try M.Reading(value: reading.value, unit: unit, status: .available,
                                          method: .imported(reading.source.kind.rawValue, reading.source.method))
            provenance[output] = .object(["source": try V.json(reading.source), "inputRevision": .number(Double(reading.inputRevision))])
        }
        if let need = selection.selected["sleep_need_min"] {
            metrics["hours_vs_needed_pct"] = try M.Reading(
                value: DailyPresentationMath.hoursVsNeededPercent(asleepMin: native.totalSleepMin, needMin: need.value),
                unit: "percent", method: .native("observed_asleep_over_imported_need"))
            provenance["hours_vs_needed_pct"] = .object(["denominatorSource": try V.json(need.source),
                "inputRevision": .number(Double(need.inputRevision))])
        }
        return Projection(metrics: metrics, provenance: provenance, calendarOverlay: cycleUsesCalendar)
    }
}
