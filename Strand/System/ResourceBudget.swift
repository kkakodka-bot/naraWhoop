import Foundation
#if os(iOS)
import UIKit
#endif

/// One admission snapshot for workers on any executor. Essential receipt/commit/ACK work stays admitted.
final class ResourceBudget: @unchecked Sendable {
    enum Work { case localCommit, acknowledgement, urgentControl, bulk, cloudPreparation, cloudTransfer, cloudControl, scoring, projection, rawBulk }
    enum PauseReason: String {
        case history, fifo, heat, lowPower, backgroundDeadline, storage, network, queuedCloud, cooldown
    }
    struct Snapshot {
        let reason: PauseReason?
        let fifoDepth: Int
        let oldestFIFOAge: TimeInterval
        let queuedCloudBytes: Int
        let queuedCloudJobs: Int
        let maximumTransfers: Int
    }
    enum OpportunityKind: String, Sendable { case bleCallback, restoration, taskAssertion, backgroundTask, urlSession }
    /// The work deadline bounds application work. It is never a claimed CoreBluetooth OS grant.
    struct Opportunity: Equatable, Sendable {
        let id: UUID
        let owner: UUID
        let kind: OpportunityKind
        let workDeadlineUptime: TimeInterval
        let platformDeadlineUptime: TimeInterval?
    }
    // Initial conservative preparation limits; throughput/energy qualification is a separate gate.
    static let maximumPreparationFIFODepth = 64
    static let maximumPreparationFIFOAge: TimeInterval = 1
    static let changed = Notification.Name("ResourceBudgetChanged")
    static let opportunityBegan = Notification.Name("ResourceBudgetOpportunityBegan")
    static let shared = ResourceBudget(observeProcess: true)
    private let lock = NSLock()
    private var historyOwners: Set<UUID> = []
    private var pipelines: [UUID: (depth: Int, oldest: TimeInterval)] = [:]
    private var cloudDebt: [UUID: (bytes: Int, jobs: Int)] = [:]
    private var backgroundDeadline: TimeInterval?
    private var backgroundOpportunities: Set<UUID> = []
    private var opportunities: [UUID: Opportunity] = [:]
    private var relayResumeAfter: TimeInterval = 0
    private var availableStorageBytes: Int64?
    private var networkPermitted = true
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
            #if os(iOS)
            observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lifecycle(backgroundRemaining: UIApplication.shared.backgroundTimeRemaining)
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                object: nil, queue: .main) { [weak self] _ in self?.lifecycle(backgroundRemaining: nil) })
            #endif
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
        switch work {
        case .localCommit, .acknowledgement, .urgentControl: return true
        default: return snapshot(for: work).reason == nil
        }
    }

    /// Called by the synchronous FIFO handoff. Old owners cannot erase another pipeline's pressure.
    func pipeline(owner: UUID, depth: Int, oldestUptime: TimeInterval?) {
        lock.lock()
        let wasActive = pipelines[owner] != nil
        if depth > 0, let oldestUptime { pipelines[owner] = (depth, oldestUptime) }
        else { pipelines.removeValue(forKey: owner) }
        let changed = wasActive != (pipelines[owner] != nil)
        if changed { resumeAfter = max(resumeAfter, clock() + cooldown) }
        lock.unlock()
        if changed {
            // The FIFO calls while holding its ordering lock. Admission changes above are immediate;
            // observers run after that lock is released and cannot re-enter the receive handoff.
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
        }
    }

    func queuedCloud(owner: UUID, bytes: Int, jobs: Int) {
        lock.lock()
        if jobs > 0 { cloudDebt[owner] = (max(0, bytes), jobs) }
        else { cloudDebt.removeValue(forKey: owner) }
        lock.unlock()
    }

    func lifecycle(backgroundRemaining: TimeInterval?) {
        lock.lock()
        backgroundDeadline = backgroundRemaining.map { clock() + max(0, $0) }
        lock.unlock()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Only an executing BGTask may grant this opportunity; expiration and completion revoke it.
    /// UIApplication's finite assertion deadline does not describe a separately granted BGTask.
    func backgroundOpportunity(owner: UUID, active: Bool) {
        lock.lock()
        let changed = active ? backgroundOpportunities.insert(owner).inserted
            : backgroundOpportunities.remove(owner) != nil
        lock.unlock()
        if changed {
            if active { _ = beginOpportunity(kind: .backgroundTask, owner: owner) }
            else { endOpportunities(owner: owner) }
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    @discardableResult
    func beginOpportunity(kind: OpportunityKind, owner: UUID, maximumDuration: TimeInterval = 2,
                          platformRemaining: TimeInterval? = nil) -> Opportunity {
        lock.lock()
        let now = clock()
        let duration = maximumDuration.isFinite ? min(5, max(0, maximumDuration)) : 0
        let platform = platformRemaining.flatMap { $0.isFinite ? now + max(0, $0) : nil }
        let opportunity = Opportunity(id: UUID(), owner: owner, kind: kind,
            workDeadlineUptime: min(now + duration, platform ?? now + duration),
            platformDeadlineUptime: platform)
        opportunities[opportunity.id] = opportunity
        lock.unlock()
        NotificationCenter.default.post(name: Self.opportunityBegan, object: self,
            userInfo: ["opportunity": opportunity])
        NotificationCenter.default.post(name: Self.changed, object: nil)
        return opportunity
    }

    /// Only explicitly admitted, still-live events may optimize ordinary transfers. A nil
    /// background deadline is not evidence of a foreground grant.
    var currentOpportunity: Opportunity? {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        return opportunities.values.filter { $0.workDeadlineUptime > now }
            .min { $0.workDeadlineUptime < $1.workDeadlineUptime }
    }

    func remainingDuration(for opportunity: Opportunity) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard opportunities[opportunity.id] == opportunity else { return nil }
        let remaining = opportunity.workDeadlineUptime - clock()
        return remaining > 0 ? remaining : nil
    }

    func isCurrent(_ opportunity: Opportunity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return opportunities[opportunity.id] == opportunity && clock() < opportunity.workDeadlineUptime
    }

    func endOpportunity(_ opportunity: Opportunity) {
        lock.lock()
        let changed = opportunities.removeValue(forKey: opportunity.id) != nil
        lock.unlock()
        if changed { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    func endOpportunities(owner: UUID) {
        lock.lock()
        opportunities = opportunities.filter { $0.value.owner != owner }
        lock.unlock()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func storage(availableBytes: Int64?) {
        lock.lock(); availableStorageBytes = availableBytes; lock.unlock()
    }

    func network(permitted: Bool) {
        lock.lock(); let changed = networkPermitted != permitted; networkPermitted = permitted; lock.unlock()
        if changed { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    func snapshot(for work: Work = .bulk) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        let heat = thermal(), powerSaving = lowPower()
        observePressure(now: now, processPressure: heat >= ProcessInfo.ThermalState.serious.rawValue || powerSaving)
        let depth = pipelines.values.reduce(0) { $0 + $1.depth }
        let oldest = pipelines.values.map(\.oldest).min().map { max(0, now - $0) } ?? 0
        let bytes = cloudDebt.values.reduce(0) { $0 + $1.bytes }
        let jobs = cloudDebt.values.reduce(0) { $0 + $1.jobs }
        let essential = work == .localCommit || work == .acknowledgement || work == .urgentControl
        let relay = work == .cloudPreparation || work == .cloudTransfer || work == .cloudControl
        opportunities = opportunities.filter { $0.value.workDeadlineUptime > now }
        let finiteRelayOpportunity = relay && !opportunities.isEmpty
        var reason: PauseReason?
        if !essential {
            if heat >= ProcessInfo.ThermalState.serious.rawValue { reason = .heat }
            else if !relay && !historyOwners.isEmpty { reason = .history }
            else if !relay && depth > 0 { reason = .fifo }
            else if work == .cloudPreparation &&
                (depth > Self.maximumPreparationFIFODepth || oldest >= Self.maximumPreparationFIFOAge) { reason = .fifo }
            else if powerSaving && work != .cloudControl && work != .cloudTransfer { reason = .lowPower }
            else if backgroundOpportunities.isEmpty && !finiteRelayOpportunity,
                    let backgroundDeadline, backgroundDeadline - now < 5 { reason = .backgroundDeadline }
            else if let availableStorageBytes, availableStorageBytes < 64 * 1_048_576 { reason = .storage }
            else if relay && !networkPermitted { reason = .network }
            else if work == .cloudPreparation && (bytes >= 256 * 1_048_576 || jobs >= 128) { reason = .queuedCloud }
            else if now < (relay ? relayResumeAfter : resumeAfter) { reason = .cooldown }
        }
        // History alone does not reduce the two slots: one historical transfer and one fresh/control.
        // Actual background or thermal pressure can leave one slot, which the queue must alternate fairly.
        let constrained = backgroundDeadline != nil || !backgroundOpportunities.isEmpty ||
            heat > 0 || powerSaving
        return Snapshot(reason: reason, fifoDepth: depth, oldestFIFOAge: oldest,
                        queuedCloudBytes: bytes, queuedCloudJobs: jobs,
                        maximumTransfers: reason != nil ? 0 : (constrained ? 1 : 2))
    }

    private func observePressure(now: TimeInterval, processPressure: Bool) {
        if processPressure { processPressureObserved = true }
        else if processPressureObserved {
            processPressureObserved = false
            resumeAfter = max(resumeAfter, now + cooldown)
            relayResumeAfter = max(relayResumeAfter, now + cooldown)
        }
        if !historyOwners.isEmpty || !pipelines.isEmpty || processPressure { resumeAfter = max(resumeAfter, now + cooldown) }
    }

    /// Nil while pressure is active; otherwise the remaining foreground optimization delay.
    /// Durable debt must still be reconciled on OS/lifecycle wakes; this is not a background timer.
    func bulkResumeDelay() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        let processPressure = thermal() >= ProcessInfo.ThermalState.serious.rawValue || lowPower()
        observePressure(now: now, processPressure: processPressure)
        if !historyOwners.isEmpty || !pipelines.isEmpty || processPressure
            || (backgroundOpportunities.isEmpty && backgroundDeadline.map({ $0 - now < 5 }) == true)
            || availableStorageBytes.map({ $0 < 64 * 1_048_576 }) == true {
            return nil
        }
        return max(0, resumeAfter - now)
    }
}
