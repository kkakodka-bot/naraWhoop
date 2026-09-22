import Foundation
import XCTest
import WhoopStore
#if !SERVER_SCORE_NATIVE_TESTS
@testable import Strand
#endif

final class ServerScoreHistoryContractTests: XCTestCase {
    private let today = "2026-09-18"
    private func snapshot(day: String = "2026-09-18", _ updates: [String: Any] = [:]) throws -> ServerScoreSnapshot {
        var object: [String: Any] = [
            "schemaVersion": 2, "userId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "sourceDeviceId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "day": day,
            "timezone": "UTC", "algorithmVersion": "history-fixture",
            "inputRevision": 2, "resultRevision": 3, "computedAt": "2026-09-18T14:00:00Z",
            "status": "partial", "coverage": [:], "daily": ["hrv_rmssd_ms": 42], "sleep": []
        ]
        object.merge(updates) { _, new in new }
        let response = try ServerScoreResponse.decode(JSONSerialization.data(withJSONObject: object), requestedDay: day)
        return try XCTUnwrap(response.snapshot)
    }
    private func state(_ snapshots: [ServerScoreSnapshot], active: Set<ServerScoreMetric> = [.hrv]) -> ServerScoreViewState {
        ServerScoreViewState(generation: UUID(), revision: 1, currentDay: today, timezone: "UTC",
            configured: true, authenticated: true, capabilities: Set(snapshots.flatMap(\.supported)),
            activated: active, days: Dictionary(uniqueKeysWithValues: snapshots.map {
                ($0.day, ServerScoreDayState(snapshot: $0, phase: $0.status == "no_data" ? .noData : .partial,
                    fetchedAt: Date(), cached: false, pending: false, requestedInputRevision: nil, archiveStatus: nil))
            }))
    }
    private func history(_ day: String, _ value: Any) -> [String: Any] {
        ["day": day, "metrics": ["hrv_rmssd_ms": ["value": value, "unit": "ms"]]]
    }

    func testMetadataPreservesSignedTemperatureAndUnknownOptionalFields() throws {
        let result = try snapshot(["metrics": ["skin_temp_dev_c": ["value": -0.75, "unit": "C",
            "status": "available", "method": "relative-fixture", "future": true]]])
        let reading = try XCTUnwrap(result.metrics?["skin_temp_dev_c"])
        XCTAssertEqual(reading.value, -0.75)
        XCTAssertEqual(reading.unit, "C")
        XCTAssertEqual(reading.status, "available")
        XCTAssertEqual(reading.method, "relative-fixture")
        XCTAssertEqual(try ServerScoreResponse.decode(result.encoded(), requestedDay: today).snapshot, result)
    }

    func testTypedNullOverridesPopulatedLegacyFieldAcrossAdapters() throws {
        let result = try snapshot(["metrics": ["hrv_rmssd_ms": ["value": NSNull(), "unit": "ms", "status": "unavailable", "method": "fixture"]]])
        let view = state([result])
        XCTAssertNil(result.value(.hrv))
        XCTAssertNil(view.value(.hrv, day: today, local: 99))
        XCTAssertNil(ServerScoreDisplay.daily(local: nil, day: today, state: view)?.avgHrv)
        XCTAssertTrue(ServerScoreDisplay.series(.hrv, through: today, state: view).isEmpty)
    }

    func testOwnedNullHeadlineNeverCarriesHistoricalTail() throws {
        let previous = try snapshot(day: "2026-09-17", ["daily": ["resp_rate_bpm": 17]])
        let current = try snapshot(["daily": ["resp_rate_bpm": NSNull()]])
        let view = state([previous, current], active: [.respiration])
        let history = ServerScoreDisplay.series(.respiration, through: today, state: view)
        XCTAssertEqual(history.last?.value, 17)
        var localReads = 0
        func tail() -> Double? { localReads += 1; return history.last?.value }
        XCTAssertNil(ServerScoreDisplay.headline(.respiration, day: today, state: view, local: tail()))
        XCTAssertEqual(localReads, 0)
        XCTAssertEqual(ServerScoreDisplay.headline(nil, day: today, state: view, local: tail()), 17)
        XCTAssertEqual(localReads, 1)
    }

    func testTemperaturePreferencePinsOwnedKindEvenWhenNull() throws {
        let current = try snapshot(["capabilities": ["skin_temp_c", "skin_temp_dev_c"],
                                    "daily": ["skin_temp_c": NSNull(), "skin_temp_dev_c": -0.7]])
        let view = state([current], active: [.skinTemperature, .skinTemperatureDeviation])
        let metric = try XCTUnwrap(ServerScoreDisplay.temperatureMetric(prefersAbsolute: true, state: view))
        XCTAssertEqual(metric, .skinTemperature)
        XCTAssertNil(current.value(metric))
        XCTAssertEqual(ServerScoreDisplay.temperatureMetric(prefersAbsolute: false, state: view), .skinTemperatureDeviation)
        XCTAssertEqual(current.value(.skinTemperatureDeviation), -0.7)
    }

    func testTemperatureSelectionRequiresActivationNotMerelyPayload() throws {
        let current = try snapshot(["capabilities": ["skin_temp_c", "skin_temp_dev_c"],
                                    "daily": ["skin_temp_c": 32, "skin_temp_dev_c": -0.7]])
        XCTAssertNil(ServerScoreDisplay.temperatureMetric(prefersAbsolute: true, state: state([current], active: [])))
        XCTAssertEqual(ServerScoreDisplay.temperatureMetric(prefersAbsolute: true,
            state: state([current], active: [.skinTemperatureDeviation])), .skinTemperatureDeviation)
    }

    func testOwnedCaloriesMasksBothSparkAliases() throws {
        let current = try snapshot(["capabilities": ["active_kcal_est"], "daily": ["active_kcal_est": NSNull()]])
        let values = ServerScoreDisplay.sparks(local: ["energy_kcal": [99], "active_kcal": [100], "weight": [70]],
                                              through: today, state: state([current], active: [.activeKcal]))
        XCTAssertEqual(values["energy_kcal"], [])
        XCTAssertEqual(values["active_kcal"], [])
        XCTAssertEqual(values["weight"], [70])
    }

    func testChartsRetainGapsCountsRangesAndNegativeValues() throws {
        let points: [[String: Any]] = [
            ["start": 100, "end": 110, "value": -0.5, "count": 3, "min": -1, "max": 0],
            ["start": 130, "end": 140, "value": NSNull(), "count": 1, "min": NSNull(), "max": NSNull()]
        ]
        let result = try snapshot(["charts": ["fixture_temperature": points]])
        let chart = try XCTUnwrap(result.charts?["fixture_temperature"])
        XCTAssertEqual(chart.count, 2)
        XCTAssertEqual(chart[0].min, -1)
        XCTAssertEqual(chart[0].count, 3)
        XCTAssertEqual(chart[1].start, 130)
        XCTAssertNil(chart[1].value)
    }

    func testMalformedChartBucketsAndUnboundedMetricValuesRejected() throws {
        for changes: [String: Any] in [["end": 100], ["count": 0], ["min": 5, "max": 4], ["value": 1e40]] {
            var point: [String: Any] = ["start": 100, "end": 110, "value": 2, "count": 1]
            point.merge(changes) { _, new in new }
            XCTAssertThrowsError(try snapshot(["charts": ["fixture": [point]]]))
        }
        XCTAssertThrowsError(try snapshot(["charts": ["fixture": [
            ["start": 100, "end": 110, "value": 2], ["start": 109, "end": 120, "value": 2]]]]))
        XCTAssertThrowsError(try snapshot(["metrics": ["fixture": ["value": 1e40]]]))
    }

    func testHistoryDatesBoundedUniqueAndNotFuture() throws {
        for entries in [[history("2026-09-19", 10)], [history("2026-02-30", 10)],
                        [history(today, 10), history(today, 11)]] {
            XCTAssertThrowsError(try snapshot(["history": entries]))
        }
        XCTAssertThrowsError(try snapshot(["history": Array(repeating: history(today, 10), count: 401)]))
    }

    func testIndividuallyFetchedCorrectionAndTombstoneOverrideHistory() throws {
        let head = try snapshot(["history": [history("2026-09-16", 11), history("2026-09-17", 12), history(today, 13)]])
        let correction = try snapshot(day: "2026-09-16", ["daily": ["hrv_rmssd_ms": 77]])
        let tombstone = try snapshot(day: "2026-09-17", ["status": "no_data", "daily": NSNull()])
        let series = ServerScoreDisplay.series(.hrv, through: today, state: state([head, correction, tombstone]))
        XCTAssertEqual(series.map(\.day), ["2026-09-16", today])
        XCTAssertEqual(series.map(\.value), [77, 42])
    }

    func testHistoryCannotMixOldSourceOrGrantUnactivatedOwnership() throws {
        let older = try snapshot(day: "2026-09-17", ["history": [history("2026-09-15", 99)]])
        let latest = try snapshot(["sourceDeviceId": "cccccccc-cccc-cccc-cccc-cccccccccccc",
                                   "history": [history("2026-09-16", 22)]])
        let view = state([older, latest])
        XCTAssertEqual(ServerScoreDisplay.series(.hrv, through: "2026-09-16", state: view).map(\.value), [22])
        XCTAssertTrue(ServerScoreDisplay.series(.hrv, through: today, state: state([latest], active: [])).isEmpty)
    }

    func testDependencyProvenanceRoundTripsWithoutGrantingOwnership() throws {
        let dependency: [String: Any] = ["stateSchemaVersion": 1, "generation": 4,
            "predecessorResultRevision": 20, "configurationRevision": 5, "profileRevision": 6, "sourceEra": "fixture-era"]
        let result = try snapshot(["dependency": dependency, "capabilities": ["hrv_rmssd_ms"]])
        XCTAssertEqual(result.dependency?.generation, 4)
        XCTAssertEqual(result.dependency?.predecessorResultRevision, 20)
        XCTAssertEqual(result.supported, [.hrv])
        XCTAssertEqual(try ServerScoreResponse.decode(result.encoded(), requestedDay: today).snapshot, result)
        var invalid = dependency
        invalid["generation"] = -1
        XCTAssertThrowsError(try snapshot(["dependency": invalid]))
    }

    func testMissingExtensionsRemainCompatibleAndCapabilitiesRemainResultScoped() throws {
        let core = try snapshot()
        XCTAssertEqual(core.value(.hrv), 42)
        XCTAssertNil(core.metrics)
        let explicit = try snapshot(["capabilities": ["sleep_sessions"], "metrics": ["hrv_rmssd_ms": ["value": 88]]])
        XCTAssertNil(explicit.value(.hrv))
        XCTAssertEqual(ServerScoreMetric.schema2.count, 13)
        XCTAssertThrowsError(try snapshot(["status": "no_data", "daily": NSNull(), "metrics": ["hrv_rmssd_ms": ["value": 88]]]))
    }

    func testScalarExtensionsNeverExpandImplicitCoreOrSleepCapabilities() throws {
        let result = try snapshot(["metrics": ["recovery": ["value": 70, "unit": "score_0_100"]]])
        XCTAssertNil(result.value(.recovery))
        XCTAssertFalse(result.supported.contains(.recovery))
        XCTAssertEqual(ServerScoreMetric.sleep.count, 9)
        XCTAssertTrue(ServerScoreMetric.schema2.isDisjoint(with: ServerScoreMetric.sleepHistory))
        XCTAssertFalse(state([result], active: [.recovery]).owns(.recovery))
    }

    func testAllDailyScalarExtensionsMapAndOwnedCarryIsEmpty() throws {
        let values: [String: Double] = ["recovery": 70, "strain": 35, "exercise_count": 2,
            "steps": 3210, "active_kcal_est": 123, "spo2_pct": 98, "spo2_red": 1000,
            "spo2_ir": 1200, "skin_temp_c": 32.5, "skin_temp_dev_c": -0.75]
        let metrics = values.mapValues { ["value": $0] }
        let result = try snapshot(["metrics": metrics, "capabilities": Array(values.keys)])
        let active = Set(values.keys.compactMap(ServerScoreMetric.init(rawValue:)))
        let view = state([result], active: active)
        let row = try XCTUnwrap(ServerScoreDisplay.daily(local: nil, day: today, state: view))
        XCTAssertEqual(row.recovery, 70)
        XCTAssertEqual(row.strain, 35)
        XCTAssertEqual(row.exerciseCount, 2)
        XCTAssertEqual(row.steps, 3210)
        XCTAssertEqual(row.activeKcalEst, 123)
        XCTAssertEqual(row.spo2Pct, 98)
        XCTAssertEqual(row.spo2Red, 1000)
        XCTAssertEqual(row.spo2Ir, 1200)
        XCTAssertEqual(row.skinTempC, 32.5)
        XCTAssertEqual(row.skinTempDevC, -0.75)
        let carry = try XCTUnwrap(ServerScoreDisplay.carry(row, state: view))
        XCTAssertNil(carry.recovery)
        XCTAssertNil(carry.strain)
        XCTAssertNil(carry.steps)
        XCTAssertNil(carry.skinTempDevC)
        XCTAssertNil(carry.spo2Pct)
    }

    func testLegacyDailySupportsSignedTemperatureButNotNegativeCounts() throws {
        let result = try snapshot(["daily": ["skin_temp_dev_c": -1.25], "capabilities": ["skin_temp_dev_c"]])
        XCTAssertEqual(result.value(.skinTemperatureDeviation), -1.25)
        XCTAssertThrowsError(try snapshot(["daily": ["steps": -1], "capabilities": ["steps"]]))
        XCTAssertThrowsError(try snapshot(["metrics": ["steps": ["value": -1]], "capabilities": ["steps"]]))
    }

    func testCoreCacheEncodingDoesNotSproutNewNullDailyFields() throws {
        let result = try snapshot()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result.encoded()) as? [String: Any])
        let daily = try XCTUnwrap(json["daily"] as? [String: Any])
        XCTAssertNotNil(daily["resting_hr_bpm"])
        XCTAssertNil(daily["skin_temp_dev_c"])
        XCTAssertNil(daily["recovery"])
    }

    func testEverySleepAndCatalogScalarUsesSameOwnedSeriesAndNullRules() throws {
        let fields = ServerScoreMetric.sleepHistory.union(ServerScoreMetric.longevity)
            .union([.averageHR, .maximumHR, .zones13, .zones45, .zonesAll, .strengthDuration, .stress, .estimatedSteps])
        for field in fields {
            let result = try snapshot(["capabilities": [field.rawValue], "metrics": [field.rawValue: ["value": 12]]])
            let view = state([result], active: [field])
            XCTAssertEqual(view.value(field, day: today, local: 99), 12)
            XCTAssertEqual(ServerScoreDisplay.series(field, through: today, state: view).map(\.value), [12])
            let nullResult = try snapshot(["capabilities": [field.rawValue], "metrics": [field.rawValue: ["value": NSNull()]]])
            XCTAssertNil(state([nullResult], active: [field]).value(field, day: today, local: 99))
        }
    }

    func testEfficiencySeriesHonorsPercentMetadataAndLegacyFractions() throws {
        let legacy = try snapshot(["daily": ["sleep_efficiency": 0.92]])
        XCTAssertEqual(ServerScoreDisplay.series(.sleepEfficiency, through: today,
            state: state([legacy], active: [.sleepEfficiency])).first?.value, 92)
        let typed = try snapshot(["metrics": ["sleep_efficiency": ["value": 0.5, "unit": "percent"]],
            "history": [["day": "2026-09-17", "metrics": ["sleep_efficiency": ["value": 0.25, "unit": "percent"]]]]])
        XCTAssertEqual(ServerScoreDisplay.series(.sleepEfficiency, through: today,
            state: state([typed], active: [.sleepEfficiency])).map(\.value), [0.25, 0.5])
    }

    func testReadyContentRequiresOwnedNonNullValueNotJustSnapshotPresence() throws {
        let core = try snapshot()
        XCTAssertTrue(state([core]).hasScalarContent(day: today))
        XCTAssertFalse(state([core], active: []).hasScalarContent(day: today))
        let empty = try snapshot(["status": "no_data", "daily": NSNull()])
        XCTAssertFalse(state([empty]).hasScalarContent(day: today))
        let typedNull = try snapshot(["metrics": ["hrv_rmssd_ms": ["value": NSNull()]]])
        XCTAssertFalse(state([typedNull]).hasScalarContent(day: today))
    }
}
