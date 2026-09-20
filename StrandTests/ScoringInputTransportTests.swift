import Foundation
import NoopPush
import XCTest
@testable import Strand

private final class InputReplyProtocol: URLProtocol {
    static var data = Data("{}".utf8)
    static var headers: [String: String] = [:]
    static var status = 200
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
            httpVersion: "HTTP/1.1", headerFields: Self.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ScoringInputTransportTests: XCTestCase {
    private final class Fence: @unchecked Sendable {
        private let lock = NSLock(); private var calls = 0
        func current() -> Bool { lock.lock(); defer { lock.unlock() }; calls += 1; return calls < 3 }
    }
    override func setUp() {
        InputReplyProtocol.data = Data("{}".utf8); InputReplyProtocol.headers = [:]
        InputReplyProtocol.status = 200; InputReplyProtocol.requests = 0
    }
    private func fixture() throws -> (AccountSessionContext, URLRequest, URLSessionConfiguration) {
        let context = AccountSessionContext(scope: try AccountScope(projectURL: "https://input-http.invalid", userID: UUID().uuidString), generation: UUID())
        var request = URLRequest(url: URL(string: context.scope.projectURL)!.appendingPathComponent("rest/v1/rpc/get_scoring_history_input_v3"))
        request.httpMethod = "POST"
        let configuration = ScoringInputTransport.configuration(); configuration.protocolClasses = [InputReplyProtocol.self]
        return (context, request, configuration)
    }

    func testNoSharedCredentialCookieOrResponseStorage() throws {
        let (_, _, configuration) = try fixture()
        XCTAssertNil(configuration.urlCache); XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage); XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testExactLimitAndSQLStateErrorBodyArePreserved() async throws {
        let (context, request, configuration) = try fixture()
        InputReplyProtocol.data = Data(repeating: 0x20, count: ScoringInputTransport.maximumResponseBytes)
        var result = try await ScoringInputTransport.perform(request, context: context, configuration: configuration, isCurrent: { _ in true })
        XCTAssertEqual(result.0.count, ScoringInputTransport.maximumResponseBytes)
        InputReplyProtocol.data = Data("{\"code\":\"40001\",\"message\":\"history_revision_conflict\"}".utf8)
        InputReplyProtocol.status = 500
        result = try await ScoringInputTransport.perform(request, context: context, configuration: configuration, isCurrent: { _ in true })
        XCTAssertEqual(result.0, InputReplyProtocol.data); XCTAssertEqual((result.1 as? HTTPURLResponse)?.statusCode, 500)
    }

    func testAnnouncedAndUnannouncedOverflowsAreRejected() async throws {
        let (context, request, configuration) = try fixture()
        for announced in [true, false] {
            InputReplyProtocol.headers = announced ? ["Content-Length": String(ScoringInputTransport.maximumResponseBytes + 1)] : [:]
            InputReplyProtocol.data = announced ? Data() : Data(repeating: 0x20, count: ScoringInputTransport.maximumResponseBytes + 1)
            do {
                _ = try await ScoringInputTransport.perform(request, context: context, configuration: configuration, isCurrent: { _ in true })
                XCTFail("response limit was bypassed")
            } catch ScoringInputRPC.Failure.invalidResponse {} catch { XCTFail("unexpected error \(error)") }
        }
    }

    func testWrongProjectRPCOrMethodDoesNotSend() async throws {
        let (context, original, configuration) = try fixture()
        var foreign = original; foreign.url = URL(string: "https://other.invalid/rest/v1/rpc/get_scoring_history_input_v3")
        var path = original; path.url = original.url?.appendingPathComponent("not_an_rpc")
        var method = original; method.httpMethod = "GET"
        for request in [foreign, path, method] {
            do {
                _ = try await ScoringInputTransport.perform(request, context: context, configuration: configuration, isCurrent: { _ in true })
                XCTFail("request destination was not pinned")
            } catch ScoringInputRPC.Failure.invalidResponse {} catch { XCTFail("unexpected error \(error)") }
        }
        XCTAssertEqual(InputReplyProtocol.requests, 0)
    }

    func testRetirementBeforeAndDuringStreamingRefusesResponse() async throws {
        let (context, request, configuration) = try fixture()
        do {
            _ = try await ScoringInputTransport.perform(request, context: context, configuration: configuration, isCurrent: { _ in false })
            XCTFail("retired admission sent")
        } catch ScoringInputRPC.Failure.staleOwner {} catch { XCTFail("unexpected error \(error)") }
        XCTAssertEqual(InputReplyProtocol.requests, 0)
        InputReplyProtocol.data = Data(repeating: 0x20, count: 8192)
        let fence = Fence()
        do {
            _ = try await ScoringInputTransport.perform(request, context: context, configuration: configuration, isCurrent: { _ in fence.current() })
            XCTFail("retired response returned")
        } catch ScoringInputRPC.Failure.staleOwner {} catch { XCTFail("unexpected error \(error)") }
    }

    func testRedirectPolicyNeverForwardsAuthenticatedRequest() throws {
        let (_, request, configuration) = try fixture()
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request) // Not resumed; delegate contract only.
        for url in [request.url!.appendingPathComponent("redirect"), URL(string: "https://other.invalid")!] {
            var called = false
            ScoringInputRedirectPolicy().urlSession(session, task: task,
                willPerformHTTPRedirection: HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!,
                newRequest: URLRequest(url: url)) { forwarded in called = true; XCTAssertNil(forwarded) }
            XCTAssertTrue(called)
        }
        XCTAssertEqual(InputReplyProtocol.requests, 0)
    }
}
