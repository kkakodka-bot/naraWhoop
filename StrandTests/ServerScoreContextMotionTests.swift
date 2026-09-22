import XCTest
#if !SERVER_SCORE_NATIVE_TESTS
@testable import Strand
#endif

final class ServerScoreContextMotionTests: XCTestCase {
    private let day = "2026-09-15"
    private let sleepID = "40000000-0000-4000-8000-000000000001"
    private let start: Int64 = 1789430400
    private let parents: Set<ServerScoreMetric> = [.illnessScore, .cyclePhase, .circadianPhase, .daytimeStress]
    private var details: [String: Any] {
        ["contextPolicy": "as-of-context-v1",
         "illness": ["level": "quiet", "signalCount": 0, "suppressedBy": [], "distanceFires": false,
                     "distanceIsAlertGate": false, "wellnessOnly": true],
         "cycle": ["phase": "learning", "confidence": "learning", "cycleDayLow": NSNull(),
                   "cycleDayHigh": NSNull(), "cycleLengthDays": NSNull(), "nextPeriodWindow": NSNull(),
                   "shiftMarkers": [], "awarenessOnly": true, "baselinePolicy": "pre_observation_absolute_temperature"],
         "circadian": ["confidence": "wide", "acrophaseHours": 16.5, "observedDays": 7,
                       "habitualWakeHour": NSNull(), "measuredTemperatureMinimum": false],
         "daytimeStress": ["personalBaseline": false, "hrOnlyFallback": true, "activityMaskedHours": 2,
                           "sustainedHigh": NSNull(), "sustainedRun": NSNull()],
         "frequencyHrv": ["lfPower": NSNull(), "hfPower": 120.5, "lfHfRatio": NSNull()],
         "futureOptional": ["ignored": true]]
    }
    private func snapshot(_ updates: [String: Any] = [:]) throws -> ServerScoreSnapshot {
        var object: [String: Any] = ["schemaVersion": 2,
            "userId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "sourceDeviceId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "day": day, "timezone": "UTC",
            "algorithmVersion": "fixture", "inputRevision": 1, "resultRevision": 2,
            "computedAt": "2026-09-15T12:00:00Z", "status": "partial", "coverage": [:], "sleep": [],
            "capabilities": parents.map(\.rawValue), "details": details]
        object.merge(updates) { _, new in new }
        let response = try ServerScoreResponse.decode(JSONSerialization.data(withJSONObject: object), requestedDay: day)
        return try XCTUnwrap(response.snapshot)
    }
    private func state(_ snapshot: ServerScoreSnapshot, active: Set<ServerScoreMetric>,
                       configured: Bool = true, authenticated: Bool = true,
                       capable: Set<ServerScoreMetric>? = nil) -> ServerScoreViewState {
        .init(generation: UUID(), revision: 1, currentDay: day, timezone: "UTC", configured: configured,
              authenticated: authenticated, capabilities: capable ?? snapshot.supported, activated: active,
              days: [day: .init(snapshot: snapshot, phase: .partial, fetchedAt: Date(), cached: false,
                               pending: false, requestedInputRevision: nil, archiveStatus: nil)])
    }
    private func reads(_ state: ServerScoreViewState, day: String? = nil) -> [Bool] {
        let day = day ?? self.day
        return [ServerScoreDisplay.illness(day: day, state: state) != nil,
                ServerScoreDisplay.cycle(day: day, state: state) != nil,
                ServerScoreDisplay.circadian(day: day, state: state) != nil,
                ServerScoreDisplay.daytimeStress(day: day, state: state) != nil]
    }

    func testContextRoundTripPreservesNullableEvidenceAndSignedOffset() throws {
        let value = try snapshot(["capabilities": parents.map(\.rawValue) + ["circadian_offset_min"],
            "metrics": ["circadian_offset_min": ["value": -45, "unit": "min", "method": "CircadianEngine"]]])
        XCTAssertEqual(value.value(.circadianOffset), -45)
        XCTAssertEqual(value.details?.circadian?.acrophaseHours, 16.5)
        XCTAssertNil(value.details?.circadian?.habitualWakeHour)
        XCTAssertNil(value.details?.cycle?.nextPeriodWindow)
        XCTAssertNil(value.details?.daytimeStress?.sustainedHigh)
        XCTAssertNil(value.details?.frequencyHrv?.lfPower)
        XCTAssertEqual(value.details?.frequencyHrv?.hfPower, 120.5)
        XCTAssertEqual(try ServerScoreResponse.decode(value.encoded(), requestedDay: day).snapshot, value)
    }

    func testContextReadsRequireEachOwnershipGateAndIndependentParentActivation() throws {
        let value = try snapshot()
        XCTAssertEqual(reads(state(value, active: parents)), [true, true, true, true])
        for view in [state(value, active: []), state(value, active: parents, configured: false),
                     state(value, active: parents, authenticated: false), state(value, active: parents, capable: [])] {
            XCTAssertEqual(reads(view), [false, false, false, false])
        }
        XCTAssertEqual(reads(state(value, active: [.illnessScore])), [true, false, false, false])
        XCTAssertEqual(reads(state(value, active: [.cyclePhase])), [false, true, false, false])
        XCTAssertEqual(reads(state(value, active: [.circadianPhase])), [false, false, true, false])
        XCTAssertEqual(reads(state(value, active: [.daytimeStress])), [false, false, false, true])
    }

    func testOwnedNullMissingDayAndUnsupportedCurrentResultStayUnavailable() throws {
        for updates: [String: Any] in [["details": NSNull()], ["details": [:]],
            ["details": ["illness": NSNull(), "cycle": NSNull(), "circadian": NSNull(), "daytimeStress": NSNull()]],
            ["capabilities": []], ["status": "no_data"]] {
            let value = try snapshot(updates)
            let view = state(value, active: parents, capable: parents)
            XCTAssertTrue(view.owns(.illnessScore))
            XCTAssertEqual(reads(view), [false, false, false, false])
        }
        XCTAssertEqual(reads(state(try snapshot(), active: parents), day: "2026-09-14"), [false, false, false, false])
    }

    func testContextRejectsUnsafeFlagsAndOutOfBoundEvidence() throws {
        let changes: [(String, String, Any)] = [
            ("illness", "distanceIsAlertGate", true), ("illness", "wellnessOnly", false),
            ("cycle", "awarenessOnly", false), ("cycle", "shiftMarkers", ["2026-09-16"]),
            ("circadian", "measuredTemperatureMinimum", true), ("circadian", "acrophaseHours", 24),
            ("circadian", "habitualWakeHour", -1), ("daytimeStress", "activityMaskedHours", 26),
            ("frequencyHrv", "hfPower", -1)]
        for (family, key, value) in changes {
            var changed = details
            var member = try XCTUnwrap(changed[family] as? [String: Any]); member[key] = value
            changed[family] = member
            XCTAssertThrowsError(try snapshot(["details": changed]), "\(family).\(key)")
        }
    }

    private func motion(start: Int64? = nil, values: [Double?], counts: [Int],
                        method: String = "existing_stager_epoch_motion_observed_mask") -> ServerScoreSleepDiagnostics.Motion {
        .init(start: start ?? self.start, epochSeconds: 30, unit: "gravity_delta_sum", method: method,
              values: values, counts: counts)
    }

    func testMotionKeepsAbsoluteEpochsAndNullHolesWithoutReplacingThemWithZero() {
        let runs = ServerScoreDisplay.motionRuns([motion(values: [0, 2, nil, 4, 5, nil], counts: [1, 1, 0, 1, 1, 0])])
        XCTAssertEqual(runs.map { $0.map(\.timestamp) }, [[start, start + 30], [start + 90, start + 120]])
        XCTAssertEqual(runs.map { $0.map(\.value) }, [[0, 2], [4, 5]])
    }

    func testMotionNeverJoinsSessionsOrConsumesUnknownMethodsAndUnobservedValues() {
        let runs = ServerScoreDisplay.motionRuns([
            motion(start: start + 90, values: [3], counts: [1]),
            motion(values: [1, 2], counts: [1, 0]),
            motion(start: start + 60, values: [9], counts: [1], method: "future")])
        XCTAssertEqual(runs, [[.init(timestamp: start, value: 1)], [.init(timestamp: start + 90, value: 3)]])
        XCTAssertTrue(ServerScoreDisplay.motionRuns([]).isEmpty)
        XCTAssertTrue(ServerScoreDisplay.motionRuns([motion(values: [nil], counts: [0])]).isEmpty)
    }

    private var diagnostics: [String: Any] {
        ["id": sleepID, "editEntity": "sleep:" + sleepID, "start": start, "end": start + 120,
         "isNap": false, "hrOnly": false, "stagingSparse": true, "stagedSeconds": 120,
         "stageCoverage": 0.5, "stageInsights": [],
         "motion": ["start": start, "epochSeconds": 30, "unit": "gravity_delta_sum",
                    "method": "existing_stager_epoch_motion_observed_mask", "values": [0, NSNull(), 2, NSNull()],
                    "counts": [1, 0, 1, 0]]]
    }
    private func diagnosticSnapshot(_ changed: [String: Any]) throws -> ServerScoreSnapshot {
        try snapshot(["capabilities": ["sleep_sessions"],
            "sleep": [["id": sleepID, "start_at": "2026-09-15T00:00:00Z", "end_at": "2026-09-15T00:02:00Z",
                       "is_nap": false, "stages": []]], "details": ["sleep_sessions": [changed]]])
    }

    func testDiagnosticIdentityAndObservedMaskRoundTrip() throws {
        let value = try diagnosticSnapshot(diagnostics)
        let read = ServerScoreDisplay.sleepDiagnostics(day: day, state: state(value, active: [.sleepSessions]))
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.stagingSparse, true)
        XCTAssertEqual(read.first?.motion?.values, [0, nil, 2, nil])
        XCTAssertEqual(try ServerScoreResponse.decode(value.encoded(), requestedDay: day).snapshot, value)
    }

    func testDiagnosticsRejectMismatchedSessionAndFalseObservedZero() throws {
        for changes: [String: Any] in [["id": "40000000-0000-4000-8000-000000000002"],
                                     ["editEntity": "sleep:other"], ["start": start + 30]] {
            var invalid = diagnostics; invalid.merge(changes) { _, new in new }
            XCTAssertThrowsError(try diagnosticSnapshot(invalid))
        }
        var invalid = diagnostics
        var mask = try XCTUnwrap(invalid["motion"] as? [String: Any]); mask["values"] = [0, 0, 2, NSNull()]
        invalid["motion"] = mask
        XCTAssertThrowsError(try diagnosticSnapshot(invalid))
    }
}
