import Foundation
import zlib
import NoopPush

/// Control requests block redirects. Payloads use the captured account's durable file-backed lane.
struct CloudPushTransport: PushTransport {
    static let acceptVersionHeader = "NOOP-Push-Accept-Version"

    private let endpoint: PushValidEndpoint
    private let bearerToken: String
    private let session: URLSession
    private let context: AccountSessionContext?
    private let dependentAdmission: SyncEngine.DependentStageAdmission?
    private let destination = CloudPushReceiverBinding()

    init(
        endpoint: PushValidEndpoint,
        bearerToken: String,
        context: AccountSessionContext? = nil,
        session: URLSession = CloudPushTransport.makeSession(),
        dependentAdmission: SyncEngine.DependentStageAdmission? = nil
    ) {
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.session = session
        self.context = context
        self.dependentAdmission = dependentAdmission
        if dependentAdmission != nil { destination.requirePrepared() }
    }

    func capabilities() async throws -> PushCapabilitiesResult {
        var request = URLRequest(url: URL(string: endpoint.url)!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(PushProtocol.capabilitiesAcceptVersions, forHTTPHeaderField: Self.acceptVersionHeader)
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status < 200 || status > 299 {
                let failure = PushFailure.http(status: status, receiverCode: PushError.parseCode(data))
                return .rejected(reason: failure.safeCode, retryable: failure.retryable, failure: failure)
            }
            let capabilities = try PushCapabilities.parse(data)
            try bindReceiverState(capabilities.receiverStateId)
            return .available(capabilities)
        } catch let error as PushTransportException {
            return .rejected(reason: error.failure.safeCode, retryable: error.failure.retryable, failure: error.failure)
        } catch {
            let failure = PushFailure(code: .networkIO)
            return .rejected(reason: failure.safeCode, retryable: failure.retryable, failure: failure)
        }
    }

    func post(_ batch: PushBatch) async throws -> PushTransportResponse {
        let (queue, captured, state) = try durableQueue()
        let saved = destination.requiresPrepared ? try await queue.preparedInline(batch, endpoint: endpoint.url,
            receiverStateID: state, captured: captured) : nil
        let compressed = try saved?.gzip ?? Self.gzip(batch.body)
        let compressedResponse = try await execute(body: compressed, batchID: batch.batchId, contentEncoding: "gzip", contentType: "application/x-ndjson; charset=utf-8", selectionID: saved?.selectionID)
        let response = compressedResponse.statusCode == 415
            ? try await execute(body: batch.body, batchID: batch.batchId, contentEncoding: nil, contentType: "application/x-ndjson; charset=utf-8", selectionID: saved?.selectionID)
            : compressedResponse
        if (200...299).contains(response.statusCode) {
            try await queue.validateResponse(batch: batch, response: response, captured: captured, receiverStateID: state, selectionID: saved?.selectionID)
        }
        return response
    }

    func postBinary(_ batch: PushBinaryBatch) async throws -> PushTransportResponse {
        // Guarded raw uploads use the prepared object lane, never the unprepared legacy POST.
        guard dependentAdmission == nil else { throw CloudUploadError.invalidRequest }
        let manifestHeader = batch.manifestJSON.base64EncodedString()
        return try await execute(
            body: batch.payload,
            batchID: batch.batchId,
            contentEncoding: batch.contentEncoding,
            contentType: "application/octet-stream",
            binaryObject: true,
            manifestHeader: manifestHeader
        )
    }

    // MARK: - Object lane (protocol 1.2)

    func createObjectIntent(_ manifest: PushObjectManifest, lane: PushObjectLane) async throws -> PushObjectIntent {
        let (queue, captured, state) = try durableQueue()
        if destination.requiresPrepared {
            try await queue.admitPreparedIntent(manifest, endpoint: endpoint.url, receiverStateID: state, captured: captured)
            if let saved = try await queue.savedPreparedIntent(manifest, endpoint: endpoint.url, receiverStateID: state, captured: captured) { return saved }
            try await queue.checkIntentAdmission(captured: captured)
        }
        return try await queue.initialObjectIntent(manifest, lane: lane, endpoint: endpoint.url,
            receiverStateID: state, captured: captured)
    }

    func uploadObject(_ intent: PushObjectIntent, body: Data) async throws {
        let (queue, captured, state) = try durableQueue()
        try await queue.uploadObject(endpoint: endpoint.url, objectID: intent.objectId, body: body, captured: captured, receiverStateID: state)
    }

    func completeObject(objectId: String, lane: PushObjectLane) async throws -> PushObjectAck {
        let (queue, captured, state) = try durableQueue()
        return try await queue.completeObject(endpoint: endpoint.url, objectID: objectId, captured: captured, receiverStateID: state)
    }

    /// The lane endpoint is an absolute path minted by the receiver; resolve it against the
    /// configured origin so the scheme/host policy of the validated endpoint is preserved.
    private func laneURL(_ path: String) throws -> URL {
        guard var components = URLComponents(string: endpoint.url) else {
            throw PushTransportException(PushFailure(code: .localData))
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw PushTransportException(PushFailure(code: .localData))
        }
        return url
    }

    private func execute(
        body: Data,
        batchID: String,
        contentEncoding: String?,
        contentType: String,
        binaryObject: Bool = false,
        manifestHeader: String? = nil,
        selectionID: String? = nil
    ) async throws -> PushTransportResponse {
        let (queue, captured, state) = try durableQueue()
        var headers = ["Content-Type": contentType]
        if binaryObject {
            headers["NOOP-Push-Binary-Object"] = "1"
        }
        if let manifestHeader {
            headers["NOOP-Push-Manifest"] = manifestHeader
        }
        if let contentEncoding { headers["Content-Encoding"] = contentEncoding }
        return try await queue.request(endpoint: endpoint.url, body: body, headers: headers, captured: captured, receiverStateID: state, batchID: batchID, selectionID: selectionID)
    }

    /// The production worker opts in before creating a coordinator. Legacy recovery/tests do not
    /// retroactively acquire source intent merely because a receipt shares a batch identifier.
    func requirePreparedSelections() { destination.requirePrepared() }

    func beginBinaryPreparation(maximumWireBytes: Int) async throws -> PushBinaryPreparation? {
        let (queue, captured, _) = try durableQueue()
        return try await queue.beginBinaryPreparation(maximumWireBytes: maximumWireBytes, captured: captured)
    }
    func finishBinaryPreparation(_ preparation: PushBinaryPreparation) async throws {
        let (queue, captured, _) = try durableQueue()
        try await queue.finishBinaryPreparation(preparation, captured: captured)
    }
    func uploadObject(_ intent: PushObjectIntent, file: PushImmutablePayloadFile) async throws {
        let (queue, captured, state) = try durableQueue()
        try await queue.uploadObject(endpoint: endpoint.url, objectID: intent.objectId, file: file,
            captured: captured, receiverStateID: state)
    }

    func isPreparationPaused(_ lane: PushPreparationLane) async throws -> Bool {
        let (queue, captured, state) = try durableQueue()
        return try await queue.isPreparationPaused(lane, receiverStateID: state, captured: captured)
    }

    func pausePreparation(_ lane: PushPreparationLane) async throws {
        let (queue, captured, state) = try durableQueue()
        try await queue.pausePreparation(lane, receiverStateID: state, captured: captured)
    }

    func prepareSelection(_ selection: PushPreparedSelection, progressVersion: String) async throws {
        requirePreparedSelections()
        let (queue, captured, state) = try durableQueue()
        try await queue.checkSelectionEncodingAdmission(captured: captured)
        let value = try CloudPushPreparedSelection(context: captured, endpoint: endpoint.url,
            receiverStateID: state, progressVersion: progressVersion, selection: selection,
            inlineGzip: selection.restoredInlineBatches().map { try Self.gzip($0.body) })
        // Validate the captured evaluation AFTER encoding. The actor-local check closes the hop
        // to reservation; neither step recaptures preferences or downgrades a failed admission.
        // False may still replay an exact existing reservation under its W5 account/source rules.
        let validated = await dependentAdmission?.validate() ?? true
        let capturedAdmission = dependentAdmission
        try await queue.prepareSelection(value, captured: captured, beforeFreshAdmission: {
            guard validated else { throw CancellationError() }
            try capturedAdmission?.checkBoundary()
        })
    }

    func preparedSelectionID(batchID: String, sourceID: String) async throws -> String {
        let (queue, captured, state) = try durableQueue()
        return try await queue.selectionID(batchID: batchID, sourceID: sourceID, endpoint: endpoint.url,
            receiverStateID: state, captured: captured)
    }

    func preparedSourceCommitted(_ id: String) async throws {
        let (queue, captured, _) = try durableQueue()
        try await queue.preparedSourceCommitted(selectionID: id, captured: captured)
    }
    func retireSelection(_ id: String) async throws {
        let (queue, captured, _) = try durableQueue()
        try await queue.retireSelection(id, captured: captured)
    }

    /// The account capability wrapper calls this after authenticated capability parsing.
    func bindReceiverState(_ receiverStateID: String) throws { try destination.bind(receiverStateID) }

    func sourceCommitted(batchID: String) async throws {
        let (queue, captured, state) = try durableQueue()
        try await queue.sourceCommitted(batchID: batchID, receiverStateID: state, captured: captured)
    }

    private func durableQueue() throws -> (CloudUploadQueue, AccountSessionContext, String) {
        guard let context else { throw CloudUploadError.staleOwner }
        return (try CloudPushBackgroundRuntime.current(for: context).queue, context, try destination.value())
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: RedirectBlockingDelegate.shared, delegateQueue: nil)
    }

    static func gzip(_ decoded: Data) throws -> Data {
        guard decoded.count <= PushProtocolLimits.maxBodyBytes else {
            throw PushTransportException(PushFailure(code: .localData))
        }
        var stream = z_stream()
        var status = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw PushTransportException(PushFailure(code: .localData)) }
        defer { deflateEnd(&stream) }

        var output = Data(capacity: decoded.count)
        decoded.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(decoded.count)
            let chunk = 64 * 1024
            var buffer = [UInt8](repeating: 0, count: chunk)
            buffer.withUnsafeMutableBufferPointer { bytes in
                repeat {
                    stream.next_out = bytes.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = deflate(&stream, Z_FINISH)
                    let produced = chunk - Int(stream.avail_out)
                    if produced > 0, let base = bytes.baseAddress { output.append(base, count: produced) }
                } while status == Z_OK
            }
        }
        guard status == Z_STREAM_END else { throw PushTransportException(PushFailure(code: .localData)) }
        guard output.count <= PushProtocolLimits.maxWireBodyBytes else {
            throw PushTransportException(PushFailure(code: .localData))
        }
        return output
    }
}

private final class CloudPushReceiverBinding: @unchecked Sendable {
    private let lock = NSLock()
    private var state: String?
    private var prepared = false
    var requiresPrepared: Bool { lock.lock(); defer { lock.unlock() }; return prepared }
    func requirePrepared() { lock.lock(); defer { lock.unlock() }; prepared = true }
    func bind(_ value: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !value.isEmpty, state == nil || state == value else { throw CloudUploadError.invalidReceipt }
        state = value
    }
    func value() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let state else { throw CloudUploadError.invalidRequest }
        return state
    }
}

private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, URLSessionDelegate {
    static let shared = RedirectBlockingDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
