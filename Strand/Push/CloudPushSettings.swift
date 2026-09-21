import Foundation
import CryptoKit
import NoopPush

/// Push configuration. The destination and fleet authorization token are baked into the build.
/// A source-bound enrollment credential supplies the user identity for every upload; account-scoped
/// keys isolate per-login status. Credentials for JWT readback come from the active account session.
enum CloudPushSettings {
    enum RunState: String {
        case idle, queued, running, continuing, retrying, complete, failed
    }

    struct Snapshot {
        let enabled: Bool
        let binaryObjectsEnabled: Bool
        let wifiOnly: Bool
        let endpoint: PushValidEndpoint?
        let hasToken: Bool
        let termsAccepted: Bool
        let lastSuccessAt: Date?
        let lastError: String?
        let runState: RunState
        let acceptedBatches: Int
        let acceptedRecords: Int
        let supportedStreams: [String]?
        let capabilitiesCheckedAt: Date?

        var ready: Bool { enabled && termsAccepted && endpoint != nil && hasToken }
    }

    private static func scopedKey(_ key: String) -> String {
        "account.\(CloudRuntimeIdentity.snapshot().scope?.namespace ?? "signed-out").\(key)"
    }

    private enum K {
        static let enabled = "cloudPush.enabled"
        static let binaryObjectsEnabled = "cloudPush.binaryObjectsEnabled"
        static let sourceId = "cloudPush.sourceId"
        static var scopedSourceId: String { scopedKey("cloudPush.sourceId") }
        static let wifiOnly = "cloudPush.wifiOnly"
        static var lastSuccess: String { scopedKey("cloudPush.lastSuccessAt") }
        static var lastError: String { scopedKey("cloudPush.lastError") }
        static var runState: String { scopedKey("cloudPush.runState") }
        static var acceptedBatches: String { scopedKey("cloudPush.acceptedBatches") }
        static var acceptedRecords: String { scopedKey("cloudPush.acceptedRecords") }
        static var capabilitiesEndpoint: String { scopedKey("cloudPush.capabilitiesEndpoint") }
        static var capabilitiesUserId: String { scopedKey("cloudPush.capabilitiesUserId") }
        static var capabilitiesSourceId: String { scopedKey("cloudPush.capabilitiesSourceId") }
        static var capabilitiesStreams: String { scopedKey("cloudPush.capabilitiesStreams") }
        static var capabilitiesAt: String { scopedKey("cloudPush.capabilitiesAt") }
        static let nextDevicePrefix = "cloudPush.nextDevice."
        static let cycleMorePrefix = "cloudPush.cycleMore."
    }

    /// Fleet destination baked into Info.plist at build time from Config/CloudPush.xcconfig
    /// (gitignored secrets in Config/CloudPushSecrets.xcconfig). This is the only destination —
    /// builds without the secrets file simply have push unconfigured. An unresolved `$(…)`
    /// placeholder reads as absent.
    private static func bundleValue(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    /// The first-run consent record. The Terms overlay is visual-only (it renders ABOVE the engine),
    /// so the data plane needs its own gate: no push may start until the current Terms version is
    /// accepted. Key matches `ContentView`'s `@AppStorage("noop.acceptedTermsVersion")`.
    static var termsAccepted: Bool {
        UserDefaults.standard.string(forKey: "noop.acceptedTermsVersion") == Terms.currentVersion
    }

    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: K.enabled) == nil { return true }
        return UserDefaults.standard.bool(forKey: K.enabled)
    }
    static var binaryObjectsEnabled: Bool {
        if UserDefaults.standard.object(forKey: K.binaryObjectsEnabled) == nil { return true }
        return UserDefaults.standard.bool(forKey: K.binaryObjectsEnabled)
    }
    static var endpointText: String {
        bundleValue("NOOPPushEndpoint") ?? ""
    }

    /// Fleet authorization is baked into the bundle. It authorizes an installation to contact the
    /// receiver, but user identity comes only from the enrolled upload credential.
    static func resolvedFleetToken() -> String? {
        bundleValue("NOOPPushToken")
    }
    static func resolvedToken() -> String? { CloudAuthClient.storedSession()?.accessToken }
    static var wifiOnly: Bool {
        if UserDefaults.standard.object(forKey: K.wifiOnly) == nil { return true }
        return UserDefaults.standard.bool(forKey: K.wifiOnly)
    }

    static var ready: Bool { isEnabled && termsAccepted && isConfigured }

    private static var isConfigured: Bool {
        guard configuredEndpoint() != nil else { return false }
        if let credential = CloudEnrollment.currentCredential(),
           CloudCaptureScope.isActive(for: credential.userId),
           resolvedFleetToken() != nil {
            return true
        }
        return resolvedToken() != nil
    }

    static func snapshot() -> Snapshot {
        let endpoint: PushValidEndpoint?
        if case .valid(let valid) = PushEndpointPolicy.validate(endpointText) {
            endpoint = valid
        } else {
            endpoint = nil
        }
        let sourceId = sourceId()
        let credential = CloudEnrollment.currentCredential(sourceId: sourceId)
        let supported = capabilitiesFor(endpoint: endpoint, credential: credential)
        return Snapshot(
            enabled: isEnabled,
            binaryObjectsEnabled: binaryObjectsEnabled,
            wifiOnly: wifiOnly,
            endpoint: endpoint,
            hasToken: resolvedFleetToken() != nil && credential != nil || resolvedToken() != nil,
            termsAccepted: termsAccepted,
            lastSuccessAt: UserDefaults.standard.object(forKey: K.lastSuccess).map { Date(timeIntervalSince1970: $0 as? TimeInterval ?? 0) },
            lastError: UserDefaults.standard.string(forKey: K.lastError),
            runState: RunState(rawValue: UserDefaults.standard.string(forKey: K.runState) ?? "") ?? .idle,
            acceptedBatches: max(0, UserDefaults.standard.integer(forKey: K.acceptedBatches)),
            acceptedRecords: max(0, UserDefaults.standard.integer(forKey: K.acceptedRecords)),
            supportedStreams: supported,
            capabilitiesCheckedAt: {
                let at = UserDefaults.standard.double(forKey: K.capabilitiesAt)
                return at > 0 && supported != nil ? Date(timeIntervalSince1970: at) : nil
            }()
        )
    }

    static func configuredEndpoint() -> PushValidEndpoint? {
        guard case .valid(let endpoint) = PushEndpointPolicy.validate(endpointText) else { return nil }
        return endpoint
    }

    static func enabledEndpoint() -> PushValidEndpoint? {
        guard ready else { return nil }
        return configuredEndpoint()
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if enabled && !isConfigured { return false }
        UserDefaults.standard.set(enabled, forKey: K.enabled)
        if !enabled {
            UserDefaults.standard.removeObject(forKey: K.lastError)
            UserDefaults.standard.set(RunState.idle.rawValue, forKey: K.runState)
        }
        return true
    }

    /// Enrollment enables automatic delivery even when an older local-only setup disabled it.
    /// This does not make an unactivated capture store eligible for upload.
    static func enableForEnrolledAccount(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: K.enabled)
    }

    static func setBinaryObjectsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: K.binaryObjectsEnabled)
    }

    static func setWifiOnly(_ wifiOnly: Bool) {
        UserDefaults.standard.set(wifiOnly, forKey: K.wifiOnly)
    }

    static func sourceId(
        defaults: UserDefaults = .standard,
        sourceStore: CloudInstallationSourceStore = .system
    ) -> String {
        let defaultsSource = defaults.string(forKey: K.sourceId).flatMap { existing -> String? in
            guard let uuid = UUID(uuidString: existing) else { return nil }
            return uuid.uuidString.lowercased()
        }

        let witnessedSource: String?
        do {
            witnessedSource = try sourceStore.load()
        } catch {
            // A protected Keychain can be temporarily unavailable before unlock. Do not mint a
            // replacement identity that would invalidate the returning credential and its witness.
            if let defaultsSource {
                return defaultsSource
            }
            return ""
        }

        if let defaultsSource, defaultsSource == witnessedSource {
            if defaults.string(forKey: K.sourceId) != defaultsSource {
                defaults.set(defaultsSource, forKey: K.sourceId)
            }
            return defaultsSource
        }

        // Missing defaults indicates reinstall; missing witness indicates device restore or first
        // rollout of this stronger binding. A mismatch is never allowed to inherit either source.
        let generated = UUID().uuidString.lowercased()
        do {
            try sourceStore.save(generated)
        } catch {
            return ""
        }
        defaults.set(generated, forKey: K.sourceId)
        return generated
    }

    static func sourceId() -> String {
        sourceId(defaults: .standard, sourceStore: .system)
    }

    static func sourceId(scope: AccountScope) -> String {
        if CloudRuntimeIdentity.currentEnrollmentSnapshot()?.scope == scope,
           let credential = CloudEnrollment.currentCredential() { return credential.sourceId }
        return sourceId(key: "account.\(scope.namespace).cloudPush.sourceId")
    }

    private static let sourceIDLock = NSLock()
    private static func sourceId(key: String) -> String {
        sourceIDLock.lock(); defer { sourceIDLock.unlock() }
        if let existing = UserDefaults.standard.string(forKey: key),
           UUID(uuidString: existing) != nil {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    static func progressNamespace(
        userId: String,
        sourceId: String,
        endpoint: PushValidEndpoint,
        protocolVersion: String = PushProtocol.version,
        receiverStateId: String = PushCapabilities.unscopedReceiverStateId
    ) -> String {
        let seed = "\(userId)\u{0000}\(sourceId)\u{0000}\(endpoint.url)\u{0000}\(protocolVersion)\u{0000}\(receiverStateId)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func progressNamespace(
        sourceId: String,
        endpoint: PushValidEndpoint,
        protocolVersion: String = PushProtocol.version,
        receiverStateId: String = PushCapabilities.unscopedReceiverStateId,
        scope: AccountScope? = CloudAuthClient.currentContext()?.scope
    ) -> String {
        if let scope {
            return progressNamespace(userId: scope.userID, sourceId: sourceId, endpoint: endpoint,
                                     protocolVersion: protocolVersion, receiverStateId: receiverStateId)
        }
        let seed = "unassigned\u{0000}\(sourceId)\u{0000}\(endpoint.url)\u{0000}\(protocolVersion)\u{0000}\(receiverStateId)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Worker status always writes to the captured owner, even if an identity changes concurrently.
    static func recordScopedRun(context: AccountSessionContext, state: RunState, message: String? = nil,
                                batches: Int = 0, records: Int = 0) {
        guard CloudRuntimeIdentity.isCurrent(context) else { return }
        let prefix = "account.\(context.scope.namespace).cloudPush."
        let defaults = UserDefaults.standard
        defaults.set(state.rawValue, forKey: prefix + "runState")
        if let message { defaults.set(String(message.prefix(300)), forKey: prefix + "lastError") }
        else { defaults.removeObject(forKey: prefix + "lastError") }
        if state == .complete { defaults.set(Date().timeIntervalSince1970, forKey: prefix + "lastSuccessAt") }
        if state == .running {
            defaults.set(0, forKey: prefix + "acceptedBatches")
            defaults.set(0, forKey: prefix + "acceptedRecords")
        } else {
            defaults.set(defaults.integer(forKey: prefix + "acceptedBatches") + batches, forKey: prefix + "acceptedBatches")
            defaults.set(defaults.integer(forKey: prefix + "acceptedRecords") + records, forKey: prefix + "acceptedRecords")
        }
    }

    static func recordPushStarted() {
        guard isEnabled else { return }
        UserDefaults.standard.removeObject(forKey: K.lastError)
        UserDefaults.standard.set(0, forKey: K.acceptedBatches)
        UserDefaults.standard.set(0, forKey: K.acceptedRecords)
        UserDefaults.standard.set(RunState.queued.rawValue, forKey: K.runState)
    }

    static func recordRunning() {
        guard isEnabled else { return }
        UserDefaults.standard.set(RunState.running.rawValue, forKey: K.runState)
    }

    static func recordAcceptedBatches(batches: Int, records: Int) {
        guard isEnabled, batches > 0 || records > 0 else { return }
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: K.acceptedBatches) + max(0, batches), forKey: K.acceptedBatches)
        defaults.set(defaults.integer(forKey: K.acceptedRecords) + max(0, records), forKey: K.acceptedRecords)
    }

    static func recordContinuation() {
        guard isEnabled else { return }
        UserDefaults.standard.removeObject(forKey: K.lastError)
        UserDefaults.standard.set(RunState.continuing.rawValue, forKey: K.runState)
    }

    static func recordRetrying(message: String) {
        guard isEnabled else { return }
        UserDefaults.standard.set(String(message.prefix(300)), forKey: K.lastError)
        UserDefaults.standard.set(RunState.retrying.rawValue, forKey: K.runState)
    }

    static func recordSuccess() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: K.lastSuccess)
        UserDefaults.standard.removeObject(forKey: K.lastError)
        UserDefaults.standard.set(RunState.complete.rawValue, forKey: K.runState)
    }

    static func recordError(_ message: String) {
        UserDefaults.standard.set(String(message.prefix(300)), forKey: K.lastError)
        UserDefaults.standard.set(RunState.failed.rawValue, forKey: K.runState)
    }

    static func recordCapabilities(
        endpoint: PushValidEndpoint,
        capabilities: PushCapabilities,
        credential: CloudEnrollmentCredential,
        checkedAt: Date = Date()
    ) {
        UserDefaults.standard.set(endpoint.url, forKey: K.capabilitiesEndpoint)
        UserDefaults.standard.set(credential.userId, forKey: K.capabilitiesUserId)
        UserDefaults.standard.set(credential.sourceId, forKey: K.capabilitiesSourceId)
        UserDefaults.standard.set(capabilities.wireNames.joined(separator: ","), forKey: K.capabilitiesStreams)
        UserDefaults.standard.set(checkedAt.timeIntervalSince1970, forKey: K.capabilitiesAt)
    }

    static func recordCapabilities(
        endpoint: PushValidEndpoint,
        capabilities: PushCapabilities,
        checkedAt: Date = Date()
    ) {
        UserDefaults.standard.set(endpoint.url, forKey: K.capabilitiesEndpoint)
        UserDefaults.standard.set(capabilities.wireNames.joined(separator: ","), forKey: K.capabilitiesStreams)
        UserDefaults.standard.set(checkedAt.timeIntervalSince1970, forKey: K.capabilitiesAt)
    }

    static func nextDeviceIndex(namespace: String) -> Int {
        max(0, UserDefaults.standard.integer(forKey: K.nextDevicePrefix + namespace))
    }

    static func saveNextDeviceIndex(namespace: String, index: Int) {
        UserDefaults.standard.set(max(0, index), forKey: K.nextDevicePrefix + namespace)
    }

    static func cycleNeedsAnotherPass(namespace: String) -> Bool {
        UserDefaults.standard.bool(forKey: K.cycleMorePrefix + namespace)
    }

    static func saveCycleNeedsAnotherPass(namespace: String, needed: Bool) {
        UserDefaults.standard.set(needed, forKey: K.cycleMorePrefix + namespace)
    }

    private static func capabilitiesFor(
        endpoint: PushValidEndpoint?,
        credential: CloudEnrollmentCredential?
    ) -> [String]? {
        guard let endpoint,
              UserDefaults.standard.string(forKey: K.capabilitiesEndpoint) == endpoint.url,
              UserDefaults.standard.object(forKey: K.capabilitiesStreams) != nil else { return nil }
        if let credential {
            guard UserDefaults.standard.string(forKey: K.capabilitiesUserId) == credential.userId,
                  UserDefaults.standard.string(forKey: K.capabilitiesSourceId) == credential.sourceId else { return nil }
        }
        let encoded = UserDefaults.standard.string(forKey: K.capabilitiesStreams) ?? ""
        if encoded.isEmpty { return [] }
        let names = encoded.split(separator: ",").map(String.init)
        let known = Set(PushCapabilities.all.wireNames)
        guard names.count == Set(names).count, names.allSatisfy(known.contains) else { return nil }
        return names
    }

}
