import Foundation
import NoopPush

struct CloudUploadTaskSnapshot: Sendable {
    let identifier: Int
    let description: String?
}

enum CloudUploadSessionEvent: Sendable {
    case completed(CloudUploadTaskSnapshot, status: Int, body: Data, error: Bool, retryAfter: String? = nil)
    case finishedEvents
    case invalidated
}

protocol CloudUploadSessionAdapter: Sendable {
    func tasks() async -> [CloudUploadTaskSnapshot]
    func create(request: URLRequest, file: URL, description: String) -> CloudUploadTaskSnapshot
    func resume(_ identifier: Int)
    func cancel(_ identifier: Int)
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

    func tasks() async -> [CloudUploadTaskSnapshot] {
        await withCheckedContinuation { result in
            session.getAllTasks { tasks in
                self.lock.lock()
                for task in tasks { self.handles[task.taskIdentifier] = task }
                self.lock.unlock()
                result.resume(returning: tasks.map { .init(identifier: $0.taskIdentifier, description: $0.taskDescription) })
            }
        }
    }

    func create(request: URLRequest, file: URL, description: String) -> CloudUploadTaskSnapshot {
        let task = session.uploadTask(with: request, fromFile: file)
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            task.countOfBytesClientExpectsToSend = Int64(size)
        }
        task.countOfBytesClientExpectsToReceive = Int64(PushProtocolLimits.maxAckBytes)
        task.taskDescription = description
        lock.lock(); handles[task.taskIdentifier] = task; lock.unlock()
        return .init(identifier: task.taskIdentifier, description: description)
    }

    func resume(_ identifier: Int) {
        lock.lock(); let task = handles[identifier]; lock.unlock()
        task?.resume()
    }

    func cancel(_ identifier: Int) {
        lock.lock(); let task = handles[identifier]; lock.unlock()
        task?.cancel()
    }

    func invalidate() { session.invalidateAndCancel() }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        continuation.yield(.invalidated)
        continuation.finish()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var body = bodies[dataTask.taskIdentifier] ?? Data()
        let remaining = max(0, PushProtocolLimits.maxAckBytes + 1 - body.count)
        body.append(data.prefix(remaining))
        bodies[dataTask.taskIdentifier] = body
        let tooLarge = body.count > PushProtocolLimits.maxAckBytes
        if tooLarge { oversized.insert(dataTask.taskIdentifier) }
        lock.unlock()
        if tooLarge { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let body = bodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        let tooLarge = oversized.remove(task.taskIdentifier) != nil
        handles.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        continuation.yield(.completed(.init(identifier: task.taskIdentifier, description: task.taskDescription),
                                      status: (task.response as? HTTPURLResponse)?.statusCode ?? 0,
                                      body: body, error: error != nil || tooLarge,
                                      retryAfter: (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        continuation.yield(.finishedEvents)
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
