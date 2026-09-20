import Foundation
import XCTest
#if canImport(AIPrivacyHarness)
@testable import AIPrivacyHarness
#else
@testable import Strand
#endif

final class AIAccountPrivacyTests: XCTestCase {
    func testScopedKeysNeverReadAdoptOrDeleteLegacyItem() {
        let backend = AITestKeychain()
        backend.items["api-key"] = Data("legacy-synthetic-secret".utf8)
        let a = AIKeyStore(namespace: String(repeating: "a", count: 64), backend: backend)
        let b = AIKeyStore(namespace: String(repeating: "b", count: 64), backend: backend)
        XCTAssertNil(a.read())
        XCTAssertNil(b.read())
        XCTAssertTrue(a.save(" account-a-key ", owner: "openAI"))
        XCTAssertTrue(b.save("account-b-key", owner: "custom"))
        XCTAssertEqual(a.read(), .init(key: "account-a-key", provider: "openAI"))
        XCTAssertEqual(b.read(), .init(key: "account-b-key", provider: "custom"))
        XCTAssertTrue(a.clear())
        XCTAssertNil(a.read())
        XCTAssertEqual(b.read()?.key, "account-b-key")
        XCTAssertEqual(backend.items["api-key"], Data("legacy-synthetic-secret".utf8))
        XCTAssertFalse(backend.touched.contains("api-key"))
    }

    func testFailedReplacementPreservesKeyAndProviderTogether() {
        let backend = AITestKeychain()
        let keys = AIKeyStore(namespace: String(repeating: "c", count: 64), backend: backend)
        XCTAssertTrue(keys.save("original", owner: "openAI"))
        backend.failWrites = true
        XCTAssertFalse(keys.save("replacement", owner: "custom"))
        XCTAssertEqual(keys.read(), .init(key: "original", provider: "openAI"))
        XCTAssertTrue(backend.deleted.isEmpty)
    }

    func testUnassignedAndInvalidNamespacesNeverTouchKeychain() {
        let backend = AITestKeychain()
        for namespace in [nil, "", "unassigned", "api-key", String(repeating: "A", count: 64)] as [String?] {
            let keys = AIKeyStore(namespace: namespace, backend: backend)
            XCTAssertNil(keys.read())
            XCTAssertFalse(keys.save("synthetic", owner: "custom"))
            XCTAssertFalse(keys.clear())
        }
        XCTAssertTrue(backend.touched.isEmpty)
    }

    @MainActor
    func testRetirementRetainsScopedPreferencesAndCredentialsForOriginalOwner() throws {
        let name = "test.ai.account." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = AITestKeychain()
        let namespace = String(repeating: "a", count: 64)
        let account = AICoachAccount(defaults: defaults, namespace: namespace, isCurrent: { true }, keychain: backend)
        defaults.set(true, forKey: "ai.dataConsent")
        defaults.set("private synthetic prompt", forKey: "ai.systemPrompt")
        XCTAssertTrue(account.keys.save("synthetic", owner: "custom"))
        account.retire()
        account.retire()
        XCTAssertFalse(account.isCurrent)
        XCTAssertThrowsError(try account.requireCurrent())
        XCTAssertTrue(defaults.bool(forKey: "ai.dataConsent"))
        XCTAssertEqual(defaults.string(forKey: "ai.systemPrompt"), "private synthetic prompt")
        let reopened = AICoachAccount(defaults: defaults, namespace: namespace, isCurrent: { true }, keychain: backend)
        defer { reopened.retire() }
        XCTAssertEqual(reopened.keys.read()?.key, "synthetic")
        XCTAssertTrue(reopened.isCurrent)
        XCTAssertTrue(backend.deleted.isEmpty)
    }

    @MainActor
    func testOwnerGenerationFenceRejectsWorkBeforeRetirementHook() throws {
        let name = "test.ai.fence." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var current = true
        let account = AICoachAccount(defaults: defaults, namespace: String(repeating: "a", count: 64),
                                     isCurrent: { current }, keychain: AITestKeychain())
        defer { account.retire() }
        XCTAssertNoThrow(try account.requireCurrent())
        current = false
        XCTAssertFalse(account.isCurrent)
        XCTAssertThrowsError(try account.requireCurrent())
    }

    @MainActor
    func testRetirementCancelsOwnedSessionWithoutInvalidatingAnotherOwnersSession() async throws {
        let name = "test.ai.cancel." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AIPrivacyTestURLProtocol.self]
        let started = expectation(description: "owner A request started")
        let stopped = expectation(description: "owner A request cancelled")
        let aHost = UUID().uuidString.lowercased() + ".invalid"
        let bHost = UUID().uuidString.lowercased() + ".invalid"
        AIPrivacyTestURLProtocol.install(host: aHost, start: { _ in started.fulfill() }, stop: { stopped.fulfill() })
        AIPrivacyTestURLProtocol.install(host: bHost, start: { $0.reply(Data([2, 4, 6])) })
        defer { AIPrivacyTestURLProtocol.remove(host: aHost); AIPrivacyTestURLProtocol.remove(host: bHost) }
        let a = AICoachAccount(defaults: defaults, namespace: String(repeating: "a", count: 64),
                               isCurrent: { true }, configuration: config, keychain: AITestKeychain())
        let b = AICoachAccount(defaults: defaults, namespace: String(repeating: "b", count: 64),
                               isCurrent: { true }, configuration: config, keychain: AITestKeychain())
        defer { a.retire(); b.retire() }
        let pending = Task { try await a.session.data(from: URL(string: "https://" + aHost + "/models")!) }
        await fulfillment(of: [started], timeout: 2)
        a.retire()
        await fulfillment(of: [stopped], timeout: 2)
        do { _ = try await pending.value; XCTFail("retired request completed") }
        catch { XCTAssertEqual((error as NSError).code, URLError.cancelled.rawValue) }
        let (bytes, _) = try await b.session.data(from: URL(string: "https://" + bHost + "/models")!)
        XCTAssertEqual(bytes, Data([2, 4, 6]))
        XCTAssertTrue(b.isCurrent)
    }
}

final class AITestKeychain: AIKeychainAccess {
    var items: [String: Data] = [:]
    var touched: [String] = []
    var deleted: [String] = []
    var failWrites = false
    func read(service: String, account: String) -> Data? {
        XCTAssertEqual(service, "com.noop.aicoach")
        touched.append(account)
        return items[account]
    }
    func write(_ data: Data, service: String, account: String) -> Bool {
        XCTAssertEqual(service, "com.noop.aicoach")
        touched.append(account)
        guard !failWrites else { return false }
        items[account] = data
        return true
    }
    func remove(service: String, account: String) -> Bool {
        XCTAssertEqual(service, "com.noop.aicoach")
        touched.append(account); deleted.append(account)
        items.removeValue(forKey: account)
        return true
    }
}

final class AIPrivacyTestURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handlers: [String: (start: (AIPrivacyTestURLProtocol) -> Void, stop: () -> Void)] = [:]
    static func install(host: String, start: @escaping (AIPrivacyTestURLProtocol) -> Void, stop: @escaping () -> Void = {}) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = (start, stop)
    }
    static func remove(host: String) { lock.lock(); defer { lock.unlock() }; handlers.removeValue(forKey: host) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private func handler() -> (start: (AIPrivacyTestURLProtocol) -> Void, stop: () -> Void)? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Self.handlers[request.url?.host ?? ""]
    }
    override func startLoading() {
        guard let handler = handler() else {
            XCTFail("unexpected test request")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        handler.start(self)
    }
    override func stopLoading() { handler()?.stop() }
    func reply(_ body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
