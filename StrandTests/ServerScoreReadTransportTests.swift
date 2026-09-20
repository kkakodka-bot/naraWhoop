import Foundation
import NoopPush
import XCTest
#if !SERVER_SCORE_NATIVE_TESTS
@testable import Strand
#endif

private final class ScoreReadProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var data = Data("fixture".utf8)
    }
    static var reply = Reply()
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let reply = Self.reply
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ServerScoreReadTransportTests: XCTestCase {
    private final class OwnerFence: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0
        func isCurrent() -> Bool {
            lock.lock(); defer { lock.unlock() }
            checks += 1
            return checks < 3 // retire after admission and headers, while bytes are being consumed
        }
    }
    private func context() throws -> AccountSessionContext {
        .init(scope: try AccountScope(projectURL: "https://readback-fixture.invalid", userID: UUID().uuidString), generation: UUID())
    }
    private func request(_ context: AccountSessionContext) -> URLRequest {
        var request = URLRequest(url: URL(string: context.scope.projectURL)!.appendingPathComponent("rest/v1/rpc/get_server_score_snapshot_v2"))
        request.httpMethod = "POST"
        request.setValue("Bearer synthetic-test-token", forHTTPHeaderField: "Authorization")
        return request
    }
    private func configuration() -> URLSessionConfiguration {
        let configuration = ServerScoreReadTransport.configuration()
        configuration.protocolClasses = [ScoreReadProtocol.self]
        return configuration
    }
    override func setUp() {
        ScoreReadProtocol.reply = .init()
        ScoreReadProtocol.requests = []
    }

    func testEphemeralConfigurationHasNoSharedCredentialCookieOrResponseStorage() {
        let value = ServerScoreReadTransport.configuration()
        XCTAssertNil(value.urlCache)
        XCTAssertNil(value.httpCookieStorage)
        XCTAssertNil(value.urlCredentialStorage)
        XCTAssertFalse(value.httpShouldSetCookies)
        XCTAssertEqual(value.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(value.timeoutIntervalForResource, 30)
    }

    func testCapturedOwnerReadReturnsOnlyItsResponse() async throws {
        let context = try context()
        let data = try await ServerScoreReadTransport.read(request(context), context: context,
            configuration: configuration(), isCurrent: { $0 == context })
        XCTAssertEqual(data, Data("fixture".utf8))
        XCTAssertEqual(ScoreReadProtocol.requests.count, 1)
        XCTAssertEqual(ScoreReadProtocol.requests.first?.url, request(context).url)
    }

    func testWrongProjectRejectedBeforeTransport() async throws {
        let context = try context()
        var request = request(context)
        request.url = URL(string: "https://other-fixture.invalid/rest/v1/rpc/get_server_score_snapshot_v2")
        do {
            _ = try await ServerScoreReadTransport.read(request, context: context,
                configuration: configuration(), isCurrent: { _ in true })
            XCTFail("Foreign destination was accepted")
        } catch ServerScoreClient.FetchError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(ScoreReadProtocol.requests.isEmpty)
    }

    func testAnnouncedOversizeRejectedAtHeaders() async throws {
        ScoreReadProtocol.reply.headers = ["Content-Length": String(ServerScoreReadTransport.maximumResponseBytes + 1)]
        try await assertTooLarge()
    }

    func testUnannouncedOversizeRejectedWhileStreaming() async throws {
        ScoreReadProtocol.reply.data = Data(repeating: 0x20, count: ServerScoreReadTransport.maximumResponseBytes + 1)
        try await assertTooLarge()
    }

    func testExactResponseLimitRemainsUsable() async throws {
        let context = try context()
        ScoreReadProtocol.reply.data = Data(repeating: 0x20, count: ServerScoreReadTransport.maximumResponseBytes)
        let data = try await ServerScoreReadTransport.read(request(context), context: context,
            configuration: configuration(), isCurrent: { _ in true })
        XCTAssertEqual(data.count, ServerScoreReadTransport.maximumResponseBytes)
    }

    func testOwnerRetirementDuringStreamingRejectsResponse() async throws {
        let context = try context()
        let fence = OwnerFence()
        ScoreReadProtocol.reply.data = Data(repeating: 0x20, count: 32768)
        do {
            _ = try await ServerScoreReadTransport.read(request(context), context: context,
                configuration: configuration(), isCurrent: { _ in fence.isCurrent() })
            XCTFail("Retired owner's response was returned")
        } catch ServerScoreClient.FetchError.staleSession {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private func assertTooLarge() async throws {
        let context = try context()
        do {
            _ = try await ServerScoreReadTransport.read(request(context), context: context,
                configuration: configuration(), isCurrent: { _ in true })
            XCTFail("Oversized response was accepted")
        } catch ServerScoreDecodeError.tooLarge {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testUnauthorizedResponseDoesNotBecomeUsableData() async throws {
        let context = try context()
        ScoreReadProtocol.reply.status = 401
        do {
            _ = try await ServerScoreReadTransport.read(request(context), context: context,
                configuration: configuration(), isCurrent: { _ in true })
            XCTFail("Unauthorized response was accepted")
        } catch ServerScoreClient.FetchError.unauthorized {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRetiredOwnerRejectedBeforeTransport() async throws {
        let context = try context()
        do {
            _ = try await ServerScoreReadTransport.read(request(context), context: context,
                configuration: configuration(), isCurrent: { _ in false })
            XCTFail("Retired owner was accepted")
        } catch ServerScoreClient.FetchError.staleSession {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(ScoreReadProtocol.requests.isEmpty)
    }

    func testCancellationBeforeStartDoesNotSend() async throws {
        let context = try context()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ServerScoreReadTransport.read(request(context), context: context,
                configuration: configuration(), isCurrent: { _ in true })
        }
        do { _ = try await task.value; XCTFail("Cancelled read was sent") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(ScoreReadProtocol.requests.isEmpty)
    }

    func testRedirectDelegateRefusesSameOriginAndForeignOrigin() throws {
        let context = try context()
        let session = URLSession(configuration: configuration())
        defer { session.invalidateAndCancel() }
        let original = request(context)
        let task = session.dataTask(with: original) // Never resumed; this test exercises the delegate contract.
        let policy = ServerScoreReadRedirectPolicy()
        for target in [context.scope.projectURL + "/redirected", "https://other-fixture.invalid/redirected"] {
            let response = HTTPURLResponse(url: original.url!, statusCode: 307, httpVersion: nil,
                                           headerFields: ["Location": target])!
            var called = false
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                              newRequest: URLRequest(url: URL(string: target)!)) { redirected in
                called = true
                XCTAssertNil(redirected)
            }
            XCTAssertTrue(called)
        }
        XCTAssertTrue(ScoreReadProtocol.requests.isEmpty)
    }
}
