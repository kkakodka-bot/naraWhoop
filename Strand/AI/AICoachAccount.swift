import Foundation
import Security

protocol AIKeychainAccess {
    func read(service: String, account: String) -> Data?
    func write(_ data: Data, service: String, account: String) -> Bool
    func remove(service: String, account: String) -> Bool
}

struct AISystemKeychain: AIKeychainAccess {
    private func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read(service: String, account: String) -> Data? {
        var attributes = query(service: service, account: account)
        attributes[kSecReturnData as String] = kCFBooleanTrue
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    func write(_ data: Data, service: String, account: String) -> Bool {
        let attributes = query(service: service, account: account)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(attributes as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var insert = attributes
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
    func remove(service: String, account: String) -> Bool {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

struct AIKeyStore {
    struct Credential: Codable, Equatable {
        let key: String
        let provider: String
    }
    private let account: String?
    private let backend: any AIKeychainAccess
    private let service = "com.noop.aicoach"

    init(namespace: String?, backend: any AIKeychainAccess = AISystemKeychain()) {
        account = Self.validNamespace(namespace).map { "api-key.v2." + $0 }
        self.backend = backend
    }

    static func validNamespace(_ value: String?) -> String? {
        guard let value, value.count == 64,
              value.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return value
    }

    func read() -> Credential? {
        guard let account, let data = backend.read(service: service, account: account),
              let value = try? JSONDecoder().decode(Credential.self, from: data),
              !value.key.isEmpty, !value.provider.isEmpty else { return nil }
        return value
    }

    @discardableResult
    func save(_ key: String, owner: String) -> Bool {
        guard let account, !owner.isEmpty else { return false }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return clear() }
        guard let data = try? JSONEncoder().encode(Credential(key: trimmed, provider: owner)) else { return false }
        // Provider and key change atomically. No fallback to, adoption of, or deletion of "api-key".
        return backend.write(data, service: service, account: account)
    }

    @discardableResult
    func clear() -> Bool {
        guard let account else { return false }
        return backend.remove(service: service, account: account)
    }
}

@MainActor
final class AICoachAccount {
    let defaults: UserDefaults
    let namespace: String?
    let session: URLSession
    let keys: AIKeyStore
    private let ownerIsCurrent: () -> Bool
    private var retired = false

    init(defaults: UserDefaults, namespace: String?, isCurrent: @escaping () -> Bool,
         configuration: URLSessionConfiguration = .ephemeral,
         keychain: any AIKeychainAccess = AISystemKeychain()) {
        self.defaults = defaults
        self.namespace = AIKeyStore.validNamespace(namespace)
        self.ownerIsCurrent = isCurrent
        self.keys = AIKeyStore(namespace: namespace, backend: keychain)
        self.session = URLSession(configuration: configuration)
    }

    var isCurrent: Bool { !retired && namespace != nil && ownerIsCurrent() }
    func requireCurrent() throws {
        guard isCurrent, !Task.isCancelled else { throw CancellationError() }
    }
    func retire() {
        guard !retired else { return }
        retired = true
        session.invalidateAndCancel()
    }
    deinit { session.invalidateAndCancel() }
}
