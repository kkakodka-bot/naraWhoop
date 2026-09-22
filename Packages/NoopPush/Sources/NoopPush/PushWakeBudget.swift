import Foundation

/// Admission limits for one coordinator wake. Already submitted file transfers remain OS-owned.
public final class PushWakeBudget: @unchecked Sendable {
    public let rowsPerJob: Int
    public let objectDecodedBytesPerJob: Int
    private let maximumPreparedBytes: Int
    private let maximumWireBytes: Int
    private let maximumRequests: Int
    private let deadline: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var preparedBytes = 0
    private var wireBytes = 0
    private var requests = 0
    private var admittedLargeSavedBody = false

    public init(rowsPerJob: Int = 2_000, maximumPreparedBytes: Int = 64 * 1_048_576,
                maximumWireBytes: Int = 64 * 1_048_576, maximumRequests: Int = 32,
                duration: TimeInterval = 20, objectDecodedBytesPerJob: Int = 4 * 1_048_576,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.rowsPerJob = max(1, min(2_000, rowsPerJob))
        self.objectDecodedBytesPerJob = max(1, min(4 * 1_048_576, objectDecodedBytesPerJob))
        self.maximumPreparedBytes = max(0, maximumPreparedBytes)
        self.maximumWireBytes = max(0, maximumWireBytes)
        self.maximumRequests = max(0, maximumRequests)
        self.clock = clock
        deadline = clock() + max(0, duration)
    }

    public var permitsPreparation: Bool {
        lock.lock(); defer { lock.unlock() }
        return clock() < deadline && preparedBytes < maximumPreparedBytes && wireBytes < maximumWireBytes && requests < maximumRequests
    }

    public var permitsFinishingPreparation: Bool { clock() < deadline }

    public func admitPreparation(bytes: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard bytes >= 0, clock() < deadline, bytes <= maximumPreparedBytes - preparedBytes,
              requests < maximumRequests else { return false }
        preparedBytes += bytes
        return true
    }

    /// Empty reads have no serialization/compression bytes to charge. Wall-clock admission
    /// still bounds scanning; refunding prevents fixed-order empty lanes starving later debt.
    func refundEmptyPreparation(maximumDecodedBytes: Int) {
        lock.lock(); defer { lock.unlock() }
        preparedBytes = max(0, preparedBytes - maximumDecodedBytes - 64 * 1024)
    }

    public func admitInlinePreparation(maximumDecodedBytes: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard maximumDecodedBytes >= 0, maximumDecodedBytes <= Int.max - 64 * 1024 else { return false }
        let bound = maximumDecodedBytes + 64 * 1024
        guard clock() < deadline, requests < maximumRequests,
              bound <= maximumPreparedBytes - preparedBytes, bound <= maximumWireBytes - wireBytes else { return false }
        preparedBytes += bound
        return true
    }

    /// Reserve before materializing source BLOBs. Codec expansion and control requests must fit
    /// together; otherwise repeated wakes could rebuild a valid object that never fits delivery.
    public func admitObjectPreparation() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let wireBound = objectDecodedBytesPerJob + 64 * 1024
        guard clock() < deadline, maximumRequests - requests >= 3,
              wireBound <= maximumPreparedBytes - preparedBytes,
              wireBound + 16 * 1024 <= maximumWireBytes - wireBytes else { return false }
        preparedBytes += wireBound
        return true
    }

    public func admitRequest(bytes: Int, savedObject: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard bytes >= 0, bytes <= Int.max - wireBytes, clock() < deadline, requests < maximumRequests else { return false }
        if bytes > maximumWireBytes - wireBytes {
            // Existing immutable jobs predate the fresh-job cap. Permit one OS-owned transfer,
            // including prior intent overhead, then stop admitting payloads for this wake.
            guard savedObject, !admittedLargeSavedBody, wireBytes <= 16 * 1024 else { return false }
            admittedLargeSavedBody = true
        }
        wireBytes += bytes; requests += 1
        return true
    }
}
