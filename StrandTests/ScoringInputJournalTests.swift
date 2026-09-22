import Foundation
import GRDB
import NoopPush
import WhoopStore
import XCTest
#if !SCORING_INPUT_NATIVE_TESTS
@testable import Strand
#endif

final class ScoringInputJournalTests: XCTestCase {
    static func head(_ change: ScoringInputChange, scope: AccountScope, revision: Int64 = 0) -> ScoringInputHead {
        .init(schemaVersion: 1, userId: UUID(uuidString: scope.userID)!, sourceDeviceId: UUID(uuidString: change.device)!,
              kind: change.kind, entity: change.entity, headRevision: revision)
    }
    static func receipt(_ pending: ScoringInputJournal.Pending, revision: Int64 = 1) -> ScoringInputReceipt {
        .init(schemaVersion: 1, userId: UUID(uuidString: pending.scope.userID)!,
              sourceDeviceId: UUID(uuidString: pending.change.device)!, kind: pending.change.kind,
              entity: pending.change.entity, revision: revision, clientId: pending.clientID,
              clientMutationId: UUID(uuidString: pending.id)!, clientRevision: pending.clientRevision,
              effectiveDay: pending.change.effectiveDay, deleted: pending.change.deleted, invalidatedFrom: pending.change.effectiveDay)
    }
    private func layout(_ root: URL, user: String = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa") throws -> AccountStorageLayout {
        AccountStorageLayout(baseDirectory: root,
            scope: try AccountScope(projectURL: "https://input-fixture.invalid", userID: user))
    }
    private func change(_ value: Int, kind: ScoringInputChange.Kind = .profile) throws -> ScoringInputChange {
        try ScoringInputChange(device: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", kind: kind,
            entity: "primary", effectiveDay: "2026-09-18", payload: Data("{\"value\":\(value)}".utf8))
    }

    func testConsentRecheckedInsideAdmissionTransactionImmediatelyBeforeInsert() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ScoringInputJournal(layout: layout(root))
        let consent = ScoringInputTestState()
        consent.setReady(true)
        do {
            _ = try await journal.enqueue(change(1, kind: .context), allowing: { _ in
                let allowed = consent.ready()
                consent.setReady(false)
                return allowed
            })
            XCTFail("consent revoked during SQL preparation still inserted")
        } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .held) }
        let status = try await journal.status()
        XCTAssertEqual(status, .init(pending: 0, conflicts: 0))
        _ = try await journal.enqueue(change(2))
        let pending = try await journal.next()
        XCTAssertEqual(pending?.change, try change(2))
    }

    func testRevokedFenceRollsBackReceiptHeadAndDebtDeletionAtomically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = try layout(root)
        let fence = StoreWriteFence()
        let journal = try ScoringInputJournal(layout: location, fence: fence)
        _ = try await journal.enqueue(change(1))
        let loaded = try await journal.next()
        let pending = try XCTUnwrap(loaded)
        let receipt = Self.receipt(pending, revision: 17)
        do {
            try await journal.settle(pending, receipt: receipt, beforeCommit: { fence.invalidate() })
            XCTFail("receipt transaction committed after revocation")
        } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retired) }
        let inspector = try DatabaseQueue(path: location.directory.appendingPathComponent("history-inputs.sqlite").path)
        let heads = try await inspector.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM input_head") }
        XCTAssertEqual(heads, 0, "uncommitted receipt cannot advance local head")
        let reopened = try ScoringInputJournal(layout: location)
        let retained = try await reopened.next()
        XCTAssertEqual(retained, pending, "rollback preserves the exact durable intent for retry")
        try await reopened.settle(pending, receipt: receipt)
        let settled = try await reopened.status()
        XCTAssertEqual(settled, .init(pending: 0, conflicts: 0))
        let saved = try await inspector.read { try Data.fetchOne($0, sql: "SELECT receipt FROM input_head") }
        XCTAssertEqual(try JSONDecoder().decode(ScoringInputReceipt.self, from: XCTUnwrap(saved)), receipt)
    }

    func testLostResponseRetriesExactRevisionAndReopenRetainsFollowingEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = try layout(root)
        let first = try ScoringInputJournal(layout: location)
        _ = try await first.enqueue(change(1))
        _ = try await first.enqueue(change(2))
        let sent = try await first.next()
        XCTAssertEqual(sent?.expectedRevision, 0)
        await first.retire() // server may have committed; no local response was recorded
        let reopened = try ScoringInputJournal(layout: location)
        let replay = try await reopened.next()
        XCTAssertEqual(replay, sent)
        try await reopened.settle(XCTUnwrap(replay), receipt: Self.receipt(XCTUnwrap(replay)))
        let second = try await reopened.next()
        XCTAssertEqual(second?.expectedRevision, 1)
        XCTAssertEqual(second?.change.payload, try change(2).payload)
        try await reopened.settle(XCTUnwrap(second), receipt: Self.receipt(XCTUnwrap(second), revision: 2))
        let status = try await reopened.status()
        XCTAssertEqual(status.pending, 0)
        let duplicate = try await reopened.enqueue(change(2))
        XCTAssertNil(duplicate)
    }

    func testConflictRetainsEditsAndDoesNotBlockUnrelatedEntity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ScoringInputJournal(layout: layout(root))
        _ = try await journal.enqueue(change(1))
        _ = try await journal.enqueue(change(2))
        _ = try await journal.enqueue(change(3, kind: .config))
        let pending = try await journal.next()
        try await journal.retry(XCTUnwrap(pending), conflict: true)
        let next = try await journal.next()
        XCTAssertEqual(next?.change.kind, .config)
        let status = try await journal.status()
        XCTAssertEqual(status, .init(pending: 3, conflicts: 1))
        XCTAssertEqual(pending?.expectedRevision, 0)
    }

    func testRetirementFencesAdmissionAndLateReceiptWithoutDeletingDebt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ScoringInputJournal(layout: layout(root))
        _ = try await journal.enqueue(change(1))
        let next = try await journal.next()
        await journal.retire()
        do { try await journal.settle(XCTUnwrap(next), receipt: Self.receipt(XCTUnwrap(next))); XCTFail("retired receipt settled") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retired) }
        do { _ = try await journal.enqueue(change(2)); XCTFail("retired edit admitted") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retired) }
        let status = try await journal.status()
        XCTAssertEqual(status.pending, 1)
    }

    func testCopiedJournalCannotBeAdoptedByAnotherAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try layout(root)
        let b = try layout(root, user: "cccccccc-cccc-cccc-cccc-cccccccccccc")
        let journal = try ScoringInputJournal(layout: a)
        _ = try await journal.enqueue(change(1))
        let path = a.directory.appendingPathComponent("history-inputs.sqlite")
        let inspector = try DatabaseQueue(path: path.path)
        try await inspector.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        try b.prepare()
        try FileManager.default.copyItem(at: path, to: b.directory.appendingPathComponent("history-inputs.sqlite"))
        do { _ = try ScoringInputJournal(layout: b); XCTFail("copied data changed owners") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .wrongOwner) }
        let pending = try await journal.status()
        XCTAssertEqual(pending.pending, 1)
    }

    func testAdditiveUpgradePreservesMutationExpectedRevisionAndSequence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = try layout(root)
        try location.prepare()
        let old = try DatabaseQueue(path: location.directory.appendingPathComponent("history-inputs.sqlite").path)
        let change = try change(1)
        let mutation = UUID().uuidString.lowercased()
        try await old.write { db in
            try db.execute(sql: """
                CREATE TABLE input_owner(singleton INTEGER PRIMARY KEY CHECK(singleton=1), project TEXT NOT NULL, user TEXT NOT NULL);
                CREATE TABLE input_head(device TEXT NOT NULL,kind TEXT NOT NULL,entity TEXT NOT NULL,revision INTEGER NOT NULL,digest TEXT NOT NULL,PRIMARY KEY(device,kind,entity));
                CREATE TABLE input_change(sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,device TEXT NOT NULL,
                  kind TEXT NOT NULL,entity TEXT NOT NULL,day TEXT NOT NULL,payload BLOB NOT NULL,deleted INTEGER NOT NULL,digest TEXT NOT NULL,
                  expected_revision INTEGER,failures INTEGER NOT NULL DEFAULT 0,retry_at REAL NOT NULL DEFAULT 0,conflict INTEGER NOT NULL DEFAULT 0);
                """)
            try db.execute(sql: "INSERT INTO input_owner VALUES(1,?,?)", arguments: [location.scope!.projectURL, location.scope!.userID])
            try db.execute(sql: "INSERT INTO input_change(sequence,id,device,kind,entity,day,payload,deleted,digest,expected_revision) VALUES(41,?,?,?,?,?,?,0,?,7)",
                arguments: [mutation, change.device, change.kind.rawValue, change.entity, change.effectiveDay, change.payload, change.digest])
        }
        let upgraded = try ScoringInputJournal(layout: location)
        let loaded = try await upgraded.next()
        let first = try XCTUnwrap(loaded)
        XCTAssertEqual(first.id, mutation)
        XCTAssertEqual(first.clientRevision, 41)
        XCTAssertEqual(first.expectedRevision, 7)
        await upgraded.retire()
        let reopened = try ScoringInputJournal(layout: location)
        let replay = try await reopened.next()
        XCTAssertEqual(replay, first)
        try await reopened.settle(first, receipt: Self.receipt(first, revision: 23))
        _ = try await reopened.enqueue(self.change(2))
        let following = try await reopened.next()
        XCTAssertEqual(following?.clientID, first.clientID)
        XCTAssertEqual(following?.clientRevision, 42)
        XCTAssertEqual(following?.expectedRevision, 23)
    }

    func testEveryReceiptAssociationMustMatchBeforeSettlement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ScoringInputJournal(layout: layout(root))
        _ = try await journal.enqueue(change(1))
        let loaded = try await journal.next()
        let pending = try XCTUnwrap(loaded)
        let valid = Self.receipt(pending)
        let encoded = try JSONEncoder().encode(valid)
        let fields: [String: Any] = ["schemaVersion": 2, "userId": UUID().uuidString,
            "sourceDeviceId": UUID().uuidString, "kind": "config", "entity": "another",
            "revision": 0, "clientId": UUID().uuidString, "clientMutationId": UUID().uuidString,
            "clientRevision": 2, "effectiveDay": "2026-09-19", "deleted": true, "invalidatedFrom": "2026-09-19"]
        for (key, value) in fields {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            json[key] = value
            let receipt = try JSONDecoder().decode(ScoringInputReceipt.self, from: JSONSerialization.data(withJSONObject: json))
            do { try await journal.settle(pending, receipt: receipt); XCTFail("settled mismatched \(key)") }
            catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .invalidReceipt, key) }
        }
        let retained = try await journal.next()
        XCTAssertEqual(retained, pending)
        try await journal.settle(pending, receipt: valid)
        let status = try await journal.status()
        XCTAssertEqual(status.pending, 0)
    }

    func testOwnerAndProjectHaveIndependentDurableClientIdentities() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try ScoringInputJournal(layout: layout(root))
        let b = try ScoringInputJournal(layout: layout(root, user: "cccccccc-cccc-cccc-cccc-cccccccccccc"))
        let otherProject = try ScoringInputJournal(layout: .init(baseDirectory: root,
            scope: .init(projectURL: "https://other-project.invalid", userID: a.scope.userID)))
        XCTAssertNotEqual(a.clientID, b.clientID)
        XCTAssertNotEqual(a.clientID, otherProject.clientID)
        for journal in [a, b, otherProject] { _ = try await journal.enqueue(change(1)) }
        let loaded = try await a.next()
        let pending = try XCTUnwrap(loaded)
        for journal in [b, otherProject] {
            do { try await journal.settle(pending, receipt: Self.receipt(pending)); XCTFail("cross-scope settlement") }
            catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .invalidReceipt) }
            let status = try await journal.status()
            XCTAssertEqual(status.pending, 1)
        }
    }

    func testAdmissionKeepsRootEntityAndDayBounds() throws {
        for day in ["1900-01-01", "2200-12-31"] {
            _ = try ScoringInputChange(device: UUID().uuidString, kind: .context, entity: String(repeating: "x", count: 128),
                effectiveDay: day, payload: Data("{}".utf8))
        }
        for (day, count) in [("1899-12-31", 128), ("2201-01-01", 128), ("2026-09-18", 129)] {
            XCTAssertThrowsError(try ScoringInputChange(device: UUID().uuidString, kind: .context,
                entity: String(repeating: "x", count: count), effectiveDay: day, payload: Data("{}".utf8)))
        }
    }

    func testInitialHeadFreezesOpaqueRevisionOnceAndRejectsWrongOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ScoringInputJournal(layout: layout(root))
        _ = try await journal.enqueue(change(1))
        do { _ = try await journal.next(requireKnownHead: true); XCTFail("unknown head frozen") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .headRequired) }
        let loaded = try await journal.initialHeadRequest()
        let request = try XCTUnwrap(loaded)
        let other = try AccountScope(projectURL: request.scope.projectURL, userID: UUID().uuidString)
        do { try await journal.freezeInitialHead(Self.head(request.change, scope: other, revision: 79), for: request); XCTFail("wrong owner head") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .invalidReceipt) }
        try await journal.freezeInitialHead(Self.head(request.change, scope: request.scope, revision: 79), for: request)
        try await journal.freezeInitialHead(Self.head(request.change, scope: request.scope, revision: 999), for: request)
        let frozen = try await journal.next(requireKnownHead: true)
        XCTAssertEqual(frozen?.expectedRevision, 79)
        await journal.retire()
        let reopened = try ScoringInputJournal(layout: layout(root))
        let retry = try await reopened.next(requireKnownHead: true)
        XCTAssertEqual(retry, frozen)
    }

    func testConsentHoldDoesNotPinAndDoesNotBlockOtherEntities() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = try layout(root)
        let journal = try ScoringInputJournal(layout: location)
        _ = try await journal.enqueue(change(1, kind: .context))
        _ = try await journal.enqueue(change(2, kind: .context))
        _ = try await journal.enqueue(change(3, kind: .config))
        let gate: @Sendable (ScoringInputChange) -> Bool = { $0.kind != .context }
        let loaded = try await journal.initialHeadRequest(allowing: gate)
        let request = try XCTUnwrap(loaded)
        XCTAssertEqual(request.change.kind, .config)
        try await journal.freezeInitialHead(Self.head(request.change, scope: request.scope), for: request, allowing: gate)
        let next = try await journal.next(requireKnownHead: true, allowing: gate)
        try await journal.settle(XCTUnwrap(next), receipt: Self.receipt(XCTUnwrap(next)))
        let blocked = try await journal.next(requireKnownHead: true, allowing: gate)
        XCTAssertNil(blocked)
        let inspector = try DatabaseQueue(path: location.directory.appendingPathComponent("history-inputs.sqlite").path)
        let pinned = try await inspector.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM input_change WHERE expected_revision IS NOT NULL") }
        XCTAssertEqual(pinned, 0)
        let status = try await journal.status()
        XCTAssertEqual(status, .init(pending: 2, conflicts: 0))
    }

    func testSleepEarliestDaySurvivesPendingSettlementAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = try layout(root)
        let journal = try ScoringInputJournal(layout: location)
        func edit(_ day: String, value: Int) throws -> ScoringInputChange {
            try ScoringInputChange(device: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", kind: .sleepEdit,
                entity: "sleep:fixed", effectiveDay: day, payload: Data("{\"value\":\(value)}".utf8))
        }
        _ = try await journal.enqueue(edit("2026-09-16", value: 1))
        _ = try await journal.enqueue(edit("2026-09-18", value: 2))
        for revision in [Int64(11), 29] {
            let loaded = try await journal.next()
            let pending = try XCTUnwrap(loaded)
            XCTAssertEqual(pending.change.effectiveDay, "2026-09-16")
            try await journal.settle(pending, receipt: Self.receipt(pending, revision: revision))
        }
        await journal.retire()
        let reopened = try ScoringInputJournal(layout: location)
        _ = try await reopened.enqueue(edit("2026-09-19", value: 3))
        let loaded = try await reopened.next()
        let frozen = try XCTUnwrap(loaded)
        XCTAssertEqual(frozen.change.effectiveDay, "2026-09-16")
        _ = try await reopened.enqueue(edit("2026-09-15", value: 4))
        let stillFrozen = try await reopened.next()
        XCTAssertEqual(stillFrozen, frozen, "later admissions cannot rewrite a request already frozen")
        try await reopened.settle(frozen, receipt: Self.receipt(frozen, revision: 83))
        let earlier = try await reopened.next()
        XCTAssertEqual(earlier?.change.effectiveDay, "2026-09-15")
    }

    func testOlderReceiptCannotLowerKnownHeadOrDeleteDebt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = try layout(root)
        let journal = try ScoringInputJournal(layout: location)
        _ = try await journal.enqueue(change(1))
        let loaded = try await journal.next()
        let pending = try XCTUnwrap(loaded)
        let inspector = try DatabaseQueue(path: location.directory.appendingPathComponent("history-inputs.sqlite").path)
        try await inspector.write { db in
            try db.execute(sql: "INSERT INTO input_head(device,kind,entity,revision,digest) VALUES(?,?,?,100,'newer')",
                arguments: [pending.change.device, pending.change.kind.rawValue, pending.change.entity])
        }
        do { try await journal.settle(pending, receipt: Self.receipt(pending, revision: 11)); XCTFail("head regressed") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .invalidReceipt) }
        let revision = try await inspector.read { try Int64.fetchOne($0, sql: "SELECT revision FROM input_head") }
        XCTAssertEqual(revision, 100)
        let retained = try await journal.status()
        XCTAssertEqual(retained.pending, 1)
    }

    func testExplicitResolutionRetainsReviewedChainAndRejectsNewArrivalUntilReviewed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = try layout(root)
        let journal = try ScoringInputJournal(layout: location)
        _ = try await journal.enqueue(change(1))
        _ = try await journal.enqueue(change(2))
        let loaded = try await journal.next()
        let original = try XCTUnwrap(loaded)
        try await journal.retry(original, conflict: true)
        let initialReview = try await journal.conflict(id: original.id)
        let stale = try XCTUnwrap(initialReview)
        let head = Self.head(original.change, scope: original.scope, revision: 37)
        _ = try await journal.enqueue(change(3))
        do { _ = try await journal.resolveConflict(stale, head: head, replacement: change(4)); XCTFail("unreviewed edit overwritten") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .staleReview) }
        let reread = try await journal.conflict(id: original.id)
        let review = try XCTUnwrap(reread)
        XCTAssertEqual(review.queuedMutationIDs.count, 3)
        let listed = try await journal.conflicts(limit: 1)
        XCTAssertEqual(listed, [review])
        let replacementID = try await journal.resolveConflict(review, head: head, replacement: change(4))
        XCTAssertFalse(review.queuedMutationIDs.contains(replacementID))
        await journal.retire()
        let reopened = try ScoringInputJournal(layout: location)
        let replacement = try await reopened.next(requireKnownHead: true)
        let next = try XCTUnwrap(replacement)
        XCTAssertEqual(next.id, replacementID)
        XCTAssertEqual(next.clientID, original.clientID)
        XCTAssertGreaterThan(next.clientRevision, 3)
        XCTAssertEqual(next.expectedRevision, 37)
        do { try await reopened.settle(original, receipt: Self.receipt(original)); XCTFail("superseded original receipt settled") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .invalidReceipt) }
        let receipt = Self.receipt(next, revision: 89)
        try await reopened.settle(next, receipt: receipt)
        let inspector = try DatabaseQueue(path: location.directory.appendingPathComponent("history-inputs.sqlite").path)
        let proof = try await inspector.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM input_resolution WHERE settled_revision=89"),
             try Data.fetchOne(db, sql: "SELECT receipt FROM input_head"))
        }
        XCTAssertEqual(proof.0, 3)
        XCTAssertEqual(try JSONDecoder().decode(ScoringInputReceipt.self, from: XCTUnwrap(proof.1)), receipt)
    }
}
