import Combine
import Foundation
import NoopPush
import WhoopStore

enum ScoringInputRPC {
    enum Failure: Error, Equatable { case unavailable, staleOwner, conflict, invalidResponse, rejected, held }
    struct Authorization: Sendable { let context: AccountSessionContext; let accessToken: String }
    struct Dependencies: Sendable {
        let anonKey: @Sendable () -> String?
        let authorize: @Sendable () async throws -> Authorization
        let isCurrent: @Sendable (AccountSessionContext) -> Bool
        let canUpload: @Sendable () -> Bool
        let request: @Sendable (URLRequest) async throws -> (Data, URLResponse)
        var allowsChange: @Sendable (ScoringInputChange) -> Bool = { _ in true }
    }

    static func send(_ pending: ScoringInputJournal.Pending, context: AccountSessionContext,
                     dependencies: Dependencies) async throws -> ScoringInputReceipt {
        guard pending.scope == context.scope else { throw Failure.staleOwner }
        let data = try await request("put_scoring_history_input_v3", change: pending.change, context: context,
            dependencies: dependencies, body: [
                "p_device": pending.change.device, "p_kind": pending.change.kind.rawValue,
                "p_entity": pending.change.entity, "p_effective_day": pending.change.effectiveDay,
                "p_payload": try JSONSerialization.jsonObject(with: pending.change.payload),
                "p_expected_revision": pending.expectedRevision, "p_deleted": pending.change.deleted,
                "p_client_id": pending.clientID.uuidString.lowercased(),
                "p_client_mutation_id": pending.id, "p_client_revision": pending.clientRevision
            ])
        guard let receipt = try? JSONDecoder().decode(ScoringInputReceipt.self, from: data), receipt.matches(pending) else {
            throw Failure.invalidResponse
        }
        return receipt
    }

    static func head(_ change: ScoringInputChange, context: AccountSessionContext,
                     dependencies: Dependencies) async throws -> ScoringInputHead {
        let data = try await request("get_scoring_history_input_head_v3", change: change, context: context,
            dependencies: dependencies, body: ["p_device": change.device, "p_kind": change.kind.rawValue, "p_entity": change.entity])
        guard let head = try? JSONDecoder().decode(ScoringInputHead.self, from: data), head.matches(scope: context.scope, change: change) else {
            throw Failure.invalidResponse
        }
        return head
    }

    static func read(_ change: ScoringInputChange, asOfDay: String, context: AccountSessionContext,
                     dependencies: Dependencies) async throws -> ScoringInputValue {
        guard ServerScoreDate.isDay(asOfDay) else { throw Failure.rejected }
        let data = try await request("get_scoring_history_input_v3", change: change, context: context,
            dependencies: dependencies, body: ["p_device": change.device, "p_kind": change.kind.rawValue,
                "p_entity": change.entity, "p_as_of_day": asOfDay], maximumBytes: 72 * 1024)
        return try ScoringInputValue(data: data, scope: context.scope, change: change, asOfDay: asOfDay)
    }

    private static func request(_ rpc: String, change: ScoringInputChange, context: AccountSessionContext,
                                dependencies: Dependencies, body: [String: Any], maximumBytes: Int = 8192) async throws -> Data {
        try Task.checkCancellation()
        guard dependencies.isCurrent(context) else { throw Failure.staleOwner }
        guard dependencies.allowsChange(change) else { throw Failure.held }
        guard let base = URL(string: context.scope.projectURL), let anon = dependencies.anonKey(),
              dependencies.canUpload() else { throw Failure.unavailable }
        let authorization = try await dependencies.authorize()
        try Task.checkCancellation()
        guard authorization.context == context, dependencies.isCurrent(context) else { throw Failure.staleOwner }
        guard dependencies.canUpload() else { throw Failure.unavailable }
        guard dependencies.allowsChange(change) else { throw Failure.held }
        var request = URLRequest(url: base.appendingPathComponent("rest/v1/rpc/" + rpc))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anon, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authorization.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await dependencies.request(request)
        try Task.checkCancellation()
        guard dependencies.isCurrent(context) else { throw Failure.staleOwner }
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard data.count <= maximumBytes else { throw Failure.invalidResponse }
        if response.statusCode != 200 {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = body?["code"] as? String
            let message = body?["message"] as? String
            if code == "40001", ["history_revision_conflict", "client_revision_conflict"].contains(message ?? "") {
                throw Failure.conflict
            }
            if code == "23505", message == "idempotency_conflict" { throw Failure.conflict }
            if code == "22023" { throw Failure.rejected }
            throw Failure.unavailable
        }
        return data
    }
}

/// Small control requests are opportunistic. The durable journal, not an app timer, owns pending work.
@MainActor
final class ScoringInputCoordinator: ObservableObject {
    typealias AdmissionCheck = @Sendable () -> Bool
    struct Dependencies: Sendable {
        var isCurrent: @MainActor @Sendable (AccountSessionContext) -> Bool
        var canUpload: @MainActor @Sendable () -> Bool
        var openJournal: @Sendable (AccountStorageLayout, StoreWriteFence) async throws -> ScoringInputJournal = {
            try ScoringInputJournal(layout: $0, fence: $1)
        }
        var head: @Sendable (ScoringInputChange, AccountSessionContext) async throws -> ScoringInputHead
        var send: @Sendable (ScoringInputJournal.Pending, AccountSessionContext) async throws -> ScoringInputReceipt
        var didSettle: @MainActor @Sendable (ScoringInputReceipt) -> Void = { _ in }
        var now: @Sendable () -> Date = { Date() }
        var allowsChange: @Sendable (ScoringInputChange) -> Bool = { _ in true }
    }
    struct ConflictReview: Sendable {
        let context: AccountSessionContext
        let conflict: ScoringInputJournal.Conflict
        let head: ScoringInputHead
    }
    @Published private(set) var status = ScoringInputJournal.Status(pending: 0, conflicts: 0)
    @Published private(set) var lastError: String?
    var prepareAdmission: (() async throws -> Void)?
    var captureAdmission: (() throws -> AdmissionCheck)?
    let context: AccountSessionContext
    private let layout: AccountStorageLayout
    private let dependencies: Dependencies
    private let writeFence: StoreWriteFence
    private var preparation: (id: UUID, task: Task<ScoringInputJournal, Error>)?
    private var journal: ScoringInputJournal?
    private var operation: Task<Void, Never>?
    private var retirement: Task<Void, Error>?
    private var operationID: UUID?
    private var active = true
    private var reconcileRequested = false
    private var preferenceAdmissionBusy = false
    private var preferenceAdmissionWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var preparationWaiterCount = 0

    init(context: AccountSessionContext, layout: AccountStorageLayout, dependencies: Dependencies,
         fence: StoreWriteFence = StoreWriteFence()) {
        self.context = context; self.layout = layout; self.dependencies = dependencies; self.writeFence = fence
    }

    private var current: Bool { active && writeFence.isValid && layout.scope == context.scope && dependencies.isCurrent(context) }

    private func readyJournal() async throws -> ScoringInputJournal {
        guard current else { throw ScoringInputJournal.Failure.retired }
        try Task.checkCancellation()
        if let journal { return journal }
        let pending: (id: UUID, task: Task<ScoringInputJournal, Error>)
        if let preparation { pending = preparation }
        else {
            let layout = self.layout
            let open = dependencies.openJournal
            let fence = writeFence
            pending = (UUID(), Task.detached(priority: .utility) { try await open(layout, fence) })
            preparation = pending
        }
        preparationWaiterCount += 1
        defer { preparationWaiterCount -= 1 }
        let opened: ScoringInputJournal
        do { opened = try await pending.task.value }
        catch {
            if preparation?.id == pending.id { preparation = nil }
            throw error
        }
        guard current else { await opened.retire(); throw ScoringInputJournal.Failure.retired }
        guard opened.writeFence === writeFence else { await opened.retire(); throw ScoringInputJournal.Failure.wrongOwner }
        // Preparation belongs to the account, not to any particular producer/drain waiter.
        // Publish the usable resource even when this waiter was cancelled by a policy change.
        journal = opened
        if preparation?.id == pending.id { preparation = nil }
        try Task.checkCancellation()
        return opened
    }

    func enqueue(_ change: ScoringInputChange) async throws {
        guard current else { throw ScoringInputJournal.Failure.retired }
        try Task.checkCancellation()
        try await prepareAdmission?()
        let admission = try captureAdmission?() ?? { true }
        guard current else { throw ScoringInputJournal.Failure.retired }
        guard dependencies.allowsChange(change) else { throw ScoringInputJournal.Failure.held }
        let journal = try await readyJournal()
        guard current else { throw ScoringInputJournal.Failure.retired }
        try Task.checkCancellation()
        guard dependencies.allowsChange(change) else { throw ScoringInputJournal.Failure.held }
        let allows = dependencies.allowsChange
        _ = try await journal.enqueue(change, allowing: { admission() && allows($0) })
        let status = try await journal.status()
        guard current else { return }
        self.status = status
        reconcile()
    }

    func preferenceProjection() async throws -> ScoringPreferenceProjection {
        let journal = try await readyJournal()
        guard current else { throw ScoringInputJournal.Failure.retired }
        return try await journal.committedPreferenceProjection()
    }

    enum PreferenceMaintenancePoint { case beforeCompaction, afterCompaction }

    private func acquirePreferenceAdmission() async {
        if preferenceAdmissionBusy {
            await withCheckedContinuation { preferenceAdmissionWaiters.append($0) }
        } else { preferenceAdmissionBusy = true }
    }

    private func releasePreferenceAdmission() {
        if preferenceAdmissionWaiters.isEmpty { preferenceAdmissionBusy = false }
        else { preferenceAdmissionWaiters.removeFirst().resume() }
    }

    func admitPreferenceIntent(_ intent: ScoringPreferenceIntent,
                               allowing: @escaping @Sendable () -> Bool,
                               at: (@Sendable (ScoringInputJournal.PreferenceCommitPoint) -> Void)? = nil,
                               atMaintenance: ((PreferenceMaintenancePoint) async -> Void)? = nil) async throws -> ScoringPreferenceAdmission {
        await acquirePreferenceAdmission()
        defer { releasePreferenceAdmission() }
        guard current, intent.context == context else { throw ScoringInputJournal.Failure.retired }
        try Task.checkCancellation()
        guard allowing() else { throw ScoringInputJournal.Failure.held }
        // The caller already captured its ordered permit. Never relay and acquire a newer one here.
        let journal = try await readyJournal()
        guard current else { throw ScoringInputJournal.Failure.retired }
        let allows = dependencies.allowsChange
        let permitted: @Sendable () -> Bool = {
            allowing() && (intent.profile.map(allows) ?? true) && (intent.config.map(allows) ?? true)
        }
        let receipt: ScoringPreferenceAdmission
        do { receipt = try await journal.admitPreferenceIntent(intent, allowing: permitted, at: at) }
        catch ScoringInputJournal.Failure.storageLimit {
            // Try exact replay before maintenance. A failed admission has no receipt to compact.
            await atMaintenance?(.beforeCompaction)
            guard current else { throw ScoringInputJournal.Failure.retired }
            try Task.checkCancellation()
            guard permitted() else { throw ScoringInputJournal.Failure.held }
            let removed = try await journal.compactPreferenceIntents(limit: 128)
            await atMaintenance?(.afterCompaction)
            guard current else { throw ScoringInputJournal.Failure.retired }
            try Task.checkCancellation()
            guard permitted() else { throw ScoringInputJournal.Failure.held }
            guard removed > 0 else { throw ScoringInputJournal.Failure.storageLimit }
            receipt = try await journal.admitPreferenceIntent(intent, allowing: permitted, at: at)
        }
        // A later cancellation/status refresh cannot turn a committed receipt into rejection.
        if current {
            if let next = try? await journal.status(), current { status = next }
            reconcile()
        }
        return receipt
    }

    /// Called only by the owner-bound consent relay, without recursively invoking admission.
    func importOrigin(_ id: UUID, change: ScoringInputChange,
                      position: ScoringInputJournal.OriginPosition,
                      denialPurpose: ScoringContextPurpose? = nil) async throws -> ScoringInputJournal.OriginProgress {
        guard current else { throw ScoringInputJournal.Failure.retired }
        let journal = try await readyJournal()
        guard current else { throw ScoringInputJournal.Failure.retired }
        return try await journal.importOrigin(id, change: change, position: position, denialPurpose: denialPurpose)
    }

    func retireOrigin(_ id: UUID, change: ScoringInputChange, position: ScoringInputJournal.OriginPosition,
                      receipt: ScoringInputReceipt) async throws {
        guard current else { throw ScoringInputJournal.Failure.retired }
        let journal = try await readyJournal()
        guard current else { throw ScoringInputJournal.Failure.retired }
        try await journal.retireOrigin(id, change: change, position: position, receipt: receipt)
    }

    private func prepareDrain() async throws {
        do { try await prepareAdmission?() }
        catch ScoringInputJournal.Failure.relayCapacity {
            // Only capacity pressure permits this bypass, and only for already durable rows.
            // Fresh enqueue still requires a successful relay and its generation-bound permit.
        }
    }

    @discardableResult
    func reconcile() -> Task<Void, Never>? {
        guard current else { return nil }
        guard operation == nil else { reconcileRequested = true; return operation }
        reconcileRequested = false
        let id = UUID()
        operationID = id
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.operationID == id {
                    self.operation = nil; self.operationID = nil
                    if self.reconcileRequested, self.current, self.dependencies.canUpload() { self.reconcile() }
                }
            }
            do {
                try await self.prepareDrain()
                guard self.current, !Task.isCancelled else { return }
                let journal = try await self.readyJournal()
                let status = try await journal.status()
                guard self.current, !Task.isCancelled else { return }
                self.status = status
                for _ in 0..<8 {
                    guard self.current, !Task.isCancelled, self.dependencies.canUpload() else { return }
                    if let request = try await journal.initialHeadRequest(now: self.dependencies.now(), allowing: self.dependencies.allowsChange) {
                        do {
                            let head = try await self.dependencies.head(request.change, self.context)
                            guard self.current, !Task.isCancelled, self.dependencies.canUpload() else { return }
                            try await journal.freezeInitialHead(head, for: request, allowing: self.dependencies.allowsChange)
                        } catch {
                            guard self.current, !Task.isCancelled else { return }
                            if error as? ScoringInputRPC.Failure == .held { continue }
                            try await journal.retry(request, conflict: false, now: self.dependencies.now())
                            guard self.current, !Task.isCancelled else { return }
                            self.lastError = "Scoring input head lookup is pending. Saved edits are retained."
                            continue
                        }
                    }
                    let next: ScoringInputJournal.Pending
                    do {
                        guard let ready = try await journal.next(now: self.dependencies.now(), requireKnownHead: true,
                                                               allowing: self.dependencies.allowsChange) else { return }
                        next = ready
                    } catch ScoringInputJournal.Failure.headRequired { continue }
                    guard self.current, !Task.isCancelled, self.dependencies.canUpload() else { return }
                    guard self.dependencies.allowsChange(next.change) else { continue }
                    do {
                        let receipt = try await self.dependencies.send(next, self.context)
                        guard self.current, !Task.isCancelled else { return }
                        try await journal.settle(next, receipt: receipt)
                        guard self.current, !Task.isCancelled else { return }
                        self.lastError = nil
                        self.dependencies.didSettle(receipt)
                    } catch {
                        guard self.current, !Task.isCancelled else { return }
                        if error as? ScoringInputRPC.Failure == .held { continue }
                        let conflict: Bool
                        switch error {
                        case ScoringInputRPC.Failure.conflict, ScoringInputRPC.Failure.rejected: conflict = true
                        default: conflict = false
                        }
                        try await journal.retry(next, conflict: conflict, now: self.dependencies.now())
                        guard self.current, !Task.isCancelled else { return }
                        self.lastError = conflict
                            ? "A scoring input needs review. The pending edit is retained."
                            : "Scoring input upload is pending. Saved edits are retained."
                    }
                    let status = try await journal.status()
                    guard self.current, !Task.isCancelled else { return }
                    self.status = status
                    try await self.prepareDrain()
                }
            } catch {
                guard self.current, !Task.isCancelled else { return }
                self.lastError = "Scoring input storage is unavailable. Existing edits were not discarded."
            }
        }
        return operation
    }

    func policyChanged() {
        if !dependencies.canUpload() {
            operation?.cancel()
            reconcileRequested = false
        } else { reconcile() }
    }

    func conflicts(limit: Int = 32) async throws -> [ScoringInputJournal.Conflict] {
        let journal = try await readyJournal()
        let conflicts = try await journal.conflicts(limit: limit)
        guard current else { throw ScoringInputJournal.Failure.retired }
        return conflicts
    }

    func reviewConflict(id: String) async throws -> ConflictReview {
        let journal = try await readyJournal()
        guard let conflict = try await journal.conflict(id: id) else { throw ScoringInputJournal.Failure.staleReview }
        guard current, dependencies.canUpload() else { throw ScoringInputRPC.Failure.unavailable }
        guard dependencies.allowsChange(conflict.pending.change) else { throw ScoringInputRPC.Failure.held }
        let head = try await dependencies.head(conflict.pending.change, context)
        try Task.checkCancellation()
        guard current else { throw ScoringInputJournal.Failure.retired }
        guard head.matches(scope: context.scope, change: conflict.pending.change) else { throw ScoringInputJournal.Failure.invalidReceipt }
        return ConflictReview(context: context, conflict: conflict, head: head)
    }

    /// Caller explicitly chooses the replacement after reviewing every queued intent and head.
    /// New arrivals invalidate the review; normal reconciliation never invokes resolution.
    func resolveConflict(_ review: ConflictReview, replacement: ScoringInputChange) async throws {
        guard current, review.context == context else { throw ScoringInputJournal.Failure.retired }
        guard dependencies.allowsChange(replacement) else { throw ScoringInputJournal.Failure.held }
        let journal = try await readyJournal()
        try Task.checkCancellation()
        guard current else { throw ScoringInputJournal.Failure.retired }
        guard dependencies.allowsChange(replacement) else { throw ScoringInputJournal.Failure.held }
        _ = try await journal.resolveConflict(review.conflict, head: review.head, replacement: replacement,
                                              allowing: dependencies.allowsChange)
        let status = try await journal.status()
        guard current else { return }
        self.status = status
        reconcile()
    }

    func retire() {
        guard active else { return }
        writeFence.invalidate()
        prepareAdmission = nil
        captureAdmission = nil
        active = false; operation?.cancel(); operation = nil; operationID = nil
        reconcileRequested = false
        let opened = journal
        let preparing = preparation
        journal = nil; preparation = nil
        retirement = Task {
            try await opened?.close()
            if let prepared = try? await preparing?.task.value { try await prepared.close() }
        }
        status = .init(pending: 0, conflicts: 0); lastError = nil
    }

    /// Resource owners can await the actual SQLite close before deleting a fixture or storage.
    /// Ordinary retirement still fences synchronously and never deletes durable account debt.
    func waitForRetirement() async throws {
        retire()
        try await retirement?.value
    }
}

#if !SCORING_INPUT_NATIVE_TESTS
extension ScoringInputRPC.Dependencies {
    static func live(context: AccountSessionContext, allowsChange: @escaping @Sendable (ScoringInputChange) -> Bool) -> Self {
        Self(anonKey: { ServerScoringSettings.anonKey() }, authorize: {
            let session = try await CloudAuthClient.authorizedSession()
            return .init(context: session.context, accessToken: session.accessToken)
        }, isCurrent: { CloudAuthClient.isCurrent($0) }, canUpload: { CloudPushSettings.ready }, request: {
            try await ScoringInputTransport.perform($0, context: context, isCurrent: { CloudAuthClient.isCurrent($0) })
        }, allowsChange: allowsChange)
    }
}

extension ScoringInputCoordinator.Dependencies {
    static func live(context: AccountSessionContext,
                     allowsChange: @escaping @Sendable (ScoringInputChange) -> Bool = {
                         [.profile, .config, .sleepEdit].contains($0.kind)
                     }, nativePreferenceCurrent: @escaping @Sendable (AccountSessionContext) -> Bool = {
                         CloudAuthClient.isCurrent($0)
                     }) -> Self {
        Self(isCurrent: { nativePreferenceCurrent($0) }, canUpload: {
                guard CloudPushSettings.ready else { return false }
                #if os(iOS)
                return CloudPushNetworkPolicy.isNetworkAvailable(wifiOnly: CloudPushSettings.wifiOnly)
                #else
                return true
                #endif
            }, openJournal: { layout, fence in
                // CloudAuthClient delegates to the NSRecursiveLock-protected identity controller.
                // This native DB predicate must not capture a MainActor-only runtime callback.
                try ScoringInputJournal(layout: layout, fence: fence, preferenceContext: context,
                    isPreferenceContextCurrent: nativePreferenceCurrent)
            }, head: { try await ScoringInputRPC.head($0, context: $1, dependencies: .live(context: $1, allowsChange: allowsChange)) },
            send: { try await ScoringInputRPC.send($0, context: $1, dependencies: .live(context: $1, allowsChange: allowsChange)) }, didSettle: { _ in
                NotificationCenter.default.post(name: ServerScoreRepository.refreshRequested, object: nil)
            }, allowsChange: allowsChange)
    }
}

extension ScoringInputCoordinator {
    convenience init(context: AccountSessionContext, layout: AccountStorageLayout,
                     allowsChange: @escaping @Sendable (ScoringInputChange) -> Bool = {
                         [.profile, .config, .sleepEdit].contains($0.kind)
                     }) {
        self.init(context: context, layout: layout, dependencies: .live(context: context, allowsChange: allowsChange))
    }
}
#endif
