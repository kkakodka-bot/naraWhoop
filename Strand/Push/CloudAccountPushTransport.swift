import Foundation
import NoopPush

/// Retains the authenticated owner from the capability response without changing the legacy codec.
struct CloudAccountPushTransport: PushTransport {
    let endpoint: PushValidEndpoint
    let base: CloudPushTransport
    private let context: AccountSessionContext
    private let accessToken: String
    private let isCurrent: @Sendable (AccountSessionContext) -> Bool
    private let session: URLSession
    private let controlQueue: CloudUploadQueue?

    init(endpoint: PushValidEndpoint, authorization: AuthorizedCloudSession,
         dependentAdmission: SyncEngine.DependentStageAdmission? = nil) throws {
        try self.init(endpoint: endpoint, context: authorization.context, accessToken: authorization.accessToken,
                      session: CloudPushBackgroundRuntime.current(for: authorization.context).controlSession,
                      isCurrent: { CloudRuntimeIdentity.isCurrent($0) },
                      dependentAdmission: dependentAdmission,
                      controlQueue: CloudPushBackgroundRuntime.current(for: authorization.context).queue)
        base.requirePreparedSelections()
    }

    init(endpoint: PushValidEndpoint, context: AccountSessionContext, accessToken: String,
         session: URLSession, isCurrent: @escaping @Sendable (AccountSessionContext) -> Bool,
         dependentAdmission: SyncEngine.DependentStageAdmission? = nil,
         controlQueue: CloudUploadQueue? = nil) throws {
        let expected = context.scope.projectURL + "/functions/v1/push"
        guard endpoint.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == expected else {
            throw AccountAuthError.invalidIdentity
        }
        self.endpoint = endpoint
        self.context = context; self.accessToken = accessToken
        self.isCurrent = isCurrent; self.session = session
        self.controlQueue = controlQueue
        self.base = CloudPushTransport(endpoint: endpoint, bearerToken: accessToken,
                                       context: context, session: session, dependentAdmission: dependentAdmission)
    }

    func capabilities() async throws -> PushCapabilitiesResult {
        guard isCurrent(context) else { throw AccountAuthError.staleOperation }
        if let controlQueue {
            let result = try await controlQueue.capabilities(endpoint: endpoint.url, captured: context)
            guard isCurrent(context) else { throw AccountAuthError.staleOperation }
            if case .available(let value) = result { try base.bindReceiverState(value.receiverStateId) }
            return result
        }
        var request = URLRequest(url: URL(string: endpoint.url)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let fleet = CloudPushSettings.resolvedFleetToken() {
            request.setValue(fleet, forHTTPHeaderField: CloudPushTransport.fleetTokenHeader)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(PushProtocol.capabilitiesAcceptVersions, forHTTPHeaderField: CloudPushTransport.acceptVersionHeader)
        let (data, response) = try await session.data(for: request)
        guard isCurrent(context) else { throw AccountAuthError.staleOperation }
        guard let http = response as? HTTPURLResponse else { throw AccountAuthError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let failure = PushFailure.http(status: http.statusCode, receiverCode: PushError.parseCode(data))
            return .rejected(reason: failure.safeCode, retryable: failure.retryable, failure: failure)
        }
        let capabilities = try AccountVerifiedCapabilities.parse(data, scope: context.scope)
        guard isCurrent(context) else { throw AccountAuthError.staleOperation }
        try base.bindReceiverState(capabilities.receiverStateId)
        return .available(capabilities)
    }

    func post(_ batch: PushBatch) async throws -> PushTransportResponse {
        let interval = SyncPipelineTrace.begin(.uploadReceipt, correlation: UUID(uuidString: batch.batchId) ?? UUID())
        var outcome = SyncPipelineTrace.Outcome.failed
        defer { SyncPipelineTrace.end(interval, outcome: outcome) }
        let result = try await base.post(batch)
        guard isCurrent(context) else {
            outcome = .cancelled
            throw AccountAuthError.staleOperation
        }
        if let ack = try? PushAck.parse(result.body), ack.exactlyMatches(batch),
           (200...299).contains(result.statusCode) {
            outcome = .succeeded
            SyncPipelineTrace.event(.cloudAcknowledgement, correlation: UUID(uuidString: batch.batchId) ?? UUID())
        }
        return result
    }
    func postBinary(_ batch: PushBinaryBatch) async throws -> PushTransportResponse {
        SyncPipelineTrace.event(.uploadScheduling, correlation: UUID(uuidString: batch.batchId) ?? UUID())
        let response = try await base.postBinary(batch)
        guard isCurrent(context) else { throw AccountAuthError.staleOperation }
        if (200...299).contains(response.statusCode), let ack = try? PushAck.parse(response.body), ack.exactlyMatches(batch) {
            SyncPipelineTrace.event(.cloudAcknowledgement, correlation: UUID(uuidString: batch.batchId) ?? UUID())
        }
        return response
    }
    func beginBinaryPreparation(maximumWireBytes: Int) async throws -> PushBinaryPreparation? {
        guard isCurrent(context) else { throw AccountAuthError.staleOperation }
        let value = try await base.beginBinaryPreparation(maximumWireBytes: maximumWireBytes)
        guard isCurrent(context) else {
            if let value { try? await base.finishBinaryPreparation(value) }
            throw AccountAuthError.staleOperation
        }
        return value
    }
    func finishBinaryPreparation(_ preparation: PushBinaryPreparation) async throws {
        try await base.finishBinaryPreparation(preparation)
    }
    func uploadObject(_ intent: PushObjectIntent, file: PushImmutablePayloadFile) async throws {
        guard isCurrent(context) else { throw AccountAuthError.staleOperation }
        try await base.uploadObject(intent, file: file)
        guard isCurrent(context) else { throw AccountAuthError.staleOperation }
    }

    func isPreparationPaused(_ lane: PushPreparationLane) async throws -> Bool {
        guard isCurrent(context) else { throw AccountAuthError.staleOperation }
        return try await base.isPreparationPaused(lane)
    }
    func pausePreparation(_ lane: PushPreparationLane) async throws {
        guard isCurrent(context) else { throw AccountAuthError.staleOperation }
        try await base.pausePreparation(lane)
    }
    func createObjectIntent(_ manifest: PushObjectManifest, lane: PushObjectLane) async throws -> PushObjectIntent {
        try await base.createObjectIntent(manifest, lane: lane)
    }
    func uploadObject(_ intent: PushObjectIntent, body: Data) async throws {
        let interval = SyncPipelineTrace.begin(.uploadScheduling, correlation: UUID(uuidString: intent.objectId) ?? UUID())
        var outcome = SyncPipelineTrace.Outcome.failed
        defer { SyncPipelineTrace.end(interval, outcome: outcome) }
        try await base.uploadObject(intent, body: body)
        guard isCurrent(context) else {
            outcome = .cancelled
            throw AccountAuthError.staleOperation
        }
        outcome = .succeeded
    }
    func completeObject(objectId: String, lane: PushObjectLane) async throws -> PushObjectAck {
        let interval = SyncPipelineTrace.begin(.uploadReceipt, correlation: UUID(uuidString: objectId) ?? UUID())
        var outcome = SyncPipelineTrace.Outcome.failed
        defer { SyncPipelineTrace.end(interval, outcome: outcome) }
        let ack = try await base.completeObject(objectId: objectId, lane: lane)
        guard isCurrent(context) else {
            outcome = .cancelled
            throw AccountAuthError.staleOperation
        }
        if ack.objectId == objectId, ack.releasesLocalRows {
            outcome = .succeeded
            SyncPipelineTrace.event(.cloudAcknowledgement, correlation: UUID(uuidString: objectId) ?? UUID())
        }
        return ack
    }
}
