import Foundation
import GRDB
import NoopPush
import WhoopStore
import XCTest
@testable import Strand

@MainActor
final class ScoringContextConsentTests: XCTestCase {
    private let device = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private func layout(_ root: URL, user: String = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                        project: String = "https://consent.invalid") throws -> AccountStorageLayout {
        .init(baseDirectory: root, scope: try AccountScope(projectURL: project, userID: user))
    }
    private func change(_ decision: ScoringContextDecision) throws -> ScoringInputChange {
        try ScoringContextInput.context(device: device, day: "2026-09-18", timezone: "UTC",
            flags: .init(alcohol: false, stress: nil, sauna: nil, hardOrLateWorkout: true,
                         travelPhaseJump: nil, alreadyUnwell: nil), decision: decision)
    }

    func testConsentIsDefaultOffDurableAndAccountProjectIsolated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = ScoringContextConsent(layout: try layout(root))
        await a.load()
        XCTAssertTrue(a.loaded)
        XCTAssertFalse(a.enabled(.journal)); XCTAssertFalse(a.enabled(.cycle))
        await a.setEnabled(true, purpose: .journal)
        let decision = try XCTUnwrap(a.decisions[.journal])
        let input = try change(decision)
        XCTAssertTrue(a.gate.allows(input))
        a.retire()
        XCTAssertFalse(a.gate.allows(input))
        let reopened = ScoringContextConsent(layout: try layout(root))
        await reopened.load()
        XCTAssertEqual(reopened.decisions[.journal], decision)
        XCTAssertTrue(reopened.gate.allows(input))
        let b = ScoringContextConsent(layout: try layout(root, user: device))
        let anotherProject = ScoringContextConsent(layout: try layout(root, project: "https://other.invalid"))
        await b.load(); await anotherProject.load()
        XCTAssertFalse(b.gate.allows(input)); XCTAssertFalse(anotherProject.gate.allows(input))
        reopened.retire(); b.retire(); anotherProject.retire()
    }

    func testRevocationAndNewDecisionDoNotReleasePreviouslyQueuedSensitiveInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let consent = ScoringContextConsent(layout: try layout(root))
        await consent.load(); await consent.setEnabled(true, purpose: .journal)
        let old = try change(XCTUnwrap(consent.decisions[.journal]))
        await consent.setEnabled(false, purpose: .journal)
        XCTAssertFalse(consent.gate.allows(old))
        await consent.setEnabled(true, purpose: .journal)
        let renewed = try change(XCTUnwrap(consent.decisions[.journal]))
        XCTAssertFalse(consent.gate.allows(old))
        XCTAssertTrue(consent.gate.allows(renewed))
        XCTAssertNotEqual(old.payload, renewed.payload)
        consent.retire()
    }

    func testRevokedSQLiteCommitCannotPersistOverSuccessorDecision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let captured = try layout(root)
        let fence = StoreWriteFence()
        let old = try ScoringContextConsentStore(layout: captured, fence: fence)
        _ = try await old.set(.cycle, enabled: false)
        do {
            _ = try await old.set(.cycle, enabled: true, beforeCommit: { fence.invalidate() })
            XCTFail("revocation must roll back the real SQLite transaction")
        } catch {}
        let successor = try ScoringContextConsentStore(layout: captured, fence: StoreWriteFence())
        let values = try await successor.read()
        XCTAssertEqual(values[.cycle]?.enabled, false)
        let saved = try await successor.set(.cycle, enabled: true)
        do { _ = try await old.set(.cycle, enabled: false); XCTFail("retired writer accepted a change") } catch {}
        let current = try await successor.read()
        XCTAssertEqual(current[.cycle], saved)
    }

    func testFailedRevocationRemainsPausedAcrossReloadAndOtherPurposeWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let captured = try layout(root)
        let consent = ScoringContextConsent(layout: captured)
        await consent.load(); await consent.setEnabled(true, purpose: .journal)
        let old = try change(XCTUnwrap(consent.decisions[.journal]))
        XCTAssertTrue(consent.gate.allows(old))
        let db = try DatabaseQueue(path: captured.directory.appendingPathComponent("scoring-context-consent.sqlite").path)
        try await db.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_revocation BEFORE UPDATE ON consent_decision
                WHEN NEW.purpose='journal_context' AND NEW.enabled=0
                BEGIN SELECT RAISE(ABORT,'injected consent write failure'); END;
                """)
        }
        await consent.setEnabled(false, purpose: .journal)
        XCTAssertNotNil(consent.error)
        XCTAssertFalse(consent.enabled(.journal)); XCTAssertFalse(consent.gate.allows(old))
        await consent.load()
        XCTAssertNotNil(consent.error)
        XCTAssertFalse(consent.enabled(.journal)); XCTAssertFalse(consent.gate.allows(old))
        await consent.setEnabled(true, purpose: .cycle)
        XCTAssertTrue(consent.enabled(.cycle))
        XCTAssertNotNil(consent.error)
        XCTAssertFalse(consent.enabled(.journal)); XCTAssertFalse(consent.gate.allows(old))
        let saved = try await db.read { try Bool.fetchOne($0, sql: "SELECT enabled FROM consent_decision WHERE purpose='journal_context'") }
        XCTAssertEqual(saved, true, "the actual failed transaction retained the prior durable grant")
        let beforeRetry = ScoringContextConsent(layout: captured)
        await beforeRetry.load()
        XCTAssertNotNil(beforeRetry.error)
        XCTAssertFalse(beforeRetry.enabled(.journal))
        XCTAssertFalse(beforeRetry.gate.allows(old), "the durable barrier must survive a new runtime before retry")
        XCTAssertTrue(beforeRetry.enabled(.cycle))
        beforeRetry.retire()
        try await db.write { try $0.execute(sql: "DROP TRIGGER reject_revocation") }
        await consent.setEnabled(false, purpose: .journal)
        XCTAssertNil(consent.error)
        await consent.load()
        XCTAssertFalse(consent.enabled(.journal)); XCTAssertFalse(consent.gate.allows(old))
        consent.retire()
        let reopened = ScoringContextConsent(layout: captured)
        await reopened.load()
        XCTAssertFalse(reopened.enabled(.journal)); XCTAssertTrue(reopened.enabled(.cycle))
        reopened.retire()
    }

    func testUnknownFlagsStayNullAndNoNotesOrLocalOnlyValuesAreExported() throws {
        let decision = ScoringContextDecision(purpose: .journal, id: UUID(), enabled: true, decidedAt: Date())
        let input = try change(decision)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: input.payload) as? [String: Any])
        let flags = try XCTUnwrap(body["flags"] as? [String: Any])
        XCTAssertEqual(flags.count, 6)
        XCTAssertEqual(flags["alcohol"] as? Bool, false)
        XCTAssertEqual(flags["hardOrLateWorkout"] as? Bool, true)
        XCTAssertTrue(flags["alreadyUnwell"] is NSNull)
        XCTAssertEqual(Set(body.keys), ["schemaVersion", "day", "timezone", "flags", "consent"])
        XCTAssertThrowsError(try ScoringContextInput.periodStart(device: device, day: "2026-09-18",
            timezone: "UTC", eventID: UUID(), decision: decision))
    }

    func testWrongOwnerDatabaseFailsClosedWithoutRebinding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let captured = try layout(root)
        try captured.prepare()
        let db = try DatabaseQueue(path: captured.directory.appendingPathComponent("scoring-context-consent.sqlite").path)
        try await db.write { database in
            try database.execute(sql: """
                CREATE TABLE consent_owner(singleton INTEGER PRIMARY KEY,project TEXT,user TEXT);
                CREATE TABLE consent_decision(purpose TEXT PRIMARY KEY,decision_id TEXT,enabled INTEGER,decided_at REAL);
                INSERT INTO consent_owner VALUES(1,'https://consent.invalid','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
                """)
        }
        let consent = ScoringContextConsent(layout: captured)
        await consent.load()
        XCTAssertFalse(consent.loaded)
        XCTAssertNotNil(consent.error)
        XCTAssertFalse(consent.enabled(.cycle))
        let owner = try await db.read { try String.fetchOne($0, sql: "SELECT user FROM consent_owner") }
        XCTAssertEqual(owner, device)
    }

    func testConsentCannotBeForgedByOtherPurposeIDOrBooleanVersion() throws {
        let gate = ScoringConsentGate()
        let decision = ScoringContextDecision(purpose: .journal, id: UUID(), enabled: true, decidedAt: Date())
        gate.replace([.journal: decision])
        let original = try change(decision)
        XCTAssertTrue(gate.allows(original))
        let variants: [[String: Any]] = [
            ["purpose": "cycle_context", "decisionId": decision.id.uuidString, "policyVersion": 1],
            ["purpose": "journal_context", "decisionId": UUID().uuidString, "policyVersion": 1],
            ["purpose": "journal_context", "decisionId": decision.id.uuidString, "policyVersion": true],
            ["purpose": "journal_context", "decisionId": decision.id.uuidString, "policyVersion": 1.5]
        ]
        for consent in variants {
            var body = try XCTUnwrap(JSONSerialization.jsonObject(with: original.payload) as? [String: Any])
            body["consent"] = consent
            let forged = try ScoringInputChange(device: original.device, kind: original.kind, entity: original.entity,
                effectiveDay: original.effectiveDay, payload: JSONSerialization.data(withJSONObject: body))
            XCTAssertFalse(gate.allows(forged))
        }
    }
}
