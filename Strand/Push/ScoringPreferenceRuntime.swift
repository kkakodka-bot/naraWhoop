import Combine
import Foundation
import NoopPush
import WhoopStore

@MainActor
final class ScoringPreferenceTicket: ObservableObject {
    enum Failure: Error, Equatable { case loading, held, missingSource, missingPermit, dependent, capacity, invalid, retired, storage, alreadyWaiting }
    enum State: Equatable { case queued, held(Failure), accepted(ScoringPreferenceAdmission), discarded }
    let id: UUID
    @Published private(set) var state: State = .queued
    private var currentState: State = .queued
    private var publishingState = false
    fileprivate var isQueued: Bool { currentState == .queued }
    private var waiter: CheckedContinuation<ScoringPreferenceAdmission, Error>?
    init(id: UUID = UUID()) { self.id = id }
    func acceptance() async throws -> ScoringPreferenceAdmission {
        switch currentState {
        case .accepted(let receipt): return receipt
        case .held(let failure): throw failure
        case .discarded: throw Failure.retired
        case .queued:
            guard waiter == nil else { throw Failure.alreadyWaiting }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }
    }
    fileprivate func update(_ next: State) {
        currentState = next
        guard !publishingState else { return }
        publishingState = true
        // Published sends in willSet. Finish any newer reentrant transition before returning.
        repeat { state = currentState } while state != currentState
        publishingState = false
        guard currentState != .queued, let waiter else { return }
        self.waiter = nil
        switch currentState {
        case .accepted(let receipt): waiter.resume(returning: receipt)
        case .held(let error): waiter.resume(throwing: error)
        default: waiter.resume(throwing: Failure.retired)
        }
    }
}

@MainActor
final class ScoringPreferenceRuntime: @MainActor ObservableObject {
    enum Publication { case hydrated, committed }
    struct Hooks {
        var atCommit: (@Sendable (ScoringInputJournal.PreferenceCommitPoint) -> Void)?
        var beforePublication: (() async -> Void)?
        var afterMirrorKey: ((ScoringPreferenceKey) -> Void)?
    }
    private struct Prepared {
        let ticket: ScoringPreferenceTicket
        let intent: ScoringPreferenceIntent?
        let snapshot: ScoringPreferenceSnapshot
        let action: ScoringPreferenceAction
        let bytes: Int
    }
    let context: AccountSessionContext
    let objectWillChange = ObservableObjectPublisher()
    private var acceptedStorage: ScoringPreferenceSnapshot?
    var accepted: ScoringPreferenceSnapshot? { current ? acceptedStorage : nil }
    @Published private(set) var pendingCount = 0
    @Published private(set) var pendingBytes = 0
    @Published private(set) var lastError: ScoringPreferenceTicket.Failure?
    var willAccept: (() -> Void)?
    var onAccepted: ((ScoringPreferenceSnapshot, Publication) -> Void)?
    private let seed: ScoringPreferenceSnapshot
    private let inputs: ScoringInputCoordinator
    private let defaults: UserDefaults
    private let isCurrent: @Sendable (AccountSessionContext) -> Bool
    private let fence = StoreWriteFence()
    private let hooks: Hooks
    private let maxActions: Int
    private let maxBytes: Int
    private var queue: [Prepared] = []
    private var queueBytes: Int { queue.reduce(0) { $0 + $1.bytes } }
    private var publishingCounts = false
    private var worker: Task<Void, Never>?
    private var inFlight: ScoringPreferenceTicket?
    private var active = true
    private var hydrating = false
    var isReady: Bool { current && accepted != nil }
    var draft: ScoringPreferenceSnapshot? { current ? queue.last?.snapshot ?? accepted : nil }
    var pendingHeadTicket: ScoringPreferenceTicket? { current ? queue.first?.ticket : nil }
    private var current: Bool { active && fence.isValid && isCurrent(context) }

    init(context: AccountSessionContext, inputs: ScoringInputCoordinator, seed: ScoringPreferenceSnapshot,
         defaults: UserDefaults, isCurrent: @escaping @Sendable (AccountSessionContext) -> Bool,
         maxActions: Int = 64, maxBytes: Int = 1_048_576, hooks: Hooks = .init()) throws {
        guard inputs.context == context, seed.context == context else { throw ScoringInputJournal.Failure.wrongOwner }
        self.context = context; self.inputs = inputs; self.seed = seed; self.defaults = defaults
        self.isCurrent = isCurrent; self.hooks = hooks
        self.maxActions = min(64, max(1, maxActions)); self.maxBytes = min(1_048_576, max(1, maxBytes))
    }

    func hydrate() async throws {
        guard current else { throw ScoringInputJournal.Failure.retired }
        if accepted != nil { return }
        guard !hydrating else { throw ScoringPreferenceTicket.Failure.loading }
        hydrating = true; defer { hydrating = false }
        let projection = try await inputs.preferenceProjection()
        guard current, !Task.isCancelled else { throw ScoringInputJournal.Failure.retired }
        let next = try seed.restoring(projection)
        publish(next, reason: .hydrated)
        guard current else { throw ScoringInputJournal.Failure.retired }
    }

    @discardableResult func complete(_ action: ScoringPreferenceAction) -> ScoringPreferenceTicket {
        let ticket = ScoringPreferenceTicket()
        guard current, action.capture.context == context else { ticket.update(.held(.retired)); return ticket }
        guard let base = draft else { ticket.update(.held(.loading)); return ticket }
        guard queue.last?.intent != nil || queue.isEmpty else { ticket.update(.held(.dependent)); return ticket }
        do {
            let capture = action.capture
            guard capture.occurredAt.timeIntervalSince1970.isFinite,
                  TimeZone(identifier: capture.timezone) != nil,
                  base.position.sequence < Int64.max else { throw ScoringInputJournal.Failure.invalidInput }
            if let source = capture.sourceDeviceID, UUID(uuidString: source) == nil { throw ScoringInputJournal.Failure.invalidInput }
            let position = ScoringPreferencePosition(sequence: base.position.sequence + 1, id: ticket.id)
            let candidate = try base.applying(action.patch, position: position, disposition: capture.disposition)
            var held: ScoringPreferenceTicket.Failure?
            var intent: ScoringPreferenceIntent?
            if capture.disposition == .serverCoupled && capture.sourceDeviceID == nil { held = .missingSource }
            else if capture.disposition == .serverCoupled && (capture.allowing == nil || capture.consent == nil) { held = .missingPermit }
            else {
                let payloads = capture.disposition == .serverCoupled
                    ? try candidate.payloads(at: capture.occurredAt, timezone: capture.timezone, consent: capture.consent!) : nil
                intent = try ScoringPreferenceIntent(context: context, id: ticket.id, predecessor: base.position,
                    occurredAt: capture.occurredAt, timezone: capture.timezone, device: capture.sourceDeviceID,
                    disposition: capture.disposition, patch: action.patch,
                    profilePayload: payloads?.profile, configPayload: payloads?.config)
            }
            // Encoded body includes both payloads. Extra fixed charge covers the bounded snapshot,
            // ticket, capture metadata and permit reference, also for a captured-absence draft.
            let metadata: [String: Any] = ["project": context.scope.projectURL, "user": context.scope.userID,
                "generation": context.generation.uuidString, "occurredAt": capture.occurredAt.timeIntervalSince1970,
                "timezone": capture.timezone, "device": capture.sourceDeviceID as Any? ?? NSNull(),
                "disposition": capture.disposition.rawValue,
                "journalConsent": capture.consent?.journalEnabled as Any? ?? NSNull(),
                "cycleConsent": capture.consent?.cycleEnabled as Any? ?? NSNull()]
            let bytes = try (intent?.encoded().count ?? 0) + JSONEncoder().encode(action.patch).count
                + JSONEncoder().encode(candidate.values).count + JSONSerialization.data(withJSONObject: metadata).count + 4096
            guard queue.count < maxActions, bytes <= maxBytes - queueBytes else {
                ticket.update(.held(.capacity)); lastError = .capacity; return ticket
            }
            queue.append(.init(ticket: ticket, intent: intent, snapshot: candidate, action: action, bytes: bytes))
            updateCounts()
            guard current else { ticket.update(.held(.retired)); return ticket }
            if let held { ticket.update(.held(held)); lastError = held }
            else { start() }
        } catch { ticket.update(.held(.invalid)); lastError = .invalid }
        return ticket
    }

    func retry(_ ticket: ScoringPreferenceTicket) {
        guard current, worker == nil, let head = queue.first, head.ticket === ticket, head.intent != nil else { return }
        ticket.update(.queued); lastError = nil; start()
    }

    @discardableResult func discardUnacceptedChain(from ticket: ScoringPreferenceTicket) -> Bool {
        guard current, let index = queue.firstIndex(where: { $0.ticket === ticket }), index > 0 || worker == nil else { return false }
        let discarded = Array(queue[index...])
        queue.removeSubrange(index...); updateCounts(); lastError = nil
        for entry in discarded { entry.ticket.update(.discarded) }
        return true
    }

    func retire() {
        guard active else { return }
        fence.invalidate(); active = false; worker?.cancel()
        willAccept?()
        // An in-flight transaction must report its real result, including a commit which won
        // the retirement race. It may never publish back into this retired facade.
        for entry in queue where entry.ticket !== inFlight { entry.ticket.update(.held(.retired)) }
        queue.removeAll(); updateCounts(); acceptedStorage = nil; willAccept = nil; onAccepted = nil
        objectWillChange.send()
    }

    func waitForRetirement() async { await worker?.value }

    private func updateCounts() {
        guard !publishingCounts else { return }
        publishingCounts = true
        defer { publishingCounts = false }
        repeat {
            if pendingCount != queue.count { pendingCount = queue.count }
            if pendingBytes != queueBytes { pendingBytes = queueBytes }
        } while pendingCount != queue.count || pendingBytes != queueBytes
    }
    private func start() {
        guard current, worker == nil, let head = queue.first, head.ticket.isQueued else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; self.inFlight = nil }
            while self.current, let head = self.queue.first, head.ticket.isQueued, let intent = head.intent {
                self.inFlight = head.ticket
                let captured = head.action.capture.allowing, fence = self.fence, owner = self.context, current = self.isCurrent
                do {
                    let receipt = try await self.inputs.admitPreferenceIntent(intent, allowing: {
                        fence.isValid && current(owner) && (captured?() ?? true)
                    }, at: self.hooks.atCommit)
                    await self.hooks.beforePublication?()
                    if self.current { self.publish(head.snapshot, reason: .committed) }
                    if self.current, self.queue.first?.ticket === head.ticket {
                        self.queue.removeFirst(); self.updateCounts(); self.lastError = nil
                    }
                    head.ticket.update(.accepted(receipt))
                    self.inFlight = nil
                } catch {
                    guard self.current else { head.ticket.update(.held(.retired)); return }
                    let failure: ScoringPreferenceTicket.Failure
                    switch error {
                    case ScoringInputJournal.Failure.held: failure = .held
                    case ScoringInputJournal.Failure.retired, is CancellationError: failure = .retired
                    case ScoringInputJournal.Failure.storageLimit: failure = .capacity
                    default: failure = .storage
                    }
                    self.lastError = failure; head.ticket.update(.held(failure)); return
                }
            }
        }
    }

    private func publish(_ snapshot: ScoringPreferenceSnapshot, reason: Publication) {
        guard current else { return }
        // Revoke work admitted under the previous value before observers see this publication.
        willAccept?()
        guard current else { return }
        objectWillChange.send()
        guard current else { return }
        acceptedStorage = snapshot
        snapshot.mirror(to: defaults, allowing: { self.current }, afterKey: hooks.afterMirrorKey)
        guard current else { return }
        onAccepted?(snapshot, reason)
    }
}
