import Foundation
import Security

/// Supabase GoTrue session for authenticated score reads (JWT only — never the push ingest token).
enum CloudAuthClient {
    private static let sessionLock = NSLock()
    private static var generation: UInt64 = 0
    struct Session: Equatable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let userId: String

        var isExpired: Bool { Date().addingTimeInterval(60) >= expiresAt }
    }

    enum AuthError: Error {
        case notConfigured
        case invalidCredentials
        case network(Error)
        case decode
    }

    private enum K {
        static let service = "noop.cloudAuth"
        static let account = "session"
    }

    static func storedSession() -> Session? {
        guard let data = KeychainHelper.load(service: K.service, account: K.account) else { return nil }
        return try? JSONDecoder().decode(Persisted.self, from: data).session
    }

    static func clearSession() {
        sessionLock.withLock {
            generation &+= 1
            KeychainHelper.delete(service: K.service, account: K.account)
        }
    }

    @discardableResult static func clearSession(ifAccessToken token: String, ownerId: String) -> Bool {
        sessionLock.withLock {
            guard let current = storedSession(), current.accessToken == token,
                  current.userId.lowercased() == ownerId.lowercased() else { return false }
            generation &+= 1
            KeychainHelper.delete(service: K.service, account: K.account)
            return true
        }
    }

    static func signIn(email: String, password: String) async throws -> Session {
        let requestGeneration = sessionLock.withLock { generation &+= 1; return generation }
        guard let base = ServerScoringSettings.supabaseProjectURL(),
              let anon = ServerScoringSettings.anonKey() else {
            throw AuthError.notConfigured
        }
        var request = URLRequest(url: base.appendingPathComponent("auth/v1/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anon, forHTTPHeaderField: "apikey")
        request.url = URL(string: base.absoluteString + "/auth/v1/token?grant_type=password")!
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "password": password,
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw AuthError.invalidCredentials
            }
            let session = try parseSession(data)
            try Task.checkCancellation()
            try sessionLock.withLock {
                guard generation == requestGeneration else { throw AuthError.invalidCredentials }
                persist(session)
            }
            ServerScoringSettings.setAuthEmail(email)
            return session
        } catch let e as AuthError {
            throw e
        } catch {
            throw AuthError.network(error)
        }
    }

    static func validAccessToken() async throws -> String {
        guard var session = storedSession() else { throw AuthError.invalidCredentials }
        if !session.isExpired { return session.accessToken }
        session = try await refresh(session: session)
        return session.accessToken
    }

    private static func refresh(session: Session) async throws -> Session {
        let requestGeneration = sessionLock.withLock { generation }
        guard let base = ServerScoringSettings.supabaseProjectURL(),
              let anon = ServerScoringSettings.anonKey() else {
            throw AuthError.notConfigured
        }
        var request = URLRequest(url: URL(string: base.absoluteString + "/auth/v1/token?grant_type=refresh_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anon, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "refresh_token": session.refreshToken,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            sessionLock.withLock {
                if generation == requestGeneration && storedSession()?.refreshToken == session.refreshToken {
                    generation &+= 1
                    KeychainHelper.delete(service: K.service, account: K.account)
                }
            }
            throw AuthError.invalidCredentials
        }
        let refreshed = try parseSession(data)
        try Task.checkCancellation()
        try sessionLock.withLock {
            guard generation == requestGeneration, storedSession()?.refreshToken == session.refreshToken,
                  refreshed.userId == session.userId else { throw AuthError.invalidCredentials }
            persist(refreshed)
        }
        return refreshed
    }

    private static func parseSession(_ data: Data) throws -> Session {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String,
              let expiresIn = obj["expires_in"] as? Double,
              let user = obj["user"] as? [String: Any],
              let userId = user["id"] as? String else {
            throw AuthError.decode
        }
        return Session(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            userId: userId
        )
    }

    private static func persist(_ session: Session) {
        let blob = try? JSONEncoder().encode(Persisted(session: session))
        if let blob { KeychainHelper.save(blob, service: K.service, account: K.account) }
    }

    private struct Persisted: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let userId: String

        init(session: Session) {
            accessToken = session.accessToken
            refreshToken = session.refreshToken
            expiresAt = session.expiresAt
            userId = session.userId
        }

        var session: Session {
            Session(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, userId: userId)
        }
    }
}

private enum KeychainHelper {
    static func save(_ data: Data, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
