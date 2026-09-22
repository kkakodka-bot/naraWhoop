import Foundation
import NoopPush

/// Compatibility facade shared by upload, readback, enrollment-gated score reads, and the root-owned
/// account runtime. Cookie/cache-free control sessions live in AccountSessionController / ReadTransport.
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

    /// HEAD enrollment/score callers may drop only the matching JWT for the active owner.
    @discardableResult static func clearSession(ifAccessToken token: String, ownerId: String) -> Bool {
        ensureConfiguration()
        guard let current = storedSession(), current.accessToken == token,
              current.userId.lowercased() == ownerId.lowercased() else { return false }
        clearSession()
        return true
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

/// The app supports two intentionally separate credentials: a normal Supabase account session and
/// the code-issued tester enrollment used by capture/readback. Root runtime ownership must recognize
/// both; treating an enrolled tester as signed out opens an unassigned store and leaves the device gate
/// waiting forever even when its server receipt is already present.
enum CloudRuntimeIdentity {
    static func enrollmentSnapshot(
        credential: CloudEnrollmentCredential?,
        projectURL: URL?
    ) -> AccountIdentitySnapshot? {
        guard let credential,
              credential.isValid(forSourceId: credential.sourceId),
              let projectURL,
              let generation = UUID(uuidString: credential.tokenId),
              let scope = try? AccountScope(projectURL: projectURL.absoluteString,
                                            userID: credential.userId) else { return nil }
        return AccountIdentitySnapshot(projectURL: scope.projectURL, scope: scope,
                                       generation: generation)
    }

    static func currentEnrollmentSnapshot() -> AccountIdentitySnapshot? {
        guard let endpoint = CloudPushSettings.configuredEndpoint()?.url,
              endpoint.hasSuffix("/functions/v1/push"), CloudCaptureScope.ready else { return nil }
        return enrollmentSnapshot(credential: CloudEnrollment.currentCredential(),
            projectURL: URL(string: String(endpoint.dropLast("/functions/v1/push".count))))
    }

    static func snapshot() -> AccountIdentitySnapshot {
        if CloudEnrollment.runtimeBlocked {
            return AccountIdentitySnapshot(projectURL: nil, scope: nil, generation: CloudEnrollment.retirementGeneration)
        }
        return currentEnrollmentSnapshot() ?? CloudAuthClient.identitySnapshot()
    }

    static func isEnrollment(_ context: AccountSessionContext) -> Bool {
        currentEnrollmentSnapshot()?.context == context
    }

    static func isCurrent(_ context: AccountSessionContext) -> Bool {
        snapshot().context == context
    }

    static func authorizedSession() async throws -> AuthorizedCloudSession {
        guard !CloudEnrollment.runtimeBlocked else { throw CloudEnrollmentError.superseded }
        if let context = currentEnrollmentSnapshot()?.context,
           let credential = CloudEnrollment.currentCredential(),
           context.generation == UUID(uuidString: credential.tokenId) {
            return AuthorizedCloudSession(context: context, accessToken: credential.uploadToken,
                                           expiresAt: .distantFuture)
        }
        return try await CloudAuthClient.authorizedSession()
    }
}
