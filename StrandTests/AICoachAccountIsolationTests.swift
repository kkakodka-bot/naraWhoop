import Foundation
import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class AICoachAccountIsolationTests: XCTestCase {
    @MainActor private struct Fixture {
        let engine: AICoachEngine
        let defaults: UserDefaults
        let suite: String
        func finish() {
            engine.shutdownForAccountChange()
            defaults.removePersistentDomain(forName: suite)
        }
    }
    private func fixture(namespace: String, backend: AITestKeychain,
                         isCurrent: @escaping () -> Bool = { true },
                         session: URLSession? = nil) throws -> Fixture {
        let suite = "test.ai.engine." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let repo = Repository(deviceId: "synthetic-ai-device", openStore: { try await WhoopStore.inMemory() })
        let engine = AICoachEngine(repo: repo, defaults: defaults, accountNamespace: namespace,
                                   isCurrent: isCurrent, session: session, keychain: backend)
        return .init(engine: engine, defaults: defaults, suite: suite)
    }

    func testAccountSwitchIsolatesAllCoachPreferencesAndRetirementPreservesOriginalOwner() throws {
        let backend = AITestKeychain()
        backend.items["api-key"] = Data("legacy-unassigned-key".utf8)
        let a = try fixture(namespace: String(repeating: "a", count: 64), backend: backend)
        let b = try fixture(namespace: String(repeating: "b", count: 64), backend: backend)
        defer { a.finish(); b.finish() }
        a.engine.provider = .custom
        a.engine.model = "owner-a-model"
        a.engine.dataConsent = true
        a.engine.includeOnDeviceSignals = true
        a.engine.multimodalChartEnabled = true
        a.engine.customBaseURL = "https://owner-a.invalid/v1"
        a.engine.customAuthHeader = .xAPIKey
        a.engine.customConnected = true
        a.engine.customSystemPrompt = "owner-a-private-prompt"
        a.engine.setKey("owner-a-key")
        a.engine.messages = [.init(role: .user, text: "private synthetic question")]
        a.engine.pendingPrompt = "private pending question"
        a.engine.pendingChartImage = "synthetic-chart"
        XCTAssertTrue(a.engine.hasKey)
        XCTAssertEqual(b.engine.provider, .openAI)
        XCTAssertFalse(b.engine.hasKey)
        XCTAssertFalse(b.engine.dataConsent)
        XCTAssertFalse(b.engine.includeOnDeviceSignals)
        XCTAssertFalse(b.engine.multimodalChartEnabled)
        XCTAssertFalse(b.engine.customConnected)
        XCTAssertEqual(b.engine.customBaseURL, "")
        XCTAssertEqual(b.engine.customSystemPrompt, AICoachEngine.defaultSystemPrompt)

        a.engine.shutdownForAccountChange()
        a.engine.dataConsent = false
        a.engine.customSystemPrompt = "late replacement"
        a.engine.setKey("late replacement")
        a.engine.clearKey()
        a.engine.disconnect()
        a.engine.appendGeneratedBrief("late private brief")
        XCTAssertTrue(a.engine.messages.isEmpty)
        XCTAssertNil(a.engine.pendingPrompt)
        XCTAssertNil(a.engine.pendingChartImage)
        XCTAssertFalse(a.engine.isConfigured)
        XCTAssertTrue(a.defaults.bool(forKey: "ai.dataConsent"))
        XCTAssertEqual(a.defaults.string(forKey: "ai.systemPrompt"), "owner-a-private-prompt")

        let reopened = AICoachEngine(repo: Repository(deviceId: "synthetic-ai-reopen"), defaults: a.defaults,
                                    accountNamespace: String(repeating: "a", count: 64), keychain: backend)
        defer { reopened.shutdownForAccountChange() }
        XCTAssertTrue(reopened.hasKey)
        XCTAssertTrue(reopened.dataConsent)
        XCTAssertTrue(reopened.includeOnDeviceSignals)
        XCTAssertTrue(reopened.multimodalChartEnabled)
        XCTAssertTrue(reopened.customConnected)
        XCTAssertEqual(reopened.provider, .custom)
        XCTAssertEqual(reopened.model, "owner-a-model")
        XCTAssertEqual(reopened.customBaseURL, "https://owner-a.invalid/v1")
        XCTAssertEqual(reopened.customAuthHeader, .xAPIKey)
        XCTAssertEqual(reopened.systemPrompt, "owner-a-private-prompt")
        XCTAssertEqual(backend.items["api-key"], Data("legacy-unassigned-key".utf8))
        XCTAssertFalse(backend.touched.contains("api-key"))
    }

    func testRetiredModelRefreshCannotPublishLateSuccessOrError() async throws {
        for fails in [false, true] {
            let a = try fixture(namespace: String(repeating: "a", count: 64), backend: AITestKeychain())
            defer { a.finish() }
            a.engine.provider = .custom
            let entered = expectation(description: "model refresh awaiting")
            let gate = Gate()
            a.engine.fetchModelsOverride = { _, _ in
                entered.fulfill()
                await gate.wait()
                if fails { throw URLError(.timedOut) }
                return ["stale-owner-model"]
            }
            let pending = Task { await a.engine.refreshModels() }
            await fulfillment(of: [entered], timeout: 2)
            a.engine.shutdownForAccountChange()
            await gate.open()
            await pending.value
            XCTAssertTrue(a.engine.availableModels.isEmpty)
            XCTAssertNil(a.engine.errorText)
            XCTAssertTrue(a.engine.messages.isEmpty)
        }
    }

    func testGenerationChangeFencesNetworkAndPreferenceWritesBeforeShutdown() async throws {
        var current = true
        let backend = AITestKeychain()
        let a = try fixture(namespace: String(repeating: "a", count: 64), backend: backend,
                            isCurrent: { current })
        defer { a.finish() }
        a.engine.provider = .custom
        a.engine.customConnected = true
        a.engine.setKey("original-key")
        let entered = expectation(description: "generation-bound refresh")
        let gate = Gate()
        a.engine.fetchModelsOverride = { _, _ in entered.fulfill(); await gate.wait(); return ["stale"] }
        let pending = Task { await a.engine.refreshModels() }
        await fulfillment(of: [entered], timeout: 2)
        current = false
        a.engine.dataConsent = true
        a.engine.customSystemPrompt = "late prompt"
        a.engine.clearKey()
        await gate.open()
        await pending.value
        XCTAssertFalse(a.engine.availableModels.contains("stale"))
        XCTAssertFalse(a.defaults.bool(forKey: "ai.dataConsent"))
        XCTAssertNil(a.defaults.string(forKey: "ai.systemPrompt"))
        XCTAssertTrue(backend.deleted.isEmpty)
        let touched = backend.touched.count
        await a.engine.send("late question")
        await a.engine.refreshModels()
        XCTAssertEqual(backend.touched.count, touched)
        XCTAssertTrue(a.engine.messages.isEmpty)
    }

    func testEachCustomRequestUsesItsCapturedAccountEndpointAndAuthHeader() async throws {
        let backend = AITestKeychain()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIPrivacyTestURLProtocol.self]
        let templateSession = URLSession(configuration: configuration)
        defer { templateSession.invalidateAndCancel() }
        let a = try fixture(namespace: String(repeating: "a", count: 64), backend: backend, session: templateSession)
        let b = try fixture(namespace: String(repeating: "b", count: 64), backend: backend, session: templateSession)
        defer { a.finish(); b.finish() }
        let aHost = UUID().uuidString.lowercased() + ".invalid"
        let bHost = UUID().uuidString.lowercased() + ".invalid"
        AIPrivacyTestURLProtocol.install(host: aHost, start: { request in
            XCTAssertEqual(request.request.url?.path, "/v1/models")
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "x-api-key"), "key-a")
            XCTAssertNil(request.request.value(forHTTPHeaderField: "Authorization"))
            request.reply(Data("{\"data\":[{\"id\":\"model-a\"}]}".utf8))
        })
        AIPrivacyTestURLProtocol.install(host: bHost, start: { request in
            XCTAssertEqual(request.request.url?.path, "/v1/models")
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer key-b")
            XCTAssertNil(request.request.value(forHTTPHeaderField: "x-api-key"))
            request.reply(Data("{\"data\":[{\"id\":\"model-b\"}]}".utf8))
        })
        defer { AIPrivacyTestURLProtocol.remove(host: aHost); AIPrivacyTestURLProtocol.remove(host: bHost) }
        a.engine.provider = .custom
        a.engine.customBaseURL = "https://" + aHost + "/v1/chat/completions/"
        a.engine.customAuthHeader = .xAPIKey
        a.engine.setKey("key-a")
        b.engine.provider = .custom
        b.engine.customBaseURL = "https://" + bHost + "/v1"
        b.engine.customAuthHeader = .bearer
        b.engine.setKey("key-b")
        await a.engine.refreshModels()
        await b.engine.refreshModels()
        XCTAssertTrue(a.engine.availableModels.contains("model-a"))
        XCTAssertFalse(a.engine.availableModels.contains("model-b"))
        XCTAssertTrue(b.engine.availableModels.contains("model-b"))
        XCTAssertFalse(b.engine.availableModels.contains("model-a"))
        XCTAssertNil(a.engine.errorText)
        XCTAssertNil(b.engine.errorText)
    }

    func testShutdownCancelsActualEngineRequestAndSuppressesCancellationError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIPrivacyTestURLProtocol.self]
        let templateSession = URLSession(configuration: configuration)
        defer { templateSession.invalidateAndCancel() }
        let a = try fixture(namespace: String(repeating: "a", count: 64), backend: AITestKeychain(), session: templateSession)
        defer { a.finish() }
        let host = UUID().uuidString.lowercased() + ".invalid"
        let entered = expectation(description: "actual engine request entered")
        let cancelled = expectation(description: "actual engine request cancelled")
        AIPrivacyTestURLProtocol.install(host: host, start: { _ in entered.fulfill() }, stop: { cancelled.fulfill() })
        defer { AIPrivacyTestURLProtocol.remove(host: host) }
        a.engine.provider = .custom
        a.engine.customBaseURL = "https://" + host + "/v1"
        let pending = Task { await a.engine.refreshModels() }
        await fulfillment(of: [entered], timeout: 2)
        a.engine.shutdownForAccountChange()
        await fulfillment(of: [cancelled], timeout: 2)
        await pending.value
        XCTAssertNil(a.engine.errorText)
        XCTAssertTrue(a.engine.availableModels.isEmpty)
        XCTAssertTrue(a.engine.messages.isEmpty)
    }

    func testShutdownClearsAndFencesAnActualStreamingTranscript() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIPrivacyTestURLProtocol.self]
        let templateSession = URLSession(configuration: configuration)
        defer { templateSession.invalidateAndCancel() }
        let a = try fixture(namespace: String(repeating: "a", count: 64), backend: AITestKeychain(), session: templateSession)
        defer { a.finish() }
        let host = UUID().uuidString.lowercased() + ".invalid"
        let entered = expectation(description: "stream entered")
        let cancelled = expectation(description: "stream cancelled")
        AIPrivacyTestURLProtocol.install(host: host, start: { stream in
            XCTAssertEqual(stream.request.url?.path, "/v1/chat/completions")
            let response = HTTPURLResponse(url: stream.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": "text/event-stream"])!
            stream.client?.urlProtocol(stream, didReceive: response, cacheStoragePolicy: .notAllowed)
            stream.client?.urlProtocol(stream, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"before-retirement\"}}]}\n\n".utf8))
            entered.fulfill()
        }, stop: { cancelled.fulfill() })
        defer { AIPrivacyTestURLProtocol.remove(host: host) }
        a.engine.provider = .custom
        a.engine.customBaseURL = "https://" + host + "/v1"
        a.engine.customConnected = true
        let pending = Task { await a.engine.send("synthetic question") }
        await fulfillment(of: [entered], timeout: 2)
        for _ in 0..<200 where a.engine.messages.last?.text != "before-retirement" {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(a.engine.messages.last?.text, "before-retirement")
        a.engine.shutdownForAccountChange()
        await fulfillment(of: [cancelled], timeout: 2)
        await pending.value
        XCTAssertFalse(a.engine.sending)
        XCTAssertNil(a.engine.errorText)
        XCTAssertTrue(a.engine.messages.isEmpty)
    }

    private actor Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiting = $0 }
        }
        func open() { opened = true; waiting?.resume(); waiting = nil }
    }
}
