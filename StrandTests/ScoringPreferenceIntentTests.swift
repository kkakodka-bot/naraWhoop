import Foundation
import GRDB
import NoopPush
import WhoopStore
import XCTest
#if !SCORING_INPUT_NATIVE_TESTS
@testable import Strand
#endif

final class PreferenceIntentSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func disable() { lock.lock(); value = false; lock.unlock() }
}

private final class PreferenceNativeCommitState: @unchecked Sendable {
    enum Effect { case permit, generation, cancellation }
    private let lock = NSLock()
    private let effect: Effect
    private var checks = 0
    private var allowed = true
    private var currentGeneration = true
    private var fired = false
    private var cancel: (@Sendable () -> Void)?
    init(_ effect: Effect) { self.effect = effect }
    func installCancellation(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock(); self.cancel = cancel; lock.unlock()
    }
    func current() -> Bool {
        lock.lock()
        var action: (@Sendable () -> Void)?
        // The last closure-body generation check precedes its second permit call. The next
        // generation check is the database-lifetime observer at SQLite's native commit hook.
        if checks >= 2, !fired {
            fired = true
            switch effect {
            case .permit: allowed = false
            case .generation: currentGeneration = false
            case .cancellation: action = cancel
            }
        }
        let value = currentGeneration
        lock.unlock()
        action?()
        return value
    }
    func permit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        checks += 1
        return allowed
    }
    var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    var permitChecks: Int { lock.lock(); defer { lock.unlock() }; return checks }
}

enum PreferenceIntentFixture {
    static let device = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    static func context(user: String = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                        project: String = "https://preference-fixture.invalid", generation: UUID = UUID()) throws -> AccountSessionContext {
        .init(scope: try AccountScope(projectURL: project, userID: user), generation: generation)
    }
    static func intent(_ context: AccountSessionContext, predecessor: ScoringPreferencePosition = .initial,
                       id: UUID = UUID(), weight: Double = 71, local: Bool = false,
                       patch: [ScoringPreferenceIntent.Patch]? = nil) throws -> ScoringPreferenceIntent {
        try .init(context: context, id: id, predecessor: predecessor,
            occurredAt: Date(timeIntervalSince1970: 1_794_122_999), timezone: "America/Los_Angeles",
            device: device, disposition: local ? .localOnly : .serverCoupled,
            patch: patch ?? [.init(key: .weightKg, value: .number(weight))],
            profilePayload: local ? nil : Data("{\"schemaVersion\":1,\"timezone\":\"America/Los_Angeles\",\"weightKg\":\(weight)}".utf8),
            configPayload: local ? nil : Data("{\"schemaVersion\":1,\"maxHR\":180,\"journalContextEnabled\":false,\"cycleAwarenessEnabled\":false}".utf8))
    }
    static func receipt(_ pending: ScoringInputJournal.Pending) -> ScoringInputReceipt {
        .init(schemaVersion: 1, userId: UUID(uuidString: pending.scope.userID)!, sourceDeviceId: UUID(uuidString: pending.change.device)!,
            kind: pending.change.kind, entity: pending.change.entity, revision: pending.expectedRevision + 1,
            clientId: pending.clientID, clientMutationId: UUID(uuidString: pending.id)!, clientRevision: pending.clientRevision,
            effectiveDay: pending.change.effectiveDay, deleted: pending.change.deleted, invalidatedFrom: pending.change.effectiveDay)
    }
}

private final class PreferenceJournalFixture: @unchecked Sendable {
    let root: URL
    let context: AccountSessionContext
    let layout: AccountStorageLayout
    let current = PreferenceIntentSwitch()
    let fence = StoreWriteFence()
    var journals: [ScoringInputJournal] = []
    var journal: ScoringInputJournal { journals[0] }
    var path: String { layout.directory.appendingPathComponent("history-inputs.sqlite").path }

    init() throws {
        let base = ProcessInfo.processInfo.environment["SCORING_PREFERENCE_SCRATCH"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("preference-\(UUID().uuidString)", isDirectory: true)
        context = try PreferenceIntentFixture.context()
        layout = .init(baseDirectory: root, scope: context.scope)
        journals = [try ScoringInputJournal(layout: layout, fence: fence, preferenceContext: context,
            isPreferenceContextCurrent: { [current, context] in $0 == context && current.get() })]
    }
    func reopen(generation: UUID? = nil) throws -> ScoringInputJournal {
        let context = AccountSessionContext(scope: context.scope, generation: generation ?? context.generation)
        let value = try ScoringInputJournal(layout: layout, preferenceContext: context, isPreferenceContextCurrent: { $0 == context })
        journals.append(value)
        return value
    }
    func sql(_ action: (Database) throws -> Void) throws {
        let db = try DatabaseQueue(path: path)
        defer { try? db.close() }
        try db.write(action)
    }
    func scalar(_ sql: String) throws -> Int {
        let db = try DatabaseQueue(path: path)
        defer { try? db.close() }
        return try db.read { try Int.fetchOne($0, sql: sql) ?? 0 }
    }
    func close() async throws { for journal in journals { try await journal.close() } }
}

final class ScoringPreferenceIntentTests: XCTestCase {
    private func fixture(_ body: (PreferenceJournalFixture) async throws -> Void) async throws {
        let f = try await Task.detached { try PreferenceJournalFixture() }.value
        let failures = testRun?.failureCount ?? 0
        do {
            try await body(f)
            try await f.close()
            if testRun?.failureCount == failures { try FileManager.default.removeItem(at: f.root) }
            else { print("Preserved preference fixture: \(f.root.path)") }
        } catch {
            try await f.close()
            print("Preserved preference fixture: \(f.root.path)")
            throw error
        }
    }
    private func failure(_ expected: ScoringInputJournal.Failure,
                         _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, expected, file: file, line: line) }
    }
    private func empty(_ f: PreferenceJournalFixture) throws {
        for table in ["preference_intent", "preference_projection", "input_change", "input_origin", "input_relay"] {
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM \(table)"), 0, table)
        }
        XCTAssertEqual(try f.scalar("SELECT sequence FROM preference_state"), 0)
    }

    func testAtomicPairProjectionAndIdempotentReceipt() async throws {
        try await fixture { f in
            let intent = try PreferenceIntentFixture.intent(f.context)
            let receipt = try await f.journal.admitPreferenceIntent(intent, allowing: { true })
            let repeated = try await f.journal.admitPreferenceIntent(intent, allowing: { true })
            XCTAssertEqual(receipt, repeated)
            XCTAssertEqual(receipt.profileMutationID, intent.profileMutationID)
            XCTAssertEqual(receipt.configMutationID, intent.configMutationID)
            XCTAssertEqual(receipt.configClientRevision, (receipt.profileClientRevision ?? 0) + 1)
            let state = try await f.journal.committedPreferenceProjection()
            XCTAssertEqual(state.position, intent.position)
            XCTAssertEqual(state.entries.map(\.value), [.number(71)])
            let first = try await f.journal.next()
            XCTAssertEqual(first?.change, intent.profile)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM input_change"), 2)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM input_origin"), 0)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM input_relay"), 0)
        }
    }

    func testFrozenSerializationDayTimezoneAndBytesSurviveNewGeneration() async throws {
        try await fixture { f in
            let intent = try PreferenceIntentFixture.intent(f.context)
            let frozen = try intent.encoded()
            XCTAssertEqual(try ScoringPreferenceIntent(encoded: frozen), intent)
            _ = try await f.journal.admitPreferenceIntent(intent, allowing: { true })
            try await f.journal.close()
            let next = try f.reopen(generation: UUID())
            let state = try await next.committedPreferenceProjection()
            XCTAssertEqual(state.entries.first?.originGeneration, f.context.generation)
            let pending = try await next.next()
            XCTAssertEqual(pending?.change.payload, intent.profile?.payload)
            XCTAssertEqual(pending?.change.effectiveDay, intent.effectiveDay)
            XCTAssertEqual(pending?.change.device, intent.device)
            await failure(.retired) { _ = try await next.admitPreferenceIntent(intent, allowing: { true }) }
            let nextContext = try PreferenceIntentFixture.context(generation: UUID())
            let fresh = try ScoringInputJournal(layout: f.layout, preferenceContext: nextContext, isPreferenceContextCurrent: { $0 == nextContext })
            f.journals.append(fresh)
            let later = try PreferenceIntentFixture.intent(nextContext, predecessor: intent.position, weight: 72)
            _ = try await fresh.admitPreferenceIntent(later, allowing: { true })
        }
    }

    func testPredecessorOrdersABAEvenWhenTasksArriveOutOfOrder() async throws {
        try await fixture { f in
            let a = try PreferenceIntentFixture.intent(f.context)
            let b = try PreferenceIntentFixture.intent(f.context, predecessor: a.position, weight: 72)
            let a2 = try PreferenceIntentFixture.intent(f.context, predecessor: b.position)
            await failure(.stalePreferenceIntent) { _ = try await f.journal.admitPreferenceIntent(b, allowing: { true }) }
            try empty(f)
            for intent in [a, b, a2] { _ = try await f.journal.admitPreferenceIntent(intent, allowing: { true }) }
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM input_change"), 6)
            let state = try await f.journal.committedPreferenceProjection()
            XCTAssertEqual(state.position, a2.position)
            XCTAssertEqual(state.entries.first?.value, .number(71))
            let mutation = try PreferenceIntentFixture.intent(f.context, id: a.id, weight: 73)
            await failure(.stalePreferenceIntent) { _ = try await f.journal.admitPreferenceIntent(mutation, allowing: { true }) }
        }
    }

    func testGenerationFenceBeforeCommitRollsBackBothChildrenAndProjection() async throws {
        try await fixture { f in
            let intent = try PreferenceIntentFixture.intent(f.context)
            await failure(.retired) {
                _ = try await f.journal.admitPreferenceIntent(intent, allowing: { true }, at: { point in
                    if point == .beforeCommit { f.current.disable() }
                })
            }
            try empty(f)
            let current = try f.reopen()
            _ = try await current.admitPreferenceIntent(intent, allowing: { true })
        }
    }

    func testOwnerFenceAfterFirstChildRollsBackEntireAdmission() async throws {
        try await fixture { f in
            await failure(.retired) {
                _ = try await f.journal.admitPreferenceIntent(PreferenceIntentFixture.intent(f.context), allowing: { true }, at: { point in
                    if point == .firstChildInserted { f.fence.invalidate() }
                })
            }
            try empty(f)
        }
    }

    func testPermitRevocationAtProjectionCommitDoesNotPublishOldConsentBits() async throws {
        try await fixture { f in
            let permit = PreferenceIntentSwitch()
            await failure(.held) {
                _ = try await f.journal.admitPreferenceIntent(PreferenceIntentFixture.intent(f.context), allowing: { permit.get() }, at: { point in
                    if point == .projectionWritten { permit.disable() }
                })
            }
            try empty(f)
        }
    }

    func testPermitRevokedByNativeGenerationObserverRollsBackAndDoesNotLeakGate() async throws {
        try await fixture { f in
            let state = PreferenceNativeCommitState(.permit)
            let journal = try ScoringInputJournal(layout: f.layout, preferenceContext: f.context,
                isPreferenceContextCurrent: { $0 == f.context && state.current() })
            f.journals.append(journal)
            await failure(.held) {
                _ = try await journal.admitPreferenceIntent(PreferenceIntentFixture.intent(f.context), allowing: { state.permit() })
            }
            XCTAssertTrue(state.didFire, "Fixture must revoke at native commit with generation still current")
            try empty(f)
            let checks = state.permitChecks
            let ordinary = try XCTUnwrap(PreferenceIntentFixture.intent(f.context, weight: 73).profile)
            _ = try await journal.enqueue(ordinary)
            let p = try await journal.next()
            let pending = try XCTUnwrap(p)
            try await journal.settle(pending, receipt: PreferenceIntentFixture.receipt(pending))
            XCTAssertEqual(state.permitChecks, checks, "Rolled-back preference permit leaked into ordinary writes")
        }
    }

    func testCancellationAtNativeCommitAfterLastBodyCheckRollsBackAndObserverIsRemoved() async throws {
        try await fixture { f in
            let state = PreferenceNativeCommitState(.cancellation)
            let journal = try ScoringInputJournal(layout: f.layout, preferenceContext: f.context,
                isPreferenceContextCurrent: { $0 == f.context && state.current() })
            f.journals.append(journal)
            let entered = expectation(description: "ready to install exact task cancellation")
            let release = DispatchSemaphore(value: 0)
            let intent = try PreferenceIntentFixture.intent(f.context)
            let task = Task.detached {
                try await journal.admitPreferenceIntent(intent, allowing: { state.permit() }, at: { point in
                    if point == .beforeCommit { entered.fulfill(); _ = release.wait(timeout: .now() + 10) }
                })
            }
            await fulfillment(of: [entered], timeout: 5)
            state.installCancellation { task.cancel() }
            release.signal()
            do { _ = try await task.value; XCTFail("Task cancelled at native commit was accepted") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(state.didFire)
            try empty(f)
            let checks = state.permitChecks
            _ = try await journal.enqueue(XCTUnwrap(intent.profile))
            XCTAssertEqual(state.permitChecks, checks, "Cancelled observer leaked into the next transaction")
        }
    }

    func testGenerationRevokedAtNativeCommitStillRollsBackWithFreshGenerationPositiveControl() async throws {
        try await fixture { f in
            let state = PreferenceNativeCommitState(.generation)
            let journal = try ScoringInputJournal(layout: f.layout, preferenceContext: f.context,
                isPreferenceContextCurrent: { $0 == f.context && state.current() })
            f.journals.append(journal)
            await failure(.retired) {
                _ = try await journal.admitPreferenceIntent(PreferenceIntentFixture.intent(f.context), allowing: { state.permit() })
            }
            XCTAssertTrue(state.didFire)
            try empty(f)
            let context = AccountSessionContext(scope: f.context.scope, generation: UUID())
            let fresh = try ScoringInputJournal(layout: f.layout, preferenceContext: context, isPreferenceContextCurrent: { $0 == context })
            f.journals.append(fresh)
            _ = try await fresh.admitPreferenceIntent(PreferenceIntentFixture.intent(context), allowing: { true })
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM input_change"), 2)
        }
    }

    func testCommittedAndEarlyRejectedPermitsDoNotAttachToLaterOrdinaryWrites() async throws {
        try await fixture { f in
            let permit = PreferenceIntentSwitch()
            let first = try PreferenceIntentFixture.intent(f.context)
            _ = try await f.journal.admitPreferenceIntent(first, allowing: { permit.get() })
            permit.disable()
            let second = try PreferenceIntentFixture.intent(f.context, predecessor: first.position, weight: 74)
            await failure(.held) { _ = try await f.journal.admitPreferenceIntent(second, allowing: { permit.get() }) }
            _ = try await f.journal.enqueue(XCTUnwrap(second.profile))
            let p = try await f.journal.next()
            let pending = try XCTUnwrap(p)
            try await f.journal.settle(pending, receipt: PreferenceIntentFixture.receipt(pending))
            let receipt = try await f.journal.admitPreferenceIntent(second, allowing: { true })
            XCTAssertEqual(receipt.position, second.position, "A fresh preference permit must not inherit an old denial")
        }
    }

    func testMissingBoundContextAndWrongScopeFailClosed() async throws {
        try await fixture { f in
            let unbound = try ScoringInputJournal(layout: f.layout)
            f.journals.append(unbound)
            let intent = try PreferenceIntentFixture.intent(f.context)
            await failure(.retired) { _ = try await unbound.admitPreferenceIntent(intent, allowing: { true }) }
            for context in [try PreferenceIntentFixture.context(user: "cccccccc-cccc-cccc-cccc-cccccccccccc"),
                            try PreferenceIntentFixture.context(project: "https://other-project.invalid")] {
                await failure(.wrongOwner) { _ = try await f.journal.admitPreferenceIntent(PreferenceIntentFixture.intent(context), allowing: { true }) }
            }
            try empty(f)
        }
    }

    func testLocalOnlyNeverCreatesDebtOrPromotesDuringRecovery() async throws {
        try await fixture { f in
            let local = try PreferenceIntentFixture.intent(f.context, local: true, patch: [
                .init(key: .hrvBaselineEpoch, value: .number(1_794_122_999)),
                .init(key: .recoveryBaselineEpoch, value: .number(1_794_122_999)),
                .init(key: .hrMaxOverride, value: .clear)])
            let receipt = try await f.journal.admitPreferenceIntent(local, allowing: { true })
            XCTAssertNil(receipt.profileMutationID); XCTAssertNil(receipt.configClientRevision)
            let compacted = try await f.journal.compactPreferenceIntents()
            XCTAssertEqual(compacted, 1)
            try await f.journal.close()
            let next = try f.reopen()
            let state = try await next.committedPreferenceProjection()
            XCTAssertEqual(state.entries.count, 3)
            XCTAssertTrue(state.entries.allSatisfy { $0.disposition == .localOnly })
            XCTAssertTrue(state.entries.contains { $0.key == .hrMaxOverride && $0.value == .clear })
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM input_change"), 0)
            await failure(.stalePreferenceIntent) { _ = try await next.admitPreferenceIntent(local, allowing: { true }) }
            let fresh = try PreferenceIntentFixture.intent(f.context, predecessor: local.position)
            _ = try await next.admitPreferenceIntent(fresh, allowing: { true })
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM input_change"), 2)
        }
    }

    func testExactChildSettlementRequiredBeforeCompactionAndReplayRejectedAfter() async throws {
        try await fixture { f in
            let intent = try PreferenceIntentFixture.intent(f.context)
            _ = try await f.journal.admitPreferenceIntent(intent, allowing: { true })
            var count = try await f.journal.compactPreferenceIntents()
            XCTAssertEqual(count, 0)
            let p = try await f.journal.next()
            let first = try XCTUnwrap(p)
            try await f.journal.settle(first, receipt: PreferenceIntentFixture.receipt(first))
            count = try await f.journal.compactPreferenceIntents()
            XCTAssertEqual(count, 0)
            try await f.journal.close()
            let reopened = try f.reopen()
            let q = try await reopened.next()
            let second = try XCTUnwrap(q)
            XCTAssertEqual(second.id, intent.configMutationID?.uuidString.lowercased())
            try await reopened.settle(second, receipt: PreferenceIntentFixture.receipt(second))
            count = try await reopened.compactPreferenceIntents()
            XCTAssertEqual(count, 1)
            await failure(.stalePreferenceIntent) { _ = try await reopened.admitPreferenceIntent(intent, allowing: { true }) }
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM preference_intent"), 0)
            let projection = try await reopened.committedPreferenceProjection()
            XCTAssertEqual(projection.position, intent.position)
        }
    }

    func testCompactionWorkIsBoundedAndProjectionHasFixedKeyCardinality() async throws {
        try await fixture { f in
            var head = ScoringPreferencePosition.initial
            for index in 0..<140 {
                let intent = try PreferenceIntentFixture.intent(f.context, predecessor: head, weight: Double(70 + index % 2), local: true)
                _ = try await f.journal.admitPreferenceIntent(intent, allowing: { true })
                head = intent.position
            }
            let count = try await f.journal.compactPreferenceIntents(limit: Int.max)
            XCTAssertEqual(count, 128)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM preference_intent"), 12)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM preference_projection"), 1)
            let state = try await f.journal.committedPreferenceProjection()
            XCTAssertEqual(state.position, head)
        }
    }

    func testCountCapacityReservesBothChildrenAndPreservesDenialReserve() async throws {
        try await fixture { f in
            try f.sql { db in
                for index in 0..<4095 {
                    try db.execute(sql: "INSERT INTO input_change(id,device,kind,entity,day,payload,deleted,digest) VALUES(?,?,'profile','held','2026-09-18',?,0,'fixture')",
                        arguments: [UUID().uuidString, PreferenceIntentFixture.device, Data("{\"i\":\(index)}".utf8)])
                }
            }
            await failure(.storageLimit) { _ = try await f.journal.admitPreferenceIntent(PreferenceIntentFixture.intent(f.context), allowing: { true }) }
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM preference_intent"), 0)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM input_change"), 4095)
            try f.sql { try $0.execute(sql: "DELETE FROM input_change WHERE sequence=1") }
            _ = try await f.journal.admitPreferenceIntent(PreferenceIntentFixture.intent(f.context), allowing: { true })
            let deny = try ScoringInputChange(device: PreferenceIntentFixture.device, kind: .config, entity: "primary", effectiveDay: "2026-09-18",
                payload: Data("{\"schemaVersion\":1,\"journalContextEnabled\":false}".utf8))
            _ = try await f.journal.importOrigin(UUID(), change: deny, position: .init(source: UUID(), sequence: 1), denialPurpose: .journal)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM input_control"), 1)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM input_change"), 4097)
        }
    }

    func testByteCapacityIncludesEnvelopeChildMetadataAndFixedProjection() async throws {
        try await fixture { f in
            let intent = try PreferenceIntentFixture.intent(f.context)
            let profileBytes = try XCTUnwrap(intent.profile).payload.count
            let configBytes = try XCTUnwrap(intent.config).payload.count
            let envelopeBytes = try intent.encoded().count
            let charge = envelopeBytes + 1024 + 2 * (profileBytes + configBytes) + ScoringInputJournal.preferenceProjectionBudget
            // Valid bounded fixture rows, not an oversized single payload that ordinary admission would reject.
            let fill = 16 * 1_048_576 - charge + 1
            try f.sql { db in
                var remaining = fill
                while remaining > 0 {
                    let size = min(60_000, remaining)
                    try db.execute(sql: "INSERT INTO input_change(id,device,kind,entity,day,payload,deleted,digest) VALUES(?,?,'profile','held','2026-09-18',zeroblob(?),0,'fixture')",
                        arguments: [UUID().uuidString, PreferenceIntentFixture.device, size])
                    remaining -= size
                }
            }
            await failure(.storageLimit) { _ = try await f.journal.admitPreferenceIntent(intent, allowing: { true }) }
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM preference_projection"), 0)
            try f.sql { try $0.execute(sql: "UPDATE input_change SET payload=substr(payload,1,length(payload)-1) WHERE sequence=1") }
            _ = try await f.journal.admitPreferenceIntent(intent, allowing: { true })
            let ordinary = try ScoringInputChange(device: PreferenceIntentFixture.device, kind: .context, entity: "ordinary", effectiveDay: "2026-09-18", payload: Data("{}".utf8))
            await failure(.storageLimit) { _ = try await f.journal.enqueue(ordinary) }
        }
    }

    func testSQLFailureOnSecondChildRollsBackFirstChildAndLocalChoice() async throws {
        try await fixture { f in
            try f.sql { try $0.execute(sql: "CREATE TRIGGER preference_test_failure BEFORE INSERT ON input_change WHEN NEW.kind='config' BEGIN SELECT RAISE(ABORT,'fixture disk failure'); END") }
            do { _ = try await f.journal.admitPreferenceIntent(PreferenceIntentFixture.intent(f.context), allowing: { true }); XCTFail("SQL failure accepted") }
            catch { XCTAssertTrue(error is DatabaseError) }
            try empty(f)
            try f.sql { try $0.execute(sql: "DROP TRIGGER preference_test_failure") }
            _ = try await f.journal.admitPreferenceIntent(PreferenceIntentFixture.intent(f.context), allowing: { true })
        }
    }

    func testUnknownVersionColumnsPartialSchemaAndOwnerlessDataAreNotAdopted() async throws {
        for corruption in ["UPDATE preference_state SET version=2", "UPDATE preference_state SET version='future'",
                           "ALTER TABLE preference_intent ADD COLUMN future TEXT",
                           "DROP TABLE preference_projection; CREATE TABLE preference_projection(key TEXT, value BLOB, sequence INTEGER, intent_id TEXT, generation TEXT, disposition TEXT)",
                           "DROP TABLE preference_projection", "DELETE FROM input_owner"] {
            try await fixture { f in
                _ = try await f.journal.admitPreferenceIntent(PreferenceIntentFixture.intent(f.context, local: true), allowing: { true })
                try await f.journal.close()
                try f.sql { try $0.execute(sql: corruption) }
                do { _ = try f.reopen(); XCTFail("Adopted \(corruption)") }
                catch { XCTAssertNotNil(error as? ScoringInputJournal.Failure) }
                XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM preference_intent"), 1)
            }
        }
    }

    func testLegacyAdditiveUpgradePreservesClientRevisionAndMutationIdentity() async throws {
        try await fixture { f in
            let change = try XCTUnwrap(PreferenceIntentFixture.intent(f.context).profile)
            _ = try await f.journal.enqueue(change)
            let before = try await f.journal.next()
            try await f.journal.close()
            try f.sql { try $0.execute(sql: "DROP TABLE preference_intent; DROP TABLE preference_projection; DROP TABLE preference_state") }
            let upgraded = try f.reopen()
            let after = try await upgraded.next()
            XCTAssertEqual(before, after)
            let head = try await upgraded.preferencePosition()
            XCTAssertEqual(head, .initial)
            _ = try await upgraded.admitPreferenceIntent(PreferenceIntentFixture.intent(f.context), allowing: { true })
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM input_change"), 3)
        }
    }

    func testMalformedEnvelopeUnknownPayloadAndLocalOnlyChildrenRejected() throws {
        let context = try PreferenceIntentFixture.context()
        let intent = try PreferenceIntentFixture.intent(context)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.encoded()) as? [String: Any])
        for key in ["version", "effectiveDay", "unexpected"] {
            var mutation = object
            mutation[key] = key == "version" ? 2 : "bad"
            XCTAssertThrowsError(try ScoringPreferenceIntent(encoded: JSONSerialization.data(withJSONObject: mutation, options: [.sortedKeys])))
        }
        object["generation"] = "invalid"
        XCTAssertThrowsError(try ScoringPreferenceIntent(encoded: JSONSerialization.data(withJSONObject: object)))
        for payload in ["{\"schemaVersion\":2}", "{\"schemaVersion\":true}", "{\"schemaVersion\":1,\"notes\":\"private\"}",
                        "{\"schemaVersion\":1,\"journalContextEnabled\":1}", "{\"schemaVersion\":1,\"maxHR\":true}",
                        "{\"schemaVersion\":1,\"customHRZoneLowerBounds\":[30,31,32,32,34]}"] {
            XCTAssertThrowsError(try ScoringPreferenceIntent(context: context, predecessor: .initial, occurredAt: intent.occurredAt,
                timezone: intent.timezone, device: intent.device, disposition: .serverCoupled, patch: intent.patch,
                profilePayload: intent.profile?.payload, configPayload: Data(payload.utf8)))
        }
        XCTAssertThrowsError(try ScoringPreferenceIntent(context: context, predecessor: .initial, occurredAt: intent.occurredAt,
            timezone: intent.timezone, device: intent.device, disposition: .localOnly, patch: intent.patch, profilePayload: intent.profile?.payload))
        XCTAssertThrowsError(try PreferenceIntentFixture.intent(context, patch: [.init(key: .weightKg, value: .number(.nan))]))
        XCTAssertThrowsError(try PreferenceIntentFixture.intent(context, patch: [.init(key: .sex, value: .text("private notes"))]))
    }

    func testConflictReplacementMustSettleBeforeBundleCanCompact() async throws {
        try await fixture { f in
            let intent = try PreferenceIntentFixture.intent(f.context)
            _ = try await f.journal.admitPreferenceIntent(intent, allowing: { true })
            let p = try await f.journal.next()
            let first = try XCTUnwrap(p)
            try await f.journal.retry(first, conflict: true)
            let reviews = try await f.journal.conflicts()
            let review = try XCTUnwrap(reviews.first)
            let head = ScoringInputHead(schemaVersion: 1, userId: UUID(uuidString: f.context.scope.userID)!,
                sourceDeviceId: UUID(uuidString: PreferenceIntentFixture.device)!, kind: .profile, entity: "primary", headRevision: 8)
            _ = try await f.journal.resolveConflict(review, head: head, replacement: XCTUnwrap(intent.profile))
            let q = try await f.journal.next()
            let config = try XCTUnwrap(q)
            XCTAssertEqual(config.change.kind, .config)
            try await f.journal.settle(config, receipt: PreferenceIntentFixture.receipt(config))
            let before = try await f.journal.compactPreferenceIntents()
            XCTAssertEqual(before, 0, "An archived child is not a settled child")
            let r = try await f.journal.next()
            let replacement = try XCTUnwrap(r)
            XCTAssertEqual(replacement.expectedRevision, 8)
            try await f.journal.settle(replacement, receipt: PreferenceIntentFixture.receipt(replacement))
            let after = try await f.journal.compactPreferenceIntents()
            XCTAssertEqual(after, 1)
        }
    }

    func testCancelledBeforeCommitRollsBackButCancellationAfterCommitCannotUndoAcceptance() async throws {
        try await fixture { f in
            let intent = try PreferenceIntentFixture.intent(f.context)
            let entered = expectation(description: "before commit")
            let release = DispatchSemaphore(value: 0)
            let task = Task.detached {
                try await f.journal.admitPreferenceIntent(intent, allowing: { true }, at: { point in
                    if point == .beforeCommit { entered.fulfill(); _ = release.wait(timeout: .now() + 10) }
                })
            }
            await fulfillment(of: [entered], timeout: 5)
            task.cancel(); release.signal()
            do { _ = try await task.value; XCTFail("Cancelled transaction committed") }
            catch { XCTAssertTrue(error is CancellationError) }
            try empty(f)
            let committed = expectation(description: "committed before callback")
            let after = DispatchSemaphore(value: 0)
            let retry = Task.detached {
                try await f.journal.admitPreferenceIntent(intent, allowing: { true }, at: { point in
                    if point == .afterCommit { committed.fulfill(); _ = after.wait(timeout: .now() + 10) }
                })
            }
            await fulfillment(of: [committed], timeout: 5)
            retry.cancel(); after.signal()
            let receipt = try await retry.value
            XCTAssertEqual(receipt.position, intent.position)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM input_change"), 2)
        }
    }

    func testUnknownProjectionCannotBePublishedAndRetiredInitializerCannotCreateJournal() async throws {
        try await fixture { f in
            _ = try await f.journal.admitPreferenceIntent(PreferenceIntentFixture.intent(f.context, local: true), allowing: { true })
            try f.sql { try $0.execute(sql: "UPDATE preference_projection SET disposition='future-auto-promote'") }
            await failure(.invalidInput) { _ = try await f.journal.committedPreferenceProjection() }
            let retiredLayout = AccountStorageLayout(baseDirectory: f.root.appendingPathComponent("retired"), scope: f.context.scope)
            do {
                _ = try ScoringInputJournal(layout: retiredLayout, preferenceContext: f.context, isPreferenceContextCurrent: { _ in false })
                XCTFail("Stale generation initialized journal")
            } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retired) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: retiredLayout.directory.path))
        }
    }

    func testIntentCapacityCannotGrowUUIDTombstonesAndProjectionSurvivesCompaction() async throws {
        try await fixture { f in
            var head = ScoringPreferencePosition.initial
            var first: ScoringPreferenceIntent?
            for _ in 0..<4096 {
                let intent = try PreferenceIntentFixture.intent(f.context, predecessor: head, local: true)
                if first == nil { first = intent }
                _ = try await f.journal.admitPreferenceIntent(intent, allowing: { true })
                head = intent.position
            }
            let next = try PreferenceIntentFixture.intent(f.context, predecessor: head, local: true)
            await failure(.storageLimit) { _ = try await f.journal.admitPreferenceIntent(next, allowing: { true }) }
            let count = try await f.journal.compactPreferenceIntents()
            XCTAssertEqual(count, 128)
            await failure(.stalePreferenceIntent) { _ = try await f.journal.admitPreferenceIntent(XCTUnwrap(first), allowing: { true }) }
            _ = try await f.journal.admitPreferenceIntent(next, allowing: { true })
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM preference_intent"), 3969)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM preference_projection"), 1)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM preference_state"), 1)
        }
    }

    @MainActor func testBlockedStorageActorDoesNotBlockMainActorAndReturnsOnlyAfterCommit() async throws {
        try await fixture { f in
            let entered = expectation(description: "storage worker before commit")
            let release = DispatchSemaphore(value: 0)
            let returned = PreferenceIntentSwitch()
            let intent = try PreferenceIntentFixture.intent(f.context)
            let task = Task.detached {
                let receipt = try await f.journal.admitPreferenceIntent(intent, allowing: { true }, at: { point in
                    XCTAssertFalse(Thread.isMainThread)
                    if point == .beforeCommit { entered.fulfill(); _ = release.wait(timeout: .now() + 10) }
                })
                returned.disable()
                return receipt
            }
            await fulfillment(of: [entered], timeout: 5)
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(returned.get(), "No acceptance returned before commit")
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM input_change"), 0, "Uncommitted children are invisible")
            release.signal()
            let receipt = try await task.value
            XCTAssertEqual(receipt.position, intent.position)
        }
    }

    #if SCORING_INPUT_NATIVE_TESTS
    func testSubprocessSIGKILLAtNativeTransactionAndReopenPoints() async throws {
        try await PreferenceCrashProbe.runCrashes()
    }
    #endif
}
