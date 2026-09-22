import Foundation
import NoopPush
import WhoopStore

enum ServerScoreClient {
    enum FetchError: Error { case notConfigured, unauthorized, staleSession, invalidResponse }

    /// The request URL and JWT are pinned to the same identity, not a mutable upload endpoint.
    static func fetchDaySnapshot(day: String, context: AccountSessionContext) async throws -> ServerScoreResponse {
        guard ServerScoreDate.isDay(day), let base = URL(string: context.scope.projectURL),
              let anon = ServerScoringSettings.anonKey() else { throw FetchError.notConfigured }
        let authorized = try await CloudAuthClient.authorizedSession()
        guard authorized.context == context, CloudAuthClient.isCurrent(context) else { throw FetchError.staleSession }
        var request = URLRequest(url: base.appendingPathComponent("rest/v1/rpc/get_server_score_snapshot_v2"))
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anon, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authorized.accessToken)", forHTTPHeaderField: "Authorization")
        // Omitting p_algorithm_version selects the controlled active pointer.
        request.httpBody = try JSONSerialization.data(withJSONObject: ["p_day": day])
        let data = try await ServerScoreReadTransport.read(request, context: context)
        try Task.checkCancellation()
        guard CloudAuthClient.isCurrent(context) else { throw FetchError.staleSession }
        let result = try await ServerScoreDecodeWorker.shared.decode(data, day: day)
        try Task.checkCancellation()
        guard CloudAuthClient.isCurrent(context) else { throw FetchError.staleSession }
        return result
    }
}

/// Decode and canonical serialization never run in a SwiftUI body or on the main actor.
actor ServerScoreDecodeWorker {
    static let shared = ServerScoreDecodeWorker()
    func decode(_ data: Data, day: String) throws -> ServerScoreResponse {
        try ServerScoreResponse.decode(data, requestedDay: day)
    }
    func restore(_ row: ServerScoreCachedSnapshot) throws -> ServerScoreSnapshot {
        let snapshot = try JSONDecoder().decode(ServerScoreSnapshot.self, from: row.payload)
        try snapshot.validate()
        guard snapshot.day == row.key.day, snapshot.timezone == row.key.timeZoneID,
              snapshot.sourceDeviceId == row.key.sourceDeviceID,
              snapshot.userId.lowercased() == row.key.owner.userID.lowercased(),
              snapshot.schemaVersion == row.key.schemaVersion, snapshot.algorithmVersion == row.key.algorithmVersion,
              snapshot.inputRevision == row.inputRevision, snapshot.resultRevision == row.resultRevision,
              snapshot.status == row.state.rawValue else { throw ServerScoreDecodeError.invalid }
        return snapshot
    }
    func prepare(_ snapshot: ServerScoreSnapshot, owner: ServerScoreCacheOwner, now: Date) throws -> ServerScoreCachedSnapshot {
        try snapshot.validate()
        guard let status = ServerScoreCachedSnapshot.State(rawValue: snapshot.status) else { throw ServerScoreDecodeError.invalid }
        return ServerScoreCachedSnapshot(
            key: ServerScoreCacheKey(owner: owner, sourceDeviceID: snapshot.sourceDeviceId, day: snapshot.day,
                                     timeZoneID: snapshot.timezone, schemaVersion: snapshot.schemaVersion,
                                     algorithmVersion: snapshot.algorithmVersion),
            inputRevision: snapshot.inputRevision, resultRevision: snapshot.resultRevision, state: status,
            payload: try snapshot.encoded(), fetchedAt: now)
    }
}
