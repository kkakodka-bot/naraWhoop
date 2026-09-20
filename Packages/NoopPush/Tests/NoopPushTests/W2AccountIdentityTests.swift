import Foundation
import XCTest
@testable import NoopPush

private let w2UserA = "11111111-1111-4111-8111-111111111111"
private let w2UserB = "22222222-2222-4222-8222-222222222222"
private let w2Source = "33333333-3333-4333-8333-333333333333"
private let w2Now = Date(timeIntervalSince1970: 1_800_000_000)

final class W2AccountIdentityTests: XCTestCase {
    func testSecureClearFailureStillInvalidatesAndNotifies() async throws {
        let fixture = try W2Fixture()
        let notifications = W2NotificationCount()
        let controller = AccountSessionController(credentials: fixture.store, transport: fixture.transport,
                                                  changed: { notifications.increment() })
        controller.configure(fixture.configuration)
        let initial = try XCTUnwrap(controller.currentContext())
        fixture.store.failClear = true
        XCTAssertThrowsError(try controller.clearSession())
        XCTAssertFalse(controller.isCurrent(initial))
        XCTAssertNil(controller.currentContext())
        XCTAssertEqual(notifications.value, 2)
        await expect(.credentialUnavailable) {
            _ = try await controller.signIn(email: "synthetic@example.test", password: "synthetic")
        }
        XCTAssertEqual(notifications.value, 3)
    }

    func testCredentialUnlockNotifiesAndChangesUnassignedGeneration() throws {
        let fixture = try W2Fixture()
        let notifications = W2NotificationCount()
        let controller = AccountSessionController(credentials: fixture.store, transport: fixture.transport,
                                                  changed: { notifications.increment() })
        controller.configure(fixture.configuration)
        fixture.store.failLoad = true
        let unavailable = controller.identitySnapshot()
        XCTAssertNil(unavailable.scope)
        fixture.store.failLoad = false
        let restored = controller.identitySnapshot()
        XCTAssertEqual(restored.scope?.userID, w2UserA)
        XCTAssertNotEqual(restored.generation, unavailable.generation)
        XCTAssertEqual(notifications.value, 2)
    }

    func testFailedSignInSaveDoesNotPublishOrPersistNewIdentity() async throws {
        let fixture = try W2Fixture()
        let login = Task { try await fixture.controller.signIn(email: "synthetic@example.test", password: "synthetic") }
        await fixture.transport.waitForRequests(1)
        fixture.store.failSave = true
        await fixture.transport.answer(0, with: reply(user: w2UserB))
        await expect(.credentialUnavailable) { _ = try await login.value }
        XCTAssertNil(fixture.controller.currentContext())
        XCTAssertNil(fixture.store.current)
    }

    func testCanonicalScopeAndPersistentNamespaceIgnoreGeneration() throws {
        let a = try AccountScope(projectURL: "https://EXAMPLE.test:443/", userID: w2UserA.uppercased())
        let same = try AccountScope(projectURL: "https://example.test", userID: w2UserA)
        XCTAssertEqual(a, same)
        XCTAssertEqual(a.namespace.count, 64)
        XCTAssertNotEqual(a.namespace, try AccountScope(projectURL: a.projectURL, userID: w2UserB).namespace)
        XCTAssertNotEqual(a.namespace, try AccountScope(projectURL: "https://other.test", userID: w2UserA).namespace)
        let first = try AccountPushAdmission(context: .init(scope: a, generation: UUID()),
                                            captureScope: a, sourceID: w2Source, isCurrent: { _ in true })
        let next = try AccountPushAdmission(context: .init(scope: a, generation: UUID()),
                                           captureScope: a, sourceID: w2Source, isCurrent: { _ in true })
        XCTAssertEqual(first.namespace(endpoint: a.projectURL, protocolVersion: "1.2", receiverStateID: "r"),
                       next.namespace(endpoint: a.projectURL, protocolVersion: "1.2", receiverStateID: "r"))
        XCTAssertThrowsError(try AccountScope(projectURL: "https://user:password@example.test", userID: w2UserA))
        XCTAssertThrowsError(try AccountScope(projectURL: "https://example.test", userID: "unassigned"))
    }

    func testConcurrentRefreshIsSingleFlightAndPreservesGeneration() async throws {
        let fixture = try W2Fixture()
        let before = try XCTUnwrap(fixture.controller.currentContext())
        let requests = (0..<24).map { _ in Task { try await fixture.controller.authorizedSession() } }
        await fixture.transport.waitForRequests(1)
        await fixture.transport.answer(0, with: reply(user: w2UserA))
        for request in requests {
            let result = try await request.value
            XCTAssertEqual(result.context, before)
            XCTAssertEqual(result.accessToken, "access-new")
        }
        let count = await fixture.transport.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(fixture.store.saves, 1)
        XCTAssertEqual(fixture.controller.identitySnapshot().generation, before.generation)
    }

    func testLogoutFencesDelayedRefreshAndDoesNotResurrectAfterReopen() async throws {
        let fixture = try W2Fixture()
        let before = try XCTUnwrap(fixture.controller.currentContext())
        let task = Task { try await fixture.controller.authorizedSession() }
        await fixture.transport.waitForRequests(1)
        try fixture.controller.clearSession()
        XCTAssertNil(fixture.controller.identitySnapshot().scope)
        XCTAssertNotEqual(fixture.controller.identitySnapshot().generation, before.generation)
        await fixture.transport.answer(0, with: reply(user: w2UserA))
        await expect(.staleOperation) { _ = try await task.value }
        XCTAssertEqual(fixture.store.saves, 0)
        let reopened = AccountSessionController(credentials: fixture.store, transport: fixture.transport)
        reopened.configure(fixture.configuration)
        XCTAssertNil(reopened.storedSession())
    }

    func testOldRefreshFailureCannotClearNewUserSession() async throws {
        let fixture = try W2Fixture()
        let old = Task { try await fixture.controller.authorizedSession() }
        await fixture.transport.waitForRequests(1)
        let login = Task { try await fixture.controller.signIn(email: "synthetic@example.test", password: "synthetic") }
        await fixture.transport.waitForRequests(2)
        await fixture.transport.answer(1, with: reply(user: w2UserB))
        let signedIn = try await login.value
        XCTAssertEqual(signedIn.userId, w2UserB)
        await fixture.transport.answer(0, with: .init(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)))
        await expect(.staleOperation) { _ = try await old.value }
        XCTAssertEqual(fixture.controller.currentContext()?.scope.userID, w2UserB)
        XCTAssertEqual(fixture.store.current?.scope.userID, w2UserB)
    }

    func testProjectChangeFencesPendingSignIn() async throws {
        let fixture = try W2Fixture()
        let login = Task { try await fixture.controller.signIn(email: "synthetic@example.test", password: "synthetic") }
        await fixture.transport.waitForRequests(1)
        fixture.controller.configure(try .init(projectURL: "https://other.test", anonKey: "test-key"))
        await fixture.transport.answer(0, with: reply(user: w2UserA))
        await expect(.staleOperation) { _ = try await login.value }
        XCTAssertNil(fixture.controller.currentContext())
        XCTAssertEqual(fixture.store.saves, 0)
    }

    func testTransientRefreshResponsesRetainSessionAndCanRecover() async throws {
        for status in [408, 429, 500, 503] {
            let fixture = try W2Fixture()
            let before = fixture.controller.currentContext()
            let first = Task { try await fixture.controller.authorizedSession() }
            await fixture.transport.waitForRequests(1)
            await fixture.transport.answer(0, with: .init(status: status, body: Data()))
            await expect(.retryable) { _ = try await first.value }
            XCTAssertEqual(fixture.controller.currentContext(), before)
            XCTAssertEqual(fixture.store.clears, 0)
            let second = Task { try await fixture.controller.authorizedSession() }
            await fixture.transport.waitForRequests(2)
            await fixture.transport.answer(1, with: reply(user: w2UserA))
            let recovered = try await second.value
            XCTAssertEqual(recovered.context, before)
        }
    }

    func testRefreshSubjectMismatchNeverPersistsAnotherOwner() async throws {
        let fixture = try W2Fixture()
        let task = Task { try await fixture.controller.authorizedSession() }
        await fixture.transport.waitForRequests(1)
        await fixture.transport.answer(0, with: reply(user: w2UserB))
        await expect(.invalidIdentity) { _ = try await task.value }
        XCTAssertEqual(fixture.store.saves, 0)
        XCTAssertEqual(fixture.controller.currentContext()?.scope.userID, w2UserA)
    }

    func testRotatedCredentialWriteFailureRetainsNewCredentialForPersistenceRetry() async throws {
        let fixture = try W2Fixture()
        fixture.store.failSave = true
        let first = Task { try await fixture.controller.authorizedSession() }
        await fixture.transport.waitForRequests(1)
        await fixture.transport.answer(0, with: reply(user: w2UserA))
        await expect(.credentialUnavailable) { _ = try await first.value }
        fixture.store.failSave = false
        let retry = try await fixture.controller.authorizedSession()
        XCTAssertEqual(retry.accessToken, "access-new")
        XCTAssertEqual(fixture.store.current?.refreshToken, "refresh-new")
        let count = await fixture.transport.count
        XCTAssertEqual(count, 1)
    }

    func testCredentialReadFailureIsNotSignedOutAndRetriesLoad() throws {
        let fixture = try W2Fixture()
        fixture.store.failLoad = true
        XCTAssertNil(fixture.controller.currentContext())
        XCTAssertEqual(fixture.controller.lastError, .credentialUnavailable)
        fixture.store.failLoad = false
        XCTAssertEqual(fixture.controller.currentContext()?.scope.userID, w2UserA)
    }

    func testRevokedRefreshClearsOnlyCurrentOwner() async throws {
        let fixture = try W2Fixture()
        let request = Task { try await fixture.controller.authorizedSession() }
        await fixture.transport.waitForRequests(1)
        await fixture.transport.answer(0, with: .init(status: 400, body: Data(#"{"error_code":"refresh_token_not_found"}"#.utf8)))
        await expect(.sessionRevoked) { _ = try await request.value }
        XCTAssertNil(fixture.controller.currentContext())
        XCTAssertEqual(fixture.store.clears, 1)
    }

    func testCapabilityOwnerAndCaptureOwnerMustAgreeBeforeAdmission() throws {
        let scope = try AccountScope(projectURL: "https://example.test", userID: w2UserA)
        func body(_ user: String?) throws -> Data {
            var object: [String: Any] = ["type": "capabilities", "protocolVersion": "1.2",
                                         "receiverStateId": w2Source, "streams": ["hrSample"]]
            object["userId"] = user
            return try JSONSerialization.data(withJSONObject: object)
        }
        XCTAssertEqual(try AccountVerifiedCapabilities.parse(body(w2UserA), scope: scope).appendTables, [.hrSample])
        XCTAssertThrowsError(try AccountVerifiedCapabilities.parse(body(w2UserB), scope: scope))
        XCTAssertThrowsError(try AccountVerifiedCapabilities.parse(body(nil), scope: scope))
        let b = try AccountScope(projectURL: scope.projectURL, userID: w2UserB)
        XCTAssertThrowsError(try AccountPushAdmission(context: .init(scope: b, generation: UUID()),
            captureScope: scope, sourceID: w2Source, isCurrent: { _ in true }))
    }

    func testLateTransportReceiptIsRejectedAfterLogout() async throws {
        let fixture = try W2Fixture()
        let context = try XCTUnwrap(fixture.controller.currentContext())
        let admission = try AccountPushAdmission(context: context, captureScope: context.scope,
            sourceID: w2Source, isCurrent: { fixture.controller.isCurrent($0) })
        let delayed = W2DelayedPush()
        let fenced = AccountFencedTransport(transport: delayed, admission: admission)
        let batch = try PushProtocol.appendBatch(table: .hrSample, sourceId: w2Source, deviceId: "synthetic",
            startCursor: nil, records: [.init(rowId: 1, key: ["ts": .int(100)], data: ["bpm": .int(60)])])
        let request = Task { try await fenced.post(batch) }
        await delayed.waitForPost()
        try fixture.controller.clearSession()
        await delayed.finish()
        await expect(.staleOperation) { _ = try await request.value }
        await expect(.staleOperation) { _ = try await fenced.post(batch) }
        let count = await delayed.count
        XCTAssertEqual(count, 1)
    }

    private func reply(user: String) -> AccountAuthReply {
        .init(status: 200, body: try! JSONSerialization.data(withJSONObject: [
            "access_token": "access-new", "refresh_token": "refresh-new", "expires_in": 3600,
            "user": ["id": user],
        ]))
    }

    private func expect(_ error: AccountAuthError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(error)") }
        catch let actual as AccountAuthError { XCTAssertEqual(actual, error) }
        catch { XCTFail("Unexpected error type") }
    }
}

private struct W2Fixture {
    let store: W2CredentialMemory
    let transport = W2ControlledAuth()
    let controller: AccountSessionController
    let configuration: AccountAuthConfiguration

    init() throws {
        configuration = try .init(projectURL: "https://example.test", anonKey: "synthetic-anon")
        store = W2CredentialMemory(.init(scope: try .init(projectURL: configuration.projectURL, userID: w2UserA),
                                        accessToken: "access-old", refreshToken: "refresh-old",
                                        expiresAt: w2Now.addingTimeInterval(-1)))
        controller = AccountSessionController(credentials: store, transport: transport, now: { w2Now })
        controller.configure(configuration)
    }
}

private final class W2CredentialMemory: AccountCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AccountAuthSession?
    private var saveCount = 0
    private var clearCount = 0
    var failSave = false
    var failLoad = false
    var failClear = false
    init(_ value: AccountAuthSession?) { self.value = value }
    var current: AccountAuthSession? { lock.lock(); defer { lock.unlock() }; return value }
    var saves: Int { lock.lock(); defer { lock.unlock() }; return saveCount }
    var clears: Int { lock.lock(); defer { lock.unlock() }; return clearCount }
    func load(projectURL: String) throws -> AccountAuthSession? {
        lock.lock(); defer { lock.unlock() }
        if failLoad { throw AccountAuthError.credentialUnavailable }
        return value?.scope.projectURL == projectURL ? value : nil
    }
    func save(_ session: AccountAuthSession) throws {
        lock.lock(); defer { lock.unlock() }
        if failSave { throw AccountAuthError.credentialUnavailable }
        value = session; saveCount += 1
    }
    func clear(projectURL: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failClear { throw AccountAuthError.credentialUnavailable }
        value = nil; clearCount += 1
    }
}

private final class W2NotificationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}

private actor W2ControlledAuth: AccountAuthTransport {
    private var requests: [CheckedContinuation<AccountAuthReply, Error>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    var count: Int { requests.count }
    func exchange(configuration: AccountAuthConfiguration, grant: AccountAuthGrant) async throws -> AccountAuthReply {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
            let ready = observers.filter { requests.count >= $0.0 }
            observers.removeAll { requests.count >= $0.0 }
            for waiter in ready { waiter.1.resume() }
        }
    }
    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func answer(_ index: Int, with reply: AccountAuthReply) { requests[index].resume(returning: reply) }
}

private actor W2DelayedPush: PushTransport {
    private var pending: CheckedContinuation<PushTransportResponse, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var count = 0
    func capabilities() async throws -> PushCapabilitiesResult { .available(.all) }
    func post(_ batch: PushBatch) async throws -> PushTransportResponse {
        count += 1
        return await withCheckedContinuation {
            pending = $0; started?.resume(); started = nil
        }
    }
    func postBinary(_ batch: PushBinaryBatch) async throws -> PushTransportResponse {
        throw AccountAuthError.invalidResponse
    }
    func waitForPost() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { pending?.resume(returning: .init(statusCode: 200, body: Data())); pending = nil }
}
