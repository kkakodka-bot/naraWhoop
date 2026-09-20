import Foundation
import CoreFoundation

/// A selected server respiratory-rate summary, never a local or vendor fallback.
public struct ServerRespirationSummary: Equatable {
    public let breathsPerMinute: Double?
    public let mean: Double?
    public let distribution: [Double]
    public let coverage: Double?
    public let acceptedSeconds: Double?
    public let acceptedWindows: Int?
    public let totalWindows: Int?
    public let context: String?
    public let method: String?
    public let calibrationStatus: String?
    public let reason: String?
    /// Measurement eligibility is separate from snapshot freshness (for example newer_input_pending).
    public let measurementReason: String?
    public let legacy: Bool

    public static func project(_ cache: ServerScoreDayCache?, day: String) -> Self? {
        guard let cache, cache.day == day, !cache.ownerId.isEmpty,
              let feature = cache.features["respiration"],
              let device = feature.deviceId, !device.isEmpty,
              let version = feature.algorithmVersion, !version.isEmpty,
              let bytes = cache.rawSnapshotJSON?.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let overlay = root["server_scoring"] as? [String: Any],
              (overlay["user_id"] as? String)?.lowercased() == cache.ownerId.lowercased(),
              overlay["day"] as? String == day,
              let features = overlay["features"] as? [String: [String: Any]],
              features["respiration"]?["device_id"] as? String == device,
              features["respiration"]?["algorithm_version"] as? String == version else { return nil }
        func number(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        func nonnegativeInt(_ value: Any?) -> Int? {
            guard let n = number(value), n >= 0, n < Double(Int.max), n.rounded() == n else { return nil }
            return Int(n)
        }
        let daily = overlay["daily"] as? [String: Any] ?? [:]
        let legacy = version == "frwhoop-server-1"
        let summary = daily["respiration_summary"] as? [String: Any] ?? [:]
        let scalar = number(daily["resp_rate_bpm"]).flatMap { $0 > 0 ? $0 : nil }
        let median = number(summary["median_bpm"]).flatMap { $0 > 0 ? $0 : nil }
        let mean = number(summary["mean_bpm"]).flatMap { $0 > 0 ? $0 : nil }
        let coverage = number(summary["coverage"]).flatMap { (0...1).contains($0) ? $0 : nil }
        let seconds = number(summary["accepted_seconds"]).flatMap { $0 >= 0 ? $0 : nil }
        let accepted = nonnegativeInt(summary["accepted_windows"])
        let total = nonnegativeInt(summary["total_windows"])
        let context = summary["context"] as? String
        let distribution = (summary["distribution_bpm"] as? [Any] ?? []).compactMap(number).filter { $0 > 0 }.sorted()
        let visible = ["available", "fresh", "stale"].contains(feature.status)
        let measurementReason = daily["respiration_unavailable_reason"] as? String
        var reason = feature.reason ?? measurementReason
        var primary = visible ? scalar : nil
        if !visible { reason = reason ?? "respiration_unavailable" }
        if legacy {
            reason = reason ?? "legacy_quality_unavailable"
        } else if primary != nil {
            if context != "main_sleep" {
                primary = nil; reason = "incompatible_respiration_context"
            } else if median != scalar || mean == nil || coverage == nil || coverage == 0 || seconds == nil || seconds == 0 ||
                        accepted == nil || accepted == 0 || total == nil || accepted! > total! {
                primary = nil; reason = "inconsistent_respiration_summary"
            }
        }
        if primary == nil { reason = reason ?? "no_quality_eligible_windows" }
        return Self(breathsPerMinute: primary, mean: legacy ? nil : mean, distribution: legacy ? [] : distribution,
                    coverage: legacy ? nil : coverage, acceptedSeconds: legacy ? nil : seconds,
                    acceptedWindows: legacy ? nil : accepted, totalWindows: legacy ? nil : total,
                    context: legacy ? nil : context, method: legacy ? nil : summary["method_version"] as? String,
                    calibrationStatus: legacy ? nil : summary["calibration_status"] as? String,
                    reason: reason, measurementReason: primary == nil ? measurementReason : nil, legacy: legacy)
    }
}
