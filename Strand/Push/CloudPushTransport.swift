import Foundation
import zlib
import NoopPush

/// Minimal HTTP adapter for the push receiver: no redirects, bounded ack reads, and no
/// receiver credentials on direct-to-bucket uploads.
struct CloudPushTransport: PushTransport {
    static let acceptVersionHeader = "NOOP-Push-Accept-Version"
    static let fleetTokenHeader = "X-NOOP-Fleet-Token"

    private let endpoint: PushValidEndpoint
    private let uploadToken: String
    private let fleetToken: String
    private let session: URLSession
    private let uploadSession: URLSession

    init(
        endpoint: PushValidEndpoint,
        uploadToken: String,
        fleetToken: String,
        session: URLSession = CloudPushTransport.makeSession(),
        uploadSession: URLSession = CloudPushTransport.makeUploadSession()
    ) {
        self.endpoint = endpoint
        self.uploadToken = uploadToken
        self.fleetToken = fleetToken
        self.session = session
        self.uploadSession = uploadSession
    }

    func capabilities() async throws -> PushCapabilitiesResult {
        var request = URLRequest(url: URL(string: endpoint.url)!)
        request.httpMethod = "GET"
        authorizeReceiverRequest(&request)
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
            return .available(capabilities)
        } catch let error as PushTransportException {
            return .rejected(reason: error.failure.safeCode, retryable: error.failure.retryable, failure: error.failure)
        } catch {
            let failure = PushFailure(code: .networkIO)
            return .rejected(reason: failure.safeCode, retryable: failure.retryable, failure: failure)
        }
    }

    func post(_ batch: PushBatch) async throws -> PushTransportResponse {
        let compressed = try Self.gzip(batch.body)
        let compressedResponse = try await execute(body: compressed, contentEncoding: "gzip", contentType: "application/x-ndjson; charset=utf-8")
        if compressedResponse.statusCode != 415 { return compressedResponse }
        return try await execute(body: batch.body, contentEncoding: nil, contentType: "application/x-ndjson; charset=utf-8")
    }

    func postBinary(_ batch: PushBinaryBatch) async throws -> PushTransportResponse {
        let manifestHeader = batch.manifestJSON.base64EncodedString()
        return try await execute(
            body: batch.payload,
            contentEncoding: batch.contentEncoding,
            contentType: "application/octet-stream",
            binaryObject: true,
            manifestHeader: manifestHeader
        )
    }

    // MARK: - Object lane (protocol 1.2)

    func createObjectIntent(_ manifest: PushObjectManifest, lane: PushObjectLane) async throws -> PushObjectIntent {
        let body = try manifest.encode()
        guard body.count <= 8 * 1024 else {
            throw PushTransportException(PushFailure(code: .localData))
        }
        var request = URLRequest(url: try laneURL(lane.endpoint))
        request.httpMethod = "POST"
        request.httpBody = body
        authorizeReceiverRequest(&request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status >= 200, status <= 299 else {
            throw PushTransportException(PushError.httpFailure(
                status: status, body: data, expectedVersion: PushProtocol.objectVersion,
                table: PushBinaryTable(rawValue: manifest.stream)
            ))
        }
        do {
            return try PushObjectIntent.parse(data, expectedObjectId: manifest.objectId)
        } catch {
            throw PushTransportException(PushFailure(code: .ackInvalid))
        }
    }

    func uploadObject(_ intent: PushObjectIntent, body: Data) async throws {
        guard let uploadUrl = intent.uploadUrl, let url = URL(string: uploadUrl) else {
            throw PushTransportException(PushFailure(code: .ackInvalid))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = body
        // Exactly the signed headers and nothing else: extras break the SigV4 signature, and
        // receiver credentials must never leak to the bucket host.
        for (name, value) in intent.requiredHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (_, response) = try await uploadSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status >= 200, status <= 299 else {
            throw PushTransportException(PushFailure.http(status: status))
        }
    }

    func completeObject(objectId: String, lane: PushObjectLane) async throws -> PushObjectAck {
        var request = URLRequest(url: try laneURL("\(lane.endpoint)/\(objectId)/complete"))
        request.httpMethod = "POST"
        request.httpBody = Data()
        authorizeReceiverRequest(&request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status >= 200, status <= 299 else {
            throw PushTransportException(PushError.httpFailure(
                status: status, body: data, expectedVersion: PushProtocol.objectVersion
            ))
        }
        do {
            return try PushObjectAck.parse(data, expectedObjectId: objectId)
        } catch {
            throw PushTransportException(PushFailure(code: .ackInvalid))
        }
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
        contentEncoding: String?,
        contentType: String,
        binaryObject: Bool = false,
        manifestHeader: String? = nil
    ) async throws -> PushTransportResponse {
        var request = URLRequest(url: URL(string: endpoint.url)!)
        request.httpMethod = "POST"
        request.httpBody = body
        authorizeReceiverRequest(&request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if binaryObject {
            request.setValue("1", forHTTPHeaderField: "NOOP-Push-Binary-Object")
        }
        if let manifestHeader {
            request.setValue(manifestHeader, forHTTPHeaderField: "NOOP-Push-Manifest")
        }
        if let contentEncoding { request.setValue(contentEncoding, forHTTPHeaderField: "Content-Encoding") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bounded = data.prefix(PushProtocolLimits.maxAckBytes + 1)
        return PushTransportResponse(statusCode: status, body: Data(bounded))
    }

    private func authorizeReceiverRequest(_ request: inout URLRequest) {
        request.setValue("Bearer \(uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue(fleetToken, forHTTPHeaderField: Self.fleetTokenHeader)
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: RedirectBlockingDelegate.shared, delegateQueue: nil)
    }

    /// Direct-to-bucket PUTs move up to 256 MiB on whatever uplink the patient has; the 15 s API
    /// session would abort every large object, so uploads get their own long-resource session.
    static func makeUploadSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 30 * 60
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: RedirectBlockingDelegate.shared, delegateQueue: nil)
    }

    static func gzip(_ decoded: Data) throws -> Data {
        precondition(decoded.count <= PushProtocolLimits.maxBodyBytes)
        var stream = z_stream()
        var status = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw PushTransportException(PushFailure(code: .localData)) }
        defer { deflateEnd(&stream) }

        var output = Data(capacity: decoded.count)
        try decoded.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(decoded.count)
            let chunk = 64 * 1024
            var buffer = [UInt8](repeating: 0, count: chunk)
            repeat {
                stream.next_out = UnsafeMutablePointer<Bytef>(&buffer)
                stream.avail_out = uInt(chunk)
                status = deflate(&stream, Z_FINISH)
                let produced = chunk - Int(stream.avail_out)
                if produced > 0 { output.append(buffer, count: produced) }
            } while status == Z_OK
        }
        guard status == Z_STREAM_END else { throw PushTransportException(PushFailure(code: .localData)) }
        guard output.count <= PushProtocolLimits.maxWireBodyBytes else {
            throw PushTransportException(PushFailure(code: .localData))
        }
        return output
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
