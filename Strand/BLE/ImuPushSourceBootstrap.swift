import Foundation
import NoopPush

/// One captured account/store pair, one published mux. Failed index opens are retryable;
/// they never become a session-only/global source or a successful empty lane.
@MainActor
final class ImuPushSourceBootstrap {
    enum Failure: Error, Equatable { case unassigned, missingStorageDirectory, retired }
    typealias Factory = @Sendable () throws -> CloudImuPushSource

    private let factory: Factory
    private var pending: (id: UUID, task: Task<CloudImuPushSource, Error>)?
    private var retired = false
    private(set) var source: CloudImuPushSource?

    convenience init(scope: AccountScope?, directory: URL?, sessionStore: ImuSessionFileStore,
                     continuousStore: ImuSessionFileStore) {
        self.init {
            guard let scope else { throw Failure.unassigned }
            guard let directory else { throw Failure.missingStorageDirectory }
            return try CloudImuPushSource(scope: scope,
                directory: directory.appendingPathComponent("RawImuUploadIndex"),
                sessionStore: sessionStore, continuousStore: continuousStore)
        }
    }

    /// Internal factory seam verifies off-main initialization and retirement races natively.
    init(factory: @escaping Factory) { self.factory = factory }

    func prepare() async throws -> CloudImuPushSource {
        guard !retired else { throw Failure.retired }
        if let source { return source }
        let work: (id: UUID, task: Task<CloudImuPushSource, Error>)
        if let pending { work = pending }
        else {
            let factory = factory
            work = (UUID(), Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let source = try factory()
                try Task.checkCancellation()
                return source
            })
            pending = work
        }
        do {
            let value = try await work.task.value
            guard !retired else { throw Failure.retired }
            if source == nil { source = value }
            if pending?.id == work.id { pending = nil }
            return value
        } catch {
            // A late waiter from a failed attempt must not clear a newer retry's task.
            if pending?.id == work.id { pending = nil }
            throw error
        }
    }

    func shutdownForAccountChange() {
        retired = true
        pending?.task.cancel()
        pending = nil
    }
}
