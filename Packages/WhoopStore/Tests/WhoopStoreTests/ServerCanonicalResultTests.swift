import XCTest
import WhoopProtocol
@testable import WhoopStore

final class ServerCanonicalResultTests: XCTestCase {
    private let owner = "00000000-0000-4000-8000-000000000001"
    private let device = "00000000-0000-4000-8000-000000000002"
    private let source = "00000000-0000-4000-8000-000000000003"
    private let project = "https://compute-test.supabase.co"
    private let day = "2026-09-21"

    private func document(status: String = "unqualified", value: Any = NSNull()) -> [String: Any] {
        var families: [String: Any] = [:]
        for (family, metrics) in ServerCanonicalResults.familyMetrics {
            families[family] = ["owner": "server", "metrics": metrics.sorted(), "status": status,
                "reason": status == "available" ? NSNull() : "reference_required",
                "result_revision": "compute:1", "input_revision": 4,
                "algorithm_version": status == "available" ? "frwhoop-server-1" : "vps-only-1",
                "canonical_qualification": status == "available" ? "retained_legacy" as Any : NSNull(),
                "manifest_hash": status == "available" ? String(repeating: "a", count: 64) as Any : NSNull(),
                "configuration_version": "vps-only-1", "project": project, "owner_id": owner,
                "device_id": device, "source_id": source, "window": day,
                "timezone_id": "America/Los_Angeles", "computed_at": "2026-09-22T06:00:00Z",
                "freshness": "current", "values": Dictionary(uniqueKeysWithValues: metrics.map { ($0, value) }),
                "details": [String: Any]()]
        }
        return ["mode": "final_hosted", "policy_version": "vps-only-1", "project": project,
            "owner_id": owner, "device_id": device, "source_id": source, "day": day, "families": families]
    }

    private func decode(_ document: [String: Any]) throws -> ServerCanonicalResults {
        try JSONDecoder().decode(ServerCanonicalResults.self, from: JSONSerialization.data(withJSONObject: document))
    }

    func testAllFamiliesHaveExplicitServerOwnedMissingness() throws {
        let results = try decode(document())
        try results.validate(owner: owner, day: day, project: project, source: source, device: device)
        XCTAssertEqual(results.families.count, 27)
        XCTAssertEqual(ServerCanonicalResults.allMetrics.count, 80)
        for result in results.families.values {
            XCTAssertEqual(result.owner, "server")
            XCTAssertEqual(result.resultRevision, "compute:1")
            for metric in result.metrics { XCTAssertNil(result.number(metric)) }
        }
    }

    func testValidZeroAndOwnedNullNeverInvokeFallback() throws {
        let canonical = try decode(document(status: "available", value: 0))
        try canonical.validate(owner: owner, day: day)
        var cache = ServerScoreDayCache(day: day, algorithmVersion: "per_feature", daily: nil, nights: [], computedAt: nil, stale: false, fetchedAt: Date())
        cache.ownerId = owner
        cache.canonicalResults = canonical
        var localCalls = 0
        func fallback() -> Double? { localCalls += 1; return 88 }
        let selected = ServerVitalSelection.resolve(.restingHR, serverEnabled: false, selectedDay: day, overlay: cache, localValue: fallback())
        XCTAssertEqual(selected.value, 0)
        XCTAssertEqual(selected.canonicalResult?.resultRevision, "compute:1")
        cache.canonicalResults = try decode(document())
        XCTAssertNil(ServerVitalSelection.resolve(.restingHR, serverEnabled: false, selectedDay: day, overlay: cache, localValue: fallback()).value)
        XCTAssertEqual(localCalls, 0)
    }

    func testProjectSourceDeviceAndHistoricalDayFences() throws {
        let result = try decode(document())
        XCTAssertThrowsError(try result.validate(owner: device, day: day))
        XCTAssertThrowsError(try result.validate(owner: owner, day: "2026-09-20"))
        XCTAssertThrowsError(try result.validate(owner: owner, day: day, project: "https://other.supabase.co"))
        XCTAssertThrowsError(try result.validate(owner: owner, day: day, source: device))
        XCTAssertThrowsError(try result.validate(owner: owner, day: day, device: source))
    }

    func testIncompleteRegistryAndNumericShadowAreRejected() throws {
        var raw = document()
        var families = raw["families"] as! [String: Any]
        families.removeValue(forKey: "biofeedback")
        raw["families"] = families
        XCTAssertThrowsError(try decode(raw).validate(owner: owner, day: day))
        XCTAssertThrowsError(try decode(document(value: 12)).validate(owner: owner, day: day))
        var available = document(status: "available", value: 12)
        var values = available["families"] as! [String: [String: Any]]
        values["night_hrv"]?["algorithm_version"] = "frwhoop-physiology-2"
        available["families"] = values
        XCTAssertThrowsError(try decode(available).validate(owner: owner, day: day))
    }

    func testOwnershipPersistsUnavailableContractWithoutFabricatedPublication() throws {
        let suite = "compute-ledger-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = ServerMetricOwnership.Scope(project: project, ownerID: owner, deviceID: device)
        var cache = ServerScoreDayCache(day: day, algorithmVersion: "per_feature", daily: nil, nights: [], computedAt: nil, stale: false, fetchedAt: Date())
        cache.ownerId = owner
        cache.canonicalResults = try decode(document())
        let ledger = ServerMetricOwnershipStore(defaults: defaults).observe(cache, scope: scope)
        XCTAssertTrue(ledger.canRetireDailyKernel)
        let restored = ServerMetricOwnershipStore(defaults: defaults).load(scope)
        XCTAssertEqual(restored.metrics, ServerCanonicalResults.allMetrics)
        let missingDay = restored.presentation(nil, day: "2026-09-20", readFailed: true)
        XCTAssertNil(missingDay?.canonicalResults)
        XCTAssertNil(missingDay?.computedAt)
        XCTAssertEqual(missingDay?.readFailure, "server_read_failed")
        XCTAssertEqual(missingDay?.ownedMetrics, ServerCanonicalResults.allMetrics)
    }

    func testFinalHostedHasNoLegacyValueBeforeFirstRead() {
        PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            var localCalls = 0
            func fallback() -> Double? { localCalls += 1; return 88 }
            let result = ServerVitalSelection.resolve(.charge, serverEnabled: false, selectedDay: day, overlay: nil, localValue: fallback())
            XCTAssertNil(result.value)
            XCTAssertTrue(result.fromServer)
            XCTAssertEqual(result.status, "awaiting_server_result")
            XCTAssertEqual(localCalls, 0)
        }
    }

    func testFreshnessOutsideCurrentOrStaleCannotPublishSignedNumbers() throws {
        for freshness in ["expired", "unavailable"] {
            var raw = document(status: "available", value: 0)
            var families = raw["families"] as! [String: [String: Any]]
            families["night_hrv"]?["freshness"] = freshness
            raw["families"] = families
            let result = try decode(raw)
            try result.validate(owner: owner, day: day, project: project, source: source, device: device)
            let recovery = try XCTUnwrap(result.families["night_hrv"])
            XCTAssertFalse(recovery.admitsCanonicalPublication(), freshness)
            XCTAssertNil(recovery.number("resting_hr_bpm"), freshness)
        }

        var invalid = document(status: "available", value: 0)
        var families = invalid["families"] as! [String: [String: Any]]
        families["night_hrv"]?["freshness"] = "future"
        invalid["families"] = families
        XCTAssertThrowsError(try decode(invalid).validate(owner: owner, day: day,
            project: project, source: source, device: device))
    }
}
