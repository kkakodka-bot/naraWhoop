import XCTest
import StrandAnalytics
@testable import Strand

final class ServerScoreContextPresentationTests: XCTestCase {
    private let day = "2026-09-15"
    private let metrics: Set<ServerScoreMetric> = [.cyclePhase, .circadianPhase, .circadianOffset, .illnessScore]
    private var details: [String: Any] {
        ["contextPolicy": "as-of-context-v1",
         "cycle": ["phase": "luteal", "confidence": "solid", "cycleDayLow": 16, "cycleDayHigh": 18,
                   "cycleLengthDays": 28, "nextPeriodWindow": ["earliestDay": "2026-09-25", "latestDay": "2026-09-28"],
                   "shiftMarkers": ["2026-09-13"], "awarenessOnly": true,
                   "baselinePolicy": "pre_observation_absolute_temperature", "note": "synthetic emitted cycle note"],
         "circadian": ["confidence": "wide", "acrophaseHours": 16.5, "observedDays": 7,
                       "habitualWakeHour": 7.5, "measuredTemperatureMinimum": false, "note": "synthetic emitted clock note"],
         "illness": ["level": "suppressed", "signalCount": 2, "suppressedBy": ["alcohol"],
                     "distanceFires": true, "distanceIsAlertGate": false, "wellnessOnly": true,
                     "firedSignals": ["synthetic HR evidence", "synthetic HRV evidence"], "copy": "synthetic emitted wellness copy"]]
    }

    private func snapshot(details changed: [String: Any]? = nil, extra: [String: Any] = [:]) throws -> ServerScoreSnapshot {
        var object: [String: Any] = ["schemaVersion": 2,
            "userId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "sourceDeviceId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "day": day, "timezone": "UTC", "algorithmVersion": "fixture", "inputRevision": 1, "resultRevision": 2,
            "computedAt": "2026-09-15T12:00:00Z", "status": "partial", "coverage": [:], "sleep": [],
            "capabilities": metrics.map(\.rawValue), "details": changed ?? details,
            "metrics": ["circadian_phase_hour": ["value": 4.5, "unit": "local_hour", "method": "CircadianEngine_observed_hourly_hr_proxy"],
                        "circadian_offset_min": ["value": -45, "unit": "min", "method": "CircadianEngine"],
                        "illness_score": ["value": 32, "unit": "score_0_100", "method": "IllnessSignalEngine"]]]
        object.merge(extra) { _, new in new }
        return try XCTUnwrap(ServerScoreResponse.decode(JSONSerialization.data(withJSONObject: object), requestedDay: day).snapshot)
    }

    private func state(_ snapshot: ServerScoreSnapshot, active: Set<ServerScoreMetric>? = nil,
                       configured: Bool = true, authenticated: Bool = true) -> ServerScoreViewState {
        .init(generation: UUID(), revision: 1, currentDay: day, timezone: "UTC", configured: configured,
              authenticated: authenticated, capabilities: metrics, activated: active ?? metrics,
              days: [day: .init(snapshot: snapshot, phase: .offline, fetchedAt: nil, cached: true,
                               pending: false, requestedInputRevision: nil, archiveStatus: nil)])
    }

    private func available(_ state: ServerScoreViewState) -> [Bool] {
        [ServerScoreContextPresentation.cycle(day: day, state: state) != nil,
         ServerScoreContextPresentation.circadian(day: day, state: state) != nil,
         ServerScoreContextPresentation.illness(day: day, state: state) != nil]
    }

    func testCompleteCachedContextConvertsExactFieldsWithoutScoring() throws {
        let snapshot = try snapshot(), view = state(snapshot)
        let cycle = try XCTUnwrap(ServerScoreContextPresentation.cycle(day: day, state: view))
        XCTAssertEqual(cycle.phase, .luteal); XCTAssertEqual(cycle.confidence, .solid)
        XCTAssertEqual(cycle.cycleDayLow, 16); XCTAssertEqual(cycle.cycleDayHigh, 18)
        XCTAssertEqual(cycle.cycleLengthDays, 28)
        XCTAssertEqual(cycle.shiftMarkers.map(\.day), ["2026-09-13"])
        XCTAssertEqual(cycle.nextPeriodWindow?.latestDay, "2026-09-28")
        XCTAssertEqual(cycle.note, "synthetic emitted cycle note")
        let clock = try XCTUnwrap(ServerScoreContextPresentation.circadian(day: day, state: view))
        XCTAssertEqual(clock.tempMinHour, 4.5); XCTAssertEqual(clock.acrophaseHours, 16.5)
        XCTAssertEqual(clock.offsetVsScheduleMinutes, -45); XCTAssertEqual(clock.confidence, .wide)
        XCTAssertEqual(clock.note, "synthetic emitted clock note")
        let illness = try XCTUnwrap(ServerScoreContextPresentation.illness(day: day, state: view))
        XCTAssertEqual(illness.score, 32); XCTAssertEqual(illness.level, .suppressed)
        XCTAssertEqual(illness.signalCount, 2); XCTAssertEqual(illness.suppressedBy, ["alcohol"])
        XCTAssertEqual(illness.firedSignals, ["synthetic HR evidence", "synthetic HRV evidence"])
        XCTAssertEqual(illness.copy, "synthetic emitted wellness copy")
        XCTAssertNil(illness.message, "the old wire contract has no semantic-message enum to infer")
        XCTAssertEqual(try ServerScoreResponse.decode(snapshot.encoded(), requestedDay: day).snapshot, snapshot)
    }

    func testEachOwnershipGateAndIndependentCircadianOffsetMustHold() throws {
        let value = try snapshot()
        for view in [state(value, active: []), state(value, configured: false), state(value, authenticated: false)] {
            XCTAssertEqual(available(view), [false, false, false])
        }
        XCTAssertEqual(available(state(value, active: [.cyclePhase])), [true, false, false])
        XCTAssertEqual(available(state(value, active: [.circadianPhase])), [false, false, false])
        XCTAssertEqual(available(state(value, active: [.circadianPhase, .circadianOffset])), [false, true, false])
        XCTAssertEqual(available(state(value, active: [.illnessScore])), [false, false, true])
    }

    func testLegacyIncompleteEvidenceDecodesButCannotManufactureRequiredEngineFields() throws {
        var legacy = details
        for (family, keys) in [("cycle", ["note"]), ("circadian", ["note"]), ("illness", ["firedSignals", "copy"])] {
            var object = try XCTUnwrap(legacy[family] as? [String: Any])
            keys.forEach { object.removeValue(forKey: $0) }; legacy[family] = object
        }
        let value = try snapshot(details: legacy)
        XCTAssertNil(value.details?.cycle?.note)
        XCTAssertEqual(available(state(value)), [false, false, false])
    }

    func testUnknownPolicyEnumsAndMissingScalarsStayUnavailable() throws {
        for policy in ["future-policy", ""] {
            var changed = details; changed["contextPolicy"] = policy
            XCTAssertEqual(available(state(try snapshot(details: changed))), [false, false, false])
        }
        for (family, key, position) in [("cycle", "phase", 0), ("cycle", "confidence", 0),
                                      ("cycle", "baselinePolicy", 0), ("circadian", "confidence", 1), ("illness", "level", 2)] {
            var changed = details, object = try XCTUnwrap(details[family] as? [String: Any])
            object[key] = "future"; changed[family] = object
            XCTAssertFalse(available(state(try snapshot(details: changed)))[position])
        }
        XCTAssertEqual(available(state(try snapshot(extra: ["metrics": [:]]))), [true, false, false])
    }

    func testWithdrawalNoDataAndWrongDayDoNotReturnRetainedDetail() throws {
        for extra: [String: Any] in [["capabilities": []], ["status": "no_data", "metrics": [:]], ["details": [:]]] {
            let view = state(try snapshot(extra: extra))
            XCTAssertTrue(view.owns(.cyclePhase))
            XCTAssertEqual(available(view), [false, false, false])
        }
        let view = state(try snapshot())
        XCTAssertNil(ServerScoreContextPresentation.cycle(day: "2026-09-14", state: view))
        XCTAssertNil(ServerScoreContextPresentation.circadian(day: "2026-09-14", state: view))
        XCTAssertNil(ServerScoreContextPresentation.illness(day: "2026-09-14", state: view))
        let noOffset = state(try snapshot(extra: ["capabilities": metrics.subtracting([.circadianOffset]).map(\.rawValue)]))
        XCTAssertNil(ServerScoreContextPresentation.circadian(day: day, state: noOffset))
    }
}
