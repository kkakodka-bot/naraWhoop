import Foundation
import NoopPush

/// Root retains one runtime for the verified active account. Never instantiate for `unassigned`.
final class CloudPushBackgroundRuntime: @unchecked Sendable {
    let context: AccountSessionContext
    let identifier: String
    let queue: CloudUploadQueue
    let progressDirectory: URL
    let controlSession: URLSession
    private let adapter: CloudUploadURLSession
    private let invalidation = CloudUploadInvalidation()
    private let lifecycleLock = NSLock()
    private var retired = false
    private let completion = CloudUploadEventCompletion()
    private var eventTask: Task<Void, Never>?
    private static let lock = NSLock()
    private static var active: CloudPushBackgroundRuntime?

    static func sessionIdentifier(scope: AccountScope) -> String {
        (Bundle.main.bundleIdentifier ?? "com.frwhoop.strand") + ".cloud-upload.v1." + scope.namespace
    }

    init(context: AccountSessionContext, layout: AccountStorageLayout,
         authorize: @escaping CloudUploadQueue.Authorize,
         isCurrent: @escaping CloudUploadQueue.Current,
         policy: @escaping @Sendable () -> CloudUploadPolicy,
         backgroundEventsCompletion: (() -> Void)? = nil,
         sessionConfiguration: URLSessionConfiguration? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         resourceBudget: ResourceBudget = .shared) throws {
        guard layout.scope == context.scope else { throw CloudUploadError.staleOwner }
        self.context = context
        progressDirectory = layout.uploadDirectory.appendingPathComponent("source-progress", isDirectory: true)
        identifier = Self.sessionIdentifier(scope: context.scope)
        let lease = try CloudUploadSessionLease.acquire(identifier)
        if let backgroundEventsCompletion { completion.store(backgroundEventsCompletion) }
        adapter = CloudUploadURLSession(identifier: identifier, configuration: sessionConfiguration)
        let adapter = self.adapter
        let controlSession = sessionConfiguration.map { URLSession(configuration: $0) } ?? CloudPushTransport.makeSession()
        self.controlSession = controlSession
        do { queue = try CloudUploadQueue(context: context, layout: layout, adapter: adapter,
            authorize: authorize, isCurrent: isCurrent, policy: policy, control: { request in
                let (data, response) = try await controlSession.data(for: request)
                guard data.count <= PushProtocolLimits.maxAckBytes else { throw CloudUploadError.responseTooLarge }
                return .init(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data,
                             retryAfter: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"))
            }, now: now, refreshCredentials: {
                guard !CloudRuntimeIdentity.isEnrollment($0) else { throw AccountAuthError.sessionRevoked }
                try await CloudAuthClient.refreshRejectedCredentials($0)
            }, fleetToken: { CloudPushSettings.resolvedFleetToken() }, resourceBudget: resourceBudget)
        } catch {
            let identifier = self.identifier
            let completion = self.completion
            adapter.invalidate()
            Task {
                for await _ in adapter.events {}
                controlSession.invalidateAndCancel()
                CloudUploadSessionLease.release(identifier, token: lease)
                completion.finish()
            }
            throw error
        }
        let queue = self.queue
        let completion = self.completion
        let invalidation = self.invalidation
        let identifier = self.identifier
        eventTask = Task {
            for await event in adapter.events {
                switch event {
                case let .completed(task, status, body, error, retryAfter):
                    await queue.receive(task, status: status, body: body, error: error, retryAfter: retryAfter)
                case .finishedEvents:
                    // Serial stream consumption guarantees receipt writes finish before OS completion.
                    completion.finish()
                case .invalidated:
                    controlSession.invalidateAndCancel()
                    CloudUploadSessionLease.release(identifier, token: lease)
                    completion.finish()
                    await invalidation.finish()
                }
            }
        }
    }

    deinit { adapter.invalidate() }

    /// Install only after verified identity and scoped layout preparation. Returns the previous owner
    /// so root can retain it until any already-delivered background-event completion has drained.
    @discardableResult
    static func install(_ runtime: CloudPushBackgroundRuntime?) -> CloudPushBackgroundRuntime? {
        lock.lock()
        let previous = active
        active = runtime
        lock.unlock()
        if let previous, previous !== runtime { Task { await previous.queue.suspend() } }
        return previous
    }

    static func current(for captured: AccountSessionContext) throws -> CloudPushBackgroundRuntime {
        lock.lock(); defer { lock.unlock() }
        guard let runtime = active, runtime.context == captured, !runtime.isRetired else { throw CloudUploadError.staleOwner }
        return runtime
    }

    /// Root calls after launch authentication, and on foreground/BG-refresh/network/thermal wakes.
    func reconcile() async throws { try await queue.reconcile() }

    /// Await before constructing another runtime for this stable identifier. Delegate invalidation
    /// is ordered after outstanding callbacks; all payloads and pending journal records remain.
    func retire() async {
        markRetired()
        await queue.suspend()
        adapter.invalidate()
        await invalidation.wait()
    }

    private func markRetired() { lifecycleLock.lock(); retired = true; lifecycleLock.unlock() }
    private var isRetired: Bool { lifecycleLock.lock(); defer { lifecycleLock.unlock() }; return retired }

    /// Call from application(_:handleEventsForBackgroundURLSession:completionHandler:).
    /// Return false for an unrelated identifier; root must route it to its original owner, never
    /// attach those tasks to a newly signed-in account. This method never starts an unscoped queue.
    func handleEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        guard identifier == self.identifier, !isRetired else { return false }
        completion.store(completionHandler)
        Task { try? await queue.reconcile() }
        return true
    }

    static func reconcileActive() async {
        let runtime = snapshot()
        try? await runtime?.reconcile()
    }

    static func nextWake() async -> (AccountSessionContext, Date?)? {
        guard let runtime = snapshot(), !runtime.isRetired else { return nil }
        guard let date = try? await runtime.queue.nextWakeDate(captured: runtime.context) else {
            return (runtime.context, nil)
        }
        return (runtime.context, date)
    }

    private static func snapshot() -> CloudPushBackgroundRuntime? {
        lock.lock(); defer { lock.unlock() }; return active
    }

    /// Ownerless relaunch: reconnect only the exact W5 identifier, cancel/drain its daemon tasks,
    /// and finish the OS handler after delegate invalidation. No credentials or directories read.
    /// False means unrelated identifier or a still-live runtime that root must route/retire first.
    static func drainEvents(identifier: String, completionHandler: @escaping () -> Void,
                            sessionConfiguration: URLSessionConfiguration? = nil) -> Bool {
        let prefix = (Bundle.main.bundleIdentifier ?? "com.frwhoop.strand") + ".cloud-upload.v1."
        guard identifier.hasPrefix(prefix) else { return false }
        let suffix = identifier.dropFirst(prefix.count)
        guard suffix.count == 64, suffix.allSatisfy({ "0123456789abcdef".contains($0) }),
              let lease = try? CloudUploadSessionLease.acquire(identifier) else { return false }
        let completion = CloudUploadEventCompletion()
        completion.store(completionHandler)
        let adapter = CloudUploadURLSession(identifier: identifier, configuration: sessionConfiguration)
        Task {
            // invalidation cancels every restored task, including ones not yet enumerated.
            _ = await adapter.tasks()
            adapter.invalidate()
        }
        Task {
            for await event in adapter.events {
                if case .invalidated = event {
                    CloudUploadSessionLease.release(identifier, token: lease)
                    completion.finish()
                }
            }
        }
        return true
    }
}
