import Foundation
import CoreFoundation

/// Display projection of the selected server RMSSD series; never substitutes a daily scalar or SDNN.
public struct ServerHrvSeries {
    public struct Window: Equatable, Identifiable {
        public var id: Int { start }
        public let start: Int, end: Int
        public let rmssdMs: Double?
        public let measurementValid: Bool
        public let context: String
        public let baselineEligible: Bool
        public let reason: String?, baselineReason: String?
        public let baselineEffectiveSampleCount: Int?
        public let baselineRobustZ: Double?
        public let source: String?, modality: String?, methodVersion: String?
        public let observedTimeFraction: Double?
        public let isGap: Bool
    }
    public let windows: [Window]
    public let featureStatus: String?, featureReason: String?
    public let deviceId: String?, algorithmVersion: String?, observedThrough: String?
    public let stale: Bool

    public static func from(_ cache: ServerScoreDayCache?, day: String) -> Self {
        let feature = cache?.features["hrv"]
        func result(_ windows: [Window]) -> Self {
            Self(windows: windows, featureStatus: feature?.status, featureReason: feature?.reason,
                deviceId: feature?.deviceId, algorithmVersion: feature?.algorithmVersion,
                observedThrough: feature?.observedThrough, stale: cache?.stale ?? true)
        }
        guard let cache, cache.day == day, !cache.ownerId.isEmpty, cache.schemaVersion == 2,
              let feature, feature.algorithmVersion == "frwhoop-physiology-2", let device = feature.deviceId, !device.isEmpty,
              let revision = feature.inputRevision,
              let json = cache.rawSnapshotJSON?.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let overlay = root["server_scoring"] as? [String: Any],
              (overlay["user_id"] as? String)?.lowercased() == cache.ownerId.lowercased(), overlay["day"] as? String == day,
              let selected = (overlay["features"] as? [String: [String: Any]])?["hrv"],
              selected["device_id"] as? String == device, selected["algorithm_version"] as? String == feature.algorithmVersion,
              (selected["input_revision"] as? NSNumber)?.int64Value == revision,
              let rows = overlay["measurements"] as? [Any] else { return result([]) }
        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        func integer(_ value: Any?) -> Int? {
            guard let n = number(value), n.rounded() == n, n >= -62135596800, n <= 253402300799 else { return nil }
            return Int(n)
        }
        let parsed = rows.compactMap { raw -> Window? in
            guard let row = raw as? [String: Any] else { return nil }
            guard integer(row["measurement_schema_version"]) == 1, row["feature"] as? String == "hrv",
                  (row["user_id"] as? String)?.lowercased() == cache.ownerId.lowercased(), row["device_id"] as? String == device,
                  row["metric"] as? String == "rmssd", row["unit"] as? String == "ms",
                  let start = integer(row["start"]), let end = integer(row["end"]), start % 300 == 0, end - start == 300 else { return nil }
            let rawRevision = (row["input_revision"] as? String) ?? (row["input_revision"] as? NSNumber)?.stringValue
            guard rawRevision == String(revision) else { return nil }
            let value = number(row["observed_rmssd_ms"])
            let source = row["source"] as? String, modality = row["modality"] as? String
            let valid = (row["measurement_valid"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } == true &&
                value.map { $0 >= 0 } == true && (row["reason"] == nil || row["reason"] is NSNull) &&
                source?.isEmpty == false && modality?.isEmpty == false
            let context = row["context"] as? String ?? "unknown"
            let eligible = valid && row["baseline_eligible"] as? Bool == true && ["sleep", "nap", "quiet_rest"].contains(context)
            let baseline = row["baseline"] as? [String: Any]
            let coverage = number(row["observed_time_fraction"]).flatMap { (0...1).contains($0) ? $0 : nil }
            return Window(start: start, end: end, rmssdMs: valid ? value : nil, measurementValid: valid,
                context: context, baselineEligible: eligible,
                reason: valid ? nil : (row["reason"] as? String ?? "measurement_unavailable"),
                baselineReason: (row["baseline_reason"] as? String) ?? (baseline?["reason"] as? String),
                baselineEffectiveSampleCount: integer(baseline?["effective_sample_count"]).flatMap { $0 >= 0 ? $0 : nil },
                baselineRobustZ: eligible ? number(baseline?["robust_z"]) : nil,
                source: source, modality: modality, methodVersion: row["algorithm_version"] as? String,
                observedTimeFraction: coverage, isGap: false)
        }
        let buckets = Dictionary(grouping: parsed, by: \.start)
        guard let first = buckets.keys.min(), let last = buckets.keys.max(), last - first <= 76 * 3600 else { return result([]) }
        let windows = stride(from: first, through: last, by: 300).map { start -> Window in
            guard let values = buckets[start], let row = values.first else { return gap(start, "window_missing") }
            return values.allSatisfy { $0 == row } ? row : gap(start, "conflicting_window_records")
        }
        return result(windows)
    }

    private static func gap(_ start: Int, _ reason: String) -> Window {
        Window(start: start, end: start + 300, rmssdMs: nil, measurementValid: false, context: "unknown",
            baselineEligible: false, reason: reason, baselineReason: "measurement_unavailable",
            baselineEffectiveSampleCount: nil, baselineRobustZ: nil, source: nil, modality: nil,
            methodVersion: nil, observedTimeFraction: nil, isGap: true)
    }
}
