import Foundation
import NoopPush

// Unexpected credential access must fail, never open the host Keychain or refresh a real account.
enum CloudAuthClient {
    static func isCurrent(_ context: AccountSessionContext) -> Bool { false }
    static func refreshRejectedCredentials(_ context: AccountSessionContext) async throws {
        throw AccountAuthError.signedOut
    }
}

enum CloudRuntimeIdentity {
    static func isCurrent(_ context: AccountSessionContext) -> Bool { false }
    static func isEnrollment(_ context: AccountSessionContext) -> Bool { false }
}

enum CloudPushSettings {
    static func resolvedFleetToken() -> String? { nil }
}

// These suites inject queue admission directly and do not construct app SyncEngine admissions.
enum SyncEngine {
    @MainActor final class DependentStageAdmission {
        func validate() async -> Bool { false }
        nonisolated func checkBoundary() throws { throw CancellationError() }
    }
}
