import Foundation
import NoopPush

struct CloudRotationCheckpoint: Codable, Equatable, Sendable {
    let index: Int
    let carryMore: Bool
    let deviceListFingerprint: String?
    let laneIndex: Int?
    let recoveryIndex: Int?
    init(index: Int, carryMore: Bool, deviceListFingerprint: String? = nil,
         laneIndex: Int? = nil, recoveryIndex: Int? = nil) {
        self.index = index; self.carryMore = carryMore; self.deviceListFingerprint = deviceListFingerprint
        self.laneIndex = laneIndex; self.recoveryIndex = recoveryIndex
    }
}

struct CloudUploadPolicy: Sendable {
    var concurrency: Int
    var allowsCellular: Bool
    var allowsConstrained: Bool
    var cancelTransfers = false

    static func current(wifiOnly: Bool, enabled: Bool = true, resourceBudget: ResourceBudget = .shared) -> Self {
        let state = ProcessInfo.processInfo.thermalState
        let limit = enabled ? resourceBudget.snapshot(for: .cloudTransfer).maximumTransfers : 0
        return .init(concurrency: limit, allowsCellular: !wifiOnly, allowsConstrained: !wifiOnly,
                     cancelTransfers: !enabled || state == .critical)
    }
}

/// The coordinator owns source cursors. This actor owns only immutable transfer bytes and receipts.
/// An HTTP success never deletes a file or advances a source cursor.
actor CloudUploadQueue {
    struct PresentationStatus: Sendable {
        enum PauseReason: Sendable { case authentication, compatibleEncoding, terminal }
        let pendingJobs: Int
        let pendingSelections: Int
        let transferringJobs: Int
        let pausedReason: PauseReason?
        let lastVerifiedReceipt: Date?
        let retryAt: Date?
    }
    typealias Authorize = @Sendable (AccountSessionContext) async throws -> String
    typealias Current = @Sendable (AccountSessionContext) -> Bool
    private let context: AccountSessionContext
    private let journal: CloudUploadJournal
    private let adapter: any CloudUploadSessionAdapter
    private let authorize: Authorize
    private let fleetToken: @Sendable () -> String?
    private let isCurrent: Current
    private let policy: @Sendable () -> CloudUploadPolicy
    private let resourceBudget: ResourceBudget
    private let control: @Sendable (URLRequest) async throws -> PushTransportResponse
    private let now: @Sendable () -> Date
    private let randomUnit: @Sendable () -> Double
    private let refreshCredentials: (@Sendable (AccountSessionContext) async throws -> Void)?
    private var jobs: [String: CloudUploadJob]
    private var controlOutcomes: [String: CloudControlOutcome]
    private var controlsInFlight: Set<String> = []
    private let budgetOwner = UUID()
    private var lastVerifiedReceiptAt: Date?
    private var waiters: [String: [UUID: CheckedContinuation<PushTransportResponse, Error>]] = [:]
    private var pumping = false
    private var reconciled = false
    private var reconciling = false
    private var reconciliationRequested = false
    private var suspended = false
    private var binaryPreparation: PushBinaryPreparation?
    private var cancellingTasks: Set<Int> = []
    private struct OrdinaryLease { let attempt: UUID; let opportunity: ResourceBudget.Opportunity; let deadline: TimeInterval }
    private var ordinaryLeases: [String: OrdinaryLease] = [:]
    private var ordinaryWatchdogs: [String: Task<Void, Never>] = [:]
    private var ordinaryIntervals: [String: SyncPipelineTrace.Interval] = [:]
    private var cancelledOrdinaryAttempts: Set<UUID> = []
    private var opportunityObserver: NSObjectProtocol?
    private var opportunityJoins: [UUID: (Set<UUID>, CheckedContinuation<Void, Never>)] = [:]
    private struct SavedOutcomeError: Error { let underlying: Error }
    private struct CleanupBatch: Hashable {
        let receiverStateID: String
        let batchID: String
    }

    init(context: AccountSessionContext, layout: AccountStorageLayout,
         adapter: any CloudUploadSessionAdapter, authorize: @escaping Authorize,
         isCurrent: @escaping Current, policy: @escaping @Sendable () -> CloudUploadPolicy,
         control: @escaping @Sendable (URLRequest) async throws -> PushTransportResponse,
         maximumBytes: Int = 1_073_741_824, now: @escaping @Sendable () -> Date = { Date() },
         journalWriteObserver: (@Sendable (URL) throws -> Void)? = nil,
         randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
         refreshCredentials: (@Sendable (AccountSessionContext) async throws -> Void)? = nil,
         fleetToken: @escaping @Sendable () -> String? = { nil },
         resourceBudget: ResourceBudget = .shared) throws {
        guard layout.scope == context.scope else { throw CloudUploadError.staleOwner }
        self.context = context
        self.adapter = adapter
        self.authorize = authorize
        self.fleetToken = fleetToken
        self.isCurrent = isCurrent
        self.policy = policy
        self.resourceBudget = resourceBudget
        self.control = control
        self.now = now
        self.randomUnit = randomUnit
        self.refreshCredentials = refreshCredentials
        journal = try CloudUploadJournal(directory: layout.uploadDirectory, maximumBytes: maximumBytes,
            afterWrite: journalWriteObserver, resourceBudget: resourceBudget)
        try journal.loadSelections(owner: context.scope)
        try journal.recoverBinaryPreparations()
        jobs = try journal.load()
        controlOutcomes = try journal.loadControlOutcomes(owner: context.scope)
        lastVerifiedReceiptAt = try journal.receiptCheckpoint(owner: context.scope)
        guard jobs.values.allSatisfy({ $0.owner == context.scope }) else { throw CloudUploadError.staleOwner }
        // Pending refresh remains durable retry debt. On the next admitted opportunity compare
        // the submitted credential digest with the current scoped credential before refreshing.
        // The account controller may have persisted a rotation before this process stopped.
        // Earlier builds collapsed an interrupted refresh into terminal auth without a credential
        // version. Migrate only that recognized state once; every subsequent attempt uses the digest
        // fence. Other ambiguous terminal outcomes remain retained for explicit resolution.
        if refreshCredentials != nil {
            for var job in jobs.values where job.phase == .pausedTerminal && job.operation != .objectPut &&
                job.responseDisposition == .authentication && job.authenticationRefreshCount == 1 &&
                job.credentialVersion == nil && (job.legacyAuthenticationRecoveryCount ?? 0) == 0 {
                job.legacyAuthenticationRecoveryCount = 1
                job.phase = .retryPending; job.authenticationRefreshPending = true
                job.nextAttemptAt = job.nextAttemptAt ?? now()
                try journal.save(job); jobs[job.id] = job
            }
            for var value in controlOutcomes.values where value.paused && value.disposition == .authentication &&
                value.authenticationRefreshCount == 1 && value.credentialVersion == nil &&
                (value.legacyAuthenticationRecoveryCount ?? 0) == 0 {
                value.legacyAuthenticationRecoveryCount = 1
                value.paused = false; value.authenticationRefreshPending = true
                value.nextAttemptAt = value.nextAttemptAt ?? now()
                try journal.saveControlOutcome(value); controlOutcomes[value.id] = value
            }
        }
        for job in jobs.values {
            if let id = job.preparedSelectionID {
                guard let selection = journal.selectionIndex[id], let state = journal.continuations[id],
                      selection.jobIDs(state).contains(job.id), !job.acknowledged || state.sourceCommitted else {
                    throw CloudUploadError.corruptJournal
                }
            }
        }
        let pending = jobs.values.filter { !$0.acknowledged }
        resourceBudget.queuedCloud(owner: budgetOwner,
            bytes: pending.reduce(0) { $0 + $1.payloadBytes }, jobs: pending.count)
        opportunityObserver = NotificationCenter.default.addObserver(forName: ResourceBudget.changed, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.cancelExpiredOrdinaryTransfers() }
        }
    }

    private func check(_ captured: AccountSessionContext) throws {
        guard !suspended, captured == context, isCurrent(captured) else { throw CloudUploadError.staleOwner }
    }

    deinit {
        if let opportunityObserver { NotificationCenter.default.removeObserver(opportunityObserver) }
        for task in ordinaryWatchdogs.values { task.cancel() }
        resourceBudget.queuedCloud(owner: budgetOwner, bytes: 0, jobs: 0)
    }

    /// Join only attempts already admitted for this event, never future arrivals or other owners.
    /// The original watchdog deadline releases the join even if OS cancellation acknowledgement lags.
    func finishOpportunityTransfers(_ opportunity: ResourceBudget.Opportunity) async {
        guard !suspended, isCurrent(context), resourceBudget.isCurrent(opportunity) else { return }
        let attempts = Set(ordinaryLeases.values.filter { $0.opportunity.id == opportunity.id }.map(\.attempt))
        guard !attempts.isEmpty else { return }
        await withCheckedContinuation { opportunityJoins[UUID()] = (attempts, $0) }
    }

    private func finishOrdinaryLease(_ id: String, outcome: SyncPipelineTrace.Outcome = .cancelled) {
        if let interval = ordinaryIntervals.removeValue(forKey: id) { SyncPipelineTrace.end(interval, outcome: outcome) }
        ordinaryWatchdogs.removeValue(forKey: id)?.cancel()
        ordinaryLeases.removeValue(forKey: id)
        let active = Set(ordinaryLeases.values.map(\.attempt))
        for (key, value) in opportunityJoins where value.0.isDisjoint(with: active) {
            opportunityJoins.removeValue(forKey: key); value.1.resume()
        }
    }

    private func cancelOrdinary(_ id: String, attempt: UUID, timedOut: Bool = false) {
        guard !suspended, var job = jobs[id], job.phase == .transferring,
              job.transportKind == .ordinary, job.attempt == attempt else { finishOrdinaryLease(id); return }
        cancelledOrdinaryAttempts.insert(attempt)
        job.ordinaryCancellationRequested = true
        // Stop the real task even if the journal is temporarily unwritable. The in-memory attempt
        // fence also rejects a response racing that write; a cold process cannot resurrect this session.
        if let task = job.taskIdentifier { cancellingTasks.insert(task); adapter.cancel(task) }
        try? commit(job)
        finishOrdinaryLease(id, outcome: timedOut ? .timedOut : .cancelled)
    }

    private func cancelExpiredOrdinaryTransfers() {
        guard !suspended else { return }
        for (id, lease) in ordinaryLeases where !resourceBudget.isCurrent(lease.opportunity) ||
            ProcessInfo.processInfo.systemUptime >= lease.deadline ||
            !resourceBudget.permits(jobs[id]?.operation == .objectComplete ? .cloudControl : .cloudTransfer) {
            cancelOrdinary(id, attempt: lease.attempt, timedOut: ProcessInfo.processInfo.systemUptime >= lease.deadline)
        }
    }

    private func armOrdinary(_ job: CloudUploadJob, opportunity: ResourceBudget.Opportunity, deadline: TimeInterval) -> Bool {
        guard let attempt = job.attempt else { return false }
        ordinaryLeases[job.id] = OrdinaryLease(attempt: attempt, opportunity: opportunity, deadline: deadline)
        let remaining = min(resourceBudget.remainingDuration(for: opportunity) ?? 0,
                            deadline - ProcessInfo.processInfo.systemUptime)
        guard remaining > 0 else { cancelOrdinary(job.id, attempt: attempt, timedOut: ProcessInfo.processInfo.systemUptime >= deadline); return false }
        ordinaryWatchdogs[job.id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            catch { return }
            await self?.cancelOrdinary(job.id, attempt: attempt, timedOut: true)
        }
        return true
    }

    private func publishQueuePressure() {
        guard !suspended else { return }
        let pending = jobs.values.filter { !$0.acknowledged }
        resourceBudget.queuedCloud(owner: budgetOwner,
            bytes: pending.reduce(0) { $0 + $1.payloadBytes }, jobs: pending.count)
    }

    /// Account-fenced presentation contains no payload, account or device identifiers.
    /// Reading it performs no storage access and does not treat transfer success as durability.
    func presentationStatus(captured: AccountSessionContext) throws -> PresentationStatus {
        try check(captured)
        var pending = 0, transferring = 0
        var reason: PresentationStatus.PauseReason?
        for job in jobs.values where !job.acknowledged {
            pending += 1
            if job.phase == .transferring { transferring += 1 }
            if job.phase == .pausedTerminal {
                if job.responseDisposition == .authentication { reason = .authentication }
                else if reason == nil { reason = .terminal }
            }
        }
        for control in controlOutcomes.values where control.paused {
            if control.disposition == .authentication { reason = .authentication }
            else if control.receiverCode == "compatible_encoder_required", reason != .authentication { reason = .compatibleEncoding }
            else if reason == nil { reason = .terminal }
        }
        return .init(pendingJobs: pending,
            pendingSelections: journal.continuations.values.filter { !$0.sourceCommitted }.count,
            transferringJobs: transferring, pausedReason: reason,
            lastVerifiedReceipt: lastVerifiedReceiptAt, retryAt: try nextWakeDate(captured: captured))
    }

    func pausedMessage(captured: AccountSessionContext) throws -> String? {
        try check(captured)
        let paused = jobs.values.filter { $0.phase == .pausedTerminal && !$0.acknowledged }
        let pausedControls = controlOutcomes.values.filter(\.paused)
        guard !paused.isEmpty || !pausedControls.isEmpty else { return nil }
        if paused.contains(where: { $0.responseDisposition == .authentication }) ||
            pausedControls.contains(where: { $0.disposition == .authentication }) {
            return "Cloud sync paused for authentication. Local data is retained."
        }
        if pausedControls.contains(where: { $0.receiverCode == "compatible_encoder_required" }) {
            return "Retained cloud data needs a compatible app upgrade"
        }
        return "Cloud sync paused for a server or receipt error. Local data is retained; retry after resolution."
    }

    func rotationCheckpoint(namespace: String, captured: AccountSessionContext) throws -> CloudRotationCheckpoint {
        try check(captured)
        let name = try rotationName(namespace)
        guard let bytes = try journal.metadata.read(name) else { return .init(index: 0, carryMore: false) }
        guard bytes.count <= 4096 else { throw CloudUploadError.corruptJournal }
        let value = try JSONDecoder().decode(CloudRotationCheckpoint.self, from: bytes)
        guard value.index >= 0, value.index <= 1_000_000,
              value.laneIndex.map({ (0...1_000_000).contains($0) }) ?? true,
              value.recoveryIndex.map({ (0...1_000_000).contains($0) }) ?? true,
              Self.validRotationFingerprint(value.deviceListFingerprint) else { throw CloudUploadError.corruptJournal }
        return value
    }
    func saveRotationCheckpoint(namespace: String, index: Int, carryMore: Bool,
                                deviceListFingerprint: String? = nil, laneIndex: Int? = nil,
                                recoveryIndex: Int? = nil, captured: AccountSessionContext) throws {
        try check(captured)
        guard index >= 0, index <= 1_000_000,
              laneIndex.map({ (0...1_000_000).contains($0) }) ?? true,
              recoveryIndex.map({ (0...1_000_000).contains($0) }) ?? true,
              Self.validRotationFingerprint(deviceListFingerprint) else { throw CloudUploadError.invalidRequest }
        let name = try rotationName(namespace)
        let bytes = try JSONEncoder().encode(CloudRotationCheckpoint(index: index, carryMore: carryMore,
                                                                   deviceListFingerprint: deviceListFingerprint,
                                                                   laneIndex: laneIndex, recoveryIndex: recoveryIndex))
        try journal.metadata.transaction { try journal.metadata.put(name, data: bytes) }
    }
    private static func validRotationFingerprint(_ value: String?) -> Bool {
        guard let value else { return true } // Legacy pair restarts at zero in the coordinator.
        return value.utf8.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    private func rotationName(_ namespace: String) throws -> String {
        guard namespace.utf8.count == 64, namespace.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw CloudUploadError.invalidRequest }
        return AccountScope.digest("rotation-v1\u{0}" + context.scope.namespace + "\u{0}" + namespace) + ".rotation"
    }

    func beginBinaryPreparation(maximumWireBytes: Int, captured: AccountSessionContext) throws -> PushBinaryPreparation {
        try check(captured)
        guard binaryPreparation == nil, resourceBudget.permits(.cloudPreparation) else { throw CloudUploadError.retryScheduled }
        try journal.recoverBinaryPreparations()
        let value = try journal.beginBinaryPreparation(maximumWireBytes: maximumWireBytes)
        binaryPreparation = value
        return value
    }

    func finishBinaryPreparation(_ value: PushBinaryPreparation, captured: AccountSessionContext) throws {
        guard captured == context else { throw CloudUploadError.staleOwner }
        guard !suspended else { return } // A new runtime recovers the recorded scratch lease.
        guard binaryPreparation?.id == value.id else { throw CloudUploadError.invalidRequest }
        defer { binaryPreparation = nil }
        try journal.finishBinaryPreparation(value)
    }

    private func preparationID(_ lane: PushPreparationLane, receiverStateID: String) throws -> String {
        guard UUID(uuidString: lane.sourceID) != nil, !lane.table.isEmpty, lane.table.utf8.count <= 128,
              !lane.deviceID.isEmpty, lane.deviceID.utf8.count <= 1024,
              !receiverStateID.isEmpty, receiverStateID.utf8.count <= 256 else { throw CloudUploadError.invalidRequest }
        return AccountScope.digest(["source-preparation-v1", context.scope.namespace, receiverStateID,
            lane.sourceID, lane.table, lane.deviceID].joined(separator: "\u{0}"))
    }

    func isPreparationPaused(_ lane: PushPreparationLane, receiverStateID: String,
                             captured: AccountSessionContext) throws -> Bool {
        try check(captured)
        return controlOutcomes[try preparationID(lane, receiverStateID: receiverStateID)]?.paused == true
    }

    func pausePreparation(_ lane: PushPreparationLane, receiverStateID: String,
                          captured: AccountSessionContext) throws {
        try check(captured)
        let id = try preparationID(lane, receiverStateID: receiverStateID)
        guard controlOutcomes[id]?.paused != true else { return }
        var value = controlOutcomes[id] ?? CloudControlOutcome(id: id, owner: context.scope)
        value.paused = true; value.disposition = .terminal; value.receiverCode = "compatible_encoder_required"
        value.nextAttemptAt = nil; value.failures += 1
        try saveControl(value)
    }

    func lastVerifiedReceiptDate(captured: AccountSessionContext) throws -> Date? {
        try check(captured)
        return lastVerifiedReceiptAt
    }

    private func recordVerifiedReceipt(_ receipt: PushDurabilityReceipt) throws {
        guard receipt.isValid, let date = PushDurabilityReceipt.date(receipt.indexedAt) else { throw CloudUploadError.invalidReceipt }
        if let lastVerifiedReceiptAt, lastVerifiedReceiptAt >= date { return }
        try journal.saveReceiptCheckpoint(owner: context.scope, at: date)
        lastVerifiedReceiptAt = date
    }

    private func retireControl(for job: CloudUploadJob) throws {
        let id = AccountScope.digest("intent\u{0}" + job.id)
        guard controlOutcomes[id] != nil else { return }
        try journal.removeControlOutcome(id)
        controlOutcomes[id] = nil
    }

    func capabilities(endpoint: String, captured: AccountSessionContext) async throws -> PushCapabilitiesResult {
        try check(captured)
        try validateEndpoint(endpoint)
        var request = URLRequest(url: URL(string: endpoint)!)
        request.setValue(PushProtocol.capabilitiesAcceptVersions, forHTTPHeaderField: CloudPushTransport.acceptVersionHeader)
        let response = try await performControl(id: AccountScope.digest("capabilities\u{0}" + endpoint),
            request: request, version: PushProtocol.version) { response in
                _ = try AccountVerifiedCapabilities.parse(response.body, scope: captured.scope)
            }
        return .available(try AccountVerifiedCapabilities.parse(response.body, scope: captured.scope))
    }

    func initialObjectIntent(_ manifest: PushObjectManifest, lane: PushObjectLane, endpoint: String,
                             receiverStateID: String, captured: AccountSessionContext) async throws -> PushObjectIntent {
        try check(captured)
        try validateEndpoint(endpoint)
        let id = try objectID(endpoint: endpoint, objectID: manifest.objectId, receiverStateID: receiverStateID)
        if let job = jobs[id] {
            if let bytes = job.manifest {
                guard try JSONDecoder().decode(PushObjectManifest.self, from: bytes) == manifest else { throw CloudUploadError.changedPayload }
            }
            if job.phase == .pausedTerminal { throw pausedFailure(job) }
            if let date = job.nextAttemptAt, date > now() { throw CloudUploadError.retryScheduled }
            if let saved = try savedPreparedIntent(manifest, endpoint: endpoint, receiverStateID: receiverStateID, captured: captured) { return saved }
            if !job.needsNewIntent, let key = job.objectKey, let url = job.signedURL,
               job.signedExpiry.map({ $0 > now().addingTimeInterval(30) }) == true {
                return .init(objectId: manifest.objectId, objectKey: key, uploadUrl: url,
                    requiredHeaders: job.signedHeaders, expiresAt: nil, duplicate: false)
            }
        }
        var placeholder = jobs[id] ?? CloudUploadJob(id: id, owner: context.scope, generation: context.generation,
            endpoint: endpoint, deviceID: manifest.deviceId, createdAt: now(), operation: .objectPut, method: "PUT", headers: [:])
        placeholder.lanePath = lane.endpoint
        var request = URLRequest(url: try apiURL(placeholder, completion: false, intent: true))
        request.httpMethod = "POST"
        request.httpBody = try manifest.encode()
        guard request.httpBody!.count <= 8 * 1024 else { throw CloudUploadError.invalidRequest }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response: PushTransportResponse
        do {
            response = try await performControl(id: AccountScope.digest("intent\u{0}" + id), request: request,
                version: manifest.protocolVersion) { response in
                    _ = try PushObjectIntent.parse(response.body, expectedObjectId: manifest.objectId, expectedVersion: manifest.protocolVersion)
                }
        } catch let error as PushTransportException {
            if error.failure.receiverCode == "object_id_conflict", jobs[id]?.preparedSelectionID != nil {
                try recordPreparedConflict(manifest, endpoint: endpoint, receiverStateID: receiverStateID, captured: captured)
                let controlID = AccountScope.digest("intent\u{0}" + id)
                if var value = controlOutcomes[controlID] {
                    value.paused = false; value.nextAttemptAt = nil
                    try saveControl(value)
                }
            }
            throw error
        }
        let intent = try PushObjectIntent.parse(response.body, expectedObjectId: manifest.objectId, expectedVersion: manifest.protocolVersion)
        try recordIntent(manifest, lane: lane, intent: intent, endpoint: endpoint, captured: captured, receiverStateID: receiverStateID)
        return intent
    }

    private func saveControl(_ value: CloudControlOutcome) throws {
        do {
            try journal.saveControlOutcome(value)
            controlOutcomes[value.id] = value
            #if os(iOS)
            CloudPushBackgroundScheduler.scheduleIfNeeded()
            #endif
        } catch {
            if let saved = try? journal.loadControlOutcomes(owner: context.scope) { controlOutcomes = saved }
            throw error
        }
    }

    private func performControl(id: String, request original: URLRequest, version: String,
                                validate: @Sendable (PushTransportResponse) throws -> Void) async throws -> PushTransportResponse {
        try check(context)
        guard controlsInFlight.insert(id).inserted else { throw CloudUploadError.retryScheduled }
        defer { controlsInFlight.remove(id) }
        var value = controlOutcomes[id] ?? CloudControlOutcome(id: id, owner: context.scope)
        guard policy().concurrency > 0, resourceBudget.permits(.cloudControl) else { throw CloudUploadError.retryScheduled }
        if value.paused {
            guard value.disposition == .authentication, let rejected = value.credentialVersion else { throw controlFailure(value) }
            let current = try await authorize(context)
            try check(context)
            guard credentialVersion(current) != rejected else { throw controlFailure(value) }
            value.paused = false; value.authenticationRefreshCount = 0
            value.authenticationRefreshPending = false; value.authenticationRejectedVersion = nil
            value.authenticationRefreshedVersion = nil; value.nextAttemptAt = nil
            try saveControl(value)
        }
        if let date = value.nextAttemptAt, date > now() { throw CloudUploadError.retryScheduled }
        guard policy().concurrency > 0, resourceBudget.permits(.cloudControl) else { throw CloudUploadError.retryScheduled }
        var token: String
        do {
            token = try await authorize(context)
            try check(context)
            if value.authenticationRefreshPending {
                if value.authenticationRejectedVersion == nil { value.authenticationRejectedVersion = credentialVersion(token) }
                value.credentialVersion = credentialVersion(token)
                guard let refreshCredentials else { throw AccountAuthError.signedOut }
                if value.authenticationRejectedVersion == nil || value.authenticationRejectedVersion == credentialVersion(token) {
                    try saveControl(value) // Keep debt pending across both sides of the refresh await.
                    try await refreshCredentials(context)
                    try check(context)
                    token = try await authorize(context)
                    try check(context)
                }
                value.authenticationRefreshPending = false
                value.authenticationRefreshedVersion = credentialVersion(token)
                try saveControl(value)
            }
            value.credentialVersion = credentialVersion(token)
        } catch {
            try check(context)
            if Self.terminalAuthorization(error) {
                value.paused = true; value.authenticationRefreshPending = false
                value.disposition = .authentication; value.nextAttemptAt = nil
            } else {
                value.disposition = value.authenticationRefreshPending ? .authentication : .retryable
                controlBackoff(&value)
            }
            try saveControl(value)
            throw error
        }
        var request = original
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let fleet = fleetToken(), !fleet.isEmpty {
            request.setValue(fleet, forHTTPHeaderField: CloudPushTransport.fleetTokenHeader)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try check(context)
        let admission = policy()
        guard admission.concurrency > 0, resourceBudget.permits(.cloudControl) else { throw CloudUploadError.retryScheduled }
        request.allowsCellularAccess = admission.allowsCellular
        request.allowsExpensiveNetworkAccess = admission.allowsCellular
        request.allowsConstrainedNetworkAccess = admission.allowsConstrained
        let response: PushTransportResponse
        do { response = try await control(request) }
        catch {
            try check(context)
            value.responseAttempt = UUID()
            value.responseValidated = false
            value.status = nil; value.retryAfter = nil
            if (error as? CloudUploadError) == .responseTooLarge {
                value.paused = true; value.disposition = .terminal; value.receiverCode = "response_too_large"
                value.failures += 1; value.nextAttemptAt = nil
            } else {
                value.disposition = .retryable; value.receiverCode = nil
                controlBackoff(&value)
            }
            try saveControl(value)
            throw error
        }
        try check(context)
        value.responseAttempt = UUID()
        value.status = response.statusCode
        value.retryAfter = response.retryAfter.map { String($0.prefix(128)) }
        value.receiverCode = PushError.parseCode(response.body, expectedVersion: version)
        value.responseValidated = false
        if response.body.count > PushProtocolLimits.maxAckBytes {
            value.paused = true; value.disposition = .terminal; value.receiverCode = "response_too_large"
            value.failures += 1; value.nextAttemptAt = nil
        } else if !(200...299).contains(response.statusCode) {
            let failure = PushFailure.http(status: response.statusCode, receiverCode: value.receiverCode)
            if failure.code == .httpAuth, value.authenticationRefreshedVersion != value.credentialVersion,
               value.authenticationRefreshCount == 0, refreshCredentials != nil {
                value.authenticationRejectedVersion = value.credentialVersion
                value.authenticationRefreshCount = 1; value.authenticationRefreshPending = true
                value.disposition = .authentication; controlBackoff(&value)
            } else if failure.retryable {
                value.disposition = .retryable; controlBackoff(&value)
            } else {
                value.paused = true; value.disposition = failure.code == .httpAuth ? .authentication : .terminal
                value.failures += 1; value.nextAttemptAt = nil
            }
        } else {
            do {
                try validate(response)
                value.responseValidated = true; value.disposition = .verified
                value.failures = 0; value.nextAttemptAt = nil; value.authenticationRefreshCount = 0
                value.authenticationRejectedVersion = nil; value.authenticationRefreshedVersion = nil
            } catch {
                value.paused = true; value.disposition = .terminal; value.receiverCode = "response_invalid"
                value.failures += 1; value.nextAttemptAt = nil
            }
        }
        try saveControl(value)
        guard value.responseValidated else { throw controlFailure(value) }
        return response
    }

    private func controlFailure(_ value: CloudControlOutcome) -> PushTransportException {
        if value.receiverCode == "response_invalid" || value.receiverCode == "response_too_large" {
            return .init(.init(code: .ackInvalid))
        }
        return .init(PushFailure.http(status: value.status ?? 503, receiverCode: value.receiverCode))
    }

    private func controlBackoff(_ value: inout CloudControlOutcome) {
        var bridge = CloudUploadJob(id: value.id, owner: context.scope, generation: context.generation,
            endpoint: "", deviceID: "", createdAt: now(), operation: .request, method: "GET", headers: [:])
        bridge.failures = value.failures; bridge.responseRetryAfter = value.retryAfter
        backoff(&bridge)
        value.failures = bridge.failures; value.nextAttemptAt = bridge.nextAttemptAt
    }

    func resumePaused(captured: AccountSessionContext) async throws {
        try check(captured)
        for var value in controlOutcomes.values where value.paused {
            value.paused = false; value.nextAttemptAt = nil; value.disposition = nil
            value.authenticationRefreshCount = 0; value.authenticationRefreshPending = false
            value.authenticationRejectedVersion = nil; value.authenticationRefreshedVersion = nil
            try saveControl(value)
        }
        for id in jobs.values.filter({ $0.phase == .pausedTerminal }).map(\.id) {
            try await resumePaused(jobID: id, captured: captured)
        }
    }

    /// Transferring tasks already belong to URLSession; terminal records need explicit resolution.
    func nextWakeDate(captured: AccountSessionContext) throws -> Date? {
        try check(captured)
        let controlDates = controlOutcomes.values.filter { !$0.paused }.compactMap(\.nextAttemptAt)
        let jobDates = jobs.values.filter {
            !$0.acknowledged && $0.phase != .pausedTerminal && $0.phase != .transferring &&
                ($0.phase != .responseSaved || (200...299).contains($0.responseStatus ?? 0)) && mayDeliver($0)
        }.map { $0.nextAttemptAt ?? $0.createdAt }
        return (controlDates + jobDates).min()
    }

    static func objectJobID(endpoint: String, objectID: String, receiverStateID: String = "") -> String {
        AccountScope.digest("object-v1\u{0}\(endpoint)\u{0}\(receiverStateID)\u{0}\(objectID)")
    }

    func prepareSelection(_ value: CloudPushPreparedSelection, captured: AccountSessionContext,
                          beforeFreshAdmission: @Sendable () throws -> Void = {}) throws {
        try check(captured)
        guard value.owner == context.scope else { throw CloudUploadError.staleOwner }
        let isFresh = journal.selectionIndex[value.id] == nil
        // Saved receipt debt can drain a full queue during history. Only new preparation consumes
        // preparation headroom; exact existing selections retain their original byte authority.
        guard resourceBudget.permits(isFresh ? .cloudPreparation : .cloudControl) else { throw CloudUploadError.retryScheduled }
        let legacyJobs = jobs.values.filter { $0.preparedSelectionID == nil }.count
        // This synchronous actor-local boundary precedes any new reservation/body publication.
        // An exact existing reservation (including interrupted publication) keeps its original
        // authority. reserve still verifies its immutable bytes; it is not a new preference claim.
        if isFresh { try beforeFreshAdmission() }
        try journal.reserve(value, legacyJobs: legacyJobs)
        guard let saved = try journal.selection(value.id), var state = journal.continuations[value.id], !state.sourceCommitted else {
            throw CloudUploadError.corruptJournal
        }
        if state.published {
            // A conflict successor ID is durable before its body/metadata publication. Only that
            // explicit second attempt can fill a missing job; missing original jobs stay retained.
            if let object = try saved.selection.restoredObject(), state.objectIDs.count == 2,
               let last = state.objectIDs.last,
               jobs[saved.jobID(batchID: object.batch.batchId, representation: "object", objectID: last)] == nil {
                try admitPreparedIntent(object.manifest.replacingObjectId(last), endpoint: saved.endpoint,
                    receiverStateID: saved.receiverStateID, captured: captured)
            }
            try verifyPublished(saved, state: state); return
        }
        if let object = try saved.selection.restoredObject() {
            for objectID in state.objectIDs {
                let id = saved.jobID(batchID: object.batch.batchId, representation: "object", objectID: objectID)
                var job = jobs[id] ?? preparedJob(saved, id: id, operation: .objectPut, headers: [:])
                job.manifest = objectID == object.manifest.objectId ? saved.selection.objectIntentBytes
                    : try object.manifest.replacingObjectId(objectID).encode()
                job.objectID = objectID; job.batchID = object.batch.batchId; job.lanePath = object.lane.endpoint
                job.completionMode = object.lane.completionMode
                try prepare(object.batch, job: &job); try commit(job)
            }
        } else {
            for (index, batch) in try saved.selection.restoredInlineBatches().enumerated() {
                for representation in ["gzip", "identity"] {
                    let id = saved.jobID(batchID: batch.batchId, representation: representation)
                    var headers = ["Content-Type": "application/x-ndjson; charset=utf-8"]
                    if representation == "gzip" { headers["Content-Encoding"] = "gzip" }
                    var job = jobs[id] ?? preparedJob(saved, id: id, operation: .request, headers: headers)
                    job.batchID = batch.batchId
                    try prepare(representation == "gzip" ? saved.inlineGzip[index] : batch.body, job: &job)
                    try commit(job)
                }
            }
        }
        state.published = true
        try journal.saveContinuation(state)
    }

    /// Rechecked before encoding/reserving new bytes and immediately before scheduling a transfer.
    /// Tests may inject a deterministic environment; production always defaults to the shared budget.
    func checkBulkAdmission(captured: AccountSessionContext) throws {
        try check(captured)
        guard resourceBudget.permits(.bulk) else { throw CloudUploadError.retryScheduled }
    }

    /// A synchronous preparation hint avoids introducing a new suspension before preference
    /// validation. The actor still rechecks the same budget at reservation and transfer boundaries.
    nonisolated func permitsBulkPreparation() -> Bool { resourceBudget.permits(.bulk) }

    private func verifyPublished(_ saved: CloudPushPreparedSelection, state: CloudPreparedContinuation) throws {
        func verify(_ id: String, byteCount: Int, digest: String) throws {
            guard let job = jobs[id], job.preparedSelectionID == saved.id, job.owner == saved.owner,
                  job.endpoint == saved.endpoint, job.receiverStateID == saved.receiverStateID,
                  job.payloadBytes == byteCount, job.payloadSHA256 == digest else { throw CloudUploadError.changedPayload }
            try journal.verifyBody(job)
        }
        if let object = try saved.selection.restoredObject() {
            for objectID in state.objectIDs { try verify(saved.jobID(batchID: object.batch.batchId, representation: "object", objectID: objectID), byteCount: object.batch.wireBytes, digest: object.batch.wireSHA256) }
        } else {
            for (index, batch) in try saved.selection.restoredInlineBatches().enumerated() {
                try verify(saved.jobID(batchID: batch.batchId, representation: "gzip"), byteCount: saved.inlineGzip[index].count, digest: CloudUploadJournal.digest(saved.inlineGzip[index]))
                try verify(saved.jobID(batchID: batch.batchId, representation: "identity"), byteCount: batch.body.count, digest: CloudUploadJournal.digest(batch.body))
            }
        }
    }

    private func preparedJob(_ value: CloudPushPreparedSelection, id: String,
                             operation: CloudUploadJob.Operation, headers: [String: String]) -> CloudUploadJob {
        var job = CloudUploadJob(id: id, owner: context.scope, generation: context.generation,
            endpoint: value.endpoint, deviceID: value.selection.deviceID, createdAt: now(), operation: operation,
            method: operation == .objectPut ? "PUT" : "POST", headers: headers)
        job.preparedSelectionID = value.id; job.deliveryAdmitted = false
        job.localVersion = 2
        job.receiverStateID = value.receiverStateID; job.correlation = value.correlation
        return job
    }

    func preparedSelectionIDs(sourceID: String, endpoint: String, receiverStateID: String,
                              captured: AccountSessionContext) throws -> [String] {
        try check(captured)
        return journal.selectionIndex.values.filter { $0.matches(owner: context.scope, sourceID: sourceID,
            endpoint: endpoint, receiverStateID: receiverStateID) }.map(\.id).sorted()
    }

    /// Compact lane membership for fair recovery; this does not deserialize sensor payloads.
    func pendingPreparedLanes(sourceID: String, endpoint: String, receiverStateID: String,
                              captured: AccountSessionContext) throws -> [PushPendingLane] {
        try check(captured)
        return journal.selectionIndex.values.filter {
            $0.matches(owner: context.scope, sourceID: sourceID, endpoint: endpoint, receiverStateID: receiverStateID)
                && journal.continuations[$0.id]?.sourceCommitted == false
        }.sorted { $0.id < $1.id }.map {
            PushPendingLane(selectionID: $0.id, kind: $0.commit.kind, table: $0.commit.table, deviceID: $0.commit.deviceID)
        }
    }

    func selectionID(batchID: String, sourceID: String, endpoint: String, receiverStateID: String,
                     captured: AccountSessionContext) throws -> String {
        try check(captured)
        let candidates = journal.selectionIndex.values.filter { $0.matches(owner: context.scope, sourceID: sourceID,
            endpoint: endpoint, receiverStateID: receiverStateID) && $0.commit.batchIDs.contains(batchID) }
        guard candidates.count == 1 else { throw CloudUploadError.invalidRequest }
        return candidates[0].id
    }

    func preparedInline(_ batch: PushBatch, endpoint: String, receiverStateID: String,
                        captured: AccountSessionContext) throws -> (selectionID: String, gzip: Data) {
        let id = try selectionID(batchID: batch.batchId, sourceID: batch.sourceId, endpoint: endpoint,
            receiverStateID: receiverStateID, captured: captured)
        guard let saved = try journal.selection(id), journal.continuations[id]?.published == true,
              let index = saved.commit.batchIDs.firstIndex(of: batch.batchId),
              try saved.selection.restoredInlineBatches()[index].body == batch.body else { throw CloudUploadError.changedPayload }
        return (id, saved.inlineGzip[index])
    }

    /// Runs before an intent request, including the one explicitly permitted conflict successor.
    func admitPreparedIntent(_ manifest: PushObjectManifest, endpoint: String, receiverStateID: String,
                             captured: AccountSessionContext) throws {
        let id = try selectionID(batchID: manifest.batchId, sourceID: manifest.sourceId, endpoint: endpoint,
            receiverStateID: receiverStateID, captured: captured)
        guard let saved = try journal.selection(id), var state = journal.continuations[id], state.published,
              !state.sourceCommitted, let object = try saved.selection.restoredObject(),
              object.manifest.replacingObjectId(manifest.objectId) == manifest else { throw CloudUploadError.changedPayload }
        if !state.objectIDs.contains(manifest.objectId) {
            guard state.objectIDs.count == 1, state.conflictedObjectIDs.contains(state.objectIDs[0]) else { throw CloudUploadError.invalidRequest }
            state.objectIDs.append(manifest.objectId)
            try journal.saveContinuation(state) // ID is burned locally before any request can use it.
        }
        guard state.objectIDs.last == manifest.objectId, !state.conflictedObjectIDs.contains(manifest.objectId) else { throw CloudUploadError.retryScheduled }
        let jobID = saved.jobID(batchID: manifest.batchId, representation: "object", objectID: manifest.objectId)
        if jobs[jobID] == nil {
            var job = preparedJob(saved, id: jobID, operation: .objectPut, headers: [:])
            job.manifest = try manifest.encode(); job.objectID = manifest.objectId
            job.batchID = manifest.batchId; job.lanePath = object.lane.endpoint
            job.completionMode = object.lane.completionMode
            try prepare(object.batch, job: &job); try commit(job)
        }
    }

    func recordPreparedConflict(_ manifest: PushObjectManifest, endpoint: String, receiverStateID: String,
                                captured: AccountSessionContext) throws {
        let id = try selectionID(batchID: manifest.batchId, sourceID: manifest.sourceId, endpoint: endpoint,
            receiverStateID: receiverStateID, captured: captured)
        guard var state = journal.continuations[id], state.objectIDs.last == manifest.objectId else { throw CloudUploadError.invalidRequest }
        state.conflictedObjectIDs.insert(manifest.objectId)
        try journal.saveContinuation(state)
    }

    func resumeManifest(selectionID: String, captured: AccountSessionContext) throws -> PushObjectManifest? {
        try check(captured)
        guard let saved = try journal.selection(selectionID), let state = journal.continuations[selectionID] else { throw CloudUploadError.corruptJournal }
        guard let object = try saved.selection.restoredObject() else { return nil }
        guard let last = state.objectIDs.last else { throw CloudUploadError.corruptJournal }
        if state.conflictedObjectIDs.contains(last) {
            guard state.objectIDs.count == 1 else { throw CloudUploadError.invalidRequest }
            let manifest = object.manifest.replacingObjectId(PushProtocol.freshObjectId())
            try admitPreparedIntent(manifest, endpoint: saved.endpoint, receiverStateID: saved.receiverStateID, captured: captured)
            return manifest
        }
        return object.manifest.replacingObjectId(last)
    }

    func savedPreparedIntent(_ manifest: PushObjectManifest, endpoint: String, receiverStateID: String,
                             captured: AccountSessionContext) throws -> PushObjectIntent? {
        try check(captured)
        let id = try objectID(endpoint: endpoint, objectID: manifest.objectId, receiverStateID: receiverStateID)
        guard let job = jobs[id], job.preparedSelectionID != nil, let bytes = job.manifest,
              try JSONDecoder().decode(PushObjectManifest.self, from: bytes) == manifest else { return nil }
        if let ack = try savedReceipt(job) {
            return .init(objectId: ack.objectId, objectKey: ack.objectKey, uploadUrl: nil,
                requiredHeaders: [:], expiresAt: nil, duplicate: true)
        }
        if job.phase == .uploaded || job.operation == .objectComplete {
            guard let key = job.objectKey else { throw CloudUploadError.corruptJournal }
            return .init(objectId: manifest.objectId, objectKey: key, uploadUrl: nil,
                requiredHeaders: [:], expiresAt: nil, duplicate: true)
        }
        return nil
    }

    private func objectID(endpoint: String, objectID: String, receiverStateID: String) throws -> String {
        let matches = jobs.values.filter { $0.endpoint == endpoint && $0.objectID == objectID && $0.receiverStateID == receiverStateID && $0.preparedSelectionID != nil }
        guard matches.count <= 1 else { throw CloudUploadError.corruptJournal }
        return matches.first?.id ?? Self.objectJobID(endpoint: endpoint, objectID: objectID, receiverStateID: receiverStateID)
    }

    func preparedSelection(_ id: String, captured: AccountSessionContext) throws -> CloudPushPreparedSelection {
        try check(captured)
        guard resourceBudget.permits(.cloudControl) else { throw CloudUploadError.retryScheduled }
        guard let value = try journal.selection(id) else { throw CloudUploadError.corruptJournal }
        return value
    }

    func checkSelectionEncodingAdmission(captured: AccountSessionContext) throws {
        try check(captured)
        guard resourceBudget.permits(.cloudPreparation) else { throw CloudUploadError.retryScheduled }
    }

    func checkIntentAdmission(captured: AccountSessionContext) throws {
        try check(captured)
        guard policy().concurrency > 0, resourceBudget.permits(.cloudControl) else { throw CloudUploadError.retryScheduled }
    }

    func preparedIntentBody(_ manifest: PushObjectManifest, endpoint: String, receiverStateID: String,
                            captured: AccountSessionContext) throws -> Data {
        try check(captured)
        let id = try objectID(endpoint: endpoint, objectID: manifest.objectId, receiverStateID: receiverStateID)
        guard let job = jobs[id], job.preparedSelectionID != nil, let body = job.manifest,
              try JSONDecoder().decode(PushObjectManifest.self, from: body) == manifest else { throw CloudUploadError.changedPayload }
        return body
    }

    private func mayDeliver(_ job: CloudUploadJob) -> Bool {
        guard let id = job.preparedSelectionID else { return true }
        guard job.deliveryAdmitted == true, let saved = journal.selectionIndex[id], let state = journal.continuations[id],
              state.published, !state.sourceCommitted else { return false }
        if let objectID = job.objectID { return state.objectIDs.last == objectID && !state.conflictedObjectIDs.contains(objectID) }
        guard let batchID = job.batchID, let index = saved.commit.batchIDs.firstIndex(of: batchID) else { return false }
        for prior in saved.commit.batchIDs.prefix(index) {
            let ids = ["gzip", "identity"].map { saved.jobID(batchID: prior, representation: $0) }
            guard ids.contains(where: { jobs[$0].map(hasCleanupReceipt) == true }) else { return false }
        }
        if job.headers["Content-Encoding"] != "gzip" {
            let gzip = jobs[saved.jobID(batchID: batchID, representation: "gzip")]
            return gzip?.phase == .responseSaved && gzip?.responseStatus == 415
        }
        return true
    }

    /// Authority is the exact selection reference atomically staged with the full-group commit.
    func preparedSourceCommitted(selectionID: String, captured: AccountSessionContext) throws {
        try check(captured)
        guard let saved = journal.selectionIndex[selectionID], var state = journal.continuations[selectionID] else {
            // Retirement may have completed before the progress-store debt was settled.
            return
        }
        let ids = saved.jobIDs(state)
        guard !ids.contains(where: { jobs[$0]?.phase == .transferring }) else { throw CloudUploadError.retryScheduled }
        state.sourceCommitted = true
        try journal.saveContinuation(state) // Group marker precedes EVERY unlink.
        for id in ids {
            if var job = jobs[id] {
                guard job.preparedSelectionID == selectionID else { throw CloudUploadError.corruptJournal }
                job.acknowledged = true; try commit(job); try retireControl(for: job)
                try journal.removeCommitted(job); jobs[id] = nil
            }
        }
    }

    func retireSelection(_ id: String, captured: AccountSessionContext) throws {
        try check(captured)
        guard !jobs.values.contains(where: { $0.preparedSelectionID == id }) else { throw CloudUploadError.invalidReceipt }
        try journal.retireSelection(id)
    }

    func recordIntent(_ manifest: PushObjectManifest, lane: PushObjectLane, intent: PushObjectIntent,
                      endpoint: String, captured: AccountSessionContext, receiverStateID: String = "") throws {
        try check(captured)
        try validateEndpoint(endpoint)
        guard intent.objectId == manifest.objectId else { throw CloudUploadError.invalidReceipt }
        let id = try objectID(endpoint: endpoint, objectID: intent.objectId, receiverStateID: receiverStateID)
        let encoded = try jobs[id]?.manifest ?? manifest.encode()
        guard try JSONDecoder().decode(PushObjectManifest.self, from: encoded) == manifest else { throw CloudUploadError.changedPayload }
        var job = jobs[id] ?? CloudUploadJob(id: id, owner: context.scope, generation: context.generation,
            endpoint: endpoint, deviceID: "", createdAt: now(), operation: .objectPut, method: "PUT", headers: [:])
        if let prior = job.manifest {
            guard prior == encoded, intent.duplicate || job.objectKey == nil || job.objectKey == intent.objectKey else { throw CloudUploadError.changedPayload }
        }
        // A retry keeps its captured mode even if a new capability document changes.
        if jobs[id] == nil { job.completionMode = lane.completionMode }
        // Replaying an intent must not erase an in-flight attempt or a durable receipt.
        guard job.phase != .receiptSaved, job.phase != .transferring else { return }
        job.manifest = encoded
        job.receiverStateID = receiverStateID
        job.batchID = manifest.batchId
        job.objectID = intent.objectId
        job.correlation = job.correlation ?? UUID(uuidString: intent.objectId) ?? UUID()
        // A duplicate intent names an archive key, never a new PUT target. Completion validates it.
        if !intent.duplicate { job.objectKey = intent.objectKey }
        job.lanePath = lane.endpoint
        let signedVersion = Self.intentVersion(url: intent.uploadUrl, headers: intent.requiredHeaders, expiry: intent.expiresAt)
        if job.signedIntentVersion != signedVersion { job.signedURLRenewalCount = 0 }
        job.signedIntentVersion = signedVersion
        job.signedURL = intent.uploadUrl
        job.signedHeaders = intent.requiredHeaders
        job.signedExpiry = Self.expiry(intent.expiresAt)
        job.needsNewIntent = false
        job.deliveryAdmitted = true
        if intent.duplicate { job.phase = .uploaded; job.operation = .objectComplete }
        try commit(job)
    }

    func uploadObject(endpoint: String, objectID: String, body: Data,
                      captured: AccountSessionContext, receiverStateID: String = "") async throws {
        try check(captured)
        let id = try self.objectID(endpoint: endpoint, objectID: objectID, receiverStateID: receiverStateID)
        guard var job = jobs[id] else { throw CloudUploadError.invalidRequest }
        try prepare(body, job: &job)
        try commit(job)
        if job.phase == .uploaded || job.phase == .receiptSaved || job.operation == .objectComplete { return }
        _ = try await wait(id, captured: captured, acceptUploaded: true)
    }

    func uploadObject(endpoint: String, objectID: String, file: PushImmutablePayloadFile,
                      captured: AccountSessionContext, receiverStateID: String = "") async throws {
        try check(captured)
        let id = try self.objectID(endpoint: endpoint, objectID: objectID, receiverStateID: receiverStateID)
        guard var job = jobs[id] else { throw CloudUploadError.invalidRequest }
        try journal.persistBody(file, job: &job); try commit(job)
        if job.phase == .uploaded || job.phase == .receiptSaved || job.operation == .objectComplete { return }
        _ = try await wait(id, captured: captured, acceptUploaded: true)
    }

    func completeObject(endpoint: String, objectID: String,
                        captured: AccountSessionContext, receiverStateID: String = "") async throws -> PushObjectAck {
        try check(captured)
        let id = try self.objectID(endpoint: endpoint, objectID: objectID, receiverStateID: receiverStateID)
        guard let job = jobs[id] else { throw CloudUploadError.invalidRequest }
        if let ack = try savedReceipt(job) { return ack }
        guard job.phase == .uploaded || job.operation == .objectComplete else { throw CloudUploadError.retryScheduled }
        _ = try await wait(id, captured: captured)
        try check(captured)
        guard let current = jobs[id], let ack = try savedReceipt(current) else { throw CloudUploadError.invalidReceipt }
        return ack
    }

    func request(endpoint: String, body: Data, headers: [String: String],
                 captured: AccountSessionContext, receiverStateID: String = "", batchID: String? = nil,
                 selectionID: String? = nil) async throws -> PushTransportResponse {
        try check(captured)
        try validateEndpoint(endpoint)
        guard !headers.keys.contains(where: { ["authorization", "cookie"].contains($0.lowercased()) }) else {
            throw CloudUploadError.invalidRequest
        }
        let headerData = try JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys])
        let id: String
        if let selectionID {
            guard let saved = try journal.selection(selectionID), saved.endpoint == endpoint, saved.receiverStateID == receiverStateID,
                  let batchID, saved.commit.batchIDs.contains(batchID), journal.continuations[selectionID]?.published == true else { throw CloudUploadError.invalidRequest }
            id = saved.jobID(batchID: batchID, representation: headers["Content-Encoding"] == "gzip" ? "gzip" : "identity")
            guard jobs[id]?.headers == headers else { throw CloudUploadError.changedPayload }
        } else {
            id = AccountScope.digest("request-v1\u{0}\(endpoint)\u{0}\(receiverStateID)\u{0}\(CloudUploadJournal.digest(body))\u{0}\(CloudUploadJournal.digest(headerData))")
        }
        var job = jobs[id] ?? CloudUploadJob(id: id, owner: context.scope, generation: context.generation,
            endpoint: endpoint, deviceID: "", createdAt: now(), operation: .request, method: "POST", headers: headers)
        job.receiverStateID = receiverStateID
        job.batchID = batchID
        job.deliveryAdmitted = true
        guard mayDeliver(job) else { throw CloudUploadError.retryScheduled }
        try prepare(body, job: &job)
        try commit(job)
        if job.phase == .responseSaved, let response = job.response { return response }
        return try await wait(id, captured: captured)
    }

    /// Integration hook: call ONLY after the coordinator durably saves the exact source cursor or
    /// replacement-window commit. HTTP acceptance alone is not authorization to invoke this.
    func sourceCommitted(batchID: String, receiverStateID: String, captured: AccountSessionContext) throws {
        try check(captured)
        let matching = jobs.values.filter { $0.preparedSelectionID == nil && $0.batchID == batchID && $0.receiverStateID == receiverStateID }
        // Replay includes a crash after all exact-batch unlinks but before debt settlement.
        if matching.isEmpty { return }
        guard matching.contains(where: { hasCleanupReceipt($0) }) else {
            throw CloudUploadError.invalidReceipt
        }
        try markCleanup(matching)
        for original in matching {
            guard let job = jobs[original.id] else { continue }
            try journal.removeCommitted(job)
            jobs.removeValue(forKey: job.id)
        }
    }

    private func markCleanup(_ matching: [CloudUploadJob]) throws {
        guard !matching.contains(where: { $0.phase == .transferring }) else { throw CloudUploadError.retryScheduled }
        // Mark every representation (for example gzip plus identity fallback) before unlinking any
        // receipt. On restart, one committed marker authorizes finishing this exact scoped batch.
        for var job in matching where !job.acknowledged {
            job.acknowledged = true
            try commit(job)
        }
    }

    private func recoverCleanupMarkers() throws {
        let committed = Set(jobs.values.compactMap { job -> CleanupBatch? in
            guard job.preparedSelectionID == nil, job.acknowledged, let batchID = job.batchID else { return nil }
            return CleanupBatch(receiverStateID: job.receiverStateID, batchID: batchID)
        })
        for batch in committed {
            try markCleanup(jobs.values.filter { $0.preparedSelectionID == nil && $0.batchID == batch.batchID && $0.receiverStateID == batch.receiverStateID })
        }
    }

    private func hasCleanupReceipt(_ job: CloudUploadJob) -> Bool {
        if job.operation == .objectComplete { return (try? savedReceipt(job)) != nil }
        guard job.operation == .request, job.phase == .responseSaved,
              (200...299).contains(job.responseStatus ?? 0), let body = job.responseBody,
              let ack = try? PushAck.parse(body) else { return false }
        // Full batch equality is checked by the coordinator before the cursor commit hook.
        return ack.batchId == job.batchID && ack.status == "accepted" && ack.acceptedRows >= 0
            && job.validatedReceipt?.isValid == true && ack.durabilityReceipt == job.validatedReceipt
    }

    /// Only a saved successful response reaches receipt validation. HTTP accounting happens once in receive.
    func validateResponse(batch: PushBatch, response: PushTransportResponse, captured: AccountSessionContext,
                          receiverStateID: String, selectionID: String? = nil) throws {
        try check(captured)
        guard (200...299).contains(response.statusCode) else {
            throw PushTransportException(PushFailure.http(status: response.statusCode, receiverCode: PushError.parseCode(response.body)))
        }
        let matching = jobs.values.filter { $0.batchID == batch.batchId && $0.receiverStateID == receiverStateID
            && $0.preparedSelectionID == selectionID && $0.operation == .request && $0.responseBody == response.body && $0.responseStatus == response.statusCode }
        let ack = try? PushAck.parse(response.body)
        let valid = (200...299).contains(response.statusCode) && ack?.exactlyMatches(batch) == true
            && ack?.durabilityReceipt?.matches(batch, owner: context.scope) == true
        for var job in matching {
            if valid { job.validatedReceipt = ack?.durabilityReceipt; job.responseDisposition = .verified }
            else if job.responseDisposition != .terminal {
                job.phase = .pausedTerminal; job.validatedReceipt = nil
                job.responseDisposition = .terminal; job.responseCode = "receipt_mismatch"
                job.failures += 1; job.nextAttemptAt = nil
            }
            try commit(job)
        }
        guard valid, !matching.isEmpty else { throw PushTransportException(PushFailure(code: .ackInvalid)) }
        if let receipt = ack?.durabilityReceipt { try recordVerifiedReceipt(receipt) }
    }

    private func prepare(_ batch: PushBinaryBatch, job: inout CloudUploadJob) throws {
        if let file = batch.payloadFile { try journal.persistBody(file, job: &job) }
        else { try prepare(batch.payload, job: &job) }
    }

    private func prepare(_ body: Data, job: inout CloudUploadJob) throws {
        job.correlation = job.correlation ?? job.batchID.flatMap(UUID.init(uuidString:)) ?? UUID()
        let interval = SyncPipelineTrace.begin(.uploadPreparation, correlation: job.correlation!)
        var outcome = SyncPipelineTrace.Outcome.failed
        defer { SyncPipelineTrace.end(interval, outcome: outcome) }
        do { try journal.persistBody(body, job: &job); outcome = .succeeded }
        catch CloudUploadError.storageFull { outcome = .storageFull; throw CloudUploadError.storageFull }
    }

    /// Call on launch and every authorized wake. Never enumerate an unassigned/other-owner directory.
    func reconcile() async throws {
        try check(context)
        publishQueuePressure()
        guard !reconciling, !pumping else {
            reconciliationRequested = true
            if policy().cancelTransfers { try cancelKnownTransfers() }
            return
        }
        reconciliationRequested = false
        reconciling = true
        defer { reconciling = false; scheduleRequestedReconciliation() }
        let tasks = await adapter.tasks()
        try check(context)
        cancellingTasks.formIntersection(tasks.map(\.identifier))
        let admission = policy()
        var claimed: Set<Int> = []
        try recoverCleanupMarkers()
        // Inspect current credentials once for a paused receiver cohort; do not force refresh per job.
        // A changed scoped credential may recover an old denial, but it is never a receipt.
        var currentCredentialVersion: String?
        if jobs.values.contains(where: { $0.phase == .pausedTerminal && $0.operation != .objectPut &&
            $0.responseDisposition == .authentication && $0.credentialVersion != nil }),
           admission.concurrency > 0, resourceBudget.permits(.cloudControl) {
            if let token = try? await authorize(context) { currentCredentialVersion = credentialVersion(token) }
            try check(context)
        }
        for var job in jobs.values {
            if job.acknowledged {
                try retireControl(for: job)
                try journal.removeCommitted(job)
                jobs.removeValue(forKey: job.id)
                continue
            }
            job.generation = context.generation
            if job.phase == .pausedTerminal, job.operation != .objectPut,
               job.responseDisposition == .authentication, let rejected = job.credentialVersion,
               let currentCredentialVersion, currentCredentialVersion != rejected {
                job.phase = .retryPending; job.nextAttemptAt = nil
                job.authenticationRefreshCount = 0; job.authenticationRefreshPending = false
                job.authenticationRejectedVersion = nil; job.authenticationRefreshedVersion = nil
            }
            // Build 365 correctly retained rows when the older receiver returned an otherwise
            // matching 2xx ACK without a durability receipt, but those jobs became terminal. After
            // the receiver upgrade, replay those exact persisted bytes once. A second legacy ACK
            // stays terminal, so this cannot become an unbounded relaunch loop.
            if job.operation == .request, job.phase == .pausedTerminal,
               job.responseCode == "receipt_mismatch", (job.receiptUpgradeRetryCount ?? 0) == 0,
               let status = job.responseStatus, (200...299).contains(status),
               let body = job.responseBody, let ack = try? PushAck.parse(body),
               ack.durabilityReceipt == nil, ack.batchId == job.batchID,
               ack.deviceId == job.deviceID, ack.status == "accepted" {
                job.receiptUpgradeRetryCount = 1
                job.phase = .retryPending
                job.responseStatus = nil
                job.responseBody = nil
                job.responseRetryAfter = nil
                job.responseCode = nil
                job.responseDisposition = nil
                job.nextAttemptAt = nil
                job.validatedReceipt = nil
            }
            // Build 366 can have a valid upgraded receipt saved locally but reject it because the
            // server preserved an existing owned device UUID instead of the deterministic fallback.
            // Re-present that already durable response once under the registry-aware validator;
            // do not send the health payload over the network again.
            if job.operation == .request, job.phase == .pausedTerminal,
               job.responseCode == "receipt_mismatch", job.receiptUpgradeRetryCount == 1,
               let status = job.responseStatus, (200...299).contains(status),
               let body = job.responseBody, let ack = try? PushAck.parse(body),
               ack.durabilityReceipt?.isValid == true, ack.batchId == job.batchID,
               ack.deviceId == job.deviceID, ack.status == "accepted" {
                job.receiptUpgradeRetryCount = 2
                job.phase = .responseSaved
                job.responseDisposition = .awaitingReceipt
                job.responseCode = nil
                job.nextAttemptAt = nil
                job.validatedReceipt = nil
            }
            // Object-lane jobs from the legacy receiver either lack a receipt or contain the same
            // preserved canonical device UUID. Upgrade a receipt-less completion once; otherwise
            // accept the saved response only after full manifest, digest, owner and object-key checks.
            if job.operation == .objectComplete, job.phase == .pausedTerminal,
               job.responseCode == "receipt_mismatch", let status = job.responseStatus,
               (200...299).contains(status) {
                let savedManifestVersion = job.manifest.flatMap {
                    try? JSONDecoder().decode(PushObjectManifest.self, from: $0).protocolVersion
                } ?? PushProtocol.objectVersion
                if let ack = try? parseReceipt(job), ack.releasesLocalRows {
                    job.verifiedObjectKey = ack.objectKey
                    job.validatedReceipt = ack.durabilityReceipt
                    job.phase = .receiptSaved
                    job.responseDisposition = .verified
                    job.failures = 0
                    job.nextAttemptAt = nil
                } else if (job.receiptUpgradeRetryCount ?? 0) == 0,
                          let body = job.responseBody,
                          let objectID = job.objectID,
                          let ack = try? PushObjectAck.parse(body, expectedObjectId: objectID,
                              expectedVersion: savedManifestVersion),
                          ack.durabilityReceipt == nil {
                    job.receiptUpgradeRetryCount = 1
                    job.phase = .retryPending
                    job.responseStatus = nil
                    job.responseBody = nil
                    job.responseRetryAfter = nil
                    job.responseCode = nil
                    job.responseDisposition = nil
                    job.nextAttemptAt = nil
                    job.validatedReceipt = nil
                }
            }
            // Receiver v12 accepts the older standard-HR wire representation when its monotonic
            // clock is still an exact JSON safe integer. Retry one previously terminal 422 after
            // that bounded compatibility upgrade; any still-invalid payload remains fail-closed.
            if job.operation == .request, job.phase == .pausedTerminal,
               (job.receiptUpgradeRetryCount ?? 0) == 0, job.responseStatus == 422,
               let body = job.responseBody,
               (PushError.parseCode(body, expectedVersion: PushProtocol.binaryVersion) ?? job.responseCode) == "invalid_record" {
                job.receiptUpgradeRetryCount = 1
                job.phase = .retryPending
                job.responseStatus = nil
                job.responseBody = nil
                job.responseRetryAfter = nil
                job.responseCode = nil
                job.responseDisposition = nil
                job.nextAttemptAt = nil
                job.validatedReceipt = nil
            }
            // Retryable 5xx responses may have accumulated a long exponential delay while the
            // receiver or its database schema was unavailable. On the next authorized process
            // start, replay the exact retained bytes once without waiting for that stale delay.
            // Persist the allowance before delivery so repeated relaunches cannot bypass backoff.
            if job.operation == .request, job.phase == .retryPending,
               job.responseDisposition == .retryable,
               (job.serverRetryRecoveryCount ?? 0) == 0,
               let status = job.responseStatus, (500...599).contains(status) {
                job.serverRetryRecoveryCount = 1
                job.nextAttemptAt = nil
            }
            // Recover pre-fleet-header failures once, without changing payloads or receipts.
            if job.operation != .objectPut, job.phase == .pausedTerminal,
               job.responseDisposition == .authentication, job.fleetAuthorizationApplied != true,
               fleetToken()?.isEmpty == false {
                job.fleetAuthorizationApplied = true
                job.phase = .retryPending
                job.responseStatus = nil
                job.responseBody = nil
                job.responseCode = nil
                job.responseDisposition = nil
                job.nextAttemptAt = nil
                job.authenticationRefreshPending = false
            }
            job.correlation = job.correlation ?? (job.objectID ?? job.batchID).flatMap(UUID.init(uuidString:)) ?? UUID()
            if job.phase == .responseSaved, job.operation == .objectComplete,
               let status = job.responseStatus, (200...299).contains(status),
               let ack = try? parseReceipt(job), ack.releasesLocalRows {
                job.phase = .receiptSaved
            }
            if job.phase == .transferring {
                let matching = tasks.filter { $0.description == job.taskDescription &&
                    $0.transportKind == (job.transportKind ?? .background) }
                let networkAllowed = (admission.allowsCellular || job.allowsCellular == false) &&
                    (admission.allowsConstrained || job.allowsConstrained == false)
                if let task = matching.first, job.transportKind == .ordinary,
                   (job.ordinaryCancellationRequested == true || ordinaryLeases[job.id].map {
                       !resourceBudget.isCurrent($0.opportunity) || ProcessInfo.processInfo.systemUptime >= $0.deadline
                   } ?? true) {
                    job.ordinaryCancellationRequested = true
                    if let attempt = job.attempt { cancelledOrdinaryAttempts.insert(attempt) }
                    job.taskIdentifier = task.identifier
                    claimed.insert(task.identifier); cancellingTasks.insert(task.identifier)
                    adapter.cancel(task.identifier); finishOrdinaryLease(job.id)
                } else if let task = matching.first, !admission.cancelTransfers, networkAllowed, mayDeliver(job),
                   !cancellingTasks.contains(task.identifier) {
                    job.taskIdentifier = task.identifier
                    claimed.insert(task.identifier)
                } else {
                    if let attempt = job.attempt { cancelledOrdinaryAttempts.remove(attempt) }
                    job.taskIdentifier = nil; job.attempt = nil; job.phase = .retryPending
                    if job.transportKind == .ordinary { job.ordinaryCancellationRequested = false; finishOrdinaryLease(job.id) }
                }
            }
            try commit(job)
        }
        for task in tasks where !claimed.contains(task.identifier) {
            cancellingTasks.insert(task.identifier)
            adapter.cancel(task.identifier)
        }
        reconciled = true
        for identifier in claimed where !cancellingTasks.contains(identifier) { adapter.resume(identifier) }
        reconciling = false
        await pump()
    }

    private func cancelKnownTransfers() throws {
        let active = jobs.values.filter { $0.phase == .transferring }
        // Cancellation must not wait for credentials, task enumeration, or a successful disk write.
        for job in active {
            if let task = job.taskIdentifier, cancellingTasks.insert(task).inserted { adapter.cancel(task) }
        }
        for var job in active {
            if job.transportKind == .ordinary, let attempt = job.attempt {
                cancelOrdinary(job.id, attempt: attempt)
                continue
            }
            job.taskIdentifier = nil; job.attempt = nil; job.phase = .retryPending
            try commit(job)
        }
    }

    private func scheduleRequestedReconciliation() {
        guard reconciliationRequested, !reconciling, !pumping, !suspended else { return }
        reconciliationRequested = false
        Task { try? await self.reconcile() }
    }

    /// Logout fences callbacks immediately via isCurrent; cancellation never assigns old jobs to a new owner.
    func suspend() {
        suspended = true
        for id in Array(ordinaryLeases.keys) { finishOrdinaryLease(id) }
        resourceBudget.queuedCloud(owner: budgetOwner, bytes: 0, jobs: 0)
        for job in jobs.values { if let task = job.taskIdentifier { adapter.cancel(task) } }
        for id in Array(waiters.keys) { resolve(id, result: .failure(CloudUploadError.staleOwner)) }
        journal.close()
    }

    func receive(_ task: CloudUploadTaskSnapshot, status: Int, body: Data, error: Bool, retryAfter: String? = nil) async {
        if cancellingTasks.remove(task.identifier) != nil {
            if !suspended, isCurrent(context), var cancelled = jobs.values.first(where: {
                $0.phase == .transferring && $0.transportKind == .ordinary &&
                task.transportKind == .ordinary && ($0.taskIdentifier == task.identifier || $0.taskIdentifier == nil) && $0.taskDescription == task.description
            }) {
                if let attempt = cancelled.attempt { cancelledOrdinaryAttempts.remove(attempt) }
                cancelled.taskIdentifier = nil; cancelled.attempt = nil; cancelled.phase = .retryPending
                cancelled.ordinaryCancellationRequested = false
                cancelled.responseStatus = nil; cancelled.responseBody = nil; cancelled.responseRetryAfter = nil
                cancelled.responseCode = nil; cancelled.responseDisposition = .retryable
                backoff(&cancelled)
                try? commit(cancelled)
                finishOrdinaryLease(cancelled.id)
            }
            await pump(); return
        }
        guard reconciled, !suspended, isCurrent(context), let description = task.description,
              var job = jobs.values.first(where: { $0.taskDescription == description }),
              job.generation == context.generation, job.phase == .transferring,
              task.transportKind == (job.transportKind ?? .background),
              job.taskIdentifier == task.identifier || job.taskIdentifier == nil else { return }
        if job.transportKind == .ordinary,
           job.ordinaryCancellationRequested == true || job.attempt.map({ cancelledOrdinaryAttempts.contains($0) }) == true ||
           ordinaryLeases[job.id].map({ !resourceBudget.isCurrent($0.opportunity) || ProcessInfo.processInfo.systemUptime >= $0.deadline }) != false {
            if let attempt = job.attempt { cancelOrdinary(job.id, attempt: attempt) }
            cancellingTasks.insert(task.identifier)
            // This callback itself proves retirement; process it through the cancellation branch.
            await receive(task, status: status, body: Data(), error: true, retryAfter: nil)
            return
        }
        job.correlation = job.correlation ?? (job.objectID ?? job.batchID).flatMap(UUID.init(uuidString:)) ?? UUID()
        let interval = SyncPipelineTrace.begin(.uploadReceipt, correlation: job.correlation!)
        var outcome = SyncPipelineTrace.Outcome.failed
        defer { SyncPipelineTrace.end(interval, outcome: outcome) }
        job.responseAttempt = job.attempt
        job.taskIdentifier = nil; job.attempt = nil
        job.responseStatus = status
        job.responseBody = Data(body.prefix(PushProtocolLimits.maxAckBytes))
        job.responseRetryAfter = retryAfter.map { String($0.prefix(128)) }
        let version = job.manifest.flatMap { try? JSONDecoder().decode(PushObjectManifest.self, from: $0).protocolVersion }
        job.responseCode = PushError.parseCode(body, expectedVersion: version ?? PushProtocol.version)
        var result: Result<PushTransportResponse, Error>
        let response = PushTransportResponse(statusCode: status, body: body, retryAfter: job.responseRetryAfter)
        if (error || status == 0) && body.count <= PushProtocolLimits.maxAckBytes {
            job.responseDisposition = .retryable; job.phase = .retryPending
            backoff(&job)
            result = .failure(PushTransportException(PushFailure(code: .networkIO)))
        } else if body.count > PushProtocolLimits.maxAckBytes {
            pause(&job, code: "response_too_large")
            result = .failure(PushTransportException(PushFailure(code: .ackInvalid)))
        } else if !(200...299).contains(status) {
            let failure = PushFailure.http(status: status, receiverCode: job.responseCode)
            if status == 401 || status == 403 {
                job.responseDisposition = .authentication
                if job.operation == .objectPut {
                    let expired = job.signedExpiry.map({ $0 <= now() }) == true
                    let freshDenials = expired ? 0 : min(2, (job.consecutiveFreshIntentDenials ?? 0) + 1)
                    job.consecutiveFreshIntentDenials = freshDenials
                    if expired || ((job.signedURLRenewalCount ?? 0) == 0 && freshDenials < 2) {
                        job.signedURLRenewalCount = 1
                        job.needsNewIntent = true
                        job.phase = .retryPending
                        backoff(&job)
                    } else { pause(&job, authentication: true) }
                } else if (job.authenticationRefreshCount ?? 0) == 0 {
                    job.authenticationRefreshCount = 1
                    job.authenticationRejectedVersion = job.credentialVersion
                    if refreshCredentials != nil {
                        job.authenticationRefreshPending = true
                        job.phase = .retryPending
                        backoff(&job)
                    } else { pause(&job, authentication: true) }
                } else { pause(&job, authentication: true) }
            } else if failure.retryable {
                job.responseDisposition = .retryable; job.phase = .retryPending
                backoff(&job)
            } else if status == 415 && job.operation == .request {
                // The existing negotiated identity representation is an explicit compatible re-encode.
                job.phase = .responseSaved; job.responseDisposition = .terminal
                job.failures += 1; job.nextAttemptAt = nil
            } else { pause(&job) }
            result = job.operation == .request ? .success(response) : .failure(PushTransportException(failure))
        } else if job.operation == .objectPut {
            job.phase = .uploaded; job.operation = .objectComplete
            job.consecutiveFreshIntentDenials = 0
            job.responseDisposition = .awaitingReceipt
            job.failures = 0; job.nextAttemptAt = nil
            result = .success(response); outcome = .waitingForServer
        } else if job.operation == .objectComplete {
            if let ack = try? parseReceipt(job), ack.releasesLocalRows {
                job.verifiedObjectKey = ack.objectKey; job.validatedReceipt = ack.durabilityReceipt
                job.phase = .receiptSaved; job.responseDisposition = .verified
                job.failures = 0; job.nextAttemptAt = nil
                result = .success(response); outcome = .succeeded
            } else {
                pause(&job, code: "receipt_mismatch")
                result = .failure(PushTransportException(PushFailure(code: .ackInvalid)))
            }
        } else {
            job.phase = .responseSaved; job.responseDisposition = .awaitingReceipt
            job.nextAttemptAt = nil
            result = .success(response); outcome = .pending
        }
        do {
            try commit(job)
            if job.responseDisposition == .verified, let receipt = job.validatedReceipt {
                try recordVerifiedReceipt(receipt)
            }
            resolve(job.id, result: result)
        } catch {
            // Disk failure is not a second HTTP response. Stop admission until a fresh reconciliation.
            reconciled = false
            resolve(job.id, result: .failure(error))
        }
        finishOrdinaryLease(job.id, outcome: outcome)
        await pump()
    }

    private func wait(_ id: String, captured: AccountSessionContext, acceptUploaded: Bool = false) async throws -> PushTransportResponse {
        try check(captured)
        if !reconciled { try await reconcile() }
        try check(captured)
        if let job = jobs[id] {
            if job.phase == .pausedTerminal { throw pausedFailure(job) }
            if job.phase == .receiptSaved || (job.phase == .responseSaved && job.operation == .request),
               let response = job.response { return response }
            if acceptUploaded, job.phase == .uploaded || job.operation == .objectComplete {
                return .init(statusCode: 200, body: Data())
            }
            if let date = job.nextAttemptAt, date > now() { throw CloudUploadError.retryScheduled }
        }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiters[id, default: [:]][waiter] = continuation
                Task { await self.pump() }
            }
        } onCancel: { Task { await self.cancelWaiter(id, waiter: waiter) } }
    }

    private func cancelWaiter(_ id: String, waiter: UUID) {
        waiters[id]?.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
        if waiters[id]?.isEmpty == true { waiters.removeValue(forKey: id) }
    }

    private var transferRotationNamespace: String { AccountScope.digest("transfer-opportunities-v1") }

    // Freshness is an explicit immutable source selection, never a newly created historical job.
    private func transferClass(_ job: CloudUploadJob) -> Int {
        if job.operation == .objectComplete { return 0 }
        if let id = job.preparedSelectionID, journal.continuations[id]?.sourceCommitted == false,
           journal.selectionIndex[id]?.commit.kind.rawValue == "freshAppend" { return 1 }
        return 2
    }
    private func reservesHistoricalSlot(_ job: CloudUploadJob) -> Bool {
        transferClass(job) == 2 && (job.preparedSelectionID != nil || job.operation == .objectPut)
    }
    private func orderedTransferIDs() throws -> [String] {
        var lanes = [[String](), [String](), [String]()]
        for job in jobs.values.sorted(by: { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }) {
            guard job.phase == .prepared || job.phase == .retryPending || job.phase == .uploaded ||
                (job.phase == .responseSaved && job.operation == .objectComplete),
                mayDeliver(job), job.nextAttemptAt.map({ $0 <= now() }) ?? true else { continue }
            lanes[transferClass(job)].append(job.id)
        }
        var cursor = try rotationCheckpoint(namespace: transferRotationNamespace, captured: context).index % 3
        var positions = [0, 0, 0], result: [String] = []
        while let lane = (0..<3).map({ (cursor + $0) % 3 }).first(where: { positions[$0] < lanes[$0].count }) {
            result.append(lanes[lane][positions[lane]])
            positions[lane] += 1; cursor = (lane + 1) % 3
        }
        return result
    }

    private func pump() async {
        guard reconciled, !pumping, !reconciling else { return }
        pumping = true
        defer { pumping = false; scheduleRequestedReconciliation() }
        guard !suspended, isCurrent(context) else { suspend(); return }
        let limit = max(0, min(2, policy().concurrency))
        var active = jobs.values.filter { $0.phase == .transferring }.count + cancellingTasks.count
        var activeHistory = jobs.values.filter { $0.phase == .transferring && reservesHistoricalSlot($0) }.count
        let ordered: [String]
        do { ordered = try orderedTransferIDs() }
        catch { for id in Array(waiters.keys) { resolve(id, result: .failure(error)) }; return }
        for id in ordered {
            guard active < limit else { break }
            guard var job = jobs[id], job.phase == .prepared || job.phase == .retryPending || job.phase == .uploaded ||
                    (job.phase == .responseSaved && job.operation == .objectComplete) else { continue }
            guard mayDeliver(job) else { continue }
            // Keep one of two nominal slots available for fresh data/receipts. Existing OS-owned
            // tasks are never cancelled to manufacture room; a one-slot opportunity rotates fairly.
            if limit > 1, activeHistory >= 1, reservesHistoricalSlot(job) { continue }
            guard job.nextAttemptAt.map({ $0 <= now() }) ?? true else {
                resolve(id, result: .failure(CloudUploadError.retryScheduled)); continue
            }
            if job.operation != .objectComplete && job.payloadName == nil { continue }
            job.correlation = job.correlation ?? (job.objectID ?? job.batchID).flatMap(UUID.init(uuidString:)) ?? UUID()
            let interval = SyncPipelineTrace.begin(.uploadScheduling, correlation: job.correlation!)
            var outcome = SyncPipelineTrace.Outcome.failed
            defer { SyncPipelineTrace.end(interval, outcome: outcome) }
            do {
                try check(context)
                guard resourceBudget.permits(job.operation == .objectComplete ? .cloudControl : .cloudTransfer) else { throw CloudUploadError.retryScheduled }
                var authorizedToken: String?
                if job.authenticationRefreshPending == true {
                    var token = try await authorize(context)
                    try check(context)
                    if job.authenticationRejectedVersion == nil { job.authenticationRejectedVersion = credentialVersion(token) }
                    job.credentialVersion = credentialVersion(token)
                    guard let refreshCredentials else { throw AccountAuthError.signedOut }
                    if job.authenticationRejectedVersion == nil || job.authenticationRejectedVersion == credentialVersion(token) {
                        try commit(job) // Pending debt survives a crash before/after credential rotation.
                        try await refreshCredentials(context)
                        try check(context)
                        token = try await authorize(context)
                        try check(context)
                    }
                    job.authenticationRefreshPending = false
                    job.authenticationRefreshedVersion = credentialVersion(token)
                    job.phase = .retryPending
                    authorizedToken = token
                    try commit(job)
                }
                if job.operation == .objectPut && (job.needsNewIntent || job.signedExpiry.map({ $0 <= now().addingTimeInterval(30) }) == true) {
                    job = try await renewIntent(job)
                }
                var request: URLRequest
                let file: URL
                if job.operation == .objectPut {
                    guard let value = job.signedURL, let url = URL(string: value), url.scheme == "https",
                          url.user == nil, url.password == nil,
                          !job.signedHeaders.keys.contains(where: { ["authorization", "cookie"].contains($0.lowercased()) }) else {
                        throw CloudUploadError.invalidRequest
                    }
                    request = URLRequest(url: url); request.httpMethod = "PUT"
                    for (key, value) in job.signedHeaders { request.setValue(value, forHTTPHeaderField: key) }
                    try journal.verifyBody(job); file = try journal.bodyURL(job)
                } else {
                    let token: String
                    if let authorizedToken { token = authorizedToken }
                    else { token = try await authorize(context) }
                    try check(context)
                    let submittedVersion = credentialVersion(token)
                    if let refreshed = job.authenticationRefreshedVersion, refreshed != submittedVersion {
                        job.authenticationRefreshCount = 0
                        job.authenticationRejectedVersion = nil; job.authenticationRefreshedVersion = nil
                    }
                    job.credentialVersion = submittedVersion
                    request = URLRequest(url: try apiURL(job, completion: job.operation == .objectComplete))
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    for (key, value) in job.headers { request.setValue(value, forHTTPHeaderField: key) }
                    if let fleet = fleetToken(), !fleet.isEmpty {
                        request.setValue(fleet, forHTTPHeaderField: CloudPushTransport.fleetTokenHeader)
                        job.fleetAuthorizationApplied = true
                    }
                    if job.operation == .objectComplete {
                        if let mode = job.completionMode {
                            request.setValue(mode.rawValue, forHTTPHeaderField: "Noop-Push-Completion")
                        }
                        file = try journal.emptyBodyURL()
                    }
                    else { try journal.verifyBody(job); file = try journal.bodyURL(job) }
                }
                try check(context)
                let admission = policy()
                guard admission.concurrency > active,
                      resourceBudget.permits(job.operation == .objectComplete ? .cloudControl : .cloudTransfer) else {
                    throw CloudUploadError.retryScheduled
                }
                request.allowsCellularAccess = admission.allowsCellular
                request.allowsExpensiveNetworkAccess = admission.allowsCellular
                request.allowsConstrainedNetworkAccess = admission.allowsConstrained
                job.allowsCellular = admission.allowsCellular
                job.allowsConstrained = admission.allowsConstrained
                let transferBytes = job.operation == .objectComplete ? 0 : job.payloadBytes
                let opportunity = adapter.supportsOrdinaryTransfers && transferBytes <= 64 * 1024 &&
                    job.ordinaryAttemptOperation != job.operation.rawValue ? resourceBudget.currentOpportunity : nil
                let ordinaryDeadline = ProcessInfo.processInfo.systemUptime + min(2,
                    opportunity.flatMap { resourceBudget.remainingDuration(for: $0) } ?? 0)
                job.transportKind = opportunity == nil ? .background : .ordinary
                job.ordinaryOpportunityID = opportunity?.id
                job.ordinaryCancellationRequested = false
                if opportunity != nil {
                    job.ordinaryAttemptOperation = job.operation.rawValue
                    ordinaryIntervals[job.id] = SyncPipelineTrace.begin(.ordinaryTransfer, correlation: job.correlation!)
                }
                job.generation = context.generation
                job.attempt = UUID(); job.phase = .transferring; job.taskIdentifier = nil
                try commit(job) // Crash between this and task-ID commit is reconciled by taskDescription.
                try saveRotationCheckpoint(namespace: transferRotationNamespace,
                    index: (transferClass(job) + 1) % 3, carryMore: false, captured: context)
                if let opportunity, !resourceBudget.isCurrent(opportunity) || ordinaryDeadline <= ProcessInfo.processInfo.systemUptime {
                    job.attempt = nil; job.phase = .retryPending
                    try commit(job)
                    finishOrdinaryLease(job.id, outcome: .timedOut)
                    continue
                }
                let task = adapter.create(request: request, file: file, description: job.taskDescription!,
                                          transportKind: job.transportKind ?? .background)
                guard task.transportKind == job.transportKind else { adapter.cancel(task.identifier); throw CloudUploadError.invalidRequest }
                job.taskIdentifier = task.identifier
                do { try commit(job) } catch { adapter.cancel(task.identifier); throw error }
                if let opportunity {
                    if armOrdinary(job, opportunity: opportunity, deadline: ordinaryDeadline) { adapter.resume(task.identifier) }
                } else { adapter.resume(task.identifier) }
                active += 1
                if reservesHistoricalSlot(job) { activeHistory += 1 }
                outcome = .waitingForOS
            } catch {
                finishOrdinaryLease(id, outcome: .failed)
                if let saved = error as? SavedOutcomeError {
                    resolve(id, result: .failure(saved.underlying))
                    continue
                }
                guard !suspended, isCurrent(context) else {
                    resolve(id, result: .failure(CloudUploadError.staleOwner))
                    break
                }
                if !reconciled {
                    resolve(id, result: .failure(error))
                    break
                }
                if (error as? CloudUploadError) == .retryScheduled {
                    resolve(id, result: .failure(error))
                    continue
                }
                job.attempt = nil; job.taskIdentifier = nil
                if (error as? CloudUploadError) == .responseTooLarge {
                    pause(&job, code: "response_too_large")
                } else if Self.terminalAuthorization(error) {
                    job.authenticationRefreshPending = false
                    pause(&job, authentication: true)
                } else if job.phase != .pausedTerminal {
                    job.phase = .retryPending
                    backoff(&job)
                }
                try? commit(job)
                resolve(id, result: .failure(error))
            }
        }
        if limit == 0 {
            for id in Array(waiters.keys) { resolve(id, result: .failure(CloudUploadError.retryScheduled)) }
        }
    }

    private func renewIntent(_ original: CloudUploadJob) async throws -> CloudUploadJob {
        guard let manifest = original.manifest, let objectID = original.objectID else { throw CloudUploadError.corruptJournal }
        let originalManifest = try JSONDecoder().decode(PushObjectManifest.self, from: manifest)
        var request = URLRequest(url: try apiURL(original, completion: false, intent: true))
        request.httpMethod = "POST"; request.httpBody = manifest
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = try await authorize(context)
        try check(context)
        guard policy().concurrency > 0, resourceBudget.permits(.cloudControl) else { throw CloudUploadError.retryScheduled }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let fleet = fleetToken(), !fleet.isEmpty {
            request.setValue(fleet, forHTTPHeaderField: CloudPushTransport.fleetTokenHeader)
        }
        let response = try await control(request)
        try check(context)
        guard (200...299).contains(response.statusCode) else {
            var job = original
            job.credentialVersion = credentialVersion(token)
            job.responseStatus = response.statusCode
            job.responseBody = Data(response.body.prefix(PushProtocolLimits.maxAckBytes))
            job.responseRetryAfter = response.retryAfter
            job.responseCode = PushError.parseCode(response.body, expectedVersion: originalManifest.protocolVersion)
            let failure = PushFailure.http(status: response.statusCode, receiverCode: job.responseCode)
            if failure.code == .httpAuth, (job.authenticationRefreshCount ?? 0) == 0, refreshCredentials != nil {
                job.authenticationRefreshCount = 1
                job.authenticationRejectedVersion = job.credentialVersion
                job.authenticationRefreshPending = true
                job.responseDisposition = .authentication
                job.phase = .retryPending
                backoff(&job)
            } else if failure.retryable {
                job.responseDisposition = .retryable
                job.phase = .retryPending
                backoff(&job)
            } else { pause(&job, authentication: failure.code == .httpAuth) }
            try commit(job)
            throw SavedOutcomeError(underlying: PushTransportException(failure))
        }
        let intent: PushObjectIntent
        do {
            intent = try PushObjectIntent.parse(response.body, expectedObjectId: objectID, expectedVersion: originalManifest.protocolVersion)
            guard intent.duplicate || intent.objectKey == original.objectKey else { throw CloudUploadError.invalidReceipt }
        } catch {
            var job = original
            job.responseStatus = response.statusCode
            job.responseBody = Data(response.body.prefix(PushProtocolLimits.maxAckBytes))
            pause(&job, code: "receipt_mismatch")
            try commit(job)
            throw SavedOutcomeError(underlying: PushTransportException(PushFailure(code: .ackInvalid)))
        }
        var job = original
        let version = Self.intentVersion(url: intent.uploadUrl, headers: intent.requiredHeaders, expiry: intent.expiresAt)
        if version != job.signedIntentVersion {
            job.signedIntentVersion = version
            job.signedURLRenewalCount = 0
        }
        job.credentialVersion = credentialVersion(token)
        job.signedURL = intent.uploadUrl; job.signedHeaders = intent.requiredHeaders
        job.signedExpiry = Self.expiry(intent.expiresAt); job.needsNewIntent = false
        if intent.duplicate { job.operation = .objectComplete; job.phase = .uploaded }
        try commit(job)
        return job
    }

    private func credentialVersion(_ token: String) -> String {
        AccountScope.digest("cloud-credential-v1\u{0}" + context.scope.namespace + "\u{0}" + token)
    }

    private static func terminalAuthorization(_ error: Error) -> Bool {
        guard let value = error as? AccountAuthError else { return false }
        switch value {
        case .signedOut, .sessionRevoked, .invalidIdentity, .invalidCredentials, .notConfigured, .unboundCapture: return true
        default: return false
        }
    }

    private static func intentVersion(url: String?, headers: [String: String], expiry: String?) -> String {
        let fields = [url ?? "", expiry ?? ""] + headers.keys.sorted().flatMap { [$0, headers[$0]!] }
        return AccountScope.digest(fields.map { "\($0.utf8.count):\($0)" }.joined())
    }

    private func validateEndpoint(_ endpoint: String) throws {
        guard endpoint == context.scope.projectURL + "/functions/v1/push" else { throw CloudUploadError.invalidRequest }
    }

    private func apiURL(_ job: CloudUploadJob, completion: Bool, intent: Bool = false) throws -> URL {
        try validateEndpoint(job.endpoint)
        guard var parts = URLComponents(string: job.endpoint) else { throw CloudUploadError.invalidRequest }
        if completion || intent {
            guard let lane = job.lanePath, lane.hasPrefix("/"), !lane.hasPrefix("//"),
                  !lane.contains(".."), !lane.contains("?"), !lane.contains("#") else { throw CloudUploadError.invalidRequest }
            parts.path = lane
            if completion {
                guard let id = job.objectID, UUID(uuidString: id) != nil else { throw CloudUploadError.invalidRequest }
                parts.path += "/\(id)/complete"
            }
        }
        guard let url = parts.url else { throw CloudUploadError.invalidRequest }
        return url
    }

    private func parseReceipt(_ job: CloudUploadJob) throws -> PushObjectAck? {
        guard let body = job.responseBody, let id = job.objectID else { return nil }
        guard let encoded = job.manifest,
              let manifest = try? JSONDecoder().decode(PushObjectManifest.self, from: encoded) else { throw CloudUploadError.invalidReceipt }
        let ack = try PushObjectAck.parse(body, expectedObjectId: id, expectedVersion: manifest.protocolVersion)
        guard
              let wireHash = job.payloadSHA256,
              ack.protocolVersion == manifest.protocolVersion,
              ack.releasesLocalRows,
              ack.durabilityReceipt?.matches(manifest, owner: job.owner,
                                            wireSHA256: wireHash, wireBytes: job.payloadBytes) == true,
              job.verifiedObjectKey == nil || job.verifiedObjectKey == ack.objectKey else {
            throw CloudUploadError.invalidReceipt
        }
        return ack
    }

    private func savedReceipt(_ job: CloudUploadJob) throws -> PushObjectAck? {
        guard job.phase == .receiptSaved, let status = job.responseStatus, (200...299).contains(status),
              let ack = try parseReceipt(job), ack.releasesLocalRows else { return nil }
        return ack
    }

    private func commit(_ job: CloudUploadJob) throws {
        do {
            try journal.save(job); jobs[job.id] = job
            publishQueuePressure()
            #if os(iOS)
            CloudPushBackgroundScheduler.scheduleIfNeeded()
            #endif
        }
        catch {
            // A write can fail after rename/fsync. Reload its recorded outcome rather than applying
            // the same response to stale in-memory counters. Reconciliation must re-persist first.
            reconciled = false
            if let saved = try? journal.load(), saved.values.allSatisfy({ $0.owner == context.scope }) {
                jobs = saved
            }
            throw error
        }
    }
    private func pausedFailure(_ job: CloudUploadJob) -> PushTransportException {
        if job.responseCode == "receipt_mismatch" || job.responseCode == "response_too_large" {
            return PushTransportException(PushFailure(code: .ackInvalid))
        }
        return PushTransportException(PushFailure.http(status: job.responseStatus ?? 422, receiverCode: job.responseCode))
    }
    private func pause(_ job: inout CloudUploadJob, code: String? = nil, authentication: Bool = false) {
        job.phase = .pausedTerminal
        job.responseDisposition = authentication ? .authentication : .terminal
        if let code { job.responseCode = code }
        job.failures += 1; job.nextAttemptAt = nil
        job.validatedReceipt = nil
    }

    func resumePaused(jobID: String, captured: AccountSessionContext) async throws {
        try check(captured)
        guard var job = jobs[jobID], job.phase == .pausedTerminal else { throw CloudUploadError.invalidRequest }
        job.phase = .retryPending; job.nextAttemptAt = nil
        job.responseDisposition = nil; job.responseStatus = nil; job.responseBody = nil
        job.responseRetryAfter = nil; job.responseCode = nil
        job.authenticationRefreshCount = 0; job.authenticationRefreshPending = false
        job.authenticationRejectedVersion = nil; job.authenticationRefreshedVersion = nil
        job.signedURLRenewalCount = 0; job.consecutiveFreshIntentDenials = 0
        try commit(job)
        await pump()
    }

    private func backoff(_ job: inout CloudUploadJob) {
        job.failures += 1
        let date = now()
        // The scoring gate is a short, explicit server coordination signal. Exponential client
        // backoff turned its Retry-After: 2 response into delays of tens of minutes after several
        // otherwise healthy retries. Keep a small jitter without overriding the server cadence.
        if job.responseCode == "scoring_input_gate_busy" {
            let requested = job.responseRetryAfter.flatMap(Double.init).flatMap {
                $0.isFinite && $0 >= 0 ? min($0, 30) : nil
            } ?? 2
            job.nextAttemptAt = date.addingTimeInterval(requested + min(1, max(0, randomUnit())))
            return
        }
        let ceiling = min(3600, 5 * pow(2, Double(min(job.failures, 10))))
        let jitter = min(1, max(0, randomUnit())) * ceiling
        var retryDate = date.addingTimeInterval(jitter)
        if let value = job.responseRetryAfter {
            if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
                retryDate = max(retryDate, date.addingTimeInterval(seconds))
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                if let specified = formatter.date(from: value) { retryDate = max(retryDate, specified) }
            }
        }
        job.nextAttemptAt = retryDate
    }
    private func resolve(_ id: String, result: Result<PushTransportResponse, Error>) {
        for waiter in waiters.removeValue(forKey: id)?.values ?? [:].values { waiter.resume(with: result) }
    }
    private static func expiry(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}
