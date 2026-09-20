import Foundation
import NoopPush

/// User-facing push error copy. Mirrors Android `pushEndpointProblemMessage` / `pushFailureMessage`.
enum CloudPushMessaging {
    static func endpointProblem(_ problem: PushEndpointProblem) -> String {
        switch problem {
        case .malformedURL:
            return String(localized: "Enter a valid URL.")
        case .missingScheme:
            return String(localized: "The URL must start with http:// or https://.")
        case .unsupportedScheme:
            return String(localized: "Only HTTP and HTTPS are supported.")
        case .userInfoNotAllowed:
            return String(localized: "User names and passwords are not allowed in the URL.")
        case .fragmentNotAllowed:
            return String(localized: "URL fragments are not allowed.")
        case .missingHost:
            return String(localized: "The URL must include a host.")
        case .invalidHost:
            return String(localized: "The URL host is invalid.")
        case .invalidPort:
            return String(localized: "The URL port is invalid.")
        case .httpRequiresLocalAddress:
            return String(localized: "HTTP is only allowed for localhost and private-network addresses. Use HTTPS for public hosts.")
        }
    }

    static func pushFailureMessage(_ failure: PushFailure) -> String {
        let status = failure.httpStatus ?? defaultStatus(for: failure.code)
        let base: String = switch failure.code {
        case .dnsLookup:
            String(localized: "DNS lookup failed. Check the endpoint hostname and DNS configuration.")
        case .tlsCertificate:
            String(localized: "TLS certificate validation failed. Check the hostname, certificate chain, and expiry.")
        case .tlsHandshake:
            String(localized: "TLS handshake failed. Check the reverse proxy, TLS version, and cipher suites.")
        case .networkTimeout:
            String(localized: "The network timed out before the request finished. Check reachability and proxy timeouts.")
        case .connectionRefused:
            String(localized: "The connection was refused. Confirm the receiver is running and the proxy or backend port is listening.")
        case .networkUnreachable:
            String(localized: "The network route is unavailable. Check Wi‑Fi, routing, and firewall rules.")
        case .connectionReset:
            String(localized: "The connection was reset. Check whether the receiver or proxy restarted and its connection timeouts.")
        case .networkIO:
            String(localized: "Network I/O failed before a durable acknowledgement was received.")
        case .httpAuth:
            String(localized: "HTTP \(status): authentication was rejected. Check the token and that the proxy forwards the Authorization header.")
        case .httpNotFound:
            String(localized: "HTTP \(status): the endpoint path was not found. Check the full URL and reverse-proxy routing.")
        case .httpTimeout:
            String(localized: "HTTP \(status): the receiver or proxy timed out handling the request.")
        case .httpTooLarge:
            String(localized: "HTTP \(status): the request was too large. Align receiver and proxy body limits with protocol 1.0.")
        case .httpMediaType:
            String(localized: "HTTP \(status): the receiver rejected both gzip and uncompressed NDJSON uploads.")
        case .httpProtocolRejected:
            String(localized: "HTTP \(status): the receiver rejected the protocol batch. Check v1 schema, allowed streams, and logs.")
        case .httpRateLimit:
            String(localized: "HTTP \(status): the receiver rate limit was hit. Automatic retries will back off.")
        case .httpServer:
            String(localized: "HTTP \(status): receiver or reverse-proxy server error. Check logs and health.")
        case .httpClient:
            String(localized: "HTTP \(status): unexpected client error. Check the endpoint and reverse-proxy configuration.")
        case .capabilitiesInvalid:
            String(localized: "The capabilities response was malformed or not protocol 1.0.")
        case .ackInvalid:
            String(localized: "The receiver acknowledgement was malformed or did not match the batch. The cursor was not advanced.")
        case .localData:
            String(localized: "A local record exceeded protocol limits or could not be encoded exactly. The cursor was not advanced.")
        case .localDatabase:
            String(localized: "The local database or push progress could not be read or saved.")
        }
        let details = [failure.receiverCode, failure.safeDiagnosticSummary].compactMap { $0 }
        guard !details.isEmpty else { return String(base.prefix(300)) }
        let suffix = " (\(details.joined(separator: "; ")))"
        // Settings retain at most 300 characters; preserve the safe request identity for diagnosis.
        return String(base.prefix(max(0, 300 - suffix.count))) + String(suffix.prefix(300))
    }

    private static func defaultStatus(for code: PushFailureCode) -> Int {
        switch code {
        case .httpAuth: 401
        case .httpNotFound: 404
        case .httpTimeout: 408
        case .httpTooLarge: 413
        case .httpMediaType: 415
        case .httpProtocolRejected: 422
        case .httpRateLimit: 429
        case .httpServer: 500
        case .httpClient: 400
        default: 0
        }
    }
}
