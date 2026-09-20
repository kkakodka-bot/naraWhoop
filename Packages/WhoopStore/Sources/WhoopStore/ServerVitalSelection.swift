import Foundation

/// Hosted mode retains explicit server ownership for computed physiology metrics.
/// The caller supplies an owner-scoped overlay only after configuration and authentication checks.
public struct ServerVitalSelection: Equatable {
    public enum Metric: CaseIterable { case hrv, restingHR, respiratory, sleep, rest, charge, strain, spo2, skinTemp }
    public let value: Double?
    public let fromServer: Bool
    public let day: String
    public let status: String?
    public let stale: Bool
    public let sourceFeature: String?
    public let deviceId: String?
    public let algorithmVersion: String?

    public static func resolve(_ metric: Metric, serverEnabled: Bool, selectedDay: String,
                               overlay: ServerScoreDayCache?, localValue: Double?) -> Self {
        guard serverEnabled else {
            return Self(value: localValue, fromServer: false, day: selectedDay, status: nil, stale: false,
                        sourceFeature: nil, deviceId: nil, algorithmVersion: nil)
        }
        // A pending snapshot must not resurrect a competing local calculation.
        guard let overlay, overlay.day == selectedDay else {
            return Self(value: nil, fromServer: true, day: selectedDay, status: "unavailable", stale: false,
                        sourceFeature: nil, deviceId: nil, algorithmVersion: nil)
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
        case .skinTemp: value = overlay.daily?.skinTempC ?? overlay.daily?.skinTempDevC; featureKey = "hrv"
        }
        let feature = overlay.features[featureKey]
        let status = feature?.status ?? "unavailable"
        let available = (status == "available" || status == "stale") && feature?.hasCanonicalAuthorization == true
        // Missing/unqualified server results remain unavailable rather than falling back locally.
        if !available || value == nil {
            return Self(value: nil, fromServer: true,
                        day: selectedDay, status: available && value != nil ? status : "unavailable", stale: overlay.stale,
                        sourceFeature: feature == nil ? nil : featureKey, deviceId: feature?.deviceId,
                        algorithmVersion: feature?.algorithmVersion)
        }
        return Self(value: value, fromServer: true, day: selectedDay,
                    status: status,
                    stale: overlay.stale || status == "stale", sourceFeature: feature == nil ? nil : featureKey,
                    deviceId: feature?.deviceId, algorithmVersion: feature?.algorithmVersion)
    }
}
