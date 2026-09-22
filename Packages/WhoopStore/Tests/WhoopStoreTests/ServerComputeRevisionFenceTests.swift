import XCTest
@testable import WhoopStore

final class ServerComputeRevisionFenceTests: XCTestCase {
    private let owner = "10000000-0000-4000-8000-000000000001"
    private let source = "10000000-0000-4000-8000-000000000002"
    private let device = "10000000-0000-4000-8000-000000000003"
    private let project = "https://compute-fence.supabase.co"
    private let day = "2026-09-21"

    private func document(pending: Bool = false) -> [String: Any] {
        let null: Any = NSNull()
        var families: [String: Any] = [:]
        for (name, metrics) in ServerCanonicalResults.familyMetrics {
            let active = !pending && name == "recovery"
            var values = Dictionary(uniqueKeysWithValues: metrics.map { ($0, NSNull() as Any) })
            if active { values["recovery"] = 0 }
            families[name] = [
                "owner": "server", "metrics": metrics.sorted(),
                "project": project, "owner_id": owner, "source_id": source,
                "device_id": pending ? null : device, "window": day,
                "status": pending ? "unavailable" : active ? "available" : "unqualified",
                "reason": pending ? "device_registration_pending" : active ? null : "reference_required",
                "result_revision": pending ? null : "compute:8", "input_revision": pending ? null : 8,
                "computed_at": pending ? null : "2026-09-22T06:00:00Z", "observed_through": NSNull(),
                "algorithm_version": active ? "frwhoop-server-1" : "vps-only-1",
                "configuration_version": "vps-only-1", "timezone_id": pending ? null : "UTC",
                "manifest_hash": active ? String(repeating: "a", count: 64) : null,
                "feature_manifest_hash": NSNull(), "canonical_qualification": active ? "retained_legacy" : null,
                "freshness": pending ? "unavailable" : "current", "values": values, "details": [String: Any](),
            ]
        }
        let compute: [String: Any] = ["mode": "final_hosted", "policy_version": "vps-only-1",
            "project": project, "owner_id": owner, "source_id": source, "device_id": pending ? null : device,
            "day": day, "families": families]
        let features = Dictionary(uniqueKeysWithValues: ["hrv", "sleep", "respiration"].map {
            ($0, ["status": "unavailable", "reason": "device_registration_pending"])
        })
        return ["server_scoring": ["schema_version": 2, "contract_revision": 2,
            "user_id": owner, "day": day, "algorithm_version": "per_feature", "daily": NSNull(),
            "nights": [], "computed_at": NSNull(), "stale": true, "features": features, "compute": compute]]
    }

    private func modify(_ document: [String: Any], family key: String = "recovery",
                        _ edit: (inout [String: Any]) -> Void) -> [String: Any] {
        var result = document
        var score = result["server_scoring"] as! [String: Any]
        var compute = score["compute"] as! [String: Any]
        var families = compute["families"] as! [String: [String: Any]]
        edit(&families[key]!)
        compute["families"] = families; score["compute"] = compute; result["server_scoring"] = score
        return result
    }

    private func scope(_ document: [String: Any], field: String, value: String) -> [String: Any] {
        var result = document
        var score = result["server_scoring"] as! [String: Any]
        var compute = score["compute"] as! [String: Any]
        var families = compute["families"] as! [String: [String: Any]]
        compute[field] = value
        for name in families.keys { families[name]?[field == "day" ? "window" : field] = value }
        if field == "owner_id" { score["user_id"] = value }
        if field == "day" { score["day"] = value }
        compute["families"] = families; score["compute"] = compute; result["server_scoring"] = score
        return result
    }

    private func decode(_ document: [String: Any]) throws -> ServerScoreDayCache {
        let score = document["server_scoring"] as! [String: Any]
        return try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: document),
            day: score["day"] as! String, ownerId: score["user_id"] as! String)
    }

    func testSameAvailableRevisionCannotMutateValueOrImmutableMetadata() throws {
        let original = try decode(document())
        XCTAssertEqual(original.canonicalResults?.result(for: "recovery")?.number("recovery"), 0)
        XCTAssertTrue(ServerComputeRevisionFence.admits(previous: original, next: try decode(document())))
        for (key, value): (String, Any) in [
            ("values", ["recovery": 12]), ("configuration_version", "changed"),
            ("computed_at", "2026-09-22T07:00:00Z"), ("observed_through", "2026-09-22T06:30:00Z"),
            ("details", ["unapproved": 12]),
        ] {
            let altered = try decode(modify(document()) { $0[key] = value })
            XCTAssertFalse(ServerComputeRevisionFence.admits(previous: original, next: altered), key)
        }
    }

    func testOlderInputCannotReplaceNewerEvenWithDifferentResultRevision() throws {
        let original = try decode(document())
        let older = try decode(modify(document()) { $0["input_revision"] = 7; $0["result_revision"] = "compute:99" })
        XCTAssertFalse(ServerComputeRevisionFence.admits(previous: original, next: older))
        let newer = try decode(modify(document()) { $0["input_revision"] = 9; $0["result_revision"] = "compute:99" })
        XCTAssertTrue(ServerComputeRevisionFence.admits(previous: original, next: newer))
    }

    func testReadTimeStalenessDoesNotRewriteImmutableValueButRevocationClearsIt() throws {
        let original = try decode(document())
        let stale = try decode(modify(document()) { $0["freshness"] = "stale"; $0["status"] = "stale"; $0["reason"] = "late_input" })
        XCTAssertTrue(ServerComputeRevisionFence.admits(previous: original, next: stale))
        let revoked = try decode(modify(document()) {
            $0["status"] = "revoked"; $0["reason"] = "approval_revoked"; $0["values"] = ["recovery": NSNull()]
        })
        XCTAssertTrue(ServerComputeRevisionFence.admits(previous: original, next: revoked))
        var calls = 0
        func local() -> Double? { calls += 1; return 90 }
        let selection = ServerVitalSelection.resolve(.charge, serverEnabled: false, selectedDay: day,
            overlay: revoked, localValue: local())
        XCTAssertNil(selection.value); XCTAssertEqual(selection.status, "approval_revoked"); XCTAssertEqual(calls, 0)
        XCTAssertEqual(selection.canonicalResult?.resultRevision, original.canonicalResults?.result(for: "recovery")?.resultRevision)
    }

    func testAccountSourceProjectDeviceAndDayCannotShareRevisionCache() throws {
        let original = try decode(document())
        for (field, value) in ["owner_id": "20000000-0000-4000-8000-000000000001",
            "source_id": "20000000-0000-4000-8000-000000000002", "device_id": "20000000-0000-4000-8000-000000000003",
            "project": "https://other.supabase.co", "day": "2026-09-20"] {
            let changed = try decode(scope(document(), field: field, value: value))
            XCTAssertFalse(ServerComputeRevisionFence.admits(previous: original, next: changed), field)
        }
    }

    func testPendingDevicePersistsExplicitOwnershipWithoutInventingCanonicalDevice() throws {
        let pending = try decode(document(pending: true))
        XCTAssertNil(pending.canonicalResults)
        XCTAssertEqual(pending.pendingCanonicalResults?.familyIDs.count, 27)
        XCTAssertEqual(pending.ownedMetrics, ServerCanonicalResults.allMetrics)
        let persisted = try JSONDecoder().decode(ServerScoreDayCache.self, from: JSONEncoder().encode(pending))
        XCTAssertEqual(persisted.pendingCanonicalResults, pending.pendingCanonicalResults)
        var ownership = ServerMetricOwnership(scope: .init(project: project, ownerID: owner, deviceID: device))
        XCTAssertFalse(ownership.observe(pending)); XCTAssertTrue(ownership.metrics.isEmpty)
        var calls = 0
        func local() -> Double? { calls += 1; return 90 }
        for metric in ServerVitalSelection.Metric.allCases {
            let selected = ServerVitalSelection.resolve(metric, serverEnabled: false, selectedDay: day, overlay: pending, localValue: local())
            XCTAssertNil(selected.value); XCTAssertNil(selected.deviceId)
            XCTAssertTrue(selected.fromServer); XCTAssertEqual(selected.status, "device_registration_pending")
        }
        XCTAssertEqual(calls, 0)
    }

    func testPendingDeviceClearsOldValuesOnlyWithinSameOwnerSourceProjectDay() throws {
        let previous = try decode(document()), pending = try decode(document(pending: true))
        XCTAssertTrue(ServerComputeRevisionFence.admits(previous: previous, next: pending))
        XCTAssertTrue(ServerComputeRevisionFence.admits(previous: pending, next: previous))
        for (field, value) in ["owner_id": "20000000-0000-4000-8000-000000000001",
            "source_id": "20000000-0000-4000-8000-000000000002", "project": "https://other.supabase.co", "day": "2026-09-20"] {
            let foreign = try decode(scope(document(pending: true), field: field, value: value))
            XCTAssertFalse(ServerComputeRevisionFence.admits(previous: previous, next: foreign), field)
            XCTAssertFalse(ServerComputeRevisionFence.admits(previous: foreign, next: previous), field)
        }
    }

    func testPendingDeviceCannotCarryNumericValuePublicationOrEmbeddedPhysiology() throws {
        for (key, value): (String, Any) in [
            ("values", ["recovery": 0]), ("result_revision", "compute:9"),
            ("input_revision", 1), ("details", ["hrv_rmssd_ms": 88]),
            ("device_id", device), ("status", "available"),
        ] {
            XCTAssertThrowsError(try decode(modify(document(pending: true)) { $0[key] = value }), key)
        }
        let pending = try XCTUnwrap(try decode(document(pending: true)).pendingCanonicalResults)
        XCTAssertThrowsError(try pending.validate(owner: source, day: day))
        XCTAssertThrowsError(try pending.validate(owner: owner, day: day, project: "https://other.supabase.co"))
        XCTAssertThrowsError(try pending.validate(owner: owner, day: day, source: device))
    }

    func testAlgorithmNameCannotAuthorizeLegacyOrShadowAndImmutableIdentityMustBeReal() throws {
        for (key, value): (String, Any) in [
            ("canonical_qualification", NSNull()), ("manifest_hash", NSNull()),
            ("manifest_hash", "not-a-manifest"), ("result_revision", "unrelated-snapshot-field"),
            ("computed_at", "not-a-time"),
        ] {
            XCTAssertThrowsError(try decode(modify(document()) { $0[key] = value }), key)
        }
    }

    func testExpiryWithholdsTimeSensitiveValueWithoutErasingItsImmutableHistory() throws {
        let family = try XCTUnwrap(try decode(modify(document()) {
            $0["expires_at"] = "2026-09-21T10:01:00.250Z"
            $0["status"] = "stale"; $0["reason"] = "window_expired"
        }).canonicalResults?.result(for: "recovery"))
        let expiry = try XCTUnwrap(ServerCanonicalFamilyResult.timestamp("2026-09-21T10:01:00.250Z"))
        XCTAssertEqual(family.number("recovery", now: expiry.addingTimeInterval(-0.001)), 0)
        XCTAssertNil(family.number("recovery", now: expiry))
        XCTAssertNil(family.number("recovery", now: expiry.addingTimeInterval(60)))
        XCTAssertTrue(family.isExpired(at: expiry)); XCTAssertEqual(family.values["recovery"], .number(0))
        let daily = try XCTUnwrap(try decode(document()).canonicalResults?.result(for: "recovery"))
        XCTAssertFalse(daily.isExpired(at: .distantFuture))
        XCTAssertEqual(daily.number("recovery", now: .distantFuture), 0)
    }
}
