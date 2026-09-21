import XCTest
@testable import WhoopStore

final class ServerScoreAuthorizationTests: XCTestCase {
    private let owner = "11111111-1111-1111-1111-111111111111"
    private let day = "2026-09-16"

    private func body() -> [String: Any] {
        let feature: [String: Any] = ["status": "available", "device_id": "device-a", "algorithm_version": "frwhoop-physiology-2",
            "input_revision": 7, "canonical_qualification": "signed_reference_approval", "feature_manifest_hash": String(repeating: "f", count: 64)]
        return ["server_scoring": ["schema_version": 2, "user_id": owner, "day": day, "algorithm_version": "frwhoop-physiology-2",
            "features": ["sleep": feature, "hrv": feature, "respiration": feature],
            "daily": ["hrv_rmssd_ms": 0, "sleep_total_min": 480, "resp_rate_bpm": 12],
            "nights": [["id": "episode", "device_id": "device-a", "start_at": "2026-09-16T00:00:00Z", "end_at": "2026-09-16T08:00:00Z",
                "hrv_rmssd_ms": 42, "resting_hr_bpm": 51, "resp_rate_bpm": 12, "hrv_summary": ["value": 42], "respiration_summary": ["value": 12],
                "recovery": 77, "strain": 12, "spo2_pct": 98, "skin_temp_c": 34, "skin_temp_dev_c": 0.2]]]]
    }

    private func parse(_ root: [String: Any]) throws -> ServerScoreDayCache {
        try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: root), day: day, ownerId: owner)
    }

    func testApprovedFeaturesPreserveZeroAndMatchingNestedPhysiology() throws {
        let cache = try parse(body())
        XCTAssertTrue(cache.features.values.allSatisfy(\.isCanonicalAvailable))
        XCTAssertEqual(ServerVitalSelection.resolve(.hrv, serverEnabled: true, selectedDay: day, overlay: cache, localValue: nil).value, 0)
        XCTAssertEqual(cache.nights.first?.hrvRmssdMs, 42)
        XCTAssertEqual(cache.nights.first?.respRateBpm, 12)
    }

    func testMissingRevokedShadowAndMalformedAuthorizationNeverActivate() throws {
        let changes: [(String, Any)] = [("canonical_qualification", NSNull()), ("canonical_qualification", "revoked"),
            ("feature_manifest_hash", "not-a-hash"), ("feature_manifest_hash", NSNull()), ("publication_status", "shadow"),
            ("publication_status", "revoked"), ("status", "unavailable")]
        for (key, value) in changes {
            var root = body(), overlay = body()["server_scoring"] as! [String: Any]
            var features = overlay["features"] as! [String: [String: Any]]
            for feature in features.keys { features[feature]?[key] = value }
            overlay["features"] = features; root["server_scoring"] = overlay
            let cache = try parse(root)
            XCTAssertTrue(cache.features.values.allSatisfy { !$0.isCanonicalAvailable }, key)
            for metric in [ServerVitalSelection.Metric.hrv, .sleep, .respiratory] {
                let selected = ServerVitalSelection.resolve(metric, serverEnabled: true, selectedDay: day, overlay: cache, localValue: nil)
                XCTAssertNil(selected.value, key)
                XCTAssertEqual(selected.displayDiagnostic.status, "unavailable")
            }
            XCTAssertNil(cache.nights.first?.hrvRmssdMs)
            XCTAssertNil(cache.nights.first?.respRateBpm)
        }
    }

    func testSleepApprovalCannotAuthorizeDifferentFeatureOrSnapshot() throws {
        let changes: [(String, Any)] = [("canonical_qualification", NSNull()), ("device_id", "device-b"),
            ("algorithm_version", "different-model"), ("input_revision", 8), ("status", "unavailable")]
        for (key, value) in changes {
            var root = body(), overlay = body()["server_scoring"] as! [String: Any]
            var features = overlay["features"] as! [String: [String: Any]]
            for feature in ["hrv", "respiration"] { features[feature]?[key] = value }
            overlay["features"] = features; root["server_scoring"] = overlay
            let cache = try parse(root)
            XCTAssertTrue(cache.features["sleep"]!.isCanonicalAvailable)
            XCTAssertNil(cache.nights.first?.hrvRmssdMs)
            XCTAssertNil(cache.nights.first?.restingHrBpm)
            XCTAssertNil(cache.nights.first?.respRateBpm)
            let sanitized = try JSONSerialization.jsonObject(with: Data(cache.rawSnapshotJSON!.utf8)) as! [String: Any]
            let night = ((sanitized["server_scoring"] as! [String: Any])["nights"] as! [[String: Any]])[0]
            for field in ["hrv_rmssd_ms", "resting_hr_bpm", "hrv_summary", "resp_rate_bpm", "respiration_summary",
                          "recovery", "strain", "spo2_pct", "skin_temp_c", "skin_temp_dev_c"] {
                XCTAssertNil(night[field], "\(key): \(field)")
            }
        }
    }

    func testRetainedV1DoesNotRequireV2ApprovalAndWrongEpisodeScopeFails() throws {
        var root = body(), overlay = body()["server_scoring"] as! [String: Any]
        var features = overlay["features"] as! [String: [String: Any]]
        for feature in features.keys {
            features[feature]?["algorithm_version"] = "frwhoop-server-1"
            features[feature]?.removeValue(forKey: "canonical_qualification")
            features[feature]?.removeValue(forKey: "feature_manifest_hash")
        }
        overlay["features"] = features; root["server_scoring"] = overlay
        XCTAssertTrue(try parse(root).features.values.allSatisfy(\.isCanonicalAvailable))
        for field in ["user_id", "device_id", "algorithm_version"] {
            var invalid = overlay
            var nights = invalid["nights"] as! [[String: Any]]
            nights[0][field] = "other"
            invalid["nights"] = nights
            XCTAssertThrowsError(try parse(["server_scoring": invalid]), field)
        }
    }
}
