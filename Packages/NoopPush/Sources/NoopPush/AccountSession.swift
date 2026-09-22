import Foundation
import CryptoKit

public struct AccountScope: Hashable, Codable, Sendable {
    public let projectURL: String
    public let userID: String

    public init(projectURL: String, userID: String) throws {
        self.projectURL = try Self.canonicalProjectURL(projectURL)
        guard let id = UUID(uuidString: userID) else { throw AccountAuthError.invalidIdentity }
        self.userID = id.uuidString.lowercased()
    }

    public var namespace: String { Self.digest("account-v1\u{0}\(projectURL)\u{0}\(userID)") }

    public static func canonicalProjectURL(_ value: String) throws -> String {
        guard var parts = URLComponents(string: value), let host = parts.host?.lowercased(),
              !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.scheme?.lowercased() == "https" ||
                (parts.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)),
              !parts.path.contains(".."), !value.contains("\u{0}") else {
            throw AccountAuthError.notConfigured
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) {
            parts.port = nil
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let result = parts.string else { throw AccountAuthError.notConfigured }
        return result
    }

    public static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey { case projectURL, userID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(projectURL: c.decode(String.self, forKey: .projectURL),
                      userID: c.decode(String.self, forKey: .userID))
    }
}

public struct AccountSessionContext: Hashable, Sendable {
    public let scope: AccountScope
    public let generation: UUID
    public init(scope: AccountScope, generation: UUID) {
        self.scope = scope
        self.generation = generation
    }
}

public struct AccountIdentitySnapshot: Equatable, Sendable {
    public let projectURL: String?
    public let scope: AccountScope?
    public let generation: UUID
    public var context: AccountSessionContext? {
        scope.map { AccountSessionContext(scope: $0, generation: generation) }
    }
}

public struct AccountAuthConfiguration: Equatable, Sendable {
    public let projectURL: String
    public let anonKey: String
    public init(projectURL: String, anonKey: String) throws {
        self.projectURL = try AccountScope.canonicalProjectURL(projectURL)
        guard !anonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AccountAuthError.notConfigured
        }
        self.anonKey = anonKey
    }
}

public struct AccountAuthSession: Codable, Equatable, Sendable {
    public let scope: AccountScope
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public var userId: String { scope.userID }
    public var isExpired: Bool { expiresAt <= Date().addingTimeInterval(60) }
    public init(scope: AccountScope, accessToken: String, refreshToken: String, expiresAt: Date) {
        self.scope = scope
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public struct AuthorizedCloudSession: Sendable {
    public let context: AccountSessionContext
    public let accessToken: String
    public let expiresAt: Date
}

public enum AccountAuthError: Error, Equatable, Sendable {
    case notConfigured, signedOut, invalidIdentity, invalidCredentials, sessionRevoked
    case staleOperation, retryable, invalidResponse, credentialUnavailable, unboundCapture
    case rejected(Int)
    public var isRetryable: Bool {
        switch self {
        case .retryable, .credentialUnavailable, .staleOperation: return true
        default: return false
        }
    }
}

public enum AccountAuthGrant: Sendable {
    case password(email: String, password: String)
    case refresh(String)
}

public struct AccountAuthReply: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol AccountAuthTransport: Sendable {
    func exchange(configuration: AccountAuthConfiguration, grant: AccountAuthGrant) async throws -> AccountAuthReply
}

/// Implementations must commit the active-owner pointer only after the credential write succeeds.
/// A nil load means absent; inaccessible/corrupt storage must throw instead.
public protocol AccountCredentialStore: Sendable {
    func load(projectURL: String) throws -> AccountAuthSession?
    func save(_ session: AccountAuthSession) throws
    func clear(projectURL: String) throws
}

/// The lock permits synchronous logout fencing for existing UI callers. No network await holds it.
/// Refresh tasks are single-flight; only the generation that started a request may commit its result.
public final class AccountSessionController: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let credentials: any AccountCredentialStore
    private let transport: any AccountAuthTransport
    private let now: @Sendable () -> Date
    private let changed: @Sendable () -> Void
    private var configuration: AccountAuthConfiguration?
    private var session: AccountAuthSession?
    private var generation = UUID()
    private var loaded = false
    private var dirtyCredential = false
    private var failure: AccountAuthError?
    private var refreshTask: (id: UUID, task: Task<AuthorizedCloudSession, Error>)?

    public init(credentials: any AccountCredentialStore, transport: any AccountAuthTransport,
                now: @escaping @Sendable () -> Date = { Date() },
                changed: @escaping @Sendable () -> Void = {}) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
        self.changed = changed
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }

    public func configure(_ value: AccountAuthConfiguration?) {
        let didChange = locked { () -> Bool in
            guard value != configuration else { return false }
            invalidateLocked()
            configuration = value
            loaded = false
            failure = nil
            return true
        }
        if didChange { changed() }
    }

    public var lastError: AccountAuthError? { locked { failure } }

    public func identitySnapshot() -> AccountIdentitySnapshot {
        _ = storedSession()
        return locked {
            return AccountIdentitySnapshot(projectURL: configuration?.projectURL,
                                           scope: session?.scope, generation: generation)
        }
    }

    public func storedSession() -> AccountAuthSession? {
        var recovered = false
        let result: AccountAuthSession? = locked {
            do {
                let wasUnavailable = !loaded && failure == .credentialUnavailable
                try loadLocked()
                recovered = wasUnavailable && session != nil
                if recovered { generation = UUID() }
                return session
            }
            catch { failure = .credentialUnavailable; return nil }
        }
        if recovered { changed() }
        return result
    }

    public func currentContext() -> AccountSessionContext? {
        identitySnapshot().context
    }

    public func isCurrent(_ context: AccountSessionContext) -> Bool {
        locked { generation == context.generation && session?.scope == context.scope &&
            configuration?.projectURL == context.scope.projectURL }
    }

    public func clearSession() throws {
        do {
            try locked {
                invalidateLocked()
                loaded = true
                if let configuration { try credentials.clear(projectURL: configuration.projectURL) }
                failure = nil
            }
        } catch {
            locked { failure = .credentialUnavailable }
            changed()
            throw AccountAuthError.credentialUnavailable
        }
        changed()
    }

    public func signIn(email: String, password: String) async throws -> AccountAuthSession {
        let start: (AccountAuthConfiguration, UUID)
        do { start = try locked {
            guard let configuration else { throw AccountAuthError.notConfigured }
            invalidateLocked()
            loaded = true
            // Prevent an older persisted login returning on restart if this login fails.
            do { try credentials.clear(projectURL: configuration.projectURL) }
            catch { failure = .credentialUnavailable; throw AccountAuthError.credentialUnavailable }
            return (configuration, generation)
        } } catch {
            changed()
            throw error
        }
        changed()
        let result = try await exchange(start.0, grant: .password(email: email, password: password))
        let parsed = try parse(result, configuration: start.0, refreshing: false)
        try locked {
            guard generation == start.1, configuration == start.0 else { throw AccountAuthError.staleOperation }
            do { try credentials.save(parsed) }
            catch { failure = .credentialUnavailable; throw AccountAuthError.credentialUnavailable }
            session = parsed
            failure = nil
        }
        changed()
        return parsed
    }

    public func authorizedSession(refreshing rejectedContext: AccountSessionContext? = nil) async throws -> AuthorizedCloudSession {
        _ = storedSession()
        let selected: (AuthorizedCloudSession?, Task<AuthorizedCloudSession, Error>?) = try locked {
            try loadLocked()
            guard let configuration else { throw AccountAuthError.notConfigured }
            guard let session else { throw AccountAuthError.signedOut }
            if let rejectedContext {
                guard rejectedContext == AccountSessionContext(scope: session.scope, generation: generation) else {
                    throw AccountAuthError.staleOperation
                }
            }
            if dirtyCredential {
                do { try credentials.save(session); dirtyCredential = false; failure = nil }
                catch { throw AccountAuthError.credentialUnavailable }
            }
            if rejectedContext == nil, session.expiresAt > now().addingTimeInterval(60) {
                return (AuthorizedCloudSession(context: .init(scope: session.scope, generation: generation),
                                               accessToken: session.accessToken, expiresAt: session.expiresAt), nil)
            }
            if let refreshTask { return (nil, refreshTask.task) }
            let context = AccountSessionContext(scope: session.scope, generation: generation)
            let id = UUID()
            let task = Task { try await self.refresh(configuration, session: session, context: context, id: id) }
            refreshTask = (id, task)
            return (nil, task)
        }
        if let pending = selected.1 {
            let result = try await pending.value
            guard isCurrent(result.context) else { throw AccountAuthError.staleOperation }
            return result
        }
        guard let selected = selected.0, isCurrent(selected.context) else { throw AccountAuthError.staleOperation }
        return selected
    }

    private func refresh(_ configuration: AccountAuthConfiguration, session: AccountAuthSession,
                         context: AccountSessionContext, id: UUID) async throws -> AuthorizedCloudSession {
        defer { locked { if refreshTask?.id == id { refreshTask = nil } } }
        do {
            let reply = try await exchange(configuration, grant: .refresh(session.refreshToken))
            let refreshed = try parse(reply, configuration: configuration, refreshing: true)
            return try locked {
                guard isCurrent(context), self.configuration == configuration else { throw AccountAuthError.staleOperation }
                guard refreshed.scope == context.scope else { throw AccountAuthError.invalidIdentity }
                // Keep rotated credentials in memory if persistence is temporarily unavailable.
                self.session = refreshed
                dirtyCredential = true
                do { try credentials.save(refreshed); dirtyCredential = false; failure = nil }
                catch { failure = .credentialUnavailable; throw AccountAuthError.credentialUnavailable }
                return AuthorizedCloudSession(context: context, accessToken: refreshed.accessToken,
                                              expiresAt: refreshed.expiresAt)
            }
        } catch {
            let current = locked { isCurrent(context) && self.configuration == configuration }
            guard current else { throw AccountAuthError.staleOperation }
            if error as? AccountAuthError == .sessionRevoked {
                let didClear = locked { () -> Bool in
                    guard isCurrent(context) else { return false }
                    invalidateLocked(); loaded = true
                    do { try credentials.clear(projectURL: configuration.projectURL); failure = .sessionRevoked }
                    catch { failure = .credentialUnavailable }
                    return true
                }
                if didClear { changed() }
            }
            throw error
        }
    }

    private func loadLocked() throws {
        guard !loaded, let configuration else { return }
        do {
            let value = try credentials.load(projectURL: configuration.projectURL)
            guard value == nil || value?.scope.projectURL == configuration.projectURL else {
                throw AccountAuthError.invalidIdentity
            }
            if let value {
                guard !value.accessToken.isEmpty, !value.refreshToken.isEmpty,
                      value.expiresAt.timeIntervalSince1970.isFinite else {
                    throw AccountAuthError.credentialUnavailable
                }
            }
            session = value; loaded = true; failure = nil
        } catch { failure = .credentialUnavailable; throw AccountAuthError.credentialUnavailable }
    }

    private func invalidateLocked() {
        generation = UUID()
        session = nil
        dirtyCredential = false
        refreshTask?.task.cancel()
        refreshTask = nil
    }

    private func exchange(_ configuration: AccountAuthConfiguration, grant: AccountAuthGrant) async throws -> AccountAuthReply {
        do { return try await transport.exchange(configuration: configuration, grant: grant) }
        catch let error as AccountAuthError { throw error }
        catch { throw AccountAuthError.retryable }
    }

    private func parse(_ reply: AccountAuthReply, configuration: AccountAuthConfiguration,
                       refreshing: Bool) throws -> AccountAuthSession {
        guard reply.body.count <= 128 * 1024 else { throw AccountAuthError.invalidResponse }
        if reply.status == 429 || reply.status == 408 || reply.status >= 500 { throw AccountAuthError.retryable }
        let body = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
        guard reply.status == 200 else {
            let code = (body?["error_code"] ?? body?["error"]) as? String ?? ""
            if refreshing, [400, 401].contains(reply.status),
               ["refresh_token_not_found", "refresh_token_already_used", "invalid_grant", "session_not_found"].contains(code) {
                throw AccountAuthError.sessionRevoked
            }
            if !refreshing, [400, 401].contains(reply.status) { throw AccountAuthError.invalidCredentials }
            throw AccountAuthError.rejected(reply.status)
        }
        guard let body, let access = body["access_token"] as? String, !access.isEmpty,
              let refresh = body["refresh_token"] as? String, !refresh.isEmpty,
              let seconds = body["expires_in"] as? Double, seconds.isFinite, seconds > 0,
              let user = body["user"] as? [String: Any], let userID = user["id"] as? String else {
            throw AccountAuthError.invalidResponse
        }
        return AccountAuthSession(scope: try .init(projectURL: configuration.projectURL, userID: userID),
                                  accessToken: access, refreshToken: refresh, expiresAt: now().addingTimeInterval(seconds))
    }
}
