import Foundation

/// Owns connection intent and submits effects synchronously while a Bluetooth wake is available.
/// The adapter contains Core Bluetooth; tests drive these same effects with a scripted transport.
@MainActor
final class BLEConnectionOwner {
    enum Phase: String {
        case idle, restoring, pendingConnection, connecting, discovering, subscribing, ready
        case reconnecting, intentionallyDisconnected, bluetoothUnavailable, failed
    }
    struct Token: Equatable {
        let peripheralID: UUID
        let generation: UInt64
    }
    struct Request: Equatable {
        let token: Token
        let startDelay: TimeInterval
        let automaticReconnect: Bool
    }
    enum LinkState { case disconnected, connecting, connected, disconnecting }
    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { didTransition(phase) } }
    }
    private(set) var token: Token?
    private(set) var automaticReconnectPending = false
    private(set) var intentionallyStopped = false
    private var generation: UInt64 = 0
    private var submittedAt: TimeInterval?
    private var recoveryAttempts: [String: Int] = [:]
    private var recoveryDisconnectPending = false
    private let clock: () -> TimeInterval
    private let didTransition: (Phase) -> Void
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         didTransition: @escaping (Phase) -> Void = { _ in }) {
        self.clock = clock
        self.didTransition = didTransition
    }

    func allowExplicitConnection() {
        intentionallyStopped = false
        if phase == .intentionallyDisconnected { phase = .idle }
    }

    func stop() {
        intentionallyStopped = true
        invalidate()
        phase = .intentionallyDisconnected
    }

    func radioUnavailable() {
        invalidate()
        if !intentionallyStopped { phase = .bluetoothUnavailable }
    }

    func beginRestoration() -> Bool {
        guard !intentionallyStopped, token == nil, phase != .restoring else { return false }
        phase = .restoring
        return true
    }

    func restorationFailed() {
        guard phase == .restoring else { return }
        invalidate()
        phase = intentionallyStopped ? .intentionallyDisconnected : .idle
    }

    @discardableResult
    func attachRestored(_ id: UUID) -> Token? {
        guard !intentionallyStopped else { return nil }
        guard token == nil || token?.peripheralID == id else { return nil }
        if token?.peripheralID == id, [.discovering, .subscribing, .ready].contains(phase) { return nil }
        let current = nextToken(id)
        phase = .discovering
        return current
    }

    /// This is the only connection-request effect. No timers can own reconnect correctness.
    @discardableResult
    func request(_ id: UUID, link: LinkState, startDelay: TimeInterval = 0,
                 submit: (Request) -> Void) -> Bool {
        guard !intentionallyStopped, !automaticReconnectPending, !recoveryDisconnectPending,
              link != .disconnecting else { return false }
        if token?.peripheralID == id,
           [.pendingConnection, .connecting, .discovering, .subscribing, .ready].contains(phase) { return false }
        let current = nextToken(id)
        let delay = max(0, startDelay)
        submittedAt = clock() + delay
        phase = delay > 0 || link == .disconnected ? .pendingConnection : .connecting
        submit(.init(token: current, startDelay: delay, automaticReconnect: true))
        return true
    }

    @discardableResult
    func connected(_ id: UUID) -> Bool {
        guard !intentionallyStopped, token?.peripheralID == id,
              [.pendingConnection, .connecting, .reconnecting].contains(phase) else { return false }
        automaticReconnectPending = false
        submittedAt = nil
        recoveryAttempts.removeAll()
        phase = .discovering
        return true
    }

    /// Returns nil when the OS already owns recovery or the callback is obsolete.
    func disconnected(_ id: UUID, isReconnecting: Bool) -> TimeInterval? {
        guard !intentionallyStopped, token?.peripheralID == id,
              phase != .bluetoothUnavailable else { return nil }
        let age = submittedAt.map { max(0, clock() - $0) }
        let current = nextToken(id)
        token = current
        recoveryDisconnectPending = false
        automaticReconnectPending = isReconnecting
        phase = .reconnecting
        return isReconnecting ? nil : ((age ?? 2) < 2 ? 30 - (age ?? 0) : 0)
    }

    func accepts(_ value: Token) -> Bool {
        !intentionallyStopped && token == value &&
            [.discovering, .subscribing, .ready].contains(phase)
    }

    func subscribing() { if phase == .discovering { phase = .subscribing } }
    func ready() { if phase == .subscribing || phase == .discovering { phase = .ready } }

    /// Two idempotent retries per stage and generation, then one cancel/reconnect flow.
    func recover(stage: String, retry: () -> Void, reconnect: () -> Void) {
        guard !intentionallyStopped, !recoveryDisconnectPending,
              [.discovering, .subscribing, .ready].contains(phase) else { return }
        let count = recoveryAttempts[stage, default: 0]
        recoveryAttempts[stage] = count + 1
        if count < 2 { retry() }
        else {
            recoveryDisconnectPending = true
            phase = .failed
            reconnect()
        }
    }

    private func nextToken(_ id: UUID) -> Token {
        generation &+= 1
        recoveryAttempts.removeAll()
        let value = Token(peripheralID: id, generation: generation)
        token = value
        return value
    }
    private func invalidate() {
        generation &+= 1
        token = nil
        automaticReconnectPending = false
        recoveryDisconnectPending = false
        recoveryAttempts.removeAll()
        submittedAt = nil
    }
}
