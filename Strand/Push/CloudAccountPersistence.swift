import Foundation
import Security
import NoopPush

struct CloudAccountKeychainStore: AccountCredentialStore {
    private let service = "noop.cloudAuth.account.v1"

    func load(projectURL: String) throws -> AccountAuthSession? {
        guard let marker = try read(key: activeKey(projectURL)), !marker.isEmpty else { return nil }
        guard let namespace = String(data: marker, encoding: .utf8),
              let blob = try read(key: "session." + namespace),
              let session = try? JSONDecoder().decode(AccountAuthSession.self, from: blob),
              session.scope.projectURL == projectURL, session.scope.namespace == namespace,
              !session.accessToken.isEmpty, !session.refreshToken.isEmpty else {
            throw AccountAuthError.credentialUnavailable
        }
        return session
    }

    func save(_ session: AccountAuthSession) throws {
        try write(JSONEncoder().encode(session), key: "session." + session.scope.namespace)
        try write(Data(session.scope.namespace.utf8), key: activeKey(session.scope.projectURL))
    }

    func clear(projectURL: String) throws {
        let previous = try read(key: activeKey(projectURL))
        // Tombstone first: failure to remove old credentials must not reactivate them.
        try write(Data(), key: activeKey(projectURL))
        if let previous, let namespace = String(data: previous, encoding: .utf8), !namespace.isEmpty {
            let status = SecItemDelete(query("session." + namespace) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AccountAuthError.credentialUnavailable
            }
        }
    }

    private func activeKey(_ projectURL: String) -> String { "active." + AccountScope.digest(projectURL) }
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: key, kSecAttrSynchronizable as String: false]
    }
    private func read(key: String) throws -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AccountAuthError.credentialUnavailable }
        return data
    }
    private func write(_ data: Data, key: String) throws {
        let attrs: [String: Any] = [kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let q = query(key)
        var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(q.merging(attrs) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AccountAuthError.credentialUnavailable }
    }
}

final class CloudAccountHTTPTransport: NSObject, AccountAuthTransport, URLSessionTaskDelegate, @unchecked Sendable {
    func exchange(configuration: AccountAuthConfiguration, grant: AccountAuthGrant) async throws -> AccountAuthReply {
        let kind: String
        let payload: [String: String]
        switch grant {
        case .password(let email, let password): kind = "password"; payload = ["email": email, "password": password]
        case .refresh(let token): kind = "refresh_token"; payload = ["refresh_token": token]
        }
        guard let url = URL(string: configuration.projectURL + "/auth/v1/token?grant_type=" + kind) else {
            throw AccountAuthError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountAuthError.invalidResponse }
        return AccountAuthReply(status: http.statusCode, body: bytes)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
