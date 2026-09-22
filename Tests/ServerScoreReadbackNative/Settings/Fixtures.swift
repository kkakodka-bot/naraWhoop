import Foundation

// Compiled only by the standalone settings test binary. Production preferences/config are never read.
enum UserDefaults {
    static let suite = "w4.settings.fixture.\(UUID().uuidString)"
    static let standard = Foundation.UserDefaults(suiteName: suite)!
}
enum Bundle {
    static let main = FixtureBundle()
    struct FixtureBundle {
        func object(forInfoDictionaryKey key: String) -> Any? {
            key == "NOOPSupabaseAnonKey" ? "synthetic-public-test-key" : nil
        }
    }
}
enum CloudAuthClient {
    static var project: String? = "https://readback-fixture.invalid"
    struct Identity { let projectURL: String? }
    static func identitySnapshot() -> Identity { Identity(projectURL: project) }
}
enum CloudPushSettings {
    static var isEnabled = true
    static var termsAccepted = true
    struct Endpoint { let url: String }
    static func enabledEndpoint() -> Endpoint? {
        isEnabled && termsAccepted ? Endpoint(url: "https://old-upload-fixture.invalid/functions/v1/push") : nil
    }
}
enum RescoreBackgroundScheduler {
    static let isRescoreOwed = false
    static let currentOwedToken = 0
    static func markRescoreCompleted(seconds: Int, owedToken: Int) {}
}
