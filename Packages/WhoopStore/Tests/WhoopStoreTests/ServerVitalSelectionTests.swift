import XCTest
@testable import WhoopStore

final class ServerVitalSelectionTests: XCTestCase {
    private let day = "2026-09-16"
    private func cache(day: String = "2026-09-16", daily: ServerScoreDailyCache? = nil,
                       stale: Bool = false, statuses: [String: String] = ["respiration": "available"],
                       removing: [String] = []) throws -> ServerScoreDayCache {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "server_physiology_snapshot", withExtension: "json"))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var overlay = try XCTUnwrap(root["server_scoring"] as? [String: Any])
        var features = try XCTUnwrap(overlay["features"] as? [String: [String: Any]])
        let scope = try XCTUnwrap(features["hrv"])
        for (key, status) in statuses {
            var entry = features[key] ?? [:]; entry["status"] = status
            // Available synthetic alternatives retain the real fixture's required owner-device/model scope.
            if status != "unavailable" {
                entry["device_id"] = entry["device_id"] ?? scope["device_id"]
                entry["algorithm_version"] = entry["algorithm_version"] ?? scope["algorithm_version"]
                entry["canonical_qualification"] = "signed_reference_approval"
                entry["feature_manifest_hash"] = String(repeating: "f", count: 64)
            }
            features[key] = entry
        }
        for key in removing { features.removeValue(forKey: key) }
        overlay["features"] = features; root["server_scoring"] = overlay
        let fixture = try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: root),
            day: self.day, ownerId: "11111111-1111-1111-1111-111111111111")
        var result = ServerScoreDayCache(day: day, algorithmVersion: fixture.algorithmVersion, daily: daily, nights: [],
                                        computedAt: nil, stale: stale, fetchedAt: Date(timeIntervalSince1970: 1))
        result.features = fixture.features; result.ownerId = fixture.ownerId
        return result
    }

    func testMissingOverlayDoesNotSubstituteUnqualifiedLocalPhysiology() {
        for metric in ServerVitalSelection.Metric.allCases {
            let result = ServerVitalSelection.resolve(metric, serverEnabled: true, selectedDay: day,
                                                      overlay: nil, localValue: 99)
            let owned = metric == .sleep || metric == .hrv || metric == .respiratory
            XCTAssertEqual(result.value, owned ? nil : 99)
            XCTAssertEqual(result.fromServer, owned)
        }
    }

    func testMissingServerPhysiologyRemainsUnavailable() throws {
        let overlay = try cache()
        for metric in [ServerVitalSelection.Metric.hrv, .restingHR, .respiratory, .sleep, .charge, .strain, .spo2, .skinTemp] {
            let result = ServerVitalSelection.resolve(metric, serverEnabled: true, selectedDay: day,
                                                      overlay: overlay, localValue: 99)
            let owned = metric == .sleep || metric == .hrv || metric == .respiratory
            XCTAssertEqual(result.value, owned ? nil : 99)
            XCTAssertEqual(result.fromServer, owned)
        }
        let blankHrv = try cache(daily: .init(), statuses: ["hrv": "available", "sleep": "available", "respiration": "available"])
        let hrv = ServerVitalSelection.resolve(.hrv, serverEnabled: true, selectedDay: day,
                                              overlay: blankHrv, localValue: 99)
        XCTAssertNil(hrv.value)
        XCTAssertTrue(hrv.fromServer)
    }

    func testSelectedServerValuesAndRealZeroWin() throws {
        let overlay = try cache(daily: .init(hrvRmssdMs: 0, restingHrBpm: 51, respRateBpm: 14.2))
        for (metric, expected) in [(ServerVitalSelection.Metric.hrv, 0.0), (.restingHR, 51), (.respiratory, 14.2)] {
            XCTAssertEqual(ServerVitalSelection.resolve(metric, serverEnabled: true, selectedDay: day,
                                                        overlay: overlay, localValue: 99).value, expected)
        }
    }

    func testWrongDayCannotMasqueradeAsSelectedDay() throws {
        let overlay = try cache(day: "2026-09-15", daily: .init(hrvRmssdMs: 40, restingHrBpm: 60, respRateBpm: 15))
        for metric in ServerVitalSelection.Metric.allCases {
            let result = ServerVitalSelection.resolve(metric, serverEnabled: true, selectedDay: day,
                                                      overlay: overlay, localValue: 99)
            let owned = metric == .sleep || metric == .hrv || metric == .respiratory
            XCTAssertEqual(result.value, owned ? nil : 99)
            XCTAssertEqual(result.fromServer, owned)
        }
    }

    func testLocalModeIsUnchangedAndIgnoresServer() throws {
        let overlay = try cache(daily: .init(hrvRmssdMs: 0, restingHrBpm: 51, respRateBpm: 14.2))
        for metric in ServerVitalSelection.Metric.allCases {
            let result = ServerVitalSelection.resolve(metric, serverEnabled: false, selectedDay: day,
                                                      overlay: overlay, localValue: 99)
            XCTAssertEqual(result.value, 99); XCTAssertFalse(result.fromServer); XCTAssertNil(result.status)
        }
    }

    func testPreQualificationCacheCannotBecomeCanonicalOrFallBackToLocalPhysiology() throws {
        var overlay = try cache(daily: .init(hrvRmssdMs: 40, sleepTotalMin: 480, respRateBpm: 16),
                                statuses: ["hrv": "available", "sleep": "available", "respiration": "available"])
        for key in ["hrv", "sleep", "respiration"] { overlay.features[key]?.canonicalQualification = nil }
        for metric in [ServerVitalSelection.Metric.hrv, .sleep, .respiratory] {
            let value = ServerVitalSelection.resolve(metric, serverEnabled: true, selectedDay: day,
                                                     overlay: overlay, localValue: 99)
            XCTAssertNil(value.value); XCTAssertTrue(value.fromServer); XCTAssertEqual(value.status, "unavailable")
        }
        XCTAssertTrue(ServerSleepEpisode.episodes(overlay, day: day).isEmpty)
        XCTAssertTrue(ServerHrvSeries.from(overlay, day: day).windows.isEmpty)
        XCTAssertNil(ServerRespirationSummary.project(overlay, day: day))
    }

    func testRetainedServerValueCarriesStaleness() throws {
        let result = ServerVitalSelection.resolve(.hrv, serverEnabled: true, selectedDay: day,
                                                  overlay: try cache(daily: .init(hrvRmssdMs: 42), stale: true), localValue: 99)
        XCTAssertEqual(result.value, 42); XCTAssertTrue(result.stale); XCTAssertEqual(result.day, day)
    }

    func testRestingHRUsesActualHrvFeatureScopeAndMetadata() throws {
        let overlay = try cache(daily: .init(restingHrBpm: 51), statuses: ["hrv": "stale"])
        let result = ServerVitalSelection.resolve(.restingHR, serverEnabled: true, selectedDay: day, overlay: overlay, localValue: 99)
        XCTAssertEqual(result.value, 51); XCTAssertEqual(result.status, "stale"); XCTAssertTrue(result.stale)
        XCTAssertEqual(result.sourceFeature, "hrv")
        XCTAssertEqual(result.deviceId, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(result.algorithmVersion, "qualified-future-model-3")
    }

    func testMissingOrUnavailableSelectedFeatureRejectsEvenPresentDailyValues() throws {
        let daily = ServerScoreDailyCache(hrvRmssdMs: 40, restingHrBpm: 51, respRateBpm: 15)
        for (metric, key) in [(ServerVitalSelection.Metric.hrv, "hrv"), (.restingHR, "hrv"), (.respiratory, "respiration")] {
            for overlay in [try cache(daily: daily, statuses: [key: "unavailable", "resting_hr": "available"]),
                            try cache(daily: daily, removing: [key])] {
                let result = ServerVitalSelection.resolve(metric, serverEnabled: true, selectedDay: day, overlay: overlay, localValue: 99)
                XCTAssertEqual(result.value, metric == .restingHR ? 99 : nil)
                XCTAssertEqual(result.fromServer, metric != .restingHR)
            }
        }
    }
    func testSleepUsesSelectedDaySourceAndPreservesZeroWithoutLocalFallback() throws {
        for minutes in [0.0, 480.0] {
            let overlay = try cache(daily: .init(sleepTotalMin: minutes), statuses: ["sleep": "stale"])
            let selected = ServerVitalSelection.resolve(.sleep, serverEnabled: true, selectedDay: day, overlay: overlay, localValue: 120)
            XCTAssertEqual(selected.value, minutes); XCTAssertEqual(selected.sourceFeature, "sleep")
            XCTAssertTrue(selected.stale); XCTAssertTrue(selected.fromServer)
            XCTAssertEqual(selected.deviceId, overlay.features["sleep"]?.deviceId)
            XCTAssertEqual(selected.algorithmVersion, overlay.features["sleep"]?.algorithmVersion)
        }
        let absent = try cache(daily: .init(), statuses: ["sleep": "available"])
        let pendingSleep = ServerVitalSelection.resolve(.sleep, serverEnabled: true, selectedDay: day, overlay: absent, localValue: 120)
        XCTAssertNil(pendingSleep.value)
        XCTAssertTrue(pendingSleep.fromServer)
        let unknown = try cache(daily: .init(sleepTotalMin: 480), statuses: ["sleep": "unavailable"])
        XCTAssertNil(ServerVitalSelection.resolve(.sleep, serverEnabled: true, selectedDay: day, overlay: unknown, localValue: 120).value)
        XCTAssertTrue(ServerVitalSelection.resolve(.sleep, serverEnabled: true, selectedDay: day, overlay: unknown, localValue: 120).fromServer)
        let local = ServerVitalSelection.resolve(.sleep, serverEnabled: false, selectedDay: day, overlay: unknown, localValue: 120)
        XCTAssertEqual(local.value, 120); XCTAssertFalse(local.fromServer)
    }

}
