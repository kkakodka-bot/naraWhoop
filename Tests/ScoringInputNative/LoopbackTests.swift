import Foundation
import GRDB
import NoopPush
import XCTest

/// The only network destination accepted by this executable is the disposable loopback gateway.
actor ScoringInputLoopbackWire {
    private var loseNextSuccess: Bool
    private(set) var bodies: [Data] = []
    init(loseNextSuccess: Bool = false) { self.loseNextSuccess = loseNextSuccess }
    func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard request.url?.scheme == "http", request.url?.host == "127.0.0.1" else {
            throw ScoringInputRPC.Failure.unavailable
        }
        let isWrite = request.url?.path.hasSuffix("/put_scoring_history_input_v3") == true
        if isWrite { bodies.append(request.httpBody ?? Data()) }
        let context = AccountSessionContext(scope: try AccountScope(projectURL: "http://127.0.0.1:\(request.url!.port!)",
            userID: "11111111-1111-4111-8111-111111111111"), generation: UUID())
        let result = try await ScoringInputTransport.perform(request, context: context, isCurrent: { $0 == context })
        if isWrite, loseNextSuccess, (result.1 as? HTTPURLResponse)?.statusCode == 200 {
            loseNextSuccess = false
            throw URLError(.networkConnectionLost) // server committed; client received no usable receipt
        }
        return result
    }
}

@MainActor
final class ScoringInputLoopbackTests: XCTestCase {
    private let userA = "11111111-1111-4111-8111-111111111111"
    private let deviceA = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private func fixture() throws -> (URL, AccountStorageLayout, AccountSessionContext) {
        let origin = try XCTUnwrap(ProcessInfo.processInfo.environment["SCORING_INPUT_LOOPBACK_URL"])
        let url = try XCTUnwrap(URL(string: origin))
        guard url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
            throw ScoringInputRPC.Failure.unavailable
        }
        let scope = try AccountScope(projectURL: origin, userID: userA)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (root, .init(baseDirectory: root, scope: scope), .init(scope: scope, generation: UUID()))
    }
    private func change(_ age: Int, device: String? = nil, config: Bool = false, deleted: Bool = false) throws -> ScoringInputChange {
        let payload = deleted ? "{}" : config
            ? "{\"schemaVersion\":1,\"maxHR\":190,\"sleepNeedHours\":8,\"effortMethod\":\"EDWARDS\"}"
            : "{\"schemaVersion\":1,\"timezone\":\"UTC\",\"age\":\(age)}"
        return try .init(device: device ?? deviceA, kind: config ? .config : .profile, entity: "primary",
                         effectiveDay: "2026-09-18", payload: Data(payload.utf8), deleted: deleted)
    }
    private func rpc(_ context: AccountSessionContext, wire: ScoringInputLoopbackWire,
                     credential: String = "fixture-a") -> ScoringInputRPC.Dependencies {
        .init(anonKey: { "disposable-only" }, authorize: { .init(context: context, accessToken: credential) },
              isCurrent: { $0 == context }, canUpload: { true }, request: { try await wire.request($0) })
    }
    private func dependencies(_ context: AccountSessionContext, state: ScoringInputTestState,
                              wire: ScoringInputLoopbackWire) -> ScoringInputCoordinator.Dependencies {
        let rpc = rpc(context, wire: wire)
        return .init(isCurrent: { $0 == context }, canUpload: { state.ready() }, head: {
            try await ScoringInputRPC.head($0, context: $1, dependencies: rpc)
        }, send: { pending, captured in
            state.record(pending)
            return try await ScoringInputRPC.send(pending, context: captured, dependencies: rpc)
        }, now: { state.now() })
    }
    private func read(_ context: AccountSessionContext, device: String, kind: String) async throws -> [String: Any] {
        let wire = ScoringInputLoopbackWire()
        var request = URLRequest(url: URL(string: context.scope.projectURL)!.appendingPathComponent("rest/v1/rpc/get_scoring_history_input_v3"))
        request.httpMethod = "POST"
        request.setValue("Bearer fixture-a", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["p_device": device, "p_kind": kind,
            "p_entity": "primary", "p_as_of_day": "2026-09-18"])
        let (data, response) = try await wire.request(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try ScoringInputChange(device: device, kind: XCTUnwrap(.init(rawValue: kind)),
            entity: "primary", effectiveDay: "2026-09-18", payload: Data("{}".utf8))
        let typed = try await ScoringInputRPC.read(input, asOfDay: "2026-09-18", context: context, dependencies: rpc(context, wire: wire))
        XCTAssertEqual(typed.head.headRevision, (body["headRevision"] as? NSNumber)?.int64Value)
        XCTAssertEqual(typed.revision, (body["revision"] as? NSNumber)?.int64Value)
        return body
    }

    func testProducerLostReceiptReopenExactReplayThenFollowingProfileAndConfig() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ScoringInputTestState()
        let lostWire = ScoringInputLoopbackWire(loseNextSuccess: true)
        let first = ScoringInputCoordinator(context: context, layout: layout,
            dependencies: dependencies(context, state: state, wire: lostWire))
        try await first.enqueue(change(30))
        try await first.enqueue(change(31))
        try await first.enqueue(change(0, config: true))
        await first.reconcile()?.value
        state.setReady(true)
        await first.reconcile()?.value
        XCTAssertEqual(first.status, .init(pending: 2, conflicts: 0))
        let beforeRestart = state.sent()
        XCTAssertEqual(beforeRestart.count, 2) // lost profile receipt, unrelated config still progresses
        first.retire()
        state.advance()
        let retryWire = ScoringInputLoopbackWire()
        let restarted = ScoringInputCoordinator(context: context, layout: layout,
            dependencies: dependencies(context, state: state, wire: retryWire))
        await restarted.reconcile()?.value
        XCTAssertEqual(restarted.status, .init(pending: 0, conflicts: 0))
        XCTAssertNil(restarted.lastError)
        let sent = state.sent()
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(sent[0].id, sent[2].id)
        XCTAssertEqual(sent[0].clientID, sent[2].clientID)
        XCTAssertEqual(sent[0].clientRevision, sent[2].clientRevision)
        XCTAssertEqual(sent[0].expectedRevision, sent[2].expectedRevision)
        XCTAssertGreaterThan(sent[3].expectedRevision, 0)
        XCTAssertGreaterThan(sent[3].clientRevision, sent[2].clientRevision)
        let firstBodies = await lostWire.bodies
        let replayBodies = await retryWire.bodies
        XCTAssertEqual(firstBodies.first, replayBodies.first, "all ten arguments survive restart byte-for-byte")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(firstBodies.first)) as? [String: Any])
        XCTAssertEqual(body.count, 10)
        let profile = try await read(context, device: deviceA, kind: "profile")
        XCTAssertEqual((profile["payload"] as? [String: Any])?["age"] as? Int, 31)
        let config = try await read(context, device: deviceA, kind: "config")
        XCTAssertEqual((config["payload"] as? [String: Any])?["maxHR"] as? Int, 190)
        restarted.retire()
    }

    func testConcurrentDuplicateReceiptIsOneServerMutationAndOneLocalSettlement() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let journal = try ScoringInputJournal(layout: layout)
        _ = try await journal.enqueue(change(40, device: device))
        let loaded = try await journal.next()
        let pending = try XCTUnwrap(loaded)
        let deps = rpc(context, wire: ScoringInputLoopbackWire())
        async let one = ScoringInputRPC.send(pending, context: context, dependencies: deps)
        async let two = ScoringInputRPC.send(pending, context: context, dependencies: deps)
        let receipts = try await (one, two)
        XCTAssertEqual(receipts.0, receipts.1)
        await journal.retire() // both requests completed, local receipt not yet durable
        let reopened = try ScoringInputJournal(layout: layout)
        let replay = try await reopened.next()
        XCTAssertEqual(replay, pending)
        let receipt = try await ScoringInputRPC.send(pending, context: context, dependencies: deps)
        XCTAssertEqual(receipt, receipts.0)
        try await reopened.settle(pending, receipt: receipt)
        let status = try await reopened.status()
        XCTAssertEqual(status.pending, 0)
    }

    func testRealPostgRESTRevisionConflictRetainsDebtAndOtherEntityProgresses() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        let interrupted = try ScoringInputJournal(layout: layout)
        _ = try await interrupted.enqueue(change(51, device: device))
        _ = try await interrupted.next() // freeze a request before the competing installation writes
        await interrupted.retire()
        let otherLayout = AccountStorageLayout(baseDirectory: root.appendingPathComponent("other-installation"), scope: context.scope)
        let other = try ScoringInputJournal(layout: otherLayout)
        _ = try await other.enqueue(change(50, device: device))
        let loaded = try await other.next()
        _ = try await ScoringInputRPC.send(XCTUnwrap(loaded), context: context,
            dependencies: rpc(context, wire: ScoringInputLoopbackWire()))
        let state = ScoringInputTestState()
        let coordinator = ScoringInputCoordinator(context: context, layout: layout,
            dependencies: dependencies(context, state: state, wire: ScoringInputLoopbackWire()))
        try await coordinator.enqueue(change(51, device: device))
        try await coordinator.enqueue(change(0, device: device, config: true))
        await coordinator.reconcile()?.value
        state.setReady(true)
        await coordinator.reconcile()?.value
        XCTAssertEqual(coordinator.status, .init(pending: 1, conflicts: 1))
        let reopened = try ScoringInputJournal(layout: layout)
        let retained = try await reopened.status()
        XCTAssertEqual(retained, .init(pending: 1, conflicts: 1))
        let automaticRetry = try await reopened.next(now: state.now().addingTimeInterval(86_400))
        XCTAssertNil(automaticRetry, "a conflict stays retained for review, not automatic rebasing")
        let profile = try await read(context, device: device, kind: "profile")
        XCTAssertEqual((profile["payload"] as? [String: Any])?["age"] as? Int, 50)
        let config = try await read(context, device: device, kind: "config")
        XCTAssertEqual((config["payload"] as? [String: Any])?["maxHR"] as? Int, 190)
        coordinator.retire()
    }

    func testOrdinaryWrongOwnerRoleCannotSettleJournal() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ScoringInputJournal(layout: layout)
        _ = try await journal.enqueue(change(60))
        let loaded = try await journal.next()
        let pending = try XCTUnwrap(loaded)
        do {
            _ = try await ScoringInputRPC.send(pending, context: context,
                dependencies: rpc(context, wire: ScoringInputLoopbackWire(), credential: "fixture-b"))
            XCTFail("unowned device accepted")
        } catch { XCTAssertEqual(error as? ScoringInputRPC.Failure, .unavailable) }
        let retained = try await journal.next()
        XCTAssertEqual(retained, pending)
    }

    func testTypedTombstoneReceiptSettlesExactDeletedMutation() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        let journal = try ScoringInputJournal(layout: layout)
        _ = try await journal.enqueue(change(70, device: device))
        _ = try await journal.enqueue(change(0, device: device, deleted: true))
        let deps = rpc(context, wire: ScoringInputLoopbackWire())
        for deleted in [false, true] {
            let loaded = try await journal.next()
            let pending = try XCTUnwrap(loaded)
            let receipt = try await ScoringInputRPC.send(pending, context: context, dependencies: deps)
            XCTAssertEqual(receipt.deleted, deleted)
            try await journal.settle(pending, receipt: receipt)
        }
        let profile = try await read(context, device: device, kind: "profile")
        XCTAssertEqual(profile["deleted"] as? Bool, true)
        XCTAssertTrue(profile["payload"] is NSNull)
        let status = try await journal.status()
        XCTAssertEqual(status.pending, 0)
    }

    func testFreshInstallationUsesOpaqueFutureHeadWithoutReadingFuturePayload() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let remote = try ScoringInputJournal(layout: .init(baseDirectory: root.appendingPathComponent("first-client"), scope: context.scope))
        let profile = try change(80, device: device)
        _ = try await remote.enqueue(.init(device: device, kind: .profile, entity: "primary", effectiveDay: "2026-09-21", payload: profile.payload))
        let loaded = try await remote.next()
        let first = try XCTUnwrap(loaded)
        let rpc = rpc(context, wire: ScoringInputLoopbackWire())
        let futureReceipt = try await ScoringInputRPC.send(first, context: context, dependencies: rpc)
        try await remote.settle(first, receipt: futureReceipt)
        _ = try await remote.enqueue(change(0, device: device, config: true))
        let config = try await remote.next()
        _ = try await ScoringInputRPC.send(XCTUnwrap(config), context: context, dependencies: rpc)
        let before = try await read(context, device: device, kind: "profile")
        XCTAssertTrue(before["payload"] is NSNull)
        XCTAssertEqual(before["headRevision"] as? Int64, futureReceipt.revision)
        let state = ScoringInputTestState()
        state.setReady(true)
        let coordinator = ScoringInputCoordinator(context: context, layout: layout,
            dependencies: dependencies(context, state: state, wire: ScoringInputLoopbackWire()))
        try await coordinator.enqueue(change(79, device: device))
        await coordinator.reconcile()?.value
        XCTAssertEqual(coordinator.status, .init(pending: 0, conflicts: 0))
        XCTAssertEqual(state.sent().first?.expectedRevision, futureReceipt.revision)
        let today = try await read(context, device: device, kind: "profile")
        XCTAssertEqual((today["payload"] as? [String: Any])?["age"] as? Int, 79)
        XCTAssertGreaterThan(try XCTUnwrap(today["revision"] as? Int64), futureReceipt.revision + 1)
        coordinator.retire()
    }

    func testExplicitConflictRebaseArchivesIntentThenReopensAndSettlesNewMutation() async throws {
        let (root, layout, context) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = "abababab-abab-4bab-8bab-abababababab"
        let journal = try ScoringInputJournal(layout: layout)
        _ = try await journal.enqueue(change(30, device: device))
        _ = try await journal.enqueue(change(31, device: device))
        let original = try await journal.next() // request frozen before the competing write
        let originalID = try XCTUnwrap(original?.id)
        let other = try ScoringInputJournal(layout: .init(baseDirectory: root.appendingPathComponent("other"), scope: context.scope))
        _ = try await other.enqueue(change(40, device: device))
        let remote = try await other.next()
        _ = try await ScoringInputRPC.send(XCTUnwrap(remote), context: context, dependencies: rpc(context, wire: ScoringInputLoopbackWire()))
        let state = ScoringInputTestState()
        state.setReady(true)
        let coordinator = ScoringInputCoordinator(context: context, layout: layout,
            dependencies: dependencies(context, state: state, wire: ScoringInputLoopbackWire()))
        await coordinator.reconcile()?.value
        XCTAssertEqual(coordinator.status, .init(pending: 2, conflicts: 1))
        let review = try await coordinator.reviewConflict(id: originalID)
        XCTAssertEqual(review.conflict.queuedMutationIDs.count, 2)
        state.setReady(false); coordinator.policyChanged()
        try await coordinator.resolveConflict(review, replacement: change(32, device: device))
        await coordinator.reconcile()?.value
        coordinator.retire()
        let newContext = AccountSessionContext(scope: context.scope, generation: UUID())
        state.setReady(true)
        let restarted = ScoringInputCoordinator(context: newContext, layout: layout,
            dependencies: dependencies(newContext, state: state, wire: ScoringInputLoopbackWire()))
        await restarted.reconcile()?.value
        XCTAssertEqual(restarted.status, .init(pending: 0, conflicts: 0))
        let sent = state.sent()
        XCTAssertEqual(sent.count, 2)
        XCTAssertNotEqual(sent.first?.id, sent.last?.id)
        XCTAssertEqual(sent.last?.expectedRevision, review.head.headRevision)
        XCTAssertGreaterThan(try XCTUnwrap(sent.last?.clientRevision), 2)
        let inspector = try DatabaseQueue(path: layout.directory.appendingPathComponent("history-inputs.sqlite").path)
        let archived = try await inspector.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM input_resolution WHERE settled_revision IS NOT NULL") }
        XCTAssertEqual(archived, 2)
        let profile = try await read(context, device: device, kind: "profile")
        XCTAssertEqual((profile["payload"] as? [String: Any])?["age"] as? Int, 32)
        restarted.retire()
    }
}
