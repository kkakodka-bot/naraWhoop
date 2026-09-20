import XCTest
@testable import WhoopStore

final class ServerHrvSeriesTests: XCTestCase {
    private let day = "2026-09-18"
    private let start = 1789689600

    private func row(_ offset: Int = 0, value: Double = 40, context: String = "quiet_rest") -> [String: Any] {
        ["measurement_schema_version": 1, "feature": "hrv", "user_id": "owner", "device_id": "device",
         "start": start + offset, "end": start + offset + 300, "metric": "rmssd", "unit": "ms",
         "input_revision": "42", "observed_rmssd_ms": value, "measurement_valid": true, "reason": NSNull(),
         "context": context, "baseline_eligible": true, "source": "whoop5", "modality": "ppg_prv",
         "algorithm_version": "rmssd-5m-v2", "observed_time_fraction": 0.96,
         "baseline": ["effective_sample_count": 31, "robust_z": 8.5]]
    }

    private func cache(_ rows: [Any], status: String = "fresh", version: String = "frwhoop-physiology-2") throws -> ServerScoreDayCache {
        let body: [String: Any] = ["server_scoring": [
            "schema_version": 2, "user_id": "owner", "day": day, "algorithm_version": "per_feature",
            "features": ["hrv": ["status": status, "device_id": "device", "algorithm_version": version,
                                 "input_revision": 42, "observed_through": "2026-09-18T00:30:00Z"]],
            "daily": ["hrv_rmssd_ms": 999], "measurements": rows, "nights": []]]
        let parsed = try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: body), day: day, ownerId: "owner")
        // Exercise the actual durable-cache round trip, not only an in-memory fixture.
        return try JSONDecoder().decode(ServerScoreDayCache.self, from: JSONEncoder().encode(parsed))
    }

    func testZeroUnavailableAndMissingBucketsRemainDistinct() throws {
        var invalid = row(600, value: 500)
        invalid["measurement_valid"] = false
        invalid["reason"] = "unverified_clock"
        let series = ServerHrvSeries.from(try cache([row(value: 0), invalid]), day: day)
        XCTAssertEqual(series.windows.count, 3)
        XCTAssertEqual(series.windows[0].rmssdMs, 0)
        XCTAssertTrue(series.windows[0].measurementValid)
        XCTAssertFalse(series.windows[0].isGap)
        XCTAssertNil(series.windows[1].rmssdMs)
        XCTAssertEqual(series.windows[1].reason, "window_missing")
        XCTAssertTrue(series.windows[1].isGap)
        XCTAssertNil(series.windows[2].rmssdMs)
        XCTAssertEqual(series.windows[2].reason, "unverified_clock")
        XCTAssertFalse(series.windows[2].isGap)
        XCTAssertEqual(series.observedThrough, "2026-09-18T00:30:00Z")
    }

    func testContextBaselineCountAndHighValuesSurviveWithoutClipping() throws {
        let contexts = ["sleep", "nap", "quiet_rest", "active", "mixed", "unknown"]
        let series = ServerHrvSeries.from(try cache(contexts.enumerated().map { row($0.offset * 300, value: 450, context: $0.element) }), day: day)
        XCTAssertEqual(series.windows.map(\.context), contexts)
        XCTAssertEqual(series.windows.map(\.baselineEligible), [true, true, true, false, false, false])
        XCTAssertTrue(series.windows.allSatisfy { $0.measurementValid && $0.rmssdMs == 450 && $0.baselineEffectiveSampleCount == 31 })
        XCTAssertEqual(series.windows[2].baselineRobustZ, 8.5)
        XCTAssertNil(series.windows[3].baselineRobustZ)
        XCTAssertEqual(series.windows[0].source, "whoop5")
        XCTAssertEqual(series.windows[0].modality, "ppg_prv")
        XCTAssertEqual(series.windows[0].methodVersion, "rmssd-5m-v2")
        XCTAssertEqual(series.windows[0].observedTimeFraction, 0.96)
    }

    func testDailyAvailabilityNeverReplacesWindowValidityOrInventsWindows() throws {
        XCTAssertTrue(ServerHrvSeries.from(try cache([]), day: day).windows.isEmpty)
        let unavailable = ServerHrvSeries.from(try cache([row()], status: "unavailable"), day: day)
        XCTAssertEqual(unavailable.featureStatus, "unavailable")
        XCTAssertEqual(unavailable.windows.first?.rmssdMs, 40)
        XCTAssertTrue(ServerHrvSeries.from(try cache([row()], version: "frwhoop-server-1"), day: day).windows.isEmpty)
        XCTAssertTrue(ServerHrvSeries.from(try cache([row()]), day: "2026-09-17").windows.isEmpty)
    }

    func testOwnerDeviceRevisionSchemaAndMetricFences() throws {
        let mutations: [(String, Any)] = [("user_id", "other"), ("device_id", "other"), ("input_revision", "43"),
            ("measurement_schema_version", 2), ("metric", "sdnn"), ("unit", "s"), ("start", start + 1)]
        for (key, value) in mutations {
            var bad = row(); bad[key] = value
            XCTAssertTrue(ServerHrvSeries.from(try cache([bad]), day: day).windows.isEmpty, key)
        }
        var changedOwner = try cache([row()]); changedOwner.ownerId = "other"
        XCTAssertTrue(ServerHrvSeries.from(changedOwner, day: day).windows.isEmpty)
    }

    func testDuplicatesCollapseAndConflictingValuesFailClosed() throws {
        XCTAssertEqual(ServerHrvSeries.from(try cache([row(), row()]), day: day).windows.count, 1)
        let conflict = try XCTUnwrap(ServerHrvSeries.from(try cache([row(), row(value: 41)]), day: day).windows.first)
        XCTAssertNil(conflict.rmssdMs)
        XCTAssertEqual(conflict.reason, "conflicting_window_records")
        XCTAssertFalse(conflict.baselineEligible)
    }

    func testMalformedNumericAndValidityFieldsDoNotBecomeMeasurements() throws {
        for (key, value) in [("observed_rmssd_ms", true as Any), ("measurement_valid", 1 as Any), ("reason", 5 as Any)] {
            var bad = row(); bad[key] = value
            let parsed = try XCTUnwrap(ServerHrvSeries.from(try cache([bad]), day: day).windows.first)
            XCTAssertFalse(parsed.measurementValid, key)
            XCTAssertNil(parsed.rmssdMs, key)
        }
        XCTAssertEqual(ServerHrvSeries.from(try cache(["malformed", row()]), day: day).windows.count, 1)
    }
}
