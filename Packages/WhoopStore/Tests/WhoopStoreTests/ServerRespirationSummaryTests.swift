import XCTest
@testable import WhoopStore

final class ServerRespirationSummaryTests: XCTestCase {
    func testActualScorerSnapshotSurvivesNativeReadbackAndSQLite() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "server_scored_sleep_snapshot", withExtension: "json"))
        let bytes = try Data(contentsOf: url)
        let owner = "11111111-1111-1111-1111-111111111111"
        let day = "2026-09-17"
        let cache = try ServerScoreCacheCodec.parseSnapshot(bytes, day: day, ownerId: owner)
        let store = try await WhoopStore.inMemory()
        let persistence = ServerScoreCacheStore(db: store.registryWriter)
        try persistence.upsert(cache)
        let loaded = try XCTUnwrap(persistence.load(ownerId: owner, day: day))
        let summary = try XCTUnwrap(ServerRespirationSummary.project(loaded, day: day))
        XCTAssertEqual(try XCTUnwrap(summary.breathsPerMinute), 12, accuracy: 0.1)
        XCTAssertEqual(summary.context, "main_sleep")
        XCTAssertEqual(summary.method, "resp-spectrum-acf-1")
        XCTAssertGreaterThan(try XCTUnwrap(summary.coverage), 0.9)
        XCTAssertEqual(summary.acceptedWindows, summary.totalWindows)
        XCTAssertNil(summary.reason)
        XCTAssertEqual(loaded.nights.count, 2)
        XCTAssertTrue(loaded.nights.flatMap(\.stages).contains { $0.state == "sleep_unstaged" })
        XCTAssertEqual(loaded.features["sleep"]?.inputRevision, 42)
        XCTAssertNotNil(loaded.daily?.hrvRmssdMs)
        XCTAssertNil(try persistence.load(ownerId: "another-owner", day: day))
        XCTAssertThrowsError(try ServerScoreCacheCodec.parseSnapshot(bytes, day: day, ownerId: "another-owner"))
    }

    private func cache(version: String = "frwhoop-physiology-2", status: String = "available",
                       scalar: Any = 16.0, context: String = "main_sleep", median: Any = 16.0,
                       coverage: Any = 0.5) throws -> ServerScoreDayCache {
        let payload: [String: Any] = ["server_scoring": ["schema_version": 2, "user_id": "owner", "day": "2026-09-18",
            "algorithm_version": version, "features": ["respiration": ["status": status, "device_id": "strap", "algorithm_version": version]],
            "daily": ["resp_rate_bpm": scalar, "respiration_summary": ["median_bpm": median, "mean_bpm": 16.0,
                "distribution_bpm": [18.0, 14.0, 16.0], "accepted_seconds": 180.0, "coverage": coverage,
                "accepted_windows": 3, "total_windows": 6, "context": context,
                "method_version": "resp-spectrum-acf-1", "calibration_status": "not_reference_validated"]], "nights": []]]
        return try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: payload), day: "2026-09-18", ownerId: "owner")
    }

    func testSelectedSummaryRetainsMethodCoverageAndSortedDistribution() throws {
        let input = try cache()
        let value = try XCTUnwrap(ServerRespirationSummary.project(input, day: input.day))
        XCTAssertEqual(value.breathsPerMinute, 16)
        XCTAssertEqual(value.mean, 16)
        XCTAssertEqual(value.distribution, [14, 16, 18])
        XCTAssertEqual(value.coverage, 0.5)
        XCTAssertEqual(value.acceptedSeconds, 180)
        XCTAssertEqual(value.acceptedWindows, 3)
        XCTAssertEqual(value.totalWindows, 6)
        XCTAssertEqual(value.context, "main_sleep")
        XCTAssertEqual(value.method, "resp-spectrum-acf-1")
        XCTAssertEqual(value.calibrationStatus, "not_reference_validated")
        XCTAssertNil(value.reason)
    }

    func testStaleSummaryIsRetainedWithoutLocalFallback() throws {
        let input = try cache(status: "stale")
        XCTAssertEqual(ServerRespirationSummary.project(input, day: input.day)?.breathsPerMinute, 16)
        XCTAssertEqual(input.features["respiration"]?.status, "stale")
    }

    func testPendingRevisionDoesNotHideWhyTheCompletedMeasurementWasUnavailable() throws {
        let input = try cache(scalar: NSNull(), median: NSNull(), coverage: 0)
        let bytes = try XCTUnwrap(input.rawSnapshotJSON?.data(using: .utf8))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var overlay = try XCTUnwrap(root["server_scoring"] as? [String: Any])
        var features = try XCTUnwrap(overlay["features"] as? [String: [String: Any]])
        features["respiration"]?["status"] = "stale"
        features["respiration"]?["reason"] = "newer_input_pending"
        overlay["features"] = features
        var daily = try XCTUnwrap(overlay["daily"] as? [String: Any])
        daily["respiration_unavailable_reason"] = "no_quality_eligible_windows"
        overlay["daily"] = daily
        root["server_scoring"] = overlay
        let cache = try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: root),
                                                            day: input.day, ownerId: input.ownerId)
        let value = try XCTUnwrap(ServerRespirationSummary.project(cache, day: input.day))
        XCTAssertNil(value.breathsPerMinute)
        XCTAssertEqual(value.reason, "newer_input_pending")
        XCTAssertEqual(value.measurementReason, "no_quality_eligible_windows")
        XCTAssertEqual(cache.features["respiration"]?.status, "stale")
    }

    func testWrongDayOwnerOrSelectedSourceCannotReadSummary() throws {
        var input = try cache()
        XCTAssertNil(ServerRespirationSummary.project(input, day: "2026-09-17"))
        input.ownerId = "another-owner"
        XCTAssertNil(ServerRespirationSummary.project(input, day: input.day))
        input = try cache()
        input.rawSnapshotJSON = input.rawSnapshotJSON?.replacingOccurrences(of: "strap", with: "other-strap")
        XCTAssertNil(ServerRespirationSummary.project(input, day: input.day))
    }

    func testUnavailableOrUnsupportedRateIsNotZero() throws {
        for input in [try cache(status: "unavailable"), try cache(scalar: NSNull()), try cache(scalar: 0), try cache(scalar: true)] {
            let value = try XCTUnwrap(ServerRespirationSummary.project(input, day: input.day))
            XCTAssertNil(value.breathsPerMinute)
            XCTAssertNotNil(value.reason)
        }
    }

    func testAwakeRestAndInconsistentSummaryCannotBecomeNightlyRate() throws {
        let active = try cache(context: "awake_rest")
        XCTAssertEqual(ServerRespirationSummary.project(active, day: active.day)?.reason, "incompatible_respiration_context")
        for input in [try cache(median: 14), try cache(coverage: 1.1), try cache(coverage: true)] {
            XCTAssertNil(ServerRespirationSummary.project(input, day: input.day)?.breathsPerMinute)
            XCTAssertEqual(ServerRespirationSummary.project(input, day: input.day)?.reason, "inconsistent_respiration_summary")
        }
    }

    func testLegacyRateNeverClaimsV2QualityEvenWithUnexpectedSummaryFields() throws {
        let input = try cache(version: "frwhoop-server-1")
        let value = try XCTUnwrap(ServerRespirationSummary.project(input, day: input.day))
        XCTAssertEqual(value.breathsPerMinute, 16)
        XCTAssertTrue(value.legacy)
        XCTAssertNil(value.mean)
        XCTAssertNil(value.coverage)
        XCTAssertNil(value.method)
        XCTAssertTrue(value.distribution.isEmpty)
        XCTAssertEqual(value.reason, "legacy_quality_unavailable")
    }
}
