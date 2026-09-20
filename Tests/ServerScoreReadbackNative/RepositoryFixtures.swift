import Foundation
import NoopPush

// Host-only substitutes for app facades. Never linked into an app target; no Keychain/network/defaults.
enum CloudAuthClient {
    static let identityDidChange = Notification.Name("w4.fixture.identity")
    static var context: AccountSessionContext?
    static var failSignOut = false
    static var lastPersistenceError: AccountAuthError?
    static func currentContext() -> AccountSessionContext? { context }
    static func isCurrent(_ value: AccountSessionContext) -> Bool { context == value }
    static func clearSessionChecked() throws {
        context = nil
        lastPersistenceError = failSignOut ? .credentialUnavailable : nil
        NotificationCenter.default.post(name: identityDidChange, object: nil)
        if failSignOut { throw AccountAuthError.credentialUnavailable }
    }
    static func signIn(email: String, password: String) async throws { throw AccountAuthError.invalidCredentials }
    static func authorizedSession() async throws -> AuthorizedCloudSession { throw AccountAuthError.signedOut }
}

enum ServerScoringSettings {
    static let settingsDidChange = Notification.Name("w4.fixture.settings")
    static let pollIntervalSeconds = 60
    static var isEnabled = true
    static var activated: [AccountScope: Set<ServerScoreMetric>] = [:]
    static var known: [AccountScope: Set<ServerScoreMetric>] = [:]
    static func anonKey() -> String? { "host-fixture-not-a-credential" }
    static func activatedMetrics(scope: AccountScope) -> Set<ServerScoreMetric> { activated[scope] ?? [] }
    static func setActivated(_ metrics: Set<ServerScoreMetric>, scope: AccountScope) { activated[scope] = metrics }
    static func knownCapabilities(scope: AccountScope) -> Set<ServerScoreMetric> { known[scope] ?? [] }
    static func setKnownCapabilities(_ metrics: Set<ServerScoreMetric>, scope: AccountScope) { known[scope] = metrics }
}
