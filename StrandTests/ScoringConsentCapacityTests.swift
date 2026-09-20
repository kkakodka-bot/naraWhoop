import Foundation
import GRDB
import NoopPush
import WhoopStore
import XCTest
#if !SCORING_INPUT_NATIVE_TESTS
@testable import Strand
#endif

@MainActor
final class ScoringConsentCapacityTests: XCTestCase {
    private let device = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private func fixture() throws -> AccountStorageLayout {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("consent-capacity-" + UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return AccountStorageLayout(baseDirectory: root, scope: try AccountScope(projectURL: "https://consent-capacity.invalid",
            userID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
    }
    private func config(_ enabled: Bool, coefficient: Int = 1) throws -> ScoringConsentConfiguration {
        .init(change: try ScoringInputChange(device: device, kind: .config, entity: "primary", effectiveDay: "2026-09-18",
            payload: JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "journalContextEnabled": enabled,
                "cycleAwarenessEnabled": enabled, "stepsManualCoefficient": coefficient])), timezone: "UTC")
    }
    private func sensitive(_ decision: ScoringContextDecision) throws -> ScoringInputChange {
        let kinds: [ScoringContextPurpose: ScoringInputChange.Kind] = [.journal: .context, .cycle: .period,
            .imports: .importedDaily, .workouts: .manualWorkout]
        return try .init(device: device, kind: kinds[decision.purpose]!, entity: "primary", effectiveDay: "2026-09-18",
            payload: JSONSerialization.data(withJSONObject: ["consent": decision.payload]))
    }
    private func connect(_ consent: ScoringContextConsent, _ inputs: ScoringInputCoordinator) {
        // XCTest teardown is LIFO: close the captured actor's writer before fixture removal.
        addTeardownBlock { try await inputs.waitForRetirement() }
        inputs.prepareAdmission = { [weak consent, weak inputs] in
            guard let consent, let inputs else { throw ScoringInputJournal.Failure.retired }
            try await consent.relay(to: inputs)
        }
    }
    private func joined(_ count: Int, _ consent: ScoringContextConsent) async {
        let deadline = Date().addingTimeInterval(3)
        while consent.relayWaiterCount != count, Date() < deadline { await Task.yield() }
        XCTAssertEqual(consent.relayWaiterCount, count, "callers must join the actual shared relay before release")
    }
    private func offline(_ layout: AccountStorageLayout) throws -> ScoringInputCoordinator {
        ScoringInputCoordinator(context: .init(scope: try XCTUnwrap(layout.scope), generation: UUID()), layout: layout,
            dependencies: .init(isCurrent: { _ in true }, canUpload: { false }, head: { _, _ in
                XCTFail("offline head request"); throw ScoringInputRPC.Failure.unavailable
            }, send: { _, _ in XCTFail("offline send"); throw ScoringInputRPC.Failure.unavailable }))
    }
    private func database(_ layout: AccountStorageLayout, consent: Bool = true) throws -> DatabaseQueue {
        try DatabaseQueue(path: layout.directory.appendingPathComponent(consent ? "scoring-context-consent.sqlite" : "history-inputs.sqlite").path)
    }
    private func capacity(_ byteLimit: Bool) async throws {
        let layout = try fixture()
        let current = ScoringContextConsent(layout: layout)
        current.configuration = { [self] _, enabled, _ in try config(enabled) }
        await current.load()
        var old: [ScoringInputChange] = []
        for purpose in ScoringContextPurpose.allCases {
            await current.setEnabled(true, purpose: purpose)
            old.append(try sensitive(XCTUnwrap(current.decisions[purpose])))
        }
        let db = try database(layout)
        defer { try? db.close() }
        try await db.write { db in
            if byteLimit {
                let existing = try Int.fetchOne(db, sql: "SELECT SUM(length(payload)) FROM consent_intent")!
                var remaining = 16 * 1_048_576 - existing
                while remaining > 0 {
                    let size = min(65536, remaining)
                    let payload = Data(("{\"padding\":\"" + String(repeating: "x", count: size - 14) + "\"}").utf8)
                    XCTAssertEqual(payload.count, size)
                    try db.execute(sql: "INSERT INTO consent_intent(id,purpose,enabled,decided_at,completed,payload) VALUES(?,?,?,?,1,?)",
                        arguments: [UUID().uuidString.lowercased(), "journal_context", false, 0, payload])
                    remaining -= size
                }
            } else {
                try db.execute(sql: """
                    WITH RECURSIVE n(i) AS(VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<4092)
                    INSERT INTO consent_intent(id,purpose,enabled,decided_at,completed)
                    SELECT printf('%08x-0000-4000-8000-%012x',i,i),'journal_context',0,0,1 FROM n;
                    """)
            }
        }
        for purpose in ScoringContextPurpose.allCases {
            await current.setEnabled(false, purpose: purpose)
            XCTAssertNil(current.error)
        }
        let reserved = try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT id,purpose,payload FROM consent_intent WHERE reserved=1 ORDER BY purpose")
        }
        XCTAssertEqual(reserved.count, 4)
        XCTAssertEqual(Set(reserved.map { $0["purpose"] as String }), Set(ScoringContextPurpose.allCases.map(\.rawValue)))
        let ids: [String] = reserved.map { $0["id"] }
        current.retire()
        let reopened = ScoringContextConsent(layout: layout)
        await reopened.load()
        for input in old { XCTAssertFalse(reopened.gate.allows(input)) }
        // A refused grant cannot undo the denial, nor release rows carrying an earlier grant ID.
        reopened.configuration = { [self] _, enabled, _ in try config(enabled) }
        await reopened.setEnabled(true, purpose: .journal)
        XCTAssertNotNil(reopened.error)
        reopened.retire()
        let again = ScoringContextConsent(layout: layout)
        await again.load()
        for input in old { XCTAssertFalse(again.gate.allows(input)) }
        let retained = try await db.read { try String.fetchAll($0, sql: "SELECT id FROM consent_intent WHERE reserved=1 ORDER BY purpose") }
        XCTAssertEqual(retained, ids)
        again.retire()
    }
    func testCountCapKeepsAllFourDenialsDurableWithoutReleasingOldRows() async throws { try await capacity(false) }
    func testByteCapKeepsAllFourDenialsDurableWithoutReleasingOldRows() async throws { try await capacity(true) }

    func testOccupiedReserveAndFailedVisibleWriteStillPersistIndependentPause() async throws {
        let layout = try fixture()
        let current = ScoringContextConsent(layout: layout)
        current.configuration = { [self] _, enabled, _ in try config(enabled) }
        await current.load(); await current.setEnabled(true, purpose: .journal)
        let old = try sensitive(XCTUnwrap(current.decisions[.journal]))
        let db = try database(layout)
        defer { try? db.close() }
        try await db.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(i) AS(VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<4095)
                INSERT INTO consent_intent(id,purpose,enabled,decided_at,completed)
                SELECT printf('%08x-0000-4000-8000-%012x',i,i),'journal_context',0,0,1 FROM n;
                CREATE TRIGGER reject_decision BEFORE UPDATE ON consent_decision BEGIN SELECT RAISE(ABORT,'injected'); END;
                """)
        }
        await current.setEnabled(false, purpose: .journal)
        let first = try await db.read { try String.fetchOne($0, sql: "SELECT id FROM consent_intent WHERE reserved=1") }
        await current.setEnabled(false, purpose: .journal)
        XCTAssertNotNil(current.error)
        let second = try await db.read { try String.fetchOne($0, sql: "SELECT id FROM consent_intent WHERE reserved=1") }
        XCTAssertEqual(first, second)
        current.retire()
        let reopened = ScoringContextConsent(layout: layout); await reopened.load()
        XCTAssertFalse(reopened.gate.allows(old)); XCTAssertNotNil(reopened.error)
        reopened.retire()
    }

    func testFullPendingQueueDrainsUnrelatedDeviceThenSameDenialAcrossPartialReopen() async throws {
        let layout = try fixture()
        let seed = try ScoringInputJournal(layout: layout)
        let blocked = try ScoringInputChange(device: device, kind: .profile, entity: "primary", effectiveDay: "2026-09-18", payload: Data("{\"age\":30}".utf8))
        let other = try ScoringInputChange(device: "cccccccc-cccc-cccc-cccc-cccccccccccc", kind: .profile, entity: "primary", effectiveDay: "2026-09-18", payload: Data("{\"age\":31}".utf8))
        _ = try await seed.enqueue(blocked)
        let firstValue = try await seed.next(), first = try XCTUnwrap(firstValue)
        try await seed.retry(first, conflict: true)
        let db = try database(layout, consent: false)
        defer { try? db.close() }
        try await db.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(i) AS(VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<4094)
                INSERT INTO input_change(id,device,kind,entity,day,payload,deleted,digest)
                SELECT printf('%08x-0000-4000-8000-%012x',i,i),?,'profile','primary','2026-09-18',?,0,? FROM n;
                """, arguments: [blocked.device, blocked.payload, blocked.digest])
        }
        _ = try await seed.enqueue(other)
        await seed.retire()
        let consent = ScoringContextConsent(layout: layout)
        consent.configuration = { [self] _, enabled, _ in try config(enabled) }
        await consent.load(); await consent.setEnabled(false, purpose: .journal)
        let store = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        let intents = try await store.pendingIntents(), denial = try XCTUnwrap(intents.first)
        let state = ScoringInputTestState(); state.setReady(true)
        func coordinator(stopAfterFirst: Bool) throws -> ScoringInputCoordinator {
            ScoringInputCoordinator(context: .init(scope: try XCTUnwrap(layout.scope), generation: UUID()), layout: layout,
                dependencies: .init(isCurrent: { _ in true }, canUpload: { state.ready() }, head: {
                    ScoringInputJournalTests.head($0, scope: $1.scope, revision: 20)
                }, send: { pending, _ in
                    let count = state.record(pending)
                    if stopAfterFirst && count == 1 { state.setReady(false) }
                    return ScoringInputJournalTests.receipt(pending, revision: pending.expectedRevision + 1)
                }))
        }
        let inputs = try coordinator(stopAfterFirst: true); connect(consent, inputs)
        do { try await inputs.enqueue(config(false, coefficient: 9).change); XCTFail("fresh config bypassed denial") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .storageLimit) }
        await inputs.reconcile()?.value
        XCTAssertEqual(state.sent().map(\.change.device), [other.device])
        let queuedDenial = try await db.read { try String.fetchOne($0, sql: "SELECT id FROM input_change WHERE kind='config'") }
        XCTAssertEqual(queuedDenial, denial.id.uuidString.lowercased())
        inputs.retire(); consent.retire()
        let reopened = ScoringContextConsent(layout: layout); await reopened.load()
        let successor = try coordinator(stopAfterFirst: false); connect(reopened, successor)
        state.setReady(true); await successor.reconcile()?.value
        XCTAssertEqual(state.sent().last?.id, denial.id.uuidString.lowercased())
        XCTAssertEqual(state.sent().last?.expectedRevision, 20, "no blind rebase or zero-head assumption")
        let held = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM input_change WHERE device=?", arguments: [blocked.device]) }
        XCTAssertEqual(held, 4095, "conflict and its followers remain byte-for-byte debt")
        let conflict = try await db.read { try Int64.fetchOne($0, sql: "SELECT expected_revision FROM input_change WHERE id=?", arguments: [first.id]) }
        XCTAssertEqual(conflict, first.expectedRevision)
        state.setReady(false)
        try await successor.enqueue(config(false, coefficient: 9).change)
        await successor.reconcile()?.value
        let pending = try await store.pendingIntents()
        XCTAssertTrue(pending.isEmpty)
        successor.retire(); reopened.retire()
    }

    func testAcceptedOriginCapacityCompactsReceiptHandshakeWithoutReplayingOldIDs() async throws {
        let layout = try fixture()
        let current = ScoringContextConsent(layout: layout)
        current.configuration = { [self] _, enabled, _ in try config(enabled) }
        await current.load(); await current.setEnabled(true, purpose: .journal)
        let store = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        let originals = try await store.pendingIntents(), first = try XCTUnwrap(originals.first)
        let journal = try ScoringInputJournal(layout: layout)
        let inputDB = try database(layout, consent: false), consentDB = try database(layout)
        defer { try? inputDB.close(); try? consentDB.close() }
        let scope = try XCTUnwrap(layout.scope), change = first.configuration.change
        var receipts: [(String, Data)] = []
        for index in 1...4096 {
            let id = index == 1 ? first.id : UUID()
            let receipt = ScoringInputReceipt(schemaVersion: 1, userId: UUID(uuidString: scope.userID)!,
                sourceDeviceId: UUID(uuidString: device)!, kind: .config, entity: "primary", revision: Int64(index),
                clientId: journal.clientID, clientMutationId: id, clientRevision: Int64(index),
                effectiveDay: change.effectiveDay, deleted: false, invalidatedFrom: change.effectiveDay)
            receipts.append((id.uuidString.lowercased(), try JSONEncoder().encode(receipt)))
        }
        let frozenReceipts = receipts
        try await consentDB.write { db in
            for (offset, row) in frozenReceipts.enumerated() {
                if offset == 0 {
                    try db.execute(sql: "UPDATE consent_intent SET imported_id=id,receipt=? WHERE id=?", arguments: [row.1, row.0])
                } else {
                    try db.execute(sql: """
                        INSERT INTO consent_intent(id,purpose,enabled,decided_at,completed,device,day,payload,timezone,imported_id,receipt)
                        VALUES(?,'journal_context',1,0,1,?,?,?,'UTC',?,?)
                        """, arguments: [row.0, change.device, change.effectiveDay, change.payload, row.0, row.1])
                }
            }
        }
        try await inputDB.write { db in
            try db.execute(sql: "INSERT INTO input_relay VALUES(1,?,4096)", arguments: [store.sourceID.uuidString.lowercased()])
            for (offset, row) in frozenReceipts.enumerated() {
                try db.execute(sql: "INSERT INTO input_origin VALUES(?,?,?,?,?,?,?,?,?)",
                    arguments: [row.0, row.0, change.device, "config", "primary", change.effectiveDay, change.digest, row.1, offset + 1])
            }
        }
        await current.setEnabled(false, purpose: .journal)
        XCTAssertNil(current.error)
        let pending = try await store.pendingIntents(), denial = try XCTUnwrap(pending.first)
        let inputs = try offline(layout); connect(current, inputs)
        try await current.relay(to: inputs)
        let count = try await inputDB.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM input_origin") }
        XCTAssertLessThan(try XCTUnwrap(count), 4096)
        let rows = try await inputDB.read { try String.fetchAll($0, sql: "SELECT id FROM input_change") }
        XCTAssertEqual(rows, [denial.id.uuidString.lowercased()])
        do { _ = try await journal.importOrigin(first.id, change: change, position: first.position); XCTFail("retired origin replayed") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retiredOrigin) }
        try await current.relay(to: inputs)
        let still = try await inputDB.read { try String.fetchAll($0, sql: "SELECT id FROM input_change") }
        XCTAssertEqual(still, rows)
        inputs.retire(); current.retire(); await journal.retire()
    }

    func testReceiptCopyAndBothRetirementTransactionsRecoverAfterFailureAndReopen() async throws {
        let layout = try fixture()
        let consentFence = StoreWriteFence(), inputFence = StoreWriteFence()
        let store = try ScoringContextConsentStore(layout: layout, fence: consentFence)
        _ = try await store.set(.journal, enabled: false, configuration: config(false))
        let list = try await store.pendingIntents(), intent = try XCTUnwrap(list.first)
        let journal = try ScoringInputJournal(layout: layout, fence: inputFence)
        _ = try await journal.importOrigin(intent.id, change: intent.configuration.change, position: intent.position)
        let value = try await journal.next(), next = try XCTUnwrap(value)
        let receipt = ScoringInputJournalTests.receipt(next, revision: 8)
        try await journal.settle(next, receipt: receipt)
        let db = try database(layout)
        defer { try? db.close() }
        try await db.write { try $0.execute(sql: "CREATE TRIGGER reject_receipt BEFORE UPDATE OF receipt ON consent_intent BEGIN SELECT RAISE(ABORT,'injected'); END") }
        do { try await store.recordProgress(.accepted(receipt), for: intent); XCTFail("receipt copy succeeded") } catch {}
        let retained = try await journal.originProgress(intent.id)
        XCTAssertEqual(retained, .accepted(receipt))
        try await db.write { try $0.execute(sql: "DROP TRIGGER reject_receipt") }
        try await store.recordProgress(.accepted(receipt), for: intent)
        do {
            try await journal.retireOrigin(intent.id, change: intent.configuration.change, position: intent.position,
                receipt: receipt, beforeCommit: { inputFence.invalidate() })
            XCTFail("retired writer compacted")
        } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retired) }
        let reopenedInput = try ScoringInputJournal(layout: layout)
        let afterRollback = try await reopenedInput.originProgress(intent.id)
        XCTAssertEqual(afterRollback, .accepted(receipt))
        try await reopenedInput.retireOrigin(intent.id, change: intent.configuration.change, position: intent.position, receipt: receipt)
        // Simulated process death between the two stores: accepted consent evidence is still present.
        let reopenedConsent = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        let copied = try await reopenedConsent.acceptedIntents()
        XCTAssertEqual(copied.first?.0, intent)
        try await reopenedInput.retireOrigin(intent.id, change: intent.configuration.change, position: intent.position, receipt: receipt)
        do {
            try await store.finishRetirement(intent, receipt: receipt, beforeCommit: { consentFence.invalidate() })
            XCTFail("retired consent writer compacted")
        } catch {}
        try await reopenedConsent.finishRetirement(intent, receipt: receipt)
        try await reopenedConsent.finishRetirement(intent, receipt: receipt)
        let replayAfterReopen = try ScoringInputJournal(layout: layout)
        do { _ = try await replayAfterReopen.importOrigin(intent.id, change: intent.configuration.change, position: intent.position); XCTFail("compacted origin reappeared") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retiredOrigin) }
        _ = try await reopenedConsent.set(.journal, enabled: true, configuration: config(true))
        let newer = try await reopenedConsent.pendingIntents(), newIntent = try XCTUnwrap(newer.first)
        XCTAssertGreaterThan(newIntent.position.sequence, intent.position.sequence)
        XCTAssertNotEqual(newIntent.id, intent.id)
        _ = try await reopenedInput.importOrigin(newIntent.id, change: newIntent.configuration.change, position: newIntent.position)
        await reopenedInput.retire(); await replayAfterReopen.retire()
    }

    func testReentrantTransitionCannotLetFreshConfigOvertakeNewDenial() async throws {
        let layout = try fixture()
        let owner = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        _ = try await owner.set(.journal, enabled: true, configuration: config(true, coefficient: 1))
        let pending = try await owner.pendingIntents(), old = try XCTUnwrap(pending.first)
        let journal = try ScoringInputJournal(layout: layout)
        let progress = try await journal.importOrigin(old.id, change: old.configuration.change, position: old.position)
        try await owner.recordProgress(progress, for: old)
        await journal.retire()
        let consent = ScoringContextConsent(layout: layout); await consent.load()
        consent.configuration = { [self] _, _, _ in try config(false, coefficient: 2) }
        let gate = ScoringInputTestGate()
        let inputs = ScoringInputCoordinator(context: .init(scope: try XCTUnwrap(layout.scope), generation: UUID()), layout: layout,
            dependencies: .init(isCurrent: { _ in true }, canUpload: { false }, openJournal: { layout, fence in
                await gate.wait(); return try ScoringInputJournal(layout: layout, fence: fence)
            }, head: { _, _ in throw ScoringInputRPC.Failure.unavailable }, send: { _, _ in throw ScoringInputRPC.Failure.unavailable }))
        connect(consent, inputs)
        let older = Task { try await consent.relay(to: inputs) }
        await fulfillment(of: [gate.entered], timeout: 3)
        await consent.setEnabled(false, purpose: .journal)
        let fresh = try config(false, coefficient: 3).change
        let producer = Task { try await inputs.enqueue(fresh) }
        await joined(2, consent)
        await gate.release()
        do { try await older.value; XCTFail("old relay snapshot was accepted") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .held) }
        do { try await producer.value; XCTFail("fresh config overtook new denial") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .held) }
        try await inputs.enqueue(fresh)
        await inputs.reconcile()?.value
        let db = try database(layout, consent: false)
        defer { try? db.close() }
        let coefficients = try await db.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM input_change ORDER BY sequence").map {
                (try JSONSerialization.jsonObject(with: $0) as! [String: Any])["stepsManualCoefficient"] as! Int
            }
        }
        XCTAssertEqual(coefficients, [1, 2, 3])
        consent.retire(); inputs.retire()
    }

    func testLaterAcceptedOriginCompactsBeyond64HeldImportedEntries() async throws {
        let layout = try fixture()
        let owner = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        let journal = try ScoringInputJournal(layout: layout)
        for _ in 0..<65 {
            let body = try config(false)
            let change = try ScoringInputChange(device: UUID().uuidString, kind: .config, entity: "primary",
                effectiveDay: body.change.effectiveDay, payload: body.change.payload)
            _ = try await owner.set(.journal, enabled: false, configuration: .init(change: change, timezone: "UTC"))
        }
        let all = try await owner.pendingIntents(limit: 128)
        XCTAssertEqual(all.count, 65)
        for intent in all {
            let progress = try await journal.importOrigin(intent.id, change: intent.configuration.change, position: intent.position)
            try await owner.recordProgress(progress, for: intent)
        }
        let last = try XCTUnwrap(all.last)
        let nextValue = try await journal.next(allowing: { $0.device == last.configuration.change.device })
        let next = try XCTUnwrap(nextValue)
        try await journal.settle(next, receipt: ScoringInputJournalTests.receipt(next, revision: 3))
        let consent = ScoringContextConsent(layout: layout); await consent.load()
        let inputs = try offline(layout); connect(consent, inputs)
        try await consent.relay(to: inputs) // Visits the first 64 retained origins.
        try await consent.relay(to: inputs) // Must reach the later accepted origin.
        let remaining = try await owner.pendingIntents(limit: 128)
        XCTAssertEqual(remaining.map(\.id), Array(all.dropLast()).map(\.id))
        let db = try database(layout, consent: false)
        defer { try? db.close() }
        let origins = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM input_origin") }
        XCTAssertEqual(origins, 64)
        let earlier = try XCTUnwrap(all.first)
        let retained = try await journal.importOrigin(earlier.id, change: earlier.configuration.change, position: earlier.position)
        XCTAssertEqual(retained, .queued(earlier.id.uuidString.lowercased()), "high water must not retire older pending rows")
        do { _ = try await journal.importOrigin(last.id, change: last.configuration.change, position: last.position); XCTFail("accepted origin replayed") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retiredOrigin) }
        consent.retire(); inputs.retire(); await journal.retire()
    }

    func testCompactingAcceptedDenialCannotEraseFailedDecisionPause() async throws {
        let layout = try fixture()
        let owner = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        let grant = try await owner.set(.journal, enabled: true, configuration: config(true))
        let old = try sensitive(grant)
        let db = try database(layout)
        defer { try? db.close() }
        try await db.write { try $0.execute(sql: "CREATE TRIGGER reject_decision BEFORE UPDATE ON consent_decision BEGIN SELECT RAISE(ABORT,'injected'); END") }
        do { _ = try await owner.set(.journal, enabled: false, configuration: config(false)); XCTFail("denial visible write succeeded") } catch {}
        let pending = try await owner.pendingIntents(), intent = try XCTUnwrap(pending.last)
        let journal = try ScoringInputJournal(layout: layout)
        for intent in pending { _ = try await journal.importOrigin(intent.id, change: intent.configuration.change, position: intent.position) }
        for _ in 0..<2 {
            let value = try await journal.next(), next = try XCTUnwrap(value)
            let receipt = ScoringInputJournalTests.receipt(next, revision: next.expectedRevision + 1)
            try await journal.settle(next, receipt: receipt)
            let source = try XCTUnwrap(pending.first { $0.id.uuidString.lowercased() == next.id })
            try await owner.recordProgress(.accepted(receipt), for: source)
        }
        let accepted = try await owner.acceptedIntents()
        for (intent, receipt) in accepted {
            try await journal.retireOrigin(intent.id, change: intent.configuration.change, position: intent.position, receipt: receipt)
            try await owner.finishRetirement(intent, receipt: receipt)
        }
        let retained = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM consent_intent WHERE id=?", arguments: [intent.id.uuidString.lowercased()]) }
        XCTAssertEqual(retained, 0)
        let reopened = ScoringContextConsent(layout: layout); await reopened.load()
        XCTAssertFalse(reopened.gate.allows(old)); XCTAssertNotNil(reopened.error)
        reopened.retire(); await journal.retire()
    }

    func testCancelledRelayProducerDoesNotCancelAnotherWaiterOrReleaseItsOwnConfig() async throws {
        let layout = try fixture()
        let current = ScoringContextConsent(layout: layout)
        current.configuration = { [self] _, enabled, _ in try config(enabled) }
        await current.load(); await current.setEnabled(false, purpose: .journal)
        let gate = ScoringInputTestGate()
        let inputs = ScoringInputCoordinator(context: .init(scope: try XCTUnwrap(layout.scope), generation: UUID()), layout: layout,
            dependencies: .init(isCurrent: { _ in true }, canUpload: { false }, openJournal: { layout, fence in
                await gate.wait(); return try ScoringInputJournal(layout: layout, fence: fence)
            }, head: { _, _ in throw ScoringInputRPC.Failure.unavailable }, send: { _, _ in throw ScoringInputRPC.Failure.unavailable }))
        connect(current, inputs)
        let first = try config(false, coefficient: 2).change, second = try config(false, coefficient: 3).change
        let cancelled = Task { try await inputs.enqueue(first) }
        await fulfillment(of: [gate.entered], timeout: 3)
        cancelled.cancel()
        let live = Task { try await inputs.enqueue(second) }
        await joined(2, current)
        await gate.release()
        do { try await cancelled.value; XCTFail("cancelled producer admitted config") } catch { XCTAssertTrue(error is CancellationError) }
        try await live.value
        await inputs.reconcile()?.value
        let db = try database(layout, consent: false)
        defer { try? db.close() }
        let payloads = try await db.read { try Data.fetchAll($0, sql: "SELECT payload FROM input_change ORDER BY sequence") }
        XCTAssertEqual(payloads, [try config(false).change.payload, second.payload])
        current.retire(); inputs.retire()
    }

    func testRetiredRelayOpeningCannotWriteIntoSameAccountSuccessor() async throws {
        let layout = try fixture()
        let consent = ScoringContextConsent(layout: layout)
        consent.configuration = { [self] _, enabled, _ in try config(enabled) }
        await consent.load(); await consent.setEnabled(false, purpose: .journal)
        let gate = ScoringInputTestGate()
        let inputs = ScoringInputCoordinator(context: .init(scope: try XCTUnwrap(layout.scope), generation: UUID()), layout: layout,
            dependencies: .init(isCurrent: { _ in true }, canUpload: { false }, openJournal: { layout, fence in
                await gate.wait(); return try ScoringInputJournal(layout: layout, fence: fence)
            }, head: { _, _ in throw ScoringInputRPC.Failure.unavailable }, send: { _, _ in throw ScoringInputRPC.Failure.unavailable }))
        connect(consent, inputs)
        let pending = Task { try await consent.relay(to: inputs) }
        await fulfillment(of: [gate.entered], timeout: 3)
        consent.retire(); inputs.retire()
        let successorConsent = ScoringContextConsent(layout: layout); await successorConsent.load()
        let successor = try offline(layout); connect(successorConsent, successor)
        try await successorConsent.relay(to: successor)
        await gate.release()
        do { try await pending.value; XCTFail("retired relay completed") } catch {}
        try await successorConsent.relay(to: successor)
        let db = try database(layout, consent: false)
        defer { try? db.close() }
        let count = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM input_change") }
        XCTAssertEqual(count, 1)
        successorConsent.retire(); successor.retire()
    }

    func testLegacyPauseAndImportedMutationUpgradeWithoutChangingFrozenWireIdentity() async throws {
        let layout = try fixture(), scope = try XCTUnwrap(layout.scope)
        try layout.prepare()
        let intentID = UUID(), clientID = UUID(), grantID = UUID()
        let change = try config(false).change
        let consentDB = try database(layout), inputDB = try database(layout, consent: false)
        defer { try? consentDB.close(); try? inputDB.close() }
        try await consentDB.write { db in
            try db.execute(sql: """
                CREATE TABLE consent_owner(singleton INTEGER PRIMARY KEY,project TEXT NOT NULL,user TEXT NOT NULL);
                CREATE TABLE consent_decision(purpose TEXT PRIMARY KEY,decision_id TEXT NOT NULL,enabled INTEGER NOT NULL,decided_at REAL NOT NULL);
                CREATE TABLE consent_intent(sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT UNIQUE NOT NULL,purpose TEXT NOT NULL,
                    enabled INTEGER NOT NULL,decided_at REAL NOT NULL,completed INTEGER NOT NULL DEFAULT 0,
                    device TEXT,day TEXT,payload BLOB,timezone TEXT,imported_id TEXT,receipt BLOB,resolution_id TEXT);
                CREATE TABLE consent_barrier(purpose TEXT PRIMARY KEY,intent_id TEXT NOT NULL);
                """)
            try db.execute(sql: "INSERT INTO consent_owner VALUES(1,?,?)", arguments: [scope.projectURL, scope.userID])
            try db.execute(sql: "INSERT INTO consent_decision VALUES('journal_context',?,1,0)", arguments: [grantID.uuidString.lowercased()])
            try db.execute(sql: """
                INSERT INTO consent_intent(sequence,id,purpose,enabled,decided_at,device,day,payload,timezone,imported_id)
                VALUES(12,?,'journal_context',0,1790000000,?,?,?,'UTC',?)
                """, arguments: [intentID.uuidString.lowercased(), change.device, change.effectiveDay, change.payload, intentID.uuidString.lowercased()])
            try db.execute(sql: "INSERT INTO consent_barrier VALUES('journal_context',?)", arguments: [intentID.uuidString.lowercased()])
        }
        try await inputDB.write { db in
            try db.execute(sql: """
                CREATE TABLE input_owner(singleton INTEGER PRIMARY KEY,project TEXT NOT NULL,user TEXT NOT NULL,client_id TEXT);
                CREATE TABLE input_change(sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,
                    device TEXT NOT NULL,kind TEXT NOT NULL,entity TEXT NOT NULL,day TEXT NOT NULL,payload BLOB NOT NULL,
                    deleted INTEGER NOT NULL,digest TEXT NOT NULL,expected_revision INTEGER,failures INTEGER NOT NULL DEFAULT 0,
                    retry_at REAL NOT NULL DEFAULT 0,conflict INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE input_origin(origin_id TEXT PRIMARY KEY,mutation_id TEXT NOT NULL UNIQUE,device TEXT NOT NULL,
                    kind TEXT NOT NULL,entity TEXT NOT NULL,day TEXT NOT NULL,digest TEXT NOT NULL,receipt BLOB);
                """)
            try db.execute(sql: "INSERT INTO input_owner VALUES(1,?,?,?)", arguments: [scope.projectURL, scope.userID, clientID.uuidString.lowercased()])
            try db.execute(sql: "INSERT INTO input_change(sequence,id,device,kind,entity,day,payload,deleted,digest,expected_revision,failures) VALUES(41,?,?,'config','primary',?,?,0,?,7,3)",
                arguments: [intentID.uuidString.lowercased(), change.device, change.effectiveDay, change.payload, change.digest])
            try db.execute(sql: "INSERT INTO input_origin VALUES(?,?,?,'config','primary',?,?,NULL)",
                arguments: [intentID.uuidString.lowercased(), intentID.uuidString.lowercased(), change.device, change.effectiveDay, change.digest])
        }
        let owner = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        let values = try await owner.read()
        XCTAssertEqual(values[.journal]?.enabled, false)
        let list = try await owner.pendingIntents(), intent = try XCTUnwrap(list.first)
        XCTAssertEqual(intent.position.sequence, 12)
        let journal = try ScoringInputJournal(layout: layout)
        _ = try await journal.importOrigin(intent.id, change: intent.configuration.change, position: intent.position)
        let value = try await journal.next(), next = try XCTUnwrap(value)
        XCTAssertEqual(next.id, intentID.uuidString.lowercased()); XCTAssertEqual(next.clientID, clientID)
        XCTAssertEqual(next.clientRevision, 41); XCTAssertEqual(next.expectedRevision, 7)
        XCTAssertEqual(next.failures, 3); XCTAssertEqual(next.change, change)
        let receipt = ScoringInputJournalTests.receipt(next, revision: 8)
        try await journal.settle(next, receipt: receipt)
        try await owner.recordProgress(.accepted(receipt), for: intent)
        try await journal.retireOrigin(intent.id, change: change, position: intent.position, receipt: receipt)
        try await owner.finishRetirement(intent, receipt: receipt)
        let reopened = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        XCTAssertEqual(reopened.sourceID, owner.sourceID)
        let decisions = try await reopened.read()
        XCTAssertEqual(decisions[.journal]?.enabled, false)
        await journal.retire()
    }

    func testFixtureRetirementClosesRetainedWriterBeforeRemovingFiles() async throws {
        let layout = try fixture(), fence = StoreWriteFence()
        let journal = try ScoringInputJournal(layout: layout, fence: fence)
        let inputs = ScoringInputCoordinator(context: .init(scope: try XCTUnwrap(layout.scope), generation: UUID()), layout: layout,
            dependencies: .init(isCurrent: { _ in true }, canUpload: { false }, openJournal: { _, _ in journal },
                head: { _, _ in throw ScoringInputRPC.Failure.unavailable }, send: { _, _ in throw ScoringInputRPC.Failure.unavailable }), fence: fence)
        try await inputs.enqueue(config(false).change)
        await inputs.reconcile()?.value
        try await inputs.waitForRetirement()
        try await inputs.waitForRetirement()
        // Keep the actor strongly retained: ARC timing cannot substitute for an actual close.
        do { _ = try await journal.status(); XCTFail("retired writer remains open") }
        catch { XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_MISUSE) }
        let successor = try ScoringInputJournal(layout: layout)
        let status = try await successor.status()
        XCTAssertEqual(status.pending, 1, "resource retirement must not discard durable debt")
        try await successor.close()
    }

    /// Count fixtures use the actual context producer. Byte fixtures add inert JSON padding
    /// solely to exercise the journal's byte budget; they are never sent as server inputs.
    private func seedHeld(_ layout: AccountStorageLayout, decision: ScoringContextDecision,
                          count: Int, byteCap: Bool = false) async throws -> [ScoringInputChange] {
        let changes = try (0..<count).map { index in
            let day = ServerScoreDate.day(Date(timeIntervalSince1970: 1_420_070_400 + Double(index) * 86400),
                                          timeZone: TimeZone(secondsFromGMT: 0)!)
            let input = try ScoringContextInput.context(device: device, day: day, timezone: "UTC",
                flags: .init(stress: true), decision: decision)
            guard byteCap else { return input }
            var object = try JSONSerialization.jsonObject(with: input.payload) as! [String: Any]
            object["padding"] = ""
            let overhead = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).count
            object["padding"] = String(repeating: "x", count: 65536 - overhead)
            return try ScoringInputChange(device: input.device, kind: input.kind, entity: input.entity,
                effectiveDay: input.effectiveDay, payload: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        }
        let db = try database(layout, consent: false)
        defer { try? db.close() }
        try await db.write { db in
            for change in changes {
                try db.execute(sql: "INSERT INTO input_change(id,device,kind,entity,day,payload,deleted,digest) VALUES(?,?,?,?,?,?,0,?)",
                    arguments: [UUID().uuidString.lowercased(), change.device, change.kind.rawValue,
                        change.entity, change.effectiveDay, change.payload, change.digest])
            }
        }
        return changes
    }

    private func heldCapacity(count: Int, byteCap: Bool = false, allPurposes: Bool = true) async throws {
        let layout = try fixture(), purposes = allPurposes ? ScoringContextPurpose.allCases : [.journal]
        let store = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        let journal = try ScoringInputJournal(layout: layout)
        addTeardownBlock { try await journal.close() }
        var grant: ScoringContextDecision?
        // Settle the actual original grants before filling the sensitive queue. A remote
        // grant, not an unsent local toggle, is the predecessor for these denials.
        for purpose in purposes {
            let decision = try await store.set(purpose, enabled: true, configuration: config(true))
            if purpose == .journal { grant = decision }
            let list = try await store.pendingIntents(), intent = try XCTUnwrap(list.first)
            XCTAssertNil(intent.denialPurpose)
            _ = try await journal.importOrigin(intent.id, change: intent.configuration.change, position: intent.position)
            let value = try await journal.next(), pending = try XCTUnwrap(value)
            let receipt = ScoringInputJournalTests.receipt(pending, revision: pending.expectedRevision + 1)
            try await journal.settle(pending, receipt: receipt)
            try await store.recordProgress(.accepted(receipt), for: intent)
            try await journal.retireOrigin(intent.id, change: intent.configuration.change, position: intent.position, receipt: receipt)
            try await store.finishRetirement(intent, receipt: receipt)
        }
        let held = try await seedHeld(layout, decision: XCTUnwrap(grant), count: count, byteCap: byteCap)
        let db = try database(layout, consent: false)
        defer { try? db.close() }
        let original = try await db.read { try Row.fetchAll($0, sql: "SELECT * FROM input_change ORDER BY sequence") }
        if byteCap { XCTAssertEqual(held.reduce(0) { $0 + $1.payload.count }, 16 * 1_048_576) }
        let current = ScoringContextConsent(layout: layout); await current.load()
        XCTAssertTrue(current.gate.allows(held[0]))
        current.configuration = { [self] _, enabled, _ in try config(enabled) }
        for purpose in purposes { await current.setEnabled(false, purpose: purpose); XCTAssertNil(current.error) }
        XCTAssertTrue(held.allSatisfy { !current.gate.allows($0) })
        let denials = try await store.pendingIntents(includeImported: false)
        XCTAssertEqual(denials.map(\.denialPurpose), purposes.map { Optional($0) })
        let first = try XCTUnwrap(denials.first)
        // Crash boundary: the first immutable origin commits, but consent has not copied its
        // import result. Reopening must rediscover that same ID, source position and payload.
        _ = try await journal.importOrigin(first.id, change: first.configuration.change,
            position: first.position, denialPurpose: first.denialPurpose)
        try await journal.close(); current.retire()

        let state = ScoringInputTestState()
        func coordinator(_ consent: ScoringContextConsent, stopAfterFirst: Bool) throws -> ScoringInputCoordinator {
            let inputs = ScoringInputCoordinator(context: .init(scope: try XCTUnwrap(layout.scope), generation: UUID()), layout: layout,
                dependencies: .init(isCurrent: { _ in true }, canUpload: { state.ready() }, head: { change, context in
                    XCTAssertEqual(change.kind, .config, "held data must never reach head lookup")
                    return ScoringInputJournalTests.head(change, scope: context.scope, revision: 20)
                }, send: { pending, _ in
                    XCTAssertEqual(pending.change.kind, .config, "held sensitive bytes must never reach transport")
                    let sent = state.record(pending)
                    if stopAfterFirst && sent == 1 { state.setReady(false) }
                    return ScoringInputJournalTests.receipt(pending, revision: pending.expectedRevision + 1)
                }, allowsChange: { [gate = consent.gate] in gate.allows($0) }))
            connect(consent, inputs)
            return inputs
        }
        let reopened = ScoringContextConsent(layout: layout); await reopened.load()
        let inputs = try coordinator(reopened, stopAfterFirst: true)
        try await reopened.relay(to: inputs)
        try await reopened.relay(to: inputs)
        let queued = try await db.read { try Row.fetchAll($0, sql: "SELECT * FROM input_change WHERE kind='config' ORDER BY sequence") }
        XCTAssertEqual(queued.map { $0["id"] as String }, denials.map { $0.id.uuidString.lowercased() })
        XCTAssertEqual(queued.map { $0["payload"] as Data }, denials.map { $0.configuration.change.payload })
        let reserves = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM input_control") }
        XCTAssertEqual(reserves, (byteCap || count == 4096) ? purposes.count : 0)
        let positions = try await db.read { try Int64.fetchAll($0, sql: "SELECT source_sequence FROM input_origin ORDER BY source_sequence") }
        XCTAssertEqual(positions, denials.map(\.position.sequence))
        if byteCap || count == 4096 {
            do { try await inputs.enqueue(config(false, coefficient: 9).change); XCTFail("ordinary config consumed the denial reserve") }
            catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .storageLimit) }
        }
        state.setReady(true); await inputs.reconcile()?.value
        XCTAssertEqual(state.sent().map(\.id), [first.id.uuidString.lowercased()])
        try await inputs.waitForRetirement(); reopened.retire()
        let afterPartial = try await db.read { try Row.fetchAll($0, sql: "SELECT * FROM input_change WHERE kind='context' ORDER BY sequence") }
        XCTAssertEqual(afterPartial, original)

        let successorConsent = ScoringContextConsent(layout: layout); await successorConsent.load()
        let successor = try coordinator(successorConsent, stopAfterFirst: false)
        state.setReady(true)
        for _ in 0..<3 { await successor.reconcile()?.value }
        XCTAssertEqual(state.sent().map(\.id), denials.map { $0.id.uuidString.lowercased() })
        XCTAssertEqual(state.sent().map(\.change), denials.map(\.configuration.change))
        XCTAssertEqual(state.sent().map(\.clientRevision), queued.map { $0["sequence"] as Int64 })
        XCTAssertTrue(held.allSatisfy { !successorConsent.gate.allows($0) })
        let final = try await db.read { try Row.fetchAll($0, sql: "SELECT * FROM input_change ORDER BY sequence") }
        XCTAssertEqual(final, original, "every held byte, ID, sequence, revision and retry flag survives")
        let remaining = try await store.pendingIntents()
        XCTAssertTrue(remaining.isEmpty)
        let debt = try await db.read { try Int.fetchOne($0, sql: "SELECT (SELECT COUNT(*) FROM input_control)+(SELECT COUNT(*) FROM input_origin)") }
        XCTAssertEqual(debt, 0, "only the exact accepted receipt handshake frees the control slots")
        try await successor.waitForRetirement(); successorConsent.retire()
    }

    func testAllHeld4096RowsAdmitAllFourImmutableDenialsAcrossPartialReopen() async throws {
        try await heldCapacity(count: 4096)
    }
    func testAllHeld16MiBAdmitAllFourImmutableDenialsAcrossPartialReopen() async throws {
        try await heldCapacity(count: 256, byteCap: true)
    }
    func test4095HeldRowControlStillSettlesSameDenialWithoutReserve() async throws {
        try await heldCapacity(count: 4095, allPurposes: false)
    }

    func testControlReserveIsBoundedUntilExactReceiptRetirementCommits() async throws {
        let layout = try fixture(), fence = StoreWriteFence()
        let store = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        let journal = try ScoringInputJournal(layout: layout, fence: fence)
        addTeardownBlock { try await journal.close() }
        let grant = ScoringContextDecision(purpose: .journal, id: UUID(), enabled: true, decidedAt: Date())
        _ = try await seedHeld(layout, decision: grant, count: 4096)
        let oversized = try ScoringInputChange(device: device, kind: .config, entity: "primary", effectiveDay: "2026-09-18",
            payload: Data(("{\"padding\":\"" + String(repeating: "/", count: 40_000) + "\"}").utf8))
        XCTAssertGreaterThan(oversized.payload.count, 65536, "canonical JSON escaping expands the input bytes")
        do {
            _ = try await journal.importOrigin(UUID(), change: oversized,
                position: .init(source: store.sourceID, sequence: 1), denialPurpose: .journal)
            XCTFail("control reserve exceeded its canonical payload bound")
        } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .storageLimit) }
        for purpose in ScoringContextPurpose.allCases { _ = try await store.set(purpose, enabled: false, configuration: config(false)) }
        let originals = try await store.pendingIntents()
        for intent in originals {
            _ = try await journal.importOrigin(intent.id, change: intent.configuration.change,
                position: intent.position, denialPurpose: intent.denialPurpose)
        }
        _ = try await store.set(.journal, enabled: false, configuration: config(false, coefficient: 2))
        _ = try await store.set(.cycle, enabled: true, configuration: config(true))
        let pending = try await store.pendingIntents(), extra = try XCTUnwrap(pending.dropFirst(4).first), enable = try XCTUnwrap(pending.last)
        XCTAssertNil(enable.denialPurpose)
        for refused in [extra, enable] {
            do {
                _ = try await journal.importOrigin(refused.id, change: refused.configuration.change,
                    position: refused.position, denialPurpose: refused.denialPurpose)
                XCTFail("full reserve accepted another denial or a grant")
            } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .storageLimit) }
        }
        let first = try XCTUnwrap(originals.first)
        let value = try await journal.next(allowing: { $0.kind == .config }), sent = try XCTUnwrap(value)
        XCTAssertEqual(sent.id, first.id.uuidString.lowercased())
        let receipt = ScoringInputJournalTests.receipt(sent, revision: 7)
        try await journal.settle(sent, receipt: receipt)
        try await store.recordProgress(.accepted(receipt), for: first)
        // Settlement does not free the reserve before consent has durably copied the receipt.
        do {
            _ = try await journal.importOrigin(extra.id, change: extra.configuration.change,
                position: extra.position, denialPurpose: extra.denialPurpose)
            XCTFail("accepted-but-unretired origin freed its control slot")
        } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .storageLimit) }
        do {
            try await journal.retireOrigin(first.id, change: first.configuration.change, position: first.position,
                receipt: receipt, beforeCommit: { fence.invalidate() })
            XCTFail("retired transaction released the reserve")
        } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retired) }
        try await journal.close()
        let recovered = try ScoringInputJournal(layout: layout)
        addTeardownBlock { try await recovered.close() }
        let db = try database(layout, consent: false)
        defer { try? db.close() }
        let controls = try await db.read { try String.fetchAll($0, sql: "SELECT origin_id FROM input_control ORDER BY purpose") }
        XCTAssertEqual(Set(controls), Set(originals.map { $0.id.uuidString.lowercased() }))
        let saved = try await recovered.originProgress(first.id)
        XCTAssertEqual(saved, .accepted(receipt))
        try await recovered.retireOrigin(first.id, change: first.configuration.change, position: first.position, receipt: receipt)
        // Crash gap before consent retirement remains replay-safe and cannot regenerate IDs.
        try await recovered.retireOrigin(first.id, change: first.configuration.change, position: first.position, receipt: receipt)
        try await store.finishRetirement(first, receipt: receipt)
        _ = try await recovered.importOrigin(extra.id, change: extra.configuration.change,
            position: extra.position, denialPurpose: extra.denialPurpose)
        do {
            _ = try await recovered.importOrigin(first.id, change: first.configuration.change,
                position: first.position, denialPurpose: first.denialPurpose)
            XCTFail("retired denial resurrected")
        } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retiredOrigin) }
        let after = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM input_control") }
        let held = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM input_change WHERE kind='context'") }
        XCTAssertEqual(after, 4); XCTAssertEqual(held, 4096)
        let later = try await recovered.next(allowing: { $0.kind == .config })
        XCTAssertEqual(later?.id, originals[1].id.uuidString.lowercased(), "reserve never jumps earlier same-entity debt")
        let conflicted = try XCTUnwrap(later)
        try await recovered.retry(conflicted, conflict: true)
        let reviewValue = try await recovered.conflict(id: conflicted.id), review = try XCTUnwrap(reviewValue)
        let beforeReview = try await db.read { try Row.fetchAll($0, sql: "SELECT * FROM input_change ORDER BY sequence") }
        do {
            _ = try await recovered.resolveConflict(review,
                head: ScoringInputJournalTests.head(conflicted.change, scope: try XCTUnwrap(layout.scope), revision: 10),
                replacement: config(false, coefficient: 9).change)
            XCTFail("ordinary reviewed replacement borrowed a control reservation")
        } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .storageLimit) }
        let afterReview = try await db.read { try Row.fetchAll($0, sql: "SELECT * FROM input_change ORDER BY sequence") }
        XCTAssertEqual(afterReview, beforeReview, "failed replacement must roll back archival and deletion")
        let archived = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM input_resolution") }
        XCTAssertEqual(archived, 0)
    }

    func testReservedDenialCannotBypassConfigConflictButOtherDeviceCanProgress() async throws {
        let layout = try fixture(), store = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        let journal = try ScoringInputJournal(layout: layout)
        addTeardownBlock { try await journal.close() }
        _ = try await journal.enqueue(config(true).change)
        let value = try await journal.next(), conflict = try XCTUnwrap(value)
        try await journal.retry(conflict, conflict: true)
        let grant = ScoringContextDecision(purpose: .journal, id: UUID(), enabled: true, decidedAt: Date())
        let held = try await seedHeld(layout, decision: grant, count: 4095)
        _ = try await store.set(.journal, enabled: false, configuration: config(false))
        let remote = try ScoringInputChange(device: "cccccccc-cccc-cccc-cccc-cccccccccccc", kind: .config,
            entity: "primary", effectiveDay: "2026-09-18", payload: config(false).change.payload)
        _ = try await store.set(.cycle, enabled: false, configuration: .init(change: remote, timezone: "UTC"))
        let denials = try await store.pendingIntents()
        let consent = ScoringContextConsent(layout: layout); await consent.load()
        let state = ScoringInputTestState(); state.setReady(true)
        let inputs = ScoringInputCoordinator(context: .init(scope: try XCTUnwrap(layout.scope), generation: UUID()), layout: layout,
            dependencies: .init(isCurrent: { _ in true }, canUpload: { state.ready() }, head: {
                ScoringInputJournalTests.head($0, scope: $1.scope, revision: 20)
            }, send: { pending, _ in
                state.record(pending)
                return ScoringInputJournalTests.receipt(pending, revision: pending.expectedRevision + 1)
            }, allowsChange: { [gate = consent.gate] in gate.allows($0) }))
        connect(consent, inputs)
        let db = try database(layout, consent: false)
        defer { try? db.close() }
        let original = try await db.read { try Row.fetchAll($0, sql: "SELECT * FROM input_change ORDER BY sequence") }
        for _ in 0..<3 { await inputs.reconcile()?.value }
        XCTAssertEqual(state.sent().map(\.id), [denials[1].id.uuidString.lowercased()])
        XCTAssertEqual(state.sent().first?.expectedRevision, 20)
        let preserved = try await db.read { try Row.fetchAll($0, sql: "SELECT * FROM input_change WHERE id!=? ORDER BY sequence",
            arguments: [denials[0].id.uuidString.lowercased()]) }
        XCTAssertEqual(preserved, original)
        XCTAssertTrue(held.allSatisfy { !consent.gate.allows($0) })
        let blocked = try await db.read { try Row.fetchOne($0, sql: "SELECT * FROM input_change WHERE id=?",
            arguments: [denials[0].id.uuidString.lowercased()]) }
        XCTAssertNotNil(blocked); XCTAssertNil(blocked?["expected_revision"] as Int64?)
        let remaining = try await db.read { try String.fetchAll($0, sql: "SELECT origin_id FROM input_control") }
        XCTAssertEqual(remaining, [denials[0].id.uuidString.lowercased()])
        try await inputs.waitForRetirement(); consent.retire()
    }

    func testAcceptedOriginCapCannotConsumeAnyOfTheFourControlReservations() async throws {
        let layout = try fixture(), store = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        let journal = try ScoringInputJournal(layout: layout)
        addTeardownBlock { try await journal.close() }
        let db = try database(layout, consent: false), scope = try XCTUnwrap(layout.scope), change = try config(true).change
        defer { try? db.close() }
        // Legacy accepted origins have no source position. They remain immutable evidence;
        // a new denial must not need to delete or claim these unrelated historical receipts.
        try await db.write { db in
            for index in 1...4096 {
                let id = UUID()
                let receipt = ScoringInputReceipt(schemaVersion: 1, userId: UUID(uuidString: scope.userID)!,
                    sourceDeviceId: UUID(uuidString: change.device)!, kind: .config, entity: "primary", revision: Int64(index),
                    clientId: journal.clientID, clientMutationId: id, clientRevision: Int64(index),
                    effectiveDay: change.effectiveDay, deleted: false, invalidatedFrom: change.effectiveDay)
                try db.execute(sql: "INSERT INTO input_origin(origin_id,mutation_id,device,kind,entity,day,digest,receipt) VALUES(?,?,?,'config','primary',?,?,?)",
                    arguments: [id.uuidString.lowercased(), id.uuidString.lowercased(), change.device, change.effectiveDay,
                        change.digest, try JSONEncoder().encode(receipt)])
            }
        }
        let original = try await db.read { try Row.fetchAll($0, sql: "SELECT * FROM input_origin ORDER BY origin_id") }
        for purpose in ScoringContextPurpose.allCases { _ = try await store.set(purpose, enabled: false, configuration: config(false)) }
        let denials = try await store.pendingIntents()
        let consent = ScoringContextConsent(layout: layout); await consent.load()
        let inputs = try offline(layout); connect(consent, inputs)
        try await consent.relay(to: inputs)
        let reserved = try await db.read { try String.fetchAll($0, sql: "SELECT origin_id FROM input_control") }
        XCTAssertEqual(Set(reserved), Set(denials.map { $0.id.uuidString.lowercased() }))
        // The reserve also cannot shrink or lend out ordinary count/byte capacity.
        _ = try await journal.enqueue(ScoringInputChange(device: device, kind: .profile, entity: "primary",
            effectiveDay: "2026-09-18", payload: Data("{\"age\":30}".utf8)))
        try await inputs.waitForRetirement(); consent.retire()
        try await journal.close()
        let reopened = try ScoringInputJournal(layout: layout)
        addTeardownBlock { try await reopened.close() }
        for intent in denials {
            let value = try await reopened.next(allowing: { $0.kind == .config }), pending = try XCTUnwrap(value)
            XCTAssertEqual(pending.id, intent.id.uuidString.lowercased())
            let receipt = ScoringInputJournalTests.receipt(pending, revision: pending.expectedRevision + 1)
            try await reopened.settle(pending, receipt: receipt)
            try await store.recordProgress(.accepted(receipt), for: intent)
            try await reopened.retireOrigin(intent.id, change: intent.configuration.change, position: intent.position, receipt: receipt)
            try await store.finishRetirement(intent, receipt: receipt)
        }
        let final = try await db.read { try Row.fetchAll($0, sql: "SELECT * FROM input_origin ORDER BY origin_id") }
        XCTAssertEqual(final, original)
        let controls = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM input_control") }
        XCTAssertEqual(controls, 0)
    }
}
