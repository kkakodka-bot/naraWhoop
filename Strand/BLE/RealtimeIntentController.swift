import Foundation

/// Keeps the current realtime intent separate from the last confirmed ATT write.
@MainActor
final class RealtimeIntentController {
    struct Request: Equatable {
        let generation: UInt64
        let sequence: UInt64
        let enabled: Bool
    }

    enum Failure: String {
        case submissionRejected
        case attWriteFailed
    }

    private(set) var desiredEnabled = false
    private(set) var confirmedEnabled: Bool?
    private(set) var pending: Request?
    private(set) var recoveryRequested = false
    private(set) var attempts = 0
    private(set) var generation: UInt64?
    private var ready = false
    private var sequence: UInt64 = 0
    private let maximumAttempts: Int
    private let submit: (Request) -> Bool
    private let recover: (Failure) -> Void

    init(maximumAttempts: Int = 3, submit: @escaping (Request) -> Bool,
         recover: @escaping (Failure) -> Void) {
        precondition(maximumAttempts > 0)
        self.maximumAttempts = maximumAttempts
        self.submit = submit
        self.recover = recover
    }

    /// A fresh link has unknown producer state, including when current intent is off-wrist.
    func beginConnection(generation: UInt64) {
        guard self.generation != generation else { return }
        self.generation = generation
        ready = false
        confirmedEnabled = nil
        pending = nil
        recoveryRequested = false
        attempts = 0
    }

    func setReady(_ ready: Bool) {
        self.ready = ready
        if ready { reconcile() }
    }

    func setDesired(_ enabled: Bool) {
        if desiredEnabled != enabled {
            desiredEnabled = enabled
            attempts = 0
        }
        reconcile()
    }

    /// Retry rejected submissions on a subsequent transport event, without a timer or busy loop.
    func reconcile() {
        submitDesired(refresh: false)
    }

    /// Foreground cadence may reassert a producer whose firmware arm can lapse. Refresh is
    /// allowed only for current enabled intent, and never queues work behind an in-flight
    /// command or across a readiness/connection boundary. Stops remain completion-backed.
    func refreshEnabled() {
        guard desiredEnabled else { return }
        submitDesired(refresh: true)
    }

    private func submitDesired(refresh: Bool) {
        guard let generation, ready, !recoveryRequested, pending == nil,
              refresh || confirmedEnabled != desiredEnabled else { return }
        sequence &+= 1
        let request = Request(generation: generation, sequence: sequence, enabled: desiredEnabled)
        attempts += 1
        pending = request
        // Install before submitting so a scripted synchronous completion has identical semantics.
        let submitted = submit(request)
        guard !submitted, pending == request else { return }
        pending = nil
        confirmedEnabled = nil
        recoverIfExhausted(.submissionRejected)
    }

    /// Only the matching command queue entry can settle this request; duplicates are inert.
    func completed(_ request: Request, succeeded: Bool) {
        guard generation == request.generation, pending == request, !recoveryRequested else { return }
        pending = nil
        if succeeded {
            confirmedEnabled = request.enabled
            attempts = 0
        } else {
            confirmedEnabled = nil
            if request.enabled == desiredEnabled { recoverIfExhausted(.attWriteFailed) }
        }
        reconcile()
    }

    /// Involuntary loss keeps current intent. Account/device teardown also clears it.
    func endConnection(clearIntent: Bool = false) {
        generation = nil
        ready = false
        pending = nil
        confirmedEnabled = nil
        recoveryRequested = false
        attempts = 0
        if clearIntent { desiredEnabled = false }
    }

    private func recoverIfExhausted(_ failure: Failure) {
        guard attempts >= maximumAttempts, !recoveryRequested else { return }
        recoveryRequested = true
        recover(failure)
    }
}
