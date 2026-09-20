import Foundation

/// One admission snapshot for workers on any executor. Essential receipt/commit/ACK work stays admitted.
final class ResourceBudget: @unchecked Sendable {
    enum Work { case localCommit, acknowledgement, urgentControl, bulk }
    static let changed = Notification.Name("ResourceBudgetChanged")
    static let shared = ResourceBudget(observeProcess: true)
    private let lock = NSLock()
    private var historyOwners: Set<UUID> = []
    private var resumeAfter: TimeInterval = 0
    private var processPressureObserved = false
    private var observers: [NSObjectProtocol] = []
    private let clock: @Sendable () -> TimeInterval
    private let thermal: @Sendable () -> Int
    private let lowPower: @Sendable () -> Bool
    private let cooldown: TimeInterval

    init(observeProcess: Bool = false, cooldown: TimeInterval = 15,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         thermal: @escaping @Sendable () -> Int = { ProcessInfo.processInfo.thermalState.rawValue },
         lowPower: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }) {
        self.clock = clock; self.thermal = thermal; self.lowPower = lowPower; self.cooldown = cooldown
        if observeProcess {
            for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    _ = self?.permits(.bulk)
                    NotificationCenter.default.post(name: Self.changed, object: nil)
                })
            }
        }
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func history(owner: UUID, active: Bool) {
        lock.lock()
        let changed = active ? historyOwners.insert(owner).inserted : historyOwners.remove(owner) != nil
        if changed { resumeAfter = clock() + cooldown }
        lock.unlock()
        if changed { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    func permits(_ work: Work) -> Bool {
        guard work == .bulk else { return true }
        return bulkResumeDelay() == 0
    }

    /// Nil while pressure is active; otherwise the remaining foreground optimization delay.
    /// Durable debt must still be reconciled on OS/lifecycle wakes; this is not a background timer.
    func bulkResumeDelay() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        let processPressure = thermal() >= ProcessInfo.ThermalState.serious.rawValue || lowPower()
        if processPressure { processPressureObserved = true }
        else if processPressureObserved {
            processPressureObserved = false
            resumeAfter = max(resumeAfter, now + cooldown)
        }
        if !historyOwners.isEmpty || processPressure {
            resumeAfter = now + cooldown
            return nil
        }
        return max(0, resumeAfter - now)
    }
}
