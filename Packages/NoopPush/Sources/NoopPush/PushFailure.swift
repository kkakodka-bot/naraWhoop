import Foundation

public enum PushFailureCode: String, Sendable {
    case dnsLookup = "DNS_LOOKUP"
    case tlsCertificate = "TLS_CERTIFICATE"
    case tlsHandshake = "TLS_HANDSHAKE"
    case networkTimeout = "NETWORK_TIMEOUT"
    case connectionRefused = "CONNECTION_REFUSED"
    case networkUnreachable = "NETWORK_UNREACHABLE"
    case connectionReset = "CONNECTION_RESET"
    case networkIO = "NETWORK_IO"
    case httpAuth = "HTTP_AUTH"
    case httpNotFound = "HTTP_NOT_FOUND"
    case httpTimeout = "HTTP_TIMEOUT"
    case httpTooLarge = "HTTP_TOO_LARGE"
    case httpMediaType = "HTTP_MEDIA_TYPE"
    case httpProtocolRejected = "HTTP_PROTOCOL_REJECTED"
    case httpRateLimit = "HTTP_RATE_LIMIT"
    case httpServer = "HTTP_SERVER"
    case httpClient = "HTTP_CLIENT"
    case capabilitiesInvalid = "CAPABILITIES_INVALID"
    case ackInvalid = "ACK_INVALID"
    case localData = "LOCAL_DATA"
    case localDatabase = "LOCAL_DATABASE"
}

public struct PushFailure: Sendable {
    public let code: PushFailureCode
    public let httpStatus: Int?
    public let receiverCode: String?
    public let stream: String?
    public let stage: String?
    public let correlationId: String?

    public init(code: PushFailureCode, httpStatus: Int? = nil, receiverCode: String? = nil,
                stream: String? = nil, stage: String? = nil, correlationId: String? = nil) {
        self.code = code
        self.httpStatus = httpStatus
        self.receiverCode = receiverCode
        self.stream = stream.flatMap { value in
            PushAppendTable(rawValue: value) != nil || PushMutableTable(rawValue: value) != nil ||
                PushBinaryTable(rawValue: value) != nil ? value : nil
        }
        self.stage = stage.flatMap { Self.stages.contains($0) ? $0 : nil }
        self.correlationId = correlationId.flatMap { value in
            value.range(of: #"^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$"#,
                        options: .regularExpression) != nil ? value.lowercased() : nil
        }
    }

    private static let stages: Set<String> = [
        "receipt_lookup", "quota", "wal", "device", "archive", "archive_manifest",
        "archive_write", "archive_verify", "projection", "replacement", "ack", "wal_cleanup",
    ]

    public var safeDiagnosticSummary: String? {
        let fields = [stream.map { "stream=\($0)" }, stage.map { "stage=\($0)" },
                      correlationId.map { "request=\($0)" }].compactMap { $0 }
        return fields.isEmpty ? nil : fields.joined(separator: "; ")
    }

    public func attributed(to table: any PushTable) -> PushFailure {
        PushFailure(code: code, httpStatus: httpStatus, receiverCode: receiverCode,
                    stream: table.wireName, stage: stage, correlationId: correlationId)
    }

    public var safeCode: String { code.rawValue.lowercased() }

    public var retryable: Bool {
        switch code {
        case .dnsLookup, .tlsHandshake, .networkTimeout, .connectionRefused,
             .networkUnreachable, .connectionReset, .networkIO, .httpTimeout,
             .httpRateLimit, .httpServer, .localDatabase:
            return true
        default:
            return false
        }
    }

    public static func http(status: Int, receiverCode: String? = nil, stream: String? = nil,
                            stage: String? = nil, correlationId: String? = nil) -> PushFailure {
        let code: PushFailureCode = switch status {
        case 401, 403: .httpAuth
        case 404: .httpNotFound
        case 408: .httpTimeout
        case 413: .httpTooLarge
        case 415: .httpMediaType
        case 400, 409, 422: .httpProtocolRejected
        case 429: .httpRateLimit
        case 500...599: .httpServer
        default: .httpClient
        }
        return PushFailure(code: code, httpStatus: status, receiverCode: receiverCode,
                           stream: stream, stage: stage, correlationId: correlationId)
    }
}

public struct PushTransportException: Error, Sendable {
    public let failure: PushFailure

    public init(_ failure: PushFailure) {
        self.failure = failure
    }
}

public enum PushError {
    /// Local table identity is authoritative. Receiver fields are bounded diagnostics only.
    public static func httpFailure(status: Int, body: Data, expectedVersion: String,
                                   table: (any PushTable)? = nil) -> PushFailure {
        let code = parseCode(body, expectedVersion: expectedVersion)
        let object = code == nil ? nil : (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
        return PushFailure.http(status: status, receiverCode: code, stream: table?.wireName,
                                stage: object?["stage"] as? String,
                                correlationId: object?["correlationId"] as? String)
    }

    public static func parseCode(_ bytes: Data, expectedVersion: String = PushProtocol.version) -> String? {
        guard !bytes.isEmpty, bytes.count <= PushProtocolLimits.maxAckBytes else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              obj["type"] as? String == "error",
              obj["protocolVersion"] as? String == expectedVersion,
              let code = obj["code"] as? String,
              code.range(of: #"^[a-z][a-z0-9_]{0,63}$"#, options: .regularExpression) != nil
        else { return nil }
        return code
    }
}
