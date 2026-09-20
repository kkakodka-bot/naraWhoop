import Foundation

/// HRV, sleep and respiration retain explicit server ownership; unrelated vitals keep their legacy fallback.
/// The caller supplies an owner-scoped overlay only after configuration and authentication checks.
public struct ServerVitalSelection: Equatable {
    public enum Metric: CaseIterable { case hrv, restingHR, respiratory, sleep, charge, strain, spo2, skinTemp }
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
        let serverOwned = metric == .sleep || metric == .hrv || metric == .respiratory
        guard serverEnabled else {
            return Self(value: localValue, fromServer: false, day: selectedDay, status: nil, stale: false,
                        sourceFeature: nil, deviceId: nil, algorithmVersion: nil)
        }
        // Missing server physiology stays unavailable, including before the first completed snapshot.
        guard let overlay, overlay.day == selectedDay else {
            return Self(value: serverOwned ? nil : localValue, fromServer: serverOwned,
                        day: selectedDay, status: serverOwned ? "unavailable" : nil, stale: false,
                        sourceFeature: nil, deviceId: nil, algorithmVersion: nil)
        }
        let value: Double?
        let featureKey: String
        switch metric {
        case .hrv: value = overlay.daily?.hrvRmssdMs; featureKey = "hrv"
        case .restingHR: value = overlay.daily?.restingHrBpm.map(Double.init); featureKey = "hrv"
        case .respiratory: value = overlay.daily?.respRateBpm; featureKey = "respiration"
        case .sleep: value = overlay.daily?.sleepTotalMin; featureKey = "sleep"
        case .charge: value = overlay.daily?.recovery; featureKey = "hrv"
        case .strain: value = overlay.daily?.strain; featureKey = "hrv"
        case .spo2: value = overlay.daily?.spo2Pct; featureKey = "hrv"
        case .skinTemp: value = overlay.daily?.skinTempC ?? overlay.daily?.skinTempDevC; featureKey = "hrv"
        }
        let feature = overlay.features[featureKey]
        let status = feature?.status ?? "unavailable"
        let available = (status == "available" || status == "stale") && feature?.hasCanonicalAuthorization == true
        // A published feature with this metric still null is not live for the card.
        // A local experimental result cannot replace unavailable canonical physiology.
        if !available || value == nil {
            return Self(value: serverOwned ? nil : localValue, fromServer: serverOwned,
                        day: selectedDay, status: serverOwned ? "unavailable" : status, stale: overlay.stale,
                        sourceFeature: feature == nil ? nil : featureKey, deviceId: feature?.deviceId,
                        algorithmVersion: feature?.algorithmVersion)
        }
        return Self(value: value, fromServer: true, day: selectedDay,
                    status: status,
                    stale: overlay.stale || status == "stale", sourceFeature: feature == nil ? nil : featureKey,
                    deviceId: feature?.deviceId, algorithmVersion: feature?.algorithmVersion)
    }
}
