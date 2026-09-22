import Foundation

/// Admission limits for one coordinator wake. Already submitted file transfers remain OS-owned.
public final class PushWakeBudget: @unchecked Sendable {
    public let rowsPerJob: Int
    private let maximumPreparedBytes: Int
    private let maximumWireBytes: Int
    private let maximumRequests: Int
    private let deadline: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var preparedBytes = 0
    private var wireBytes = 0
    private var requests = 0

    public init(rowsPerJob: Int = 2_000, maximumPreparedBytes: Int = 64 * 1_048_576,
                maximumWireBytes: Int = 64 * 1_048_576, maximumRequests: Int = 32,
                duration: TimeInterval = 20,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.rowsPerJob = max(1, min(2_000, rowsPerJob))
        self.maximumPreparedBytes = max(0, maximumPreparedBytes)
        self.maximumWireBytes = max(0, maximumWireBytes)
        self.maximumRequests = max(0, maximumRequests)
        self.clock = clock
        deadline = clock() + max(0, duration)
    }

    public var permitsPreparation: Bool {
        lock.lock(); defer { lock.unlock() }
        return clock() < deadline && preparedBytes < maximumPreparedBytes && requests < maximumRequests
    }

    public func admitPreparation(bytes: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard bytes >= 0, clock() < deadline, bytes <= maximumPreparedBytes - preparedBytes,
              requests < maximumRequests else { return false }
        preparedBytes += bytes
        return true
    }

    public func admitRequest(bytes: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard bytes >= 0, clock() < deadline, bytes <= maximumWireBytes - wireBytes,
              requests < maximumRequests else { return false }
        wireBytes += bytes; requests += 1
        return true
    }
}
