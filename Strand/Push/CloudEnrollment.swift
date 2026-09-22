import Foundation
import NoopPush
import Security

struct CloudEnrollmentCredential: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let userId: String
    let sourceId: String
    let tokenId: String
    let uploadToken: String

    init(userId: String, sourceId: String, tokenId: String, uploadToken: String) {
        self.init(
            version: Self.currentVersion,
            userId: userId,
            sourceId: sourceId,
            tokenId: tokenId,
            uploadToken: uploadToken
        )
    }

    init(version: Int, userId: String, sourceId: String, tokenId: String, uploadToken: String) {
        self.version = version
        self.userId = userId
        self.sourceId = sourceId
        self.tokenId = tokenId
        self.uploadToken = uploadToken
    }

    func isValid(forSourceId expectedSourceId: String) -> Bool {
        version == Self.currentVersion
            && Self.isCanonicalUUID(userId)
            && Self.isCanonicalUUID(sourceId)
            && Self.isCanonicalUUID(tokenId)
            && sourceId == expectedSourceId
            && Self.isValidUploadToken(uploadToken)
    }

    static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    static func isValidUploadToken(_ value: String) -> Bool {
        guard value.hasPrefix("noop_") else { return false }
        let suffix = value.dropFirst("noop_".count)
        guard suffix.count == 43 else { return false }
        return suffix.unicodeScalars.allSatisfy {
            switch $0.value {
            case 45, 48...57, 65...90, 95, 97...122:
                return true
            default:
                return false
            }
        }
    }
}

enum CloudEnrollmentPlatform: String, Sendable {
    case iOS = "ios"
    case macOS = "macos"

    static var current: Self {
        #if os(iOS)
        return .iOS
        #else
        return .macOS
        #endif
    }
}

enum CloudEnrollmentError: Error, Equatable, LocalizedError {
    case notConfigured
    case invalidCode
    case invalidResponse
    case rejected(statusCode: Int)
    case networkUnavailable
    case credentialStorageUnavailable
    case ownerMismatch
    case superseded

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "Enrollment is not configured in this build.")
        case .invalidCode:
            return String(localized: "Enter a valid enrollment code.")
        case .invalidResponse:
            return String(localized: "The enrollment server returned an invalid response.")
        case .rejected(let statusCode):
            return String(localized: "Enrollment was rejected by the server (HTTP \(statusCode)).")
        case .networkUnavailable:
            return String(localized: "Enrollment could not reach the server.")
        case .credentialStorageUnavailable:
            return String(localized: "Enrollment could not save the device credential.")
        case .ownerMismatch:
            return String(localized: "This installation belongs to another account. Reconnect with a code for its original account.")
        case .superseded:
            return String(localized: "This sign-in was replaced or canceled. Enter your code again.")
        }
    }
}

struct CloudEnrollmentClient {
    private let session: URLSession

    init(session: URLSession = CloudPushTransport.makeSession()) {
        self.session = session
    }

    func verify(_ credential: CloudEnrollmentCredential, endpoint: PushValidEndpoint,
                fleetToken: String) async throws {
        let transport = CloudPushTransport(endpoint: endpoint, uploadToken: credential.uploadToken,
                                           fleetToken: fleetToken, session: session)
        guard case .available(let capabilities) = try await transport.capabilities(),
              capabilities.userId == credential.userId,
              capabilities.sourceId == credential.sourceId else {
            throw CloudEnrollmentError.invalidResponse
        }
    }

    func enroll(
        code: String,
        endpoint: PushValidEndpoint,
        fleetToken: String,
        sourceId: String,
        platform: CloudEnrollmentPlatform,
        appVersion: String
    ) async throws -> CloudEnrollmentCredential {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPrintable(normalizedCode, maximumLength: 128), normalizedCode.count >= 4 else {
            throw CloudEnrollmentError.invalidCode
        }
        guard CloudEnrollmentCredential.isCanonicalUUID(sourceId),
              Self.isPrintable(fleetToken, maximumLength: 512),
              Self.isPrintable(appVersion, maximumLength: 64) else {
            throw CloudEnrollmentError.notConfigured
        }

        let body = try JSONSerialization.data(withJSONObject: [
            "code": normalizedCode,
            "sourceId": sourceId,
            "platform": platform.rawValue,
            "appVersion": appVersion,
        ], options: [.sortedKeys])

        var request = URLRequest(url: try enrollmentURL(endpoint: endpoint))
        request.httpMethod = "POST"
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(fleetToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let status: Int
        do {
            let result = try await session.data(for: request)
            data = result.0
            status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw CloudEnrollmentError.networkUnavailable
        }

        guard (200...299).contains(status) else {
            throw CloudEnrollmentError.rejected(statusCode: status)
        }
        guard data.count <= PushProtocolLimits.maxAckBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudEnrollmentError.invalidResponse
        }

        let requiredKeys: Set<String> = [
            "type", "protocolVersion", "userId", "sourceId", "tokenId", "uploadToken",
        ]
        let actualKeys = Set(object.keys)
        guard actualKeys == requiredKeys,
              object["type"] as? String == "enrollment",
              object["protocolVersion"] as? String == "1.1",
              let userId = object["userId"] as? String,
              let returnedSourceId = object["sourceId"] as? String,
              let tokenId = object["tokenId"] as? String,
              let uploadToken = object["uploadToken"] as? String else {
            throw CloudEnrollmentError.invalidResponse
        }
        let credential = CloudEnrollmentCredential(
            userId: userId,
            sourceId: returnedSourceId,
            tokenId: tokenId,
            uploadToken: uploadToken
        )
        guard credential.isValid(forSourceId: sourceId) else {
            throw CloudEnrollmentError.invalidResponse
        }
        return credential
    }

    private func enrollmentURL(endpoint: PushValidEndpoint) throws -> URL {
        guard var components = URLComponents(string: endpoint.url) else {
            throw CloudEnrollmentError.notConfigured
        }
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + "/enroll"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw CloudEnrollmentError.notConfigured }
        return url
    }

    private static func isPrintable(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty
            && value.count <= maximumLength
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

protocol CloudEnrollmentKeychainBackend {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

/// Enrollment gates run in view and BLE hot paths. Share short-lived successful reads while
/// invalidating synchronously on every write or revocation; failed reads are always retried.
final class CachedCloudEnrollmentKeychain: CloudEnrollmentKeychainBackend, @unchecked Sendable {
    private struct Entry { let data: Data; let expiresAt: TimeInterval }
    private let lock = NSLock()
    private let backend: any CloudEnrollmentKeychainBackend
    private let now: () -> TimeInterval
    private let lifetime: TimeInterval
    private var entries: [String: Entry] = [:]

    init(backend: any CloudEnrollmentKeychainBackend, lifetime: TimeInterval = 1,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.backend = backend
        self.lifetime = lifetime
        self.now = now
    }

    func read(service: String, account: String) throws -> Data? {
        try lock.withLock {
            let key = service + "\u{0000}" + account
            if let entry = entries[key], now() < entry.expiresAt { return entry.data }
            entries[key] = nil
            guard let data = try backend.read(service: service, account: account) else { return nil }
            entries[key] = Entry(data: data, expiresAt: now() + lifetime)
            return data
        }
    }

    func write(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            entries[service + "\u{0000}" + account] = nil
            try backend.write(data, service: service, account: account)
        }
    }

    func delete(service: String, account: String) throws {
        try lock.withLock {
            entries[service + "\u{0000}" + account] = nil
            try backend.delete(service: service, account: account)
        }
    }
}

private let sharedEnrollmentKeychain = CachedCloudEnrollmentKeychain(backend: SystemCloudEnrollmentKeychain())

private struct SystemCloudEnrollmentKeychain: CloudEnrollmentKeychainBackend {
    private struct KeychainStatusError: Error {
        let status: OSStatus
    }

    func read(service: String, account: String) throws -> Data? {
        // Hosted XCTest must never borrow the developer's enrollment or trigger a Keychain prompt.
        // Enrollment tests inject their own backend; production authorization is unchanged.
        guard !AppRuntimeMode.isUnitTesting else { return nil }
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainStatusError(status: status)
        }
        return data
    }

    func write(_ data: Data, service: String, account: String) throws {
        guard !AppRuntimeMode.isUnitTesting else { throw KeychainStatusError(status: errSecInteractionNotAllowed) }
        let query = baseQuery(service: service, account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStatusError(status: updateStatus)
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard retryStatus == errSecSuccess else {
                throw KeychainStatusError(status: retryStatus)
            }
            return
        }
        throw KeychainStatusError(status: addStatus)
    }

    func delete(service: String, account: String) throws {
        guard !AppRuntimeMode.isUnitTesting else { throw KeychainStatusError(status: errSecInteractionNotAllowed) }
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStatusError(status: status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct CloudEnrollmentCredentialStore {
    static let system = CloudEnrollmentCredentialStore(backend: sharedEnrollmentKeychain)

    private let backend: any CloudEnrollmentKeychainBackend
    private let service = "noop.cloudEnrollment"
    private let account = "credential.v1"

    init(backend: any CloudEnrollmentKeychainBackend) {
        self.backend = backend
    }

    func load(sourceId: String) throws -> CloudEnrollmentCredential? {
        guard CloudEnrollmentCredential.isCanonicalUUID(sourceId) else { return nil }
        guard let data = try backend.read(service: service, account: account) else { return nil }
        guard let credential = try? JSONDecoder().decode(CloudEnrollmentCredential.self, from: data),
              credential.isValid(forSourceId: sourceId) else {
            try? backend.delete(service: service, account: account)
            return nil
        }
        return credential
    }

    func save(_ credential: CloudEnrollmentCredential, sourceId: String) throws {
        guard credential.isValid(forSourceId: sourceId) else {
            throw CloudEnrollmentError.invalidResponse
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try backend.write(try encoder.encode(credential), service: service, account: account)
    }

    func clear() throws {
        try backend.delete(service: service, account: account)
    }
}

/// A device-local witness for the installation id. UserDefaults may be restored onto another
/// phone, while this `ThisDeviceOnly` Keychain item may not. Both copies must agree before an old
/// source id is reused.
struct CloudInstallationSourceStore {
    static let system = CloudInstallationSourceStore(backend: sharedEnrollmentKeychain)

    private let backend: any CloudEnrollmentKeychainBackend
    private let service = "noop.cloudEnrollment"
    private let account = "installation-source.v1"

    init(backend: any CloudEnrollmentKeychainBackend) {
        self.backend = backend
    }

    func load() throws -> String? {
        guard let data = try backend.read(service: service, account: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8),
              CloudEnrollmentCredential.isCanonicalUUID(value) else {
            try? backend.delete(service: service, account: account)
            return nil
        }
        return value
    }

    func save(_ sourceId: String) throws {
        guard CloudEnrollmentCredential.isCanonicalUUID(sourceId) else {
            throw CloudEnrollmentError.credentialStorageUnavailable
        }
        try backend.write(Data(sourceId.utf8), service: service, account: account)
    }
}

/// Retained independently of sign-in, so changing credentials cannot relabel the capture store.
struct CloudEnrollmentOwnerStore {
    static let system = CloudEnrollmentOwnerStore(backend: sharedEnrollmentKeychain)
    private let backend: any CloudEnrollmentKeychainBackend
    private let service = "noop.cloudEnrollment"
    private let account = "capture-owner.v1"

    init(backend: any CloudEnrollmentKeychainBackend) { self.backend = backend }

    func load() throws -> String? {
        guard let data = try backend.read(service: service, account: account) else { return nil }
        guard let owner = String(data: data, encoding: .utf8),
              CloudEnrollmentCredential.isCanonicalUUID(owner) else {
            throw CloudEnrollmentError.credentialStorageUnavailable
        }
        return owner
    }

    func bind(ownerId: String) throws {
        guard CloudEnrollmentCredential.isCanonicalUUID(ownerId) else {
            throw CloudEnrollmentError.invalidResponse
        }
        if let existing = try load() {
            guard existing == ownerId else { throw CloudEnrollmentError.ownerMismatch }
            return
        }
        try backend.write(Data(ownerId.utf8), service: service, account: account)
    }
}

extension Notification.Name {
    static let cloudEnrollmentDidChange = Notification.Name("noop.cloudEnrollment.didChange")
}

/// Serializes activation and sign-out around network suspension points. No network runs under lock.
final class CloudEnrollmentSessionController: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var suspended = false

    func begin() -> UInt64 { lock.withLock { generation &+= 1; return generation } }

    func activate(_ credential: CloudEnrollmentCredential, sourceId: String, request: UInt64,
                  store: CloudEnrollmentCredentialStore, ownerStore: CloudEnrollmentOwnerStore) throws {
        try lock.withLock {
            guard request == generation else { throw CloudEnrollmentError.superseded }
            guard credential.isValid(forSourceId: sourceId) else { throw CloudEnrollmentError.invalidResponse }
            try ownerStore.bind(ownerId: credential.userId)
            try store.save(credential, sourceId: sourceId)
            suspended = false
        }
    }

    func clear(store: CloudEnrollmentCredentialStore) throws {
        try lock.withLock {
            generation &+= 1
            suspended = true
            try store.clear()
        }
    }

    func clear(ifUploadToken token: String, ownerId: String, sourceId: String,
               store: CloudEnrollmentCredentialStore) -> Bool {
        lock.withLock {
            guard let current = try? store.load(sourceId: sourceId),
                  current.uploadToken == token, current.userId == ownerId.lowercased() else { return false }
            generation &+= 1
            suspended = true
            do { try store.clear(); return true } catch { return false }
        }
    }

    func current(sourceId: String, store: CloudEnrollmentCredentialStore,
                 ownerStore: CloudEnrollmentOwnerStore) -> CloudEnrollmentCredential? {
        lock.withLock {
            guard !suspended,
                  let credential = try? store.load(sourceId: sourceId),
                  (try? ownerStore.load()) == credential.userId else { return nil }
            return credential
        }
    }
}

enum CloudEnrollment {
    private static let controller = CloudEnrollmentSessionController()
    static func currentCredential(
        sourceId: String? = nil,
        store: CloudEnrollmentCredentialStore = .system,
        ownerStore: CloudEnrollmentOwnerStore = .system
    ) -> CloudEnrollmentCredential? {
        let currentSourceId = sourceId ?? CloudPushSettings.sourceId()
        return controller.current(sourceId: currentSourceId, store: store, ownerStore: ownerStore)
    }

    @discardableResult
    static func enroll(
        code: String,
        client: CloudEnrollmentClient = CloudEnrollmentClient(),
        store: CloudEnrollmentCredentialStore = .system,
        ownerStore: CloudEnrollmentOwnerStore = .system
    ) async throws -> CloudEnrollmentCredential {
        let request = controller.begin()
        guard let endpoint = CloudPushSettings.configuredEndpoint(),
              let fleetToken = CloudPushSettings.resolvedFleetToken(),
              let appVersion = resolvedAppVersion() else {
            throw CloudEnrollmentError.notConfigured
        }
        let sourceId = CloudPushSettings.sourceId()
        guard (try? CloudInstallationSourceStore.system.load()) == sourceId else {
            throw CloudEnrollmentError.credentialStorageUnavailable
        }
        let credential = try await client.enroll(
            code: code,
            endpoint: endpoint,
            fleetToken: fleetToken,
            sourceId: sourceId,
            platform: .current,
            appVersion: appVersion
        )
        try Task.checkCancellation()
        try await client.verify(credential, endpoint: endpoint, fleetToken: fleetToken)
        try Task.checkCancellation()
        guard CloudPushSettings.sourceId() == sourceId else { throw CloudEnrollmentError.superseded }
        do {
            try controller.activate(credential, sourceId: sourceId, request: request,
                                    store: store, ownerStore: ownerStore)
        } catch let error as CloudEnrollmentError {
            throw error
        } catch {
            throw CloudEnrollmentError.credentialStorageUnavailable
        }
        enableCloudForEnrolledAccount()
        NotificationCenter.default.post(name: .cloudEnrollmentDidChange, object: nil)
        return credential
    }

    static func enableCloudForEnrolledAccount(defaults: UserDefaults = .standard) {
        CloudPushSettings.enableForEnrolledAccount(defaults: defaults)
        defaults.set(true, forKey: ServerScoringSettings.defaultsKey)
    }

    static func clear(store: CloudEnrollmentCredentialStore = .system) throws {
        defer { NotificationCenter.default.post(name: .cloudEnrollmentDidChange, object: nil, userInfo: ["revoked": true]) }
        try controller.clear(store: store)
    }

    @discardableResult
    static func clear(ifUploadToken token: String, ownerId: String) -> Bool {
        let cleared = controller.clear(ifUploadToken: token, ownerId: ownerId,
                                       sourceId: CloudPushSettings.sourceId(), store: .system)
        if cleared { NotificationCenter.default.post(name: .cloudEnrollmentDidChange, object: nil, userInfo: ["revoked": true]) }
        return cleared
    }

    private static func resolvedAppVersion(bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 64,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return value
    }
}
