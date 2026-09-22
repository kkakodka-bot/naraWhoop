import Foundation
import NoopPush
import WhoopStore

enum CanonicalScoreTransport {
    struct Identity: Equatable, Sendable {
        let context: AccountSessionContext
        let source: String
        let token: String
        let enrollmentTokenID: String?
        let fleet: String?
        let anon: String
        var base: URL { URL(string: context.scope.projectURL)! }
        var isCurrent: Bool {
            guard CloudRuntimeIdentity.snapshot().context == context,
                  ServerScoringSettings.supabaseProjectURL()?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == context.scope.projectURL else { return false }
            if let enrollmentTokenID {
                guard let credential = CloudEnrollment.currentCredential() else { return false }
                return credential.tokenId == enrollmentTokenID && credential.uploadToken == token &&
                    credential.sourceId == source && CloudCaptureScope.isActive(for: credential.userId) &&
                    CloudPushSettings.resolvedFleetToken() == fleet
            }
            return CloudAuthClient.isCurrent(context) && CloudAuthClient.storedSession()?.accessToken == token &&
                CloudPushSettings.sourceId(scope: context.scope) == source
        }
    }

    static func capture() async throws -> Identity {
        guard let anon = ServerScoringSettings.anonKey() else { throw ServerScoreClient.FetchError.notConfigured }
        if let context = CloudRuntimeIdentity.currentEnrollmentSnapshot()?.context,
           let credential = CloudEnrollment.currentCredential(), let fleet = CloudPushSettings.resolvedFleetToken() {
            let identity = Identity(context: context, source: credential.sourceId, token: credential.uploadToken,
                enrollmentTokenID: credential.tokenId, fleet: fleet, anon: anon)
            guard identity.isCurrent else { throw ServerScoreClient.FetchError.sessionChanged }
            return identity
        }
        let session = try await CloudAuthClient.authorizedSession()
        let identity = Identity(context: session.context, source: CloudPushSettings.sourceId(scope: session.context.scope),
            token: session.accessToken, enrollmentTokenID: nil, fleet: nil, anon: anon)
        guard identity.isCurrent else { throw ServerScoreClient.FetchError.sessionChanged }
        return identity
    }

    static func request(identity: Identity, path: String = "", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard identity.isCurrent else { throw ServerScoreClient.FetchError.sessionChanged }
        var url = URLComponents(url: identity.base.appendingPathComponent("functions/v1/scores" + path), resolvingAgainstBaseURL: false)!
        url.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: url.url!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(identity.anon, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(identity.token)", forHTTPHeaderField: "Authorization")
        if let fleet = identity.fleet { request.setValue(fleet, forHTTPHeaderField: CloudPushTransport.fleetTokenHeader) }
        else { request.setValue(identity.source, forHTTPHeaderField: "x-noop-source-id") }
        return try await ServerScoreReadTransport.read(request, context: identity.context, isCurrent: { _ in identity.isCurrent })
    }

    private static func mappingKey(scope: AccountScope, source: String, localDevice: String) -> String {
        "noop.compute.device.v1." + AccountScope.digest([scope.projectURL, scope.userID, source, localDevice].joined(separator: "\u{0}"))
    }

    static func canonicalDevice(owner: String, localDevice: String) -> String? {
        guard let context = CloudRuntimeIdentity.snapshot().context, context.scope.userID == owner else { return nil }
        let source = CloudPushSettings.sourceId(scope: context.scope)
        guard let value = UserDefaults.standard.string(forKey: mappingKey(scope: context.scope, source: source, localDevice: localDevice)),
              UUID(uuidString: value) != nil else { return nil }
        return value
    }

    static func validateIdentity(_ root: [String: Any], identity: Identity, localDevice: String) throws -> String {
        guard let value = root["identity"] as? [String: Any],
              value["userId"] as? String == identity.context.scope.userID,
              value["sourceId"] as? String == identity.source,
              value["externalDeviceId"] as? String == localDevice,
              let canonical = value["deviceId"] as? String, UUID(uuidString: canonical) != nil else {
            throw ServerScoreClient.FetchError.sessionChanged
        }
        return canonical
    }

    static func confirm(identity: Identity, localDevice: String) async throws -> String {
        guard !localDevice.isEmpty else { throw ServerScoreClient.FetchError.notConfigured }
        // Reconfirm on each captured credential, so a cached receipt cannot bypass server revocation.
        let data = try await request(identity: identity, path: "/devices",
            body: JSONSerialization.data(withJSONObject: ["deviceId": localDevice]))
        guard identity.isCurrent, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerScoreClient.FetchError.sessionChanged
        }
        let canonical = try validateIdentity(root, identity: identity, localDevice: localDevice)
        UserDefaults.standard.set(canonical, forKey: mappingKey(scope: identity.context.scope, source: identity.source, localDevice: localDevice))
        return canonical
    }

    static func fetch(day: String, owner: String, localDevice: String) async throws -> ServerScoreDayCache {
        let identity = try await capture()
        guard identity.context.scope.userID == owner, ServerScoreDate.isDay(day) else { throw ServerScoreClient.FetchError.sessionChanged }
        let canonical = try await confirm(identity: identity, localDevice: localDevice)
        let data = try await request(identity: identity, query: [.init(name: "day", value: day), .init(name: "deviceId", value: localDevice)])
        guard identity.isCurrent, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              try validateIdentity(root, identity: identity, localDevice: localDevice) == canonical else {
            throw ServerScoreClient.FetchError.sessionChanged
        }
        let cache = try ServerScoreCacheCodec.parseSnapshot(data, day: day, ownerId: owner)
        try cache.canonicalResults?.validate(owner: owner, day: day, project: identity.context.scope.projectURL, source: identity.source, device: canonical)
        guard cache.features.values.allSatisfy({ $0.deviceId == nil || $0.deviceId == canonical }) else {
            throw ServerScoreClient.FetchError.sessionChanged
        }
        return cache
    }
}
