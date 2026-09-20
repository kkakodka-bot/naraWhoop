import Foundation
import GRDB

/// Periodic cloud-push pump for the research corpus. Unlike offload-triggered push, this runs on a
/// cadence so live streams (HR, skin temp, gravity, PPG, v18 aux, raw IMU) migrate to B2 without
/// waiting for a full strap sync.
///
/// Design:
/// - Throttled: at most one run per `interval` (default 5 min), shared across all callers.
/// - Safe: no-op when push is disabled, unconfigured, or a run is already in flight.
/// - Foreground-friendly: uses `CloudPushWorker.runOnce` (which respects Wi‑Fi-only and network policy).
/// - Binary lane: `CloudPushWorker` already includes `ppgWaveformSample`, `v18AuxSample`, `rawBatch`,
///   and `rawImuSession` when `binaryObjectsEnabled` and the receiver advertises the object lane.
enum CloudPushPeriodicScheduler {
    /// Default cadence for research push. 5 minutes balances freshness vs battery/network.
    static let defaultInterval: TimeInterval = 5 * 60

    /// Push throttle for the current server-scoring mode (5 min legacy, 30–60 s when flag on).
    static func effectiveInterval(serverScoringEnabled: Bool = ServerScoringSettings.isEnabled) -> TimeInterval {
        serverScoringEnabled ? ServerScoringSettings.idlePushIntervalSeconds : defaultInterval
    }

    private static var lastRunAt: Date?
    private static var lastScheduledAt: Date?
    private static var pendingTask: Task<Void, Never>?
    private static let lock = NSLock()

    /// Call when live data lands or on a timer. Runs at most one push per `interval`.
    /// - Parameters:
    ///   - db: registry writer (from `Repository.registryWriterForPush()`)
    ///   - interval: minimum seconds between runs (default 5 min)
    ///   - reason: label for diagnostics (e.g. "live-hr", "timer", "imu")
    static func pushIfDue(db: any DatabaseWriter, interval: TimeInterval? = nil, reason: String = "periodic") {
        guard CloudPushSettings.ready else { return }
        let interval = interval ?? effectiveInterval()
        guard interval > 0 else { return }

        lock.lock()
        let now = Date()
        let last = lastRunAt ?? .distantPast
        let due = now.timeIntervalSince(last) >= interval
        let alreadyPending = pendingTask != nil
        lock.unlock()

        guard due, !alreadyPending else { return }

        lock.lock()
        // Double-check under lock: another caller may have just scheduled.
        if pendingTask != nil { lock.unlock(); return }
        lastScheduledAt = now
        let task = Task { @MainActor in
            defer {
                lock.lock()
                pendingTask = nil
                lastRunAt = Date()
                lock.unlock()
            }
            _ = await CloudPushWorker.runOnce(db: db, trigger: reason)
        }
        pendingTask = task
        lock.unlock()
    }

    /// Force a run on the next call regardless of cadence (e.g. user taps Export now).
    static func resetThrottle() {
        lock.lock()
        lastRunAt = nil
        lock.unlock()
    }

    /// For tests: snapshot of scheduler state.
    static var debugState: (lastRunAt: Date?, lastScheduledAt: Date?, hasPending: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (lastRunAt, lastScheduledAt, pendingTask != nil)
    }
}
