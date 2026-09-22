import Foundation
import GRDB
import XCTest
@testable import WhoopStore

final class ServerComputeOutboxTests: XCTestCase {
    private let owner = "00000000-0000-4000-8000-000000000001"
    private let device = "00000000-0000-4000-8000-000000000002"
    private let source = "00000000-0000-4000-8000-000000000003"
    private var scope: ServerComputeOutbox.Scope { .init(project: "https://fixture.invalid", owner: owner, source: source, device: device) }
    private var draft: ServerComputeOutbox.DraftScope { .init(project: scope.project, owner: owner, source: source, localDevice: "whoop-local") }
    private func request(id: UUID = UUID(), session: UUID = UUID(), revision: Int64 = 7) -> ServerComputeRequest {
        .init(id: id, family: "spot_hrv", sessionID: session, start: Date(timeIntervalSince1970: 1793520000),
            end: Date(timeIntervalSince1970: 1793520060), timezone: TimeZone(identifier: "America/Los_Angeles")!, inputRevision: revision, consent: true)
    }
    private func result(_ request: ServerComputeRequest, status: String = "unqualified", value: Any = NSNull(),
                        expires: String? = nil, freshness: String = "current") throws -> ServerCanonicalFamilyResult {
        var raw: [String: Any] = ["owner": "server", "project": scope.project, "owner_id": owner,
            "source_id": source, "device_id": device, "window": request.sessionID,
            "metrics": Array(ServerCanonicalResults.familyMetrics[request.family]!), "status": status,
            "result_revision": "session:123", "input_revision": request.inputRevision,
            "algorithm_version": status == "available" ? "frwhoop-server-1" : "vps-only-1",
            "canonical_qualification": status == "available" ? "retained_legacy" : NSNull(),
            "manifest_hash": status == "available" ? String(repeating: "a", count: 64) : NSNull(),
            "configuration_version": "vps-only-1", "computed_at": "2026-09-21T10:00:00Z",
            "timezone_id": request.timezoneID, "freshness": freshness,
            "values": Dictionary(uniqueKeysWithValues: ServerCanonicalResults.familyMetrics[request.family]!.map { ($0, value) }), "details": [:]]
        if let expires { raw["expires_at"] = expires; raw["decision_id"] = "decision-1" }
        return try JSONDecoder().decode(ServerCanonicalFamilyResult.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    func testOfflineDraftSurvivesReopenAndBindsOnlyItsOwnerSourceDevice() throws {
        let db = try DatabaseQueue(), request = request()
        try ServerComputeOutbox.saveDraft(request, scope: draft, db: db)
        try ServerComputeOutbox.saveDraft(request, scope: draft, db: db)
        let other = try ServerComputeOutbox(db: db, scope: .init(project: scope.project, owner: UUID().uuidString, source: source, device: device))
        XCTAssertThrowsError(try other.bindDrafts(draft))
        XCTAssertTrue(try other.pending().isEmpty)
        let resumed = try ServerComputeOutbox(db: db, scope: scope)
        try resumed.bindDrafts(draft); try resumed.bindDrafts(draft)
        XCTAssertEqual(try resumed.pending().map(\.request), [request])
        XCTAssertEqual(try resumed.pending().first?.request.timezoneID, "America/Los_Angeles")
    }

    func testRetriesAreImmutableAndInputEditsCreateDistinctRequests() throws {
        let db = try DatabaseQueue(), outbox = try ServerComputeOutbox(db: db, scope: scope)
        let id = UUID(), session = UUID(), original = request(id: id, session: session)
        _ = try outbox.enqueue(original, localDevice: "whoop-local")
        _ = try outbox.enqueue(original, localDevice: "whoop-local")
        XCTAssertThrowsError(try outbox.enqueue(request(id: id, session: session, revision: 8), localDevice: "whoop-local"))
        _ = try outbox.enqueue(request(session: session, revision: 8), localDevice: "whoop-local")
        XCTAssertEqual(try outbox.pending().count, 2)
    }

    func testMissingDispositionPersistsWithoutNumericFallback() throws {
        let db = try DatabaseQueue(), outbox = try ServerComputeOutbox(db: db, scope: scope), request = request()
        let item = try outbox.enqueue(request, localDevice: "whoop-local"), missing = try result(request)
        try outbox.accept(missing, for: item); try outbox.accept(missing, for: item)
        XCTAssertTrue(try outbox.pending().isEmpty)
        XCTAssertEqual(try outbox.results()[request.id]?.resultRevision, "session:123")
        XCTAssertTrue(try outbox.results()[request.id]!.metrics.allSatisfy { missing.number($0) == nil })
        XCTAssertThrowsError(try outbox.accept(result(request, status: "unqualified", value: 22), for: item))
    }

    func testDelayedAndDuplicatedDecisionsCannotReplay() throws {
        let db = try DatabaseQueue(), outbox = try ServerComputeOutbox(db: db, scope: scope), request = request()
        let decision = try result(request, status: "available", value: 0, expires: "2026-09-21T10:01:00Z")
        let clock = ISO8601DateFormatter()
        XCTAssertFalse(try outbox.consumeDecision(decision, now: clock.date(from: "2026-09-21T09:59:59Z")!))
        XCTAssertTrue(try outbox.consumeDecision(decision, now: clock.date(from: "2026-09-21T10:00:30Z")!))
        XCTAssertFalse(try outbox.consumeDecision(decision, now: clock.date(from: "2026-09-21T10:00:31Z")!))
        XCTAssertFalse(try outbox.consumeDecision(decision, now: clock.date(from: "2026-09-21T10:01:00Z")!))
    }

    func testDecisionFreshnessIsValidatedAndCannotReplayUnavailableOrExpiredValue() throws {
        let db = try DatabaseQueue(), outbox = try ServerComputeOutbox(db: db, scope: scope), request = request()
        let item = try outbox.enqueue(request, localDevice: "whoop-local")
        let clock = ISO8601DateFormatter(), now = clock.date(from: "2026-09-21T10:00:30Z")!
        for freshness in ["expired", "unavailable"] {
            let decision = try result(request, status: "available", value: 0,
                expires: "2026-09-21T10:01:00Z", freshness: freshness)
            XCTAssertFalse(try outbox.consumeDecision(decision, now: now), freshness)
        }

        let invalid = try result(request, status: "available", value: 0,
            expires: "2026-09-21T10:01:00Z", freshness: "future")
        XCTAssertThrowsError(try outbox.accept(invalid, for: item))
    }
}
