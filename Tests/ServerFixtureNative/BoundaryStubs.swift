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

// This fixture uses explicit account-owned temporary directories. Falling back to host capture
// storage is a test failure, never an inferred owner or a real Keychain operation.
enum CloudCaptureScope {
    static func component(_ value: String) -> String { fatalError("Host capture scope is unavailable in source fixtures") }
}

// Mirrors only the revocable admission callback boundary. The default is denied; tests that
// exercise revocation provide captured fixture closures. This is not hosted authentication.
enum SyncEngine {
    @MainActor final class DependentStageAdmission {
        private let current: () -> Bool
        private let revalidate: () async -> Bool
        private nonisolated let boundaryCheck: @Sendable () throws -> Void
        init(current: @escaping () -> Bool = { false }, revalidate: @escaping () async -> Bool = { false },
             boundaryCheck: @escaping @Sendable () throws -> Void = { throw CancellationError() },
             settleCaptured: @escaping () async -> Bool = { false }) {
            self.current = current; self.revalidate = revalidate; self.boundaryCheck = boundaryCheck
        }
        func validate() async -> Bool {
            guard !Task.isCancelled, current(), await revalidate() else { return false }
            return !Task.isCancelled && current()
        }
        nonisolated func checkBoundary() throws { try boundaryCheck() }
    }
}
