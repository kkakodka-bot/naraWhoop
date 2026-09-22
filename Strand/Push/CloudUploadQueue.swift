import Foundation
import NoopPush

struct CloudUploadPolicy: Sendable {
    var concurrency: Int
    var allowsCellular: Bool
    var allowsConstrained: Bool
    var cancelTransfers = false

    static func current(wifiOnly: Bool, enabled: Bool = true) -> Self {
        let state = ProcessInfo.processInfo.thermalState
        let limit = !enabled || !ResourceBudget.shared.permits(.bulk) ? 0 : 1
        return .init(concurrency: limit, allowsCellular: !wifiOnly, allowsConstrained: !wifiOnly,
                     cancelTransfers: !enabled || state == .critical)
    }
}

/// The coordinator owns source cursors. This actor owns only immutable transfer bytes and receipts.
/// An HTTP success never deletes a file or advances a source cursor.
actor CloudUploadQueue {
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
    private var waiters: [String: [UUID: CheckedContinuation<PushTransportResponse, Error>]] = [:]
    private var pumping = false
    private var reconciled = false
    private var reconciling = false
    private var reconciliationRequested = false
    private var suspended = false
    private var cancellingTasks: Set<Int> = []
    private struct SavedOutcomeError: Error { let underlying: Error }
    private struct CleanupBatch: Hashable {
        let receiverStateID: String
        let batchID: String
    }

    init(resourceBudget: ResourceBudget = .shared,
         context: AccountSessionContext, layout: AccountStorageLayout,
         adapter: any CloudUploadSessionAdapter, authorize: @escaping Authorize,
         isCurrent: @escaping Current, policy: @escaping @Sendable () -> CloudUploadPolicy,
         control: @escaping @Sendable (URLRequest) async throws -> PushTransportResponse,
         maximumBytes: Int = 1_073_741_824, now: @escaping @Sendable () -> Date = { Date() },
         journalWriteObserver: (@Sendable (URL) throws -> Void)? = nil,
         randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
         refreshCredentials: (@Sendable (AccountSessionContext) async throws -> Void)? = nil,
         fleetToken: @escaping @Sendable () -> String? = { nil }) throws {
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
        journal = try CloudUploadJournal(directory: layout.uploadDirectory, maximumBytes: maximumBytes, afterWrite: journalWriteObserver)
        try journal.loadSelections(owner: context.scope)
        jobs = try journal.load()
        guard jobs.values.allSatisfy({ $0.owner == context.scope }) else { throw CloudUploadError.staleOwner }
        for var job in jobs.values where job.authenticationRefreshPending == true {
            // The refresh allowance was consumed before a possible process death. Never repeat it blindly.
            job.phase = .pausedTerminal
            job.authenticationRefreshPending = false
            job.responseDisposition = .authentication
            try journal.save(job)
            jobs[job.id] = job
        }
        for job in jobs.values {
            if let id = job.preparedSelectionID {
                guard let selection = journal.selections[id], let state = journal.continuations[id],
                      try selection.jobIDs(state).contains(job.id), !job.acknowledged || state.sourceCommitted else {
                    throw CloudUploadError.corruptJournal
                }
            }
        }
    }

    private func check(_ captured: AccountSessionContext) throws {
        guard !suspended, captured == context, isCurrent(captured) else { throw CloudUploadError.staleOwner }
    }

    func pausedMessage(captured: AccountSessionContext) throws -> String? {
        try check(captured)
        let paused = jobs.values.filter { $0.phase == .pausedTerminal && !$0.acknowledged }
        guard !paused.isEmpty else { return nil }
        if paused.contains(where: { $0.responseDisposition == .authentication }) {
            return "Cloud sync paused for authentication. Local data is retained."
        }
        return "Cloud sync paused for a server or receipt error. Local data is retained; retry after resolution."
    }

    static func objectJobID(endpoint: String, objectID: String, receiverStateID: String = "") -> String {
        AccountScope.digest("object-v1\u{0}\(endpoint)\u{0}\(receiverStateID)\u{0}\(objectID)")
    }

    func prepareSelection(_ value: CloudPushPreparedSelection, captured: AccountSessionContext,
                          beforeFreshAdmission: @Sendable () throws -> Void = {}) throws {
        try check(captured)
        guard value.owner == context.scope else { throw CloudUploadError.staleOwner }
        try checkBulkAdmission(captured: captured)
        let legacyJobs = jobs.values.filter { $0.preparedSelectionID == nil }.count
        // This synchronous actor-local boundary precedes any new reservation/body publication.
        // An exact existing reservation (including interrupted publication) keeps its original
        // authority. reserve still verifies its immutable bytes; it is not a new preference claim.
        if journal.selections[value.id] == nil { try beforeFreshAdmission() }
        try journal.reserve(value, legacyJobs: legacyJobs)
        guard let saved = journal.selections[value.id], var state = journal.continuations[value.id], !state.sourceCommitted else {
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
                try prepare(object.batch.payload, job: &job); try commit(job)
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

    private func verifyPublished(_ saved: CloudPushPreparedSelection, state: CloudPreparedContinuation) throws {
        func verify(_ id: String, _ bytes: Data) throws {
            guard let job = jobs[id], job.preparedSelectionID == saved.id, job.owner == saved.owner,
                  job.endpoint == saved.endpoint, job.receiverStateID == saved.receiverStateID,
                  job.payloadBytes == bytes.count, job.payloadSHA256 == CloudUploadJournal.digest(bytes) else { throw CloudUploadError.changedPayload }
            try journal.verifyBody(job)
        }
        if let object = try saved.selection.restoredObject() {
            for objectID in state.objectIDs { try verify(saved.jobID(batchID: object.batch.batchId, representation: "object", objectID: objectID), object.batch.payload) }
        } else {
            for (index, batch) in try saved.selection.restoredInlineBatches().enumerated() {
                try verify(saved.jobID(batchID: batch.batchId, representation: "gzip"), saved.inlineGzip[index])
                try verify(saved.jobID(batchID: batch.batchId, representation: "identity"), batch.body)
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

    func preparedSelections(sourceID: String, endpoint: String, receiverStateID: String,
                            captured: AccountSessionContext) throws -> [CloudPushPreparedSelection] {
        try check(captured)
        return journal.selections.values.filter { $0.matches(owner: context.scope, sourceID: sourceID,
            endpoint: endpoint, receiverStateID: receiverStateID) }.sorted { $0.id < $1.id }
    }

    func selectionID(batchID: String, sourceID: String, endpoint: String, receiverStateID: String,
                     captured: AccountSessionContext) throws -> String {
        let candidates = try preparedSelections(sourceID: sourceID, endpoint: endpoint, receiverStateID: receiverStateID, captured: captured)
            .filter { $0.commit.batchIDs.contains(batchID) }
        guard candidates.count == 1 else { throw CloudUploadError.invalidRequest }
        return candidates[0].id
    }

    func preparedInline(_ batch: PushBatch, endpoint: String, receiverStateID: String,
                        captured: AccountSessionContext) throws -> (selectionID: String, gzip: Data) {
        let id = try selectionID(batchID: batch.batchId, sourceID: batch.sourceId, endpoint: endpoint,
            receiverStateID: receiverStateID, captured: captured)
        guard let saved = journal.selections[id], journal.continuations[id]?.published == true,
              let index = saved.commit.batchIDs.firstIndex(of: batch.batchId),
              try saved.selection.restoredInlineBatches()[index].body == batch.body else { throw CloudUploadError.changedPayload }
        return (id, saved.inlineGzip[index])
    }

    /// Runs before an intent request, including the one explicitly permitted conflict successor.
    func admitPreparedIntent(_ manifest: PushObjectManifest, endpoint: String, receiverStateID: String,
                             captured: AccountSessionContext) throws {
        let id = try selectionID(batchID: manifest.batchId, sourceID: manifest.sourceId, endpoint: endpoint,
            receiverStateID: receiverStateID, captured: captured)
        guard let saved = journal.selections[id], var state = journal.continuations[id], state.published,
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
            try prepare(object.batch.payload, job: &job); try commit(job)
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
        guard let saved = journal.selections[selectionID], let state = journal.continuations[selectionID] else { throw CloudUploadError.corruptJournal }
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
        guard let value = journal.selections[id] else { throw CloudUploadError.corruptJournal }
        return value
    }

    func checkIntentAdmission(captured: AccountSessionContext) throws {
        try check(captured)
        guard policy().concurrency > 0 else { throw CloudUploadError.retryScheduled }
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
        guard job.deliveryAdmitted == true, let saved = journal.selections[id], let state = journal.continuations[id],
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
        guard let saved = journal.selections[selectionID], var state = journal.continuations[selectionID] else {
            // Retirement may have completed before the progress-store debt was settled.
            return
        }
        let ids = try saved.jobIDs(state)
        guard !ids.contains(where: { jobs[$0]?.phase == .transferring }) else { throw CloudUploadError.retryScheduled }
        state.sourceCommitted = true
        try journal.saveContinuation(state) // Group marker precedes EVERY unlink.
        for id in ids {
            if var job = jobs[id] {
                guard job.preparedSelectionID == selectionID else { throw CloudUploadError.corruptJournal }
                job.acknowledged = true; try commit(job); try journal.removeCommitted(job); jobs[id] = nil
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
            guard let saved = journal.selections[selectionID], saved.endpoint == endpoint, saved.receiverStateID == receiverStateID,
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
        for var job in jobs.values {
            if job.acknowledged {
                try journal.removeCommitted(job)
                jobs.removeValue(forKey: job.id)
                continue
            }
            job.generation = context.generation
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
                let matching = tasks.filter { $0.description == job.taskDescription }
                let networkAllowed = (admission.allowsCellular || job.allowsCellular == false) &&
                    (admission.allowsConstrained || job.allowsConstrained == false)
                if let task = matching.first, !admission.cancelTransfers, networkAllowed, mayDeliver(job),
                   !cancellingTasks.contains(task.identifier) {
                    job.taskIdentifier = task.identifier
                    claimed.insert(task.identifier)
                } else {
                    job.taskIdentifier = nil; job.attempt = nil; job.phase = .retryPending
                }
            }
            try commit(job)
        }
        for task in tasks where !claimed.contains(task.identifier) {
            cancellingTasks.insert(task.identifier)
            adapter.cancel(task.identifier)
        }
        reconciled = true
        for identifier in claimed { adapter.resume(identifier) }
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
        for job in jobs.values { if let task = job.taskIdentifier { adapter.cancel(task) } }
        for id in Array(waiters.keys) { resolve(id, result: .failure(CloudUploadError.staleOwner)) }
    }

    func receive(_ task: CloudUploadTaskSnapshot, status: Int, body: Data, error: Bool, retryAfter: String? = nil) async {
        if cancellingTasks.remove(task.identifier) != nil { await pump(); return }
        guard reconciled, !suspended, isCurrent(context), let description = task.description,
              var job = jobs.values.first(where: { $0.taskDescription == description }),
              job.generation == context.generation, job.phase == .transferring,
              job.taskIdentifier == task.identifier || job.taskIdentifier == nil else { return }
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
                if (job.authenticationRefreshCount ?? 0) == 0 {
                    job.authenticationRefreshCount = 1
                    if job.operation == .objectPut {
                        job.needsNewIntent = true
                        job.phase = .retryPending
                        backoff(&job)
                    } else if refreshCredentials != nil {
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
            resolve(job.id, result: result)
        } catch {
            // Disk failure is not a second HTTP response. Stop admission until a fresh reconciliation.
            reconciled = false
            resolve(job.id, result: .failure(error))
        }
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

    private func pump() async {
        guard reconciled, !pumping, !reconciling else { return }
        pumping = true
        defer { pumping = false; scheduleRequestedReconciliation() }
        guard !suspended, isCurrent(context) else { suspend(); return }
        let limit = max(0, min(2, policy().concurrency))
        var active = jobs.values.filter { $0.phase == .transferring }.count + cancellingTasks.count
        for id in jobs.values.sorted(by: { $0.createdAt < $1.createdAt }).map(\.id) {
            guard active < limit else { break }
            guard var job = jobs[id], job.phase == .prepared || job.phase == .retryPending || job.phase == .uploaded ||
                    (job.phase == .responseSaved && job.operation == .objectComplete) else { continue }
            guard mayDeliver(job) else { continue }
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
                try checkBulkAdmission(captured: context)
                if job.authenticationRefreshPending == true {
                    job.authenticationRefreshPending = false
                    job.phase = .pausedTerminal
                    try commit(job) // Reserve exactly one refresh before suspending for credentials.
                    guard let refreshCredentials else { throw pausedFailure(job) }
                    try await refreshCredentials(context)
                    try check(context)
                    job.phase = .retryPending
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
                    let token = try await authorize(context)
                    try check(context)
                    request = URLRequest(url: try apiURL(job, completion: job.operation == .objectComplete))
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    for (key, value) in job.headers { request.setValue(value, forHTTPHeaderField: key) }
                    if let fleet = fleetToken(), !fleet.isEmpty {
                        request.setValue(fleet, forHTTPHeaderField: CloudPushTransport.fleetTokenHeader)
                        job.fleetAuthorizationApplied = true
                    }
                    if job.operation == .objectComplete { file = try journal.emptyBodyURL() }
                    else { try journal.verifyBody(job); file = try journal.bodyURL(job) }
                }
                try check(context)
                let admission = policy()
                guard admission.concurrency > active else { throw CloudUploadError.retryScheduled }
                request.allowsCellularAccess = admission.allowsCellular
                request.allowsExpensiveNetworkAccess = admission.allowsCellular
                request.allowsConstrainedNetworkAccess = admission.allowsConstrained
                job.allowsCellular = admission.allowsCellular
                job.allowsConstrained = admission.allowsConstrained
                job.generation = context.generation
                job.attempt = UUID(); job.phase = .transferring; job.taskIdentifier = nil
                try commit(job) // Crash between this and task-ID commit is reconciled by taskDescription.
                let task = adapter.create(request: request, file: file, description: job.taskDescription!)
                job.taskIdentifier = task.identifier
                do { try commit(job) } catch { adapter.cancel(task.identifier); throw error }
                adapter.resume(task.identifier)
                active += 1; outcome = .waitingForOS
            } catch {
                if let saved = error as? SavedOutcomeError {
                    resolve(id, result: .failure(saved.underlying))
                    continue
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
                if job.phase != .pausedTerminal {
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
        guard policy().concurrency > 0 else { throw CloudUploadError.retryScheduled }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let fleet = fleetToken(), !fleet.isEmpty {
            request.setValue(fleet, forHTTPHeaderField: CloudPushTransport.fleetTokenHeader)
        }
        let response = try await control(request)
        try check(context)
        guard (200...299).contains(response.statusCode) else {
            var job = original
            job.responseStatus = response.statusCode
            job.responseBody = Data(response.body.prefix(PushProtocolLimits.maxAckBytes))
            job.responseRetryAfter = response.retryAfter
            job.responseCode = PushError.parseCode(response.body, expectedVersion: originalManifest.protocolVersion)
            let failure = PushFailure.http(status: response.statusCode, receiverCode: job.responseCode)
            if failure.code == .httpAuth, (job.authenticationRefreshCount ?? 0) == 0, refreshCredentials != nil {
                job.authenticationRefreshCount = 1
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
        job.signedURL = intent.uploadUrl; job.signedHeaders = intent.requiredHeaders
        job.signedExpiry = Self.expiry(intent.expiresAt); job.needsNewIntent = false
        if intent.duplicate { job.operation = .objectComplete; job.phase = .uploaded }
        try commit(job)
        return job
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
        do { try journal.save(job); jobs[job.id] = job }
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
