import Foundation

/// Expiration cancels app work, not durable daemon transfers. BGTask completion is exactly once.
final class CloudPushRefreshCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var task: Task<Void, Never>?
    private let completion: @Sendable (Bool) -> Void
    init(completion: @escaping @Sendable (Bool) -> Void) { self.completion = completion }
    func attach(_ task: Task<Void, Never>) {
        lock.lock()
        let alreadyFinished = finished
        if !alreadyFinished { self.task = task }
        lock.unlock()
        if alreadyFinished { task.cancel() }
    }
    func finish(success: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let task = self.task
        self.task = nil
        lock.unlock()
        if !success { task?.cancel() }
        completion(success)
    }
}
