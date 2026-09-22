import Foundation
import NoopPush
enum CloudPushSettings {
    static func sourceId() -> String { "" }
    static func configuredEndpoint() -> PushValidEndpoint? { nil }
    static func resolvedFleetToken() -> String? { nil }
    static func enableForEnrolledAccount(defaults: UserDefaults) {}
}
enum ServerScoringSettings { static let defaultsKey = "test.serverScoring" }
enum CloudAuthClient { static func clearSessionChecked() throws {} }
// Network verification is outside the journal tests. Retirement HTTP uses the real URLSession code.
struct CloudPushTransport {
    static func makeSession() -> URLSession { URLSession(configuration: .ephemeral) }
    init(endpoint: PushValidEndpoint, uploadToken: String, fleetToken: String, session: URLSession) {}
    func capabilities() async throws -> PushCapabilitiesResult { throw URLError(.notConnectedToInternet) }
}
