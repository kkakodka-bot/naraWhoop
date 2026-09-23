import Foundation
import GRDB

/// Periodic cloud-push pump for the research corpus. Unlike offload-triggered push, this runs on a
/// cadence so live streams (HR, skin temp, gravity, PPG, v18 aux, raw IMU) migrate to B2 without
/// waiting for a full strap sync.
///
/// Design:
/// - Throttled: at most one run per `interval` (default ten seconds), shared across callers.
/// - Safe: disabled/unconfigured push is a no-op; an in-flight run retains a trailing wake.
/// - Foreground-friendly: uses `CloudPushWorker.runOnce` (which respects Wi‑Fi-only and network policy).
/// - Binary lane: `CloudPushWorker` already includes `ppgWaveformSample`, `v18AuxSample`, `rawBatch`,
///   and `rawImuSession` when `binaryObjectsEnabled` and the receiver advertises the object lane.
enum CloudPushPeriodicScheduler {
    /// Permitted-execution transport cadence, independent of local physiological computation.
    /// This is a scheduling target, not an OS/background network delivery guarantee.
    static let defaultInterval: TimeInterval = 10

    /// Raw transport cadence is never slowed by disabling server physiological computation.
    static func effectiveInterval(serverScoringEnabled: Bool = ServerScoringSettings.isEnabled) -> TimeInterval {
        serverScoringEnabled ? min(defaultInterval, ServerScoringSettings.idlePushIntervalSeconds) : defaultInterval
    }

    private static var lastRunAt: Date?
    private static var lastScheduledAt: Date?
    private static var pendingTask: Task<Void, Never>?
    private static var trailingRequested = false
    private static let lock = NSLock()

    /// Call when live data lands or on a timer. Runs at most one push per `interval`.
    /// - Parameters:
    ///   - db: registry writer (from `Repository.registryWriterForPush()`)
    ///   - interval: minimum seconds between runs (default ten seconds)
    ///   - reason: label for diagnostics (e.g. "live-hr", "timer", "imu")
    static func pushIfDue(db: any DatabaseWriter, interval: TimeInterval? = nil, reason: String = "periodic") {
        guard CloudPushSettings.ready, ResourceBudget.shared.permits(.cloudControl) else { return }
        let interval = interval ?? effectiveInterval()
        guard interval > 0 else { return }

        lock.lock()
        let now = Date()
        let last = lastRunAt ?? .distantPast
        let delay = max(0, interval - now.timeIntervalSince(last))
        if pendingTask != nil { trailingRequested = true; lock.unlock(); return }
        trailingRequested = false
        lastScheduledAt = now
        let task = Task {
            defer {
                lock.lock()
                pendingTask = nil
                lastRunAt = Date()
                let trailing = trailingRequested
                trailingRequested = false
                lock.unlock()
                if trailing { pushIfDue(db: db, interval: interval, reason: "trailing-commit") }
            }
            // A last commit inside the throttle window still gets its own trailing wake.
            // Suspension can delay this; durable rows and background transfers remain authoritative.
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await CloudPushBackgroundRuntime.reconcileActive()
            let outcome = await CloudPushWorker.runOnce(db: db, trigger: reason)
            if case .completed = outcome {
                Task { @MainActor in
                    await AppModel.shared?.serverScores.refreshVisibleDays(reason: .invalidation)
                }
            }
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
