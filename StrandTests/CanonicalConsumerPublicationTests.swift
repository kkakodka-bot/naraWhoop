import XCTest
import WhoopStore
import StrandDesign
@testable import Strand

@MainActor
final class CanonicalConsumerPublicationTests: XCTestCase {
    private func result(revision: String = "immutable-17", status: String = "available",
                        sleep: Any = NSNull(), hrv: Any = NSNull()) throws -> ServerCanonicalResults {
        let owner = "11111111-1111-4111-8111-111111111111"
        let source = "22222222-2222-4222-8222-222222222222"
        let device = "33333333-3333-4333-8333-333333333333"
        let project = "https://example.supabase.co", day = "2026-09-21"
        var families: [String: Any] = [:]
        for (name, metrics) in ServerCanonicalResults.familyMetrics {
            var values = Dictionary(uniqueKeysWithValues: metrics.map { ($0, NSNull() as Any) })
            if name == "recovery", status == "available" { values["recovery"] = 0 }
            if name == "night_hrv", status == "available" { values["hrv_sdnn_ms"] = hrv }
            if name == "sleep", status == "available" { values["sleep_sessions"] = sleep }
            families[name] = ["owner": "server", "metrics": metrics.sorted(), "status": status,
                "reason": status == "available" ? NSNull() : "qualification_pending",
                "result_revision": revision, "input_revision": 17,
                "algorithm_version": "frwhoop-server-1", "configuration_version": "config-1",
                "project": project, "owner_id": owner, "source_id": source, "device_id": device,
                "window": day, "computed_at": "2026-09-21T01:00:00Z",
                "observed_through": "2026-09-21T00:00:00Z", "timezone_id": "UTC",
                "freshness": "current", "values": values, "details": [:]]
        }
        let payload: [String: Any] = ["mode": "final_hosted", "policy_version": "vps-only-1",
            "project": project, "owner_id": owner, "source_id": source, "device_id": device,
            "day": day, "families": families]
        let decoded = try JSONDecoder().decode(ServerCanonicalResults.self,
            from: JSONSerialization.data(withJSONObject: payload))
        try decoded.validate(owner: owner, day: day, project: project, source: source, device: device)
        return decoded
    }

    private func state(_ result: ServerCanonicalResults, phase: ServerScoreDayState.Phase? = nil) -> ServerScoreViewState {
        var state = ServerScoreViewState(generation: nil, revision: 1, currentDay: result.day, timezone: "UTC",
            configured: true, authenticated: true, capabilities: [], activated: [],
            days: phase.map { [result.day: ServerScoreDayState.empty($0)] } ?? [:])
        state.canonicalDays = [result.day: result]
        return state
    }

    func testPublicationAndCSVRetainExactRevisionValidZeroAndOwnedNull() throws {
        let result = try result()
        let ledger = try XCTUnwrap(CanonicalConsumerPublication.ledger(result))
        XCTAssertEqual(ledger.families["recovery"]?.resultRevision, "immutable-17")
        XCTAssertEqual(ledger.project, result.project)
        XCTAssertEqual(ledger.ownerID, result.ownerID)
        XCTAssertEqual(ledger.deviceID, result.deviceID)
        XCTAssertEqual(ledger.sourceID, result.sourceID)
        XCTAssertEqual(CanonicalConsumerPublication.value("recovery", in: result), 0)
        XCTAssertNil(CanonicalConsumerPublication.value("hrv_sdnn_ms", in: result))
        let csv = CsvExport.canonicalCSV([result])
        XCTAssertTrue(csv.contains("\"recovery\",\"recovery\",\"0.0\",\"available\""))
        XCTAssertTrue(csv.contains("\"night_hrv\",\"hrv_sdnn_ms\",\"\",\"available\""))
        XCTAssertTrue(csv.contains("\"17\",\"immutable-17\",\"frwhoop-server-1\",\"config-1\""))
    }

    func testWidgetChangesOnRevisionEvenWhenValuesAreEqualAndRejectsOldCache() throws {
        let first = try result(), next = try result(revision: "immutable-18")
        var a = WidgetSnapshot(recovery: 0, bpm: 70, batteryPct: 50, bonded: true, updated: Date(),
            finalHosted: true, canonicalLedger: CanonicalConsumerPublication.ledger(first))
        var b = a; b.canonicalLedger = CanonicalConsumerPublication.ledger(next)
        XCTAssertTrue(a.hasCanonicalAdmission)
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: a, to: b))
        a.finalHosted = nil
        XCTAssertFalse(a.hasCanonicalAdmission)
        b.canonicalLedger = CanonicalConsumerPublication.ledger(try result(status: "revoked"))
        XCTAssertFalse(b.hasCanonicalAdmission)
        b.recovery = nil
        XCTAssertTrue(b.hasCanonicalAdmission)
    }

    func testHealthUsesExactAuthorizedSleepAndNeverReconstructsOwnedNull() throws {
        let sleep: [String: Any] = ["id": "44444444-4444-4444-8444-444444444444",
            "start_at": "2026-09-20T22:00:00Z", "end_at": "2026-09-21T00:00:00Z",
            "is_nap": false, "stages": [], "asleep_min": 90, "efficiency": 0.75]
        let plan = try CanonicalHealthWritebackPlan.days(state: state(result(sleep: [sleep])))
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].sleeps.count, 1)
        XCTAssertTrue(plan[0].sleeps[0].stages.isEmpty, "No phone-generated asleep intervals")
        XCTAssertNil(plan[0].sleeps[0].hrvRmssdMs, "Sleep-only result must not embed HRV")
        XCTAssertNil(plan[0].sleeps[0].restingHrBpm)
        XCTAssertTrue(plan[0].quantities.isEmpty, "Do not reconstruct nightly HRV or respiration")
        let revoked = try CanonicalHealthWritebackPlan.days(state: state(result(status: "revoked")))
        XCTAssertEqual(revoked.count, 1, "Null states must retain replacement-day identity")
        XCTAssertTrue(revoked[0].quantities.isEmpty)
        XCTAssertTrue(revoked[0].sleeps.isEmpty)
        XCTAssertFalse(CanonicalHealthWritebackPlan.quantities.contains("skin_temp_c"))
    }

    func testHealthRejectsMalformedSessionsInsteadOfEmptyDefaults() throws {
        XCTAssertThrowsError(try CanonicalHealthWritebackPlan.days(state: state(result(sleep: [["id": "bad"]]))))
        let invalid: [String: Any] = ["id": "44444444-4444-4444-8444-444444444444",
            "start_at": "2026-09-21T00:00:00Z", "end_at": "2026-09-20T22:00:00Z",
            "is_nap": false, "stages": []]
        XCTAssertThrowsError(try CanonicalHealthWritebackPlan.days(state: state(result(sleep: [invalid]))))
    }

    func testReadFailureDoesNotRewriteRevisionOrRepublishCachedValueAsCurrent() throws {
        let result = try result(), failed = state(result, phase: .failed)
        let ledger = try XCTUnwrap(CanonicalConsumerPublication.ledger(result, state: failed))
        XCTAssertEqual(ledger.readState, "failed")
        XCTAssertEqual(ledger.families["recovery"]?.resultRevision, "immutable-17")
        XCTAssertNil(CanonicalConsumerPublication.value("recovery", in: result, state: failed))
        XCTAssertTrue(try CanonicalHealthWritebackPlan.days(state: failed).isEmpty)
        var snapshot = WidgetSnapshot(recovery: 0, bpm: 70, batteryPct: 50, bonded: true, updated: Date(),
            finalHosted: true, canonicalLedger: ledger)
        XCTAssertFalse(snapshot.hasCanonicalAdmission)
        snapshot.recovery = nil
        XCTAssertTrue(snapshot.hasCanonicalAdmission)
    }

    func testActualDatabaseAccountRouteSleepOnlyEnvelopePassesProductionHealthDecoder() throws {
        // Exact synthetic DB/worker/Edge response captured by the production-route integration gate.
        // This replay does not claim a new live database run or physical HealthKit write.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/compute-account-sleep-only.json")
        struct Envelope: Decodable {
            struct Scoring: Decodable { let compute: ServerCanonicalResults }
            let server_scoring: Scoring
        }
        let result = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url)).server_scoring.compute
        try result.validate(owner: result.ownerID, day: result.day, project: result.project,
                            source: result.sourceID, device: result.deviceID)
        let plan = try XCTUnwrap(CanonicalHealthWritebackPlan.days(state: state(result)).first)
        XCTAssertEqual(plan.sleeps.count, 1)
        XCTAssertEqual(plan.sleeps[0].id, "55555555-5555-4555-8555-555555555555")
        XCTAssertEqual(plan.sleeps[0].asleepMin, 420)
        XCTAssertEqual(plan.sleeps[0].efficiency, 0.875)
        XCTAssertTrue(plan.sleeps[0].stages.isEmpty)
        XCTAssertNil(plan.sleeps[0].hrvRmssdMs)
        XCTAssertNil(plan.sleeps[0].restingHrBpm)
        XCTAssertTrue(plan.quantities.isEmpty)
    }
}
