import Foundation
import NoopPush

enum ScoringInputTransport {
    static let maximumResponseBytes = 72 * 1024
    private static let operations: Set<String> = ["put_scoring_history_input_v3",
        "get_scoring_history_input_head_v3", "get_scoring_history_input_v3"]

    static func configuration() -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral
        value.urlCache = nil; value.httpCookieStorage = nil; value.httpShouldSetCookies = false
        value.urlCredentialStorage = nil; value.requestCachePolicy = .reloadIgnoringLocalCacheData
        value.timeoutIntervalForRequest = 20; value.timeoutIntervalForResource = 30
        value.waitsForConnectivity = false
        return value
    }

    static func perform(_ request: URLRequest, context: AccountSessionContext,
                        configuration: URLSessionConfiguration = configuration(),
                        isCurrent: @escaping @Sendable (AccountSessionContext) -> Bool) async throws -> (Data, URLResponse) {
        guard let url = request.url, let base = URL(string: context.scope.projectURL),
              request.httpMethod == "POST", operations.contains(url.lastPathComponent),
              url == base.appendingPathComponent("rest/v1/rpc/" + url.lastPathComponent) else {
            throw ScoringInputRPC.Failure.invalidResponse
        }
        try Task.checkCancellation()
        guard isCurrent(context) else { throw ScoringInputRPC.Failure.staleOwner }
        let session = URLSession(configuration: configuration, delegate: ScoringInputRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard isCurrent(context) else { throw ScoringInputRPC.Failure.staleOwner }
        guard let http = response as? HTTPURLResponse, http.url == url,
              response.expectedContentLength <= Int64(maximumResponseBytes) else {
            throw ScoringInputRPC.Failure.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw ScoringInputRPC.Failure.invalidResponse }
            data.append(byte)
            if data.count % 4096 == 0 {
                try Task.checkCancellation()
                guard isCurrent(context) else { throw ScoringInputRPC.Failure.staleOwner }
            }
        }
        try Task.checkCancellation()
        guard isCurrent(context) else { throw ScoringInputRPC.Failure.staleOwner }
        return (data, response) // Preserve non-200 SQLSTATE bodies for the RPC classifier.
    }
}

final class ScoringInputRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
