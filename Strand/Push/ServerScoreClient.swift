import Foundation
import CryptoKit
import WhoopStore

/// Fetches `get_day_snapshot` and parses the `server_scoring` overlay.
enum ServerScoreClient {
    private static let registrationLock = NSLock()
    private static var registeredBindings = Set<String>()
    enum FetchError: Error {
        case notConfigured
        case unauthorized(accessToken: String)
        case sessionChanged
        case conflict
        case network(Error)
        case decode
    }

    static func fetchDaySnapshot(day: String, ownerId: String, deviceId: String) async throws -> ServerScoreDayCache {
        guard let base = ServerScoringSettings.supabaseProjectURL(),
              let anon = ServerScoringSettings.anonKey() else {
            throw FetchError.notConfigured
        }
        guard let credential = CloudEnrollment.currentCredential(), credential.userId == ownerId.lowercased(),
              CloudCaptureScope.isActive(for: credential.userId),
              let fleet = CloudPushSettings.resolvedFleetToken() else { throw FetchError.sessionChanged }
        try await ensureDevice(base: base, anon: anon, fleetToken: fleet, credential: credential, deviceId: deviceId)
        let request = try scoreRequest(base: base, anon: anon, fleetToken: fleet,
                                       credential: credential, day: day, deviceId: deviceId)
        do {
            let (data, response) = try await CloudPushTransport.makeSession().data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FetchError.decode }
            if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized(accessToken: credential.uploadToken) }
            guard http.statusCode == 200 else { throw FetchError.decode }
            try Task.checkCancellation()
            guard CloudEnrollment.currentCredential() == credential,
                  CloudCaptureScope.isActive(for: credential.userId),
                  ServerScoringSettings.supabaseProjectURL() == base,
                  CloudPushSettings.resolvedFleetToken() == fleet else { throw FetchError.sessionChanged }
            let parsed = try parseEnrolledSnapshot(data, day: day, credential: credential, deviceId: deviceId)
            if let canonical = parsed.canonicalDeviceId {
                UserDefaults.standard.set(canonical, forKey: deviceMappingKey(credential, deviceId, base: base))
            }
            return parsed.cache
        } catch let e as FetchError {
            throw e
        } catch {
            throw FetchError.network(error)
        }
    }

    private static func ensureDevice(base: URL, anon: String, fleetToken: String,
                                      credential: CloudEnrollmentCredential, deviceId: String) async throws {
        let key = deviceMappingKey(credential, deviceId, base: base) + "." + credential.tokenId
        if registrationLock.withLock({ registeredBindings.contains(key) }) { return }
        var request = try scoreRequest(base: base, anon: anon, fleetToken: fleetToken,
                                        credential: credential, day: "", deviceId: deviceId)
        request.url = base.appendingPathComponent("functions/v1/scores/devices")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceId": deviceId])
        let (data, response) = try await CloudPushTransport.makeSession().data(for: request)
        try Task.checkCancellation()
        guard CloudEnrollment.currentCredential() == credential,
              CloudCaptureScope.isActive(for: credential.userId),
              ServerScoringSettings.supabaseProjectURL() == base,
              CloudPushSettings.resolvedFleetToken() == fleetToken else { throw FetchError.sessionChanged }
        guard let http = response as? HTTPURLResponse else { throw FetchError.decode }
        if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized(accessToken: credential.uploadToken) }
        guard http.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let canonical = try identityDevice(root, credential: credential, deviceId: deviceId) else { throw FetchError.decode }
        UserDefaults.standard.set(canonical, forKey: deviceMappingKey(credential, deviceId, base: base))
        registrationLock.withLock { _ = registeredBindings.insert(key) }
    }

    static func scoreRequest(base: URL, anon: String, fleetToken: String,
                             credential: CloudEnrollmentCredential, day: String, deviceId: String) throws -> URLRequest {
        guard !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FetchError.notConfigured }
        var components = URLComponents(url: base.appendingPathComponent("functions/v1/scores"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "day", value: day), URLQueryItem(name: "deviceId", value: deviceId)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(anon, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(credential.uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue(fleetToken, forHTTPHeaderField: CloudPushTransport.fleetTokenHeader)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    static func parseEnrolledSnapshot(_ data: Data, day: String, credential: CloudEnrollmentCredential,
                                      deviceId: String) throws -> (cache: ServerScoreDayCache, canonicalDeviceId: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.decode }
        let canonical = try identityDevice(root, credential: credential, deviceId: deviceId)
        let cache = try parseSnapshot(data, day: day, ownerId: credential.userId)
        guard cache.features.values.allSatisfy({ feature in
            if let device = feature.deviceId { return device == canonical }
            return feature.status == "unavailable"
        }) else { throw FetchError.sessionChanged }
        return (cache, canonical)
    }

    private static func identityDevice(_ root: [String: Any], credential: CloudEnrollmentCredential,
                                        deviceId: String) throws -> String? {
        guard let identity = root["identity"] as? [String: Any],
              identity["userId"] as? String == credential.userId,
              identity["sourceId"] as? String == credential.sourceId,
              identity["externalDeviceId"] as? String == deviceId else { throw FetchError.sessionChanged }
        let canonical = identity["deviceId"] as? String
        guard canonical == nil || UUID(uuidString: canonical!) != nil else { throw FetchError.decode }
        return canonical
    }

    static func canonicalDeviceId(ownerId: String, localDeviceId: String) -> String? {
        guard let credential = CloudEnrollment.currentCredential(), credential.userId == ownerId,
              let base = ServerScoringSettings.supabaseProjectURL(),
              let canonical = UserDefaults.standard.string(forKey: deviceMappingKey(credential, localDeviceId, base: base)),
              UUID(uuidString: canonical) != nil else { return nil }
        return canonical
    }

    static func deviceMappingKey(_ credential: CloudEnrollmentCredential, _ local: String, base: URL) -> String {
        let value = "\(credential.userId)\u{0000}\(credential.sourceId)\u{0000}\(base.absoluteString)\u{0000}\(local)"
        return "noop.cloud.deviceMapping." + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func peekOwnerId(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let overlay = root["server_scoring"] as? [String: Any],
              let userId = overlay["user_id"] as? String,
              UUID(uuidString: userId) != nil else { return nil }
        return userId.lowercased()
    }

    static func parseSnapshot(_ data: Data, day: String, ownerId: String) throws -> ServerScoreDayCache {
        try ServerScoreCacheCodec.parseSnapshot(data, day: day, ownerId: ownerId)
    }

    static func saveSleepOverride(_ target: ServerSleepEditTarget, localDeviceId: String, start: Int, end: Int, tombstone: Bool) async throws -> Int64 {
        guard let base = ServerScoringSettings.supabaseProjectURL(), let anon = ServerScoringSettings.anonKey() else { throw FetchError.notConfigured }
        let arguments = try target.rpcArguments(start: start, end: end, tombstone: tombstone)
        guard let credential = CloudEnrollment.currentCredential(), credential.userId == target.ownerId.lowercased(),
              CloudCaptureScope.isActive(for: credential.userId),
              let fleet = CloudPushSettings.resolvedFleetToken() else { throw FetchError.sessionChanged }
        let token = credential.uploadToken
        try Task.checkCancellation()
        var request = URLRequest(url: base.appendingPathComponent("functions/v1/scores/sleep-overrides"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anon, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(fleet, forHTTPHeaderField: CloudPushTransport.fleetTokenHeader)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceId": localDeviceId, "arguments": arguments])
        let (data, response) = try await CloudPushTransport.makeSession().data(for: request)
        try Task.checkCancellation()
        guard CloudEnrollment.currentCredential() == credential else { throw FetchError.sessionChanged }
        guard let http = response as? HTTPURLResponse else { throw FetchError.decode }
        if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized(accessToken: token) }
        let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if http.statusCode == 409 || (object as? [String: Any])?["code"] as? String == "40001" { throw FetchError.conflict }
        guard http.statusCode == 200, let revision = object as? NSNumber, revision.int64Value > target.expectedRevision else { throw FetchError.decode }
        return revision.int64Value
    }
}
