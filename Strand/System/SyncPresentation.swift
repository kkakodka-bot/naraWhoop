import Foundation

/// A display projection only. It never admits work, changes connection intent, or infers cloud
/// durability from a transfer completing. All values belong to the current account snapshot.
struct SyncPresentation: Equatable {
    enum Connection: Equatable {
        case unavailable, disconnected, intentionallyDisconnected, bluetoothUnavailable
        case restoring, pending, connecting, discovering, subscribing, recovering
        case connected, catchingUp, historyPending
    }
    enum Cloud: Equatable { case unavailable, disabled, idle, pending, uploading, paused }
    enum Pause: String, Equatable {
        case authentication, terminal, compatibleEncoding, heat, lowPower, network, storage
        case history, fifo, backgroundDeadline, cooldown, queuedCloud, retry
    }
    struct CloudSnapshot: Equatable {
        var pendingJobs = 0
        var pendingSelections = 0
        var transferringJobs = 0
        var pause: Pause?
        var retryAt: Date?
        var lastVerifiedReceipt: Date?
    }
    struct Input {
        var accountIsCurrent = true
        var connectionPhase = "idle"
        var connected = false
        var historyActive = false
        var historyPending = false
        var historyExperimental = false
        var confirmedChunks = 0
        var lastStrapSync: TimeInterval?
        var cloudEnabled = true
        var cloud: CloudSnapshot?
        /// Nil means the source-debt metadata has not been read for this account/revision.
        var sourceCloudDebt: Bool?
        var budgetPause: Pause?
        var now = Date()
    }

    let connection: Connection
    let cloud: Cloud
    let cloudPause: Pause?
    let showsExperimentalHistoryNotice: Bool
    let confirmedChunks: Int?
    /// LiveState has no clock-aligned, confirmed durable frontier paired with its strap range.
    /// Neither lastStrapSync (a completion wall time) nor a chunk count is a remaining-age estimate.
    let remainingHistorySeconds: TimeInterval? = nil
    let lastStrapSync: Date?
    let lastVerifiedReceipt: Date?

    static func resolve(_ input: Input) -> Self {
        guard input.accountIsCurrent else {
            return .init(connection: .unavailable, cloud: .unavailable, cloudPause: nil,
                         showsExperimentalHistoryNotice:false, confirmedChunks: nil,
                         lastStrapSync: nil, lastVerifiedReceipt: nil)
        }
        let connection: Connection
        switch input.connectionPhase {
        case "restoring": connection = .restoring
        case "pendingConnection", "reconnecting": connection = .pending
        case "connecting": connection = .connecting
        case "discovering": connection = .discovering
        case "subscribing": connection = .subscribing
        case "bluetoothUnavailable": connection = .bluetoothUnavailable
        case "intentionallyDisconnected": connection = .intentionallyDisconnected
        case "failed": connection = .recovering
        default:
            if !input.connected { connection = .disconnected }
            else if input.historyActive { connection = .catchingUp }
            else if input.historyPending { connection = .historyPending }
            else { connection = .connected }
        }

        let cloud: Cloud
        var pause: Pause?
        if !input.cloudEnabled {
            cloud = .disabled
        } else if let snapshot = input.cloud {
            let hasDebt = snapshot.pendingJobs > 0 || snapshot.pendingSelections > 0 || input.sourceCloudDebt == true
            // Saved terminal/authentication outcomes are authoritative even before a job is staged.
            pause = snapshot.pause
            if hasDebt && pause == nil {
                pause = input.budgetPause
                if pause == nil, let retryAt = snapshot.retryAt, retryAt > input.now { pause = .retry }
            }
            if snapshot.transferringJobs > 0 { cloud = .uploading }
            else if pause != nil && pause != .queuedCloud { cloud = .paused }
            else if hasDebt { cloud = .pending }
            else { cloud = input.sourceCloudDebt == false ? .idle : .unavailable }
        } else {
            cloud = .unavailable
        }
        return .init(connection: connection, cloud: cloud, cloudPause: pause,
            showsExperimentalHistoryNotice:[.connected,.catchingUp,.historyPending].contains(connection)
                && input.historyExperimental && input.lastStrapSync == nil,
            confirmedChunks: connection == .catchingUp ? max(0,input.confirmedChunks) : nil,
            lastStrapSync: validDate(input.lastStrapSync.map(Date.init(timeIntervalSince1970:)), now: input.now),
            lastVerifiedReceipt: validDate(input.cloud?.lastVerifiedReceipt, now: input.now))
    }

    private static func validDate(_ value: Date?, now: Date) -> Date? {
        guard let value, value.timeIntervalSince1970.isFinite,
              value.timeIntervalSince1970 > 0, value <= now else { return nil }
        return value
    }
}
