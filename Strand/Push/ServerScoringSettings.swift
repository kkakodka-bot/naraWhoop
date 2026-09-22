import Foundation
import NoopPush

/// Phase 4: server HRV/sleep readback. Default on for this fork; toggled from Settings → Advanced.
enum ServerScoringSettings {
    static let defaultsKey = "noop.serverScoring"
    static let authEmailKey = "noop.serverScoring.authEmail"
    static let settingsDidChange = Notification.Name("noop.serverScores.settingsDidChange")
    static let pollIntervalSeconds = 60
    static let staleAfterSeconds = 6 * 60 * 60
    /// Foreground idle push cadence when server scoring is on (spec: 30–60 s).
    static let idlePushIntervalSeconds: TimeInterval = 45
    /// During an active offload, flush push at most once per this interval (spec: ≤10 s).
    static let syncPushIntervalSeconds: TimeInterval = 10

    /// The local pass still produces Charge/Effort/Rest and other unmigrated fields.
    static var skipsSyncCoupledRescore: Bool { false }

    /// Clear any in-flight deferred rescore debt when server scoring owns the score path.
    @MainActor
    static func settleSkippedLocalRescoreDebt() {
        guard skipsSyncCoupledRescore else { return }
        if RescoreBackgroundScheduler.isRescoreOwed {
            RescoreBackgroundScheduler.markRescoreCompleted(
                seconds: 0, owedToken: RescoreBackgroundScheduler.currentOwedToken)
        }
    }

    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: defaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
        NotificationCenter.default.post(name: settingsDidChange, object: nil)
    }

    static func activatedMetrics(scope: AccountScope) -> Set<ServerScoreMetric> {
        Set((UserDefaults.standard.stringArray(forKey: "noop.serverScores.activated.\(scope.namespace)") ?? [])
            .compactMap(ServerScoreMetric.init(rawValue:)))
    }

    static func setActivated(_ metrics: Set<ServerScoreMetric>, scope: AccountScope) {
        UserDefaults.standard.set(metrics.map(\.rawValue).sorted(), forKey: "noop.serverScores.activated.\(scope.namespace)")
        NotificationCenter.default.post(name: settingsDidChange, object: nil)
    }

    static func knownCapabilities(scope: AccountScope) -> Set<ServerScoreMetric> {
        Set((UserDefaults.standard.stringArray(forKey: "noop.serverScores.capabilities.\(scope.namespace)") ?? [])
            .compactMap(ServerScoreMetric.init(rawValue:)))
    }

    static func setKnownCapabilities(_ metrics: Set<ServerScoreMetric>, scope: AccountScope) {
        UserDefaults.standard.set(metrics.map(\.rawValue).sorted(), forKey: "noop.serverScores.capabilities.\(scope.namespace)")
    }

    static var authEmail: String {
        UserDefaults.standard.string(forKey: authEmailKey) ?? ""
    }

    static func setAuthEmail(_ email: String) {
        UserDefaults.standard.set(email.trimmingCharacters(in: .whitespacesAndNewlines), forKey: authEmailKey)
    }

    /// Readback belongs to the configured identity project, independently of permission to upload.
    /// Auth validates its configuration; canonicalize again before exposing a destination to callers.
    /// Pausing uploads or withholding upload consent must not restore local metrics over owned cache.
    static func supabaseProjectURL() -> URL? {
        guard let project = CloudAuthClient.identitySnapshot().projectURL,
              let canonical = try? AccountScope.canonicalProjectURL(project) else { return nil }
        return URL(string: canonical)
    }

    static func anonKey() -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "NOOPSupabaseAnonKey") as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    static var ready: Bool {
        isEnabled && supabaseProjectURL() != nil && anonKey() != nil
    }
}
