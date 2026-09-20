import Foundation

/// Phase 4: server HRV/sleep readback. Default on for this fork; toggled from Settings → Advanced.
enum ServerScoringSettings {
    static let defaultsKey = "noop.serverScoring"
    static let authEmailKey = "noop.serverScoring.authEmail"
    static let pollIntervalSeconds = 60
    /// Foreground idle push cadence when server scoring is on (spec: 30–60 s).
    static let idlePushIntervalSeconds: TimeInterval = 45
    /// During an active offload, flush push at most once per this interval (spec: ≤10 s).
    static let syncPushIntervalSeconds: TimeInterval = 10

    /// The hosted snapshot owns individual physiology fields, not the whole local analysis pass.
    /// Even a fresh overlay cannot settle local-only metrics or their history. Keep the existing
    /// coalesced, fingerprint-gated local schedule; fetching a score adds no new analysis timer.
    static var skipsSyncCoupledRescore: Bool {
        false
    }

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
    }

    static var authEmail: String {
        UserDefaults.standard.string(forKey: authEmailKey) ?? ""
    }

    static func setAuthEmail(_ email: String) {
        UserDefaults.standard.set(email.trimmingCharacters(in: .whitespacesAndNewlines), forKey: authEmailKey)
    }

    /// Supabase project base URL derived from the fleet push endpoint.
    static func supabaseProjectURL() -> URL? {
        guard let endpoint = CloudPushSettings.configuredEndpoint()?.url else { return nil }
        let trimmed = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard trimmed.hasSuffix("/functions/v1/push") else { return nil }
        let base = String(trimmed.dropLast("/functions/v1/push".count))
        return URL(string: base)
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
