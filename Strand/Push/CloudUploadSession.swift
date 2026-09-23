import Foundation
import NoopPush

enum CloudUploadTransportKind: String, Codable, Sendable { case background, ordinary }

struct CloudUploadTaskSnapshot: Sendable {
    /// Ordinary IDs are negative, daemon IDs positive; raw task IDs remain recoverable by magnitude.
    let identifier: Int
    let description: String?
    let transportKind: CloudUploadTransportKind
    init(identifier: Int, description: String?, transportKind: CloudUploadTransportKind = .background) {
        self.identifier = identifier; self.description = description; self.transportKind = transportKind
    }
}

enum CloudUploadSessionEvent: Sendable {
    case completed(CloudUploadTaskSnapshot, status: Int, body: Data, error: Bool, retryAfter: String? = nil)
    case finishedEvents
    case invalidated
}

protocol CloudUploadSessionAdapter: Sendable {
    var supportsOrdinaryTransfers: Bool { get }
    func create(request: URLRequest, file: URL, description: String, transportKind: CloudUploadTransportKind) -> CloudUploadTaskSnapshot
    func tasks() async -> [CloudUploadTaskSnapshot]
    func create(request: URLRequest, file: URL, description: String) -> CloudUploadTaskSnapshot
    func resume(_ identifier: Int)
    func cancel(_ identifier: Int)
}

extension CloudUploadSessionAdapter {
    var supportsOrdinaryTransfers: Bool { false }
    func create(request: URLRequest, file: URL, description: String, transportKind: CloudUploadTransportKind) -> CloudUploadTaskSnapshot {
        create(request: request, file: file, description: description)
    }
}

/// Serial delegate delivery is forwarded through one AsyncStream consumer before finishing OS events.
final class CloudUploadURLSession: NSObject, CloudUploadSessionAdapter, URLSessionDataDelegate, @unchecked Sendable {
    let events: AsyncStream<CloudUploadSessionEvent>
    private let continuation: AsyncStream<CloudUploadSessionEvent>.Continuation
    private let lock = NSLock()
    private var handles: [Int: URLSessionTask] = [:]
    private var bodies: [Int: Data] = [:]
    private var oversized: Set<Int> = []
    private var session: URLSession!
    private var ordinarySession: URLSession!
    private var invalidatedSessions: Set<ObjectIdentifier> = []
    var supportsOrdinaryTransfers: Bool { true }

    init(identifier: String, configuration: URLSessionConfiguration? = nil) {
        var streamContinuation: AsyncStream<CloudUploadSessionEvent>.Continuation!
        events = AsyncStream { streamContinuation = $0 }
        continuation = streamContinuation
        super.init()
        let config = configuration ?? Self.backgroundConfiguration(identifier: identifier)
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "CloudUploadDelegate"
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        // Tests inject a controlled URLProtocol in the same way as the daemon adapter. Production
        // uses a separate ephemeral configuration with no cookies, cache or credential storage.
        let ordinary = configuration.map { $0.copy() as! URLSessionConfiguration } ?? Self.ordinaryConfiguration()
        ordinarySession = URLSession(configuration: ordinary, delegate: self, delegateQueue: delegateQueue)
    }

    static func ordinaryConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        config.httpMaximumConnectionsPerHost = 2
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        return config
    }

    static func backgroundConfiguration(identifier: String) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        #if os(iOS)
        config.sessionSendsLaunchEvents = true
        #endif
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.httpMaximumConnectionsPerHost = 2
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return config
    }

    private func kind(of selected: URLSession) -> CloudUploadTransportKind {
        selected === ordinarySession ? .ordinary : .background
    }
    private func identifier(_ task: URLSessionTask, kind: CloudUploadTransportKind) -> Int {
        kind == .ordinary ? -task.taskIdentifier : task.taskIdentifier
    }
    private func snapshots(_ selected: URLSession, kind: CloudUploadTransportKind) async -> [CloudUploadTaskSnapshot] {
        await withCheckedContinuation { result in
            selected.getAllTasks { tasks in
                self.lock.lock()
                for task in tasks { self.handles[self.identifier(task, kind: kind)] = task }
                self.lock.unlock()
                result.resume(returning: tasks.map { .init(identifier: self.identifier($0, kind: kind),
                    description: $0.taskDescription, transportKind: kind) })
            }
        }
    }
    func tasks() async -> [CloudUploadTaskSnapshot] {
        async let background = snapshots(session, kind: .background)
        async let ordinary = snapshots(ordinarySession, kind: .ordinary)
        return await background + ordinary
    }

    func create(request: URLRequest, file: URL, description: String) -> CloudUploadTaskSnapshot {
        create(request: request, file: file, description: description, transportKind: .background)
    }
    func create(request: URLRequest, file: URL, description: String,
                transportKind: CloudUploadTransportKind) -> CloudUploadTaskSnapshot {
        let selected = transportKind == .ordinary ? ordinarySession! : session!
        let task = selected.uploadTask(with: request, fromFile: file)
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            task.countOfBytesClientExpectsToSend = Int64(size)
        }
        task.countOfBytesClientExpectsToReceive = Int64(PushProtocolLimits.maxAckBytes)
        task.taskDescription = description
        let id = identifier(task, kind: transportKind)
        lock.lock(); handles[id] = task; lock.unlock()
        return .init(identifier: id, description: description, transportKind: transportKind)
    }

    func resume(_ identifier: Int) {
        lock.lock(); let task = handles[identifier]; lock.unlock()
        task?.resume()
    }

    func cancel(_ identifier: Int) {
        lock.lock(); let task = handles[identifier]; lock.unlock()
        task?.cancel()
    }

    func invalidate() { session.invalidateAndCancel(); ordinarySession.invalidateAndCancel() }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        let inserted = invalidatedSessions.insert(ObjectIdentifier(session)).inserted
        let finished = inserted && invalidatedSessions.count == 2
        lock.unlock()
        if finished { continuation.yield(.invalidated); continuation.finish() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = identifier(dataTask, kind: kind(of: session))
        lock.lock()
        var body = bodies[id] ?? Data()
        let remaining = max(0, PushProtocolLimits.maxAckBytes + 1 - body.count)
        body.append(data.prefix(remaining))
        bodies[id] = body
        let tooLarge = body.count > PushProtocolLimits.maxAckBytes
        if tooLarge { oversized.insert(id) }
        lock.unlock()
        if tooLarge { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let transport = kind(of: session), id = identifier(task, kind: kind(of: session))
        lock.lock()
        let body = bodies.removeValue(forKey: id) ?? Data()
        let tooLarge = oversized.remove(id) != nil
        handles.removeValue(forKey: id)
        lock.unlock()
        continuation.yield(.completed(.init(identifier: id, description: task.taskDescription, transportKind: transport),
                                      status: (task.response as? HTTPURLResponse)?.statusCode ?? 0,
                                      body: body, error: error != nil || tooLarge,
                                      retryAfter: (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if kind(of: session) == .background { continuation.yield(.finishedEvents) }
    }

    // Default sessions used by tests call this. Apple's background daemon follows redirects itself.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Prevents two live URLSessions sharing an identifier, including drain-only sessions.
enum CloudUploadSessionLease {
    private static let lock = NSLock()
    private static var owners: [String: UUID] = [:]
    static func acquire(_ identifier: String) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard owners[identifier] == nil else { throw CloudUploadError.unavailable }
        let token = UUID(); owners[identifier] = token; return token
    }
    static func release(_ identifier: String, token: UUID) {
        lock.lock(); defer { lock.unlock() }
        if owners[identifier] == token { owners.removeValue(forKey: identifier) }
    }
}

actor CloudUploadInvalidation {
    private var done = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if done { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish() {
        done = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

final class CloudUploadEventCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completions: [() -> Void] = []

    func store(_ handler: @escaping () -> Void) {
        lock.lock()
        completions.append(handler)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        let handlers = completions
        completions.removeAll()
        lock.unlock()
        for handler in handlers { DispatchQueue.main.async(execute: handler) }
    }
}
