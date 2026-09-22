import Foundation
import NoopPush

/// Compatibility facade shared by upload, readback and the root-owned account runtime.
enum CloudAuthClient {
    typealias Session = AccountAuthSession
    typealias AuthError = AccountAuthError
    static let identityDidChange = Notification.Name("noop.cloudAuth.identityDidChange")

    private static let controller = AccountSessionController(
        credentials: CloudAccountKeychainStore(), transport: CloudAccountHTTPTransport(),
        changed: { NotificationCenter.default.post(name: identityDidChange, object: nil) }
    )
    private static let configurationLock = NSRecursiveLock()
    private static var configured = false

    /// Call before constructing a runtime when root selects a different project.
    static func configure(projectURL: String, anonKey: String) throws {
        let value = try AccountAuthConfiguration(projectURL: projectURL, anonKey: anonKey)
        configurationLock.lock()
        defer { configurationLock.unlock() }
        configured = true
        controller.configure(value)
    }

    private static func ensureConfiguration() {
        guard !AppRuntimeMode.isUnitTesting else { return }
        configurationLock.lock()
        defer { configurationLock.unlock() }
        guard !configured else { return }
        configured = true
        let endpoint = CloudPushSettings.endpointText.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard endpoint.hasSuffix("/functions/v1/push"),
              let anon = Bundle.main.object(forInfoDictionaryKey: "NOOPSupabaseAnonKey") as? String,
              !anon.hasPrefix("$("),
              let value = try? AccountAuthConfiguration(
                projectURL: String(endpoint.dropLast("/functions/v1/push".count)), anonKey: anon
              ) else { return }
        controller.configure(value)
    }

    static func identitySnapshot() -> AccountIdentitySnapshot {
        ensureConfiguration()
        return controller.identitySnapshot()
    }
    static func currentContext() -> AccountSessionContext? { identitySnapshot().context }
    static func isCurrent(_ context: AccountSessionContext) -> Bool {
        ensureConfiguration()
        return controller.isCurrent(context)
    }
    static func storedSession() -> Session? { ensureConfiguration(); return controller.storedSession() }
    static var lastPersistenceError: AuthError? { controller.lastError }

    /// Existing UI call remains nonthrowing; root can surface failure using the checked form.
    static func clearSession() { do { try clearSessionChecked() } catch {} }
    static func clearSessionChecked() throws {
        ensureConfiguration()
        try controller.clearSession()
    }
    static func signIn(email: String, password: String) async throws -> Session {
        ensureConfiguration()
        return try await controller.signIn(email: email, password: password)
    }
    static func authorizedSession() async throws -> AuthorizedCloudSession {
        ensureConfiguration()
        return try await controller.authorizedSession()
    }
    static func validAccessToken() async throws -> String { try await authorizedSession().accessToken }
    static func refreshRejectedCredentials(_ context: AccountSessionContext) async throws {
        ensureConfiguration()
        _ = try await controller.authorizedSession(refreshing: context)
    }
}
