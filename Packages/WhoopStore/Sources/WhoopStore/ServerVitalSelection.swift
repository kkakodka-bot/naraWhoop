import Foundation
import WhoopProtocol

/// Hosted mode retains explicit server ownership for computed physiology metrics.
/// The caller supplies an owner-scoped overlay only after configuration and authentication checks.
public struct ServerVitalSelection: Equatable {
    public enum Metric: CaseIterable {
        case hrv, restingHR, respiratory, sleep, rest, charge, strain, spo2, skinTemp
        var key: String {
            switch self {
            case .hrv: return "hrv_rmssd_ms"
            case .restingHR: return "resting_hr_bpm"
            case .respiratory: return "resp_rate_bpm"
            case .sleep: return "sleep_total_min"
            case .rest: return "sleep_performance"
            case .charge: return "recovery"
            case .strain: return "strain"
            case .spo2: return "spo2_pct"
            case .skinTemp: return "skin_temp_c"
            }
        }
        var feature: String {
            switch self {
            case .respiratory: return "respiration"
            case .sleep, .rest: return "sleep"
            default: return "hrv"
            }
        }
    }
    public let value: Double?
    public let fromServer: Bool
    public let day: String
    public let status: String?
    public let stale: Bool
    public let sourceFeature: String?
    public let deviceId: String?
    public let algorithmVersion: String?
    public var canonicalResult: ServerCanonicalFamilyResult?
    public var displayDiagnostic: ServerScoreStageDiagnostic {
        ServerScoreStageDiagnostic(stage: "displayed", status: value == nil ? "unavailable" : "available",
            reason: !fromServer ? "local_producer_retained" : value == nil ? "metric_unavailable" : "server_metric_selected")
    }

    public static func resolve(_ metric: Metric, serverEnabled: Bool, selectedDay: String,
                               overlay: ServerScoreDayCache?, localValue: @autoclosure () -> Double?) -> Self {
        if PhoneComputeRuntime.isFinalHosted || overlay?.canonicalResults != nil || overlay?.pendingCanonicalResults != nil {
            let family = overlay?.day == selectedDay ? overlay?.canonicalResults?.result(for: metric.key) : nil
            let pending = overlay?.day == selectedDay ? overlay?.pendingCanonicalResults : nil
            var result = Self(value: family?.number(metric.key), fromServer: true, day: selectedDay,
                status: overlay?.readFailure ?? family?.missingReason(metric.key) ?? family?.reason ?? family?.status ?? pending?.reason ?? "awaiting_server_result",
                stale: overlay?.stale == true || family?.freshness != "current",
                sourceFeature: metric.feature, deviceId: family?.deviceID, algorithmVersion: family?.algorithmVersion)
            result.canonicalResult = family
            return result
        }
        // An explicit ledger supersedes the legacy caller's hosted-selection argument.
        let owned = overlay?.ownedMetrics?.contains(metric.key) ?? serverEnabled
        guard owned else {
            return Self(value: localValue(), fromServer: false, day: selectedDay, status: nil, stale: false,
                        sourceFeature: nil, deviceId: nil, algorithmVersion: nil)
        }
        // A pending snapshot must not resurrect a competing local calculation.
        guard let overlay, overlay.day == selectedDay else {
            return Self(value: nil, fromServer: true, day: selectedDay, status: "pending", stale: false,
                        sourceFeature: metric.feature, deviceId: nil, algorithmVersion: nil)
        }
        let value: Double?
        let featureKey: String
        switch metric {
        case .hrv: value = overlay.daily?.hrvRmssdMs; featureKey = "hrv"
        case .restingHR: value = overlay.daily?.restingHrBpm.map(Double.init); featureKey = "hrv"
        case .respiratory: value = overlay.daily?.respRateBpm; featureKey = "respiration"
        case .sleep: value = overlay.daily?.sleepTotalMin; featureKey = "sleep"
        case .rest: value = overlay.daily?.rest; featureKey = "sleep"
        case .charge: value = overlay.daily?.recovery; featureKey = "hrv"
        case .strain: value = overlay.daily?.strain; featureKey = "hrv"
        case .spo2: value = overlay.daily?.spo2Pct; featureKey = "hrv"
        case .skinTemp: value = overlay.daily?.skinTempC; featureKey = "hrv"
        }
        let feature = overlay.features[featureKey]
        let status = feature?.status ?? "unavailable"
        let available = feature?.isCanonicalAvailable == true
        // Missing/unqualified server results remain unavailable rather than falling back locally.
        if !available || value == nil {
            let legacyReason = feature?.algorithmVersion == ServerLegacyReadEligibility.algorithm &&
                (ServerLegacyReadEligibility.always.contains(metric.key) ||
                 overlay.legacySleepWithheld && (ServerLegacyReadEligibility.sleep.contains(metric.key) || metric == .rest))
                ? ServerLegacyReadEligibility.reason : nil
            let processing = feature?.processingStatus.flatMap {
                ["pending", "running", "retry", "failed", "exhausted"].contains($0) ? $0 : nil
            }
            return Self(value: nil, fromServer: true,
                        day: selectedDay, status: overlay.readFailure ?? legacyReason ?? processing ?? feature?.reason ?? (available ? "insufficient_input" : "unavailable"), stale: overlay.stale,
                        sourceFeature: feature == nil ? nil : featureKey, deviceId: feature?.deviceId,
                        algorithmVersion: feature?.algorithmVersion)
        }
        return Self(value: value, fromServer: true, day: selectedDay,
                    status: status,
                    stale: overlay.stale || status == "stale", sourceFeature: feature == nil ? nil : featureKey,
                    deviceId: feature?.deviceId, algorithmVersion: feature?.algorithmVersion)
    }
}
