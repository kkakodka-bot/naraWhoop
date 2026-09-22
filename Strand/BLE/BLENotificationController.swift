import Foundation

/// Confirms subscriptions for one admitted connection generation. A cached native active
/// flag must complete OFF then ON before it authorizes history on a new generation.
/// The caller supplies the production transport effect and the owner's bounded recovery.
@MainActor
final class BLENotificationController<Key: Hashable> {
    enum Observation: Equatable { case confirmed, waiting, needsRecovery, ignored }
    private enum Phase { case disabling, enabling, confirmed }
    private var phases: [Key: Phase] = [:]
    private(set) var token: BLEConnectionOwner.Token?

    var confirmed: Set<Key> { Set(phases.compactMap { $0.value == .confirmed ? $0.key : nil }) }

    func reset() {
        token = nil
        phases.removeAll()
    }

    /// Returns false only when admission/submission failed. Repeated requests for a pending
    /// subscription are idempotent; their original native operation still owns completion.
    @discardableResult
    func request(_ key: Key, isNotifying: Bool, token: BLEConnectionOwner.Token,
                 submit: (Bool) -> Bool) -> Bool {
        if self.token != token {
            if let current = self.token, token.generation <= current.generation { return false }
            self.token = token
            phases.removeAll()
        }
        switch phases[key] {
        case .disabling, .enabling: return true
        case .confirmed where isNotifying: return true
        default: break
        }
        phases[key] = isNotifying ? .disabling : .enabling
        guard submit(!isNotifying) else {
            phases.removeValue(forKey: key)
            return false
        }
        return true
    }

    func observed(_ key: Key, isNotifying: Bool, succeeded: Bool,
                  token: BLEConnectionOwner.Token, submit: (Bool) -> Bool) -> Observation {
        guard self.token == token, let phase = phases[key] else { return .ignored }
        if !succeeded {
            phases.removeValue(forKey: key)
            return .needsRecovery
        }
        switch phase {
        case .disabling:
            // A duplicate/late ON cannot consume the pending OFF or authorize readiness.
            guard !isNotifying else { return .waiting }
            phases[key] = .enabling
            guard submit(true) else {
                phases.removeValue(forKey: key)
                return .needsRecovery
            }
            return .waiting
        case .enabling:
            // A duplicate OFF has no operation identifier. Preserve the pending ON until its
            // positive callback, explicit error, or the manager's generation/deadline fence.
            guard isNotifying else { return .waiting }
            phases[key] = .confirmed
            return .confirmed
        case .confirmed:
            guard !isNotifying else { return .confirmed }
            phases.removeValue(forKey: key)
            return .needsRecovery
        }
    }
}
