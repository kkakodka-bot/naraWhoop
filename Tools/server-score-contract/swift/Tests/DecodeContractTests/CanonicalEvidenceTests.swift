import Foundation
import XCTest
import WhoopStore
@testable import DecodeContract

final class CanonicalEvidenceTests: XCTestCase {
    // Synthetic retained-v1 fixture: input exclusion permits heuristic sleep only.
    // It is neither a physiological reference approval nor a physical readback.
    private func fixture() -> [String: Any] {
        ["owner": "server", "metrics": ["sleep_total_min", "sleep_in_bed_min", "sleep_sessions"],
         "status": "available", "reason": NSNull(), "result_revision": "sha256:" + String(repeating: "a", count: 64),
         "input_revision": 4, "algorithm_version": "frwhoop-server-1", "configuration_version": "legacy-1",
         "canonical_qualification": "retained_legacy", "manifest_hash": String(repeating: "b", count: 64),
         "project": "https://fixture.invalid", "owner_id": "00000000-0000-4000-8000-000000000001",
         "source_id": "00000000-0000-4000-8000-000000000002", "device_id": "00000000-0000-4000-8000-000000000003",
         "window": "2026-09-21", "timezone_id": "UTC", "computed_at": "2026-09-22T06:00:00Z",
         "freshness": "current", "values": ["sleep_total_min": 360, "sleep_in_bed_min": 480,
             "sleep_sessions": [["start_at": "2026-09-21T00:00:00Z", "asleep_min": 360, "in_bed_min": 480,
                 "resting_hr_bpm": 53, "hrv_rmssd_ms": NSNull()]]] as [String: Any],
         "details": ["input_eligibility": ["policy_version": "legacy-rr-excluded-1", "rr_input": "excluded"],
             "source_receipt": ["object_id": "00000000-0000-4000-8000-000000000004", "sha256": String(repeating: "c", count: 64)],
             "nights": [["start_at": "2026-09-21T00:00:00Z", "asleep_min": 360, "in_bed_min": 480,
                 "resting_hr_bpm": 53, "hrv_rmssd_ms": NSNull()]]]]
    }
    private func decode(_ object: [String: Any]) throws -> ServerCanonicalFamilyResult {
        try JSONDecoder().decode(ServerCanonicalFamilyResult.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func normalized(_ value: ServerCanonicalFamilyResult) throws -> [String: Any] {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        object["values"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value.values))
        object["details"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value.details))
        object["status"] = value.status
        object["reason"] = value.reason.map { $0 as Any } ?? NSNull()
        return object
    }
    func testNormalizedPersistenceMatchesCompletePublicContract() throws {
        let original = try decode(fixture())
        let restored = try decode(normalized(original))
        XCTAssertTrue(original.hasCanonicalAuthorization)
        XCTAssertNotEqual(original, restored, "Reproduces distinct private backing normalization")
        XCTAssertEqual(original.values, restored.values)
        XCTAssertEqual(original.details, restored.details)
        XCTAssertEqual(restored.number("sleep_total_min"), 360)
        XCTAssertTrue(try canonicalContractMatches(original, restored))
    }
    func testEveryAdmittedIdentityAndEvidenceFieldRemainsCompared() throws {
        let original = try decode(fixture())
        let base = try normalized(original)
        let mutations: [String: Any] = ["owner": "client", "metrics": ["sleep_total_min"],
            "status": "revoked", "reason": "qualification_revoked", "result_revision": "compute:99",
            "input_revision": 5, "algorithm_version": "other", "configuration_version": "other",
            "model_version": "other", "preprocessing_version": "other", "quality_version": "other",
            "manifest_hash": String(repeating: "d", count: 64), "feature_manifest_hash": String(repeating: "e", count: 64),
            "canonical_qualification": "other", "project": "https://other.invalid", "owner_id": "other",
            "source_id": "other", "device_id": "other", "window": "2026-09-20", "timezone_id": "Europe/London",
            "computed_at": "2026-09-22T07:00:00Z", "observed_through": "2026-09-22T07:00:00Z",
            "freshness": "stale", "expires_at": "2026-09-23T07:00:00Z", "decision_id": "other"]
        for (key, value) in mutations {
            var changed = base; changed[key] = value
            XCTAssertFalse(try canonicalContractMatches(original, decode(changed)), key)
        }
    }
    func testNumbersNestedValuesAndRawReceiptCannotMutate() throws {
        let original = try decode(fixture())
        let base = try normalized(original)
        for key in ["sleep_total_min", "sleep_in_bed_min"] {
            var changed = base; var values = changed["values"] as! [String: Any]
            values[key] = 1; changed["values"] = values
            XCTAssertFalse(try canonicalContractMatches(original, decode(changed)), key)
        }
        for container in ["values", "details"] {
            var changed = base; var object = changed[container] as! [String: Any]
            let key = container == "values" ? "sleep_sessions" : "nights"
            var nights = object[key] as! [[String: Any]]; nights[0]["resting_hr_bpm"] = 1
            object[key] = nights; changed[container] = object
            XCTAssertFalse(try canonicalContractMatches(original, decode(changed)), container)
        }
        var changed = base; var details = changed["details"] as! [String: Any]
        details["source_receipt"] = ["object_id": "other", "sha256": String(repeating: "f", count: 64)]
        changed["details"] = details
        XCTAssertFalse(try canonicalContractMatches(original, decode(changed)))
    }
}
