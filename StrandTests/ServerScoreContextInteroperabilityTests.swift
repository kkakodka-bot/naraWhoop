import Foundation
import XCTest
import StrandAnalytics
#if !SERVER_SCORE_NATIVE_TESTS
@testable import Strand
#endif

/// Dedicated gate. The JVM producer must finish successfully before this suite is selected.
final class ServerScoreContextInteroperabilityTests: XCTestCase {
    private let day = "2026-09-15"
    private let filename = "W4-POPULATED-CONTEXT-SNAPSHOT-V2-NATIVE-FIXTURE.json"
    private let fields: Set<ServerScoreMetric> = [.illnessScore, .illnessDistance, .cyclePhase, .circadianPhase, .circadianOffset]
    private enum FixtureError: Error { case missingPath, wrongFilename, invalidObject }

    private func load(path: String?) throws -> [String: Any] {
        guard let path, !path.isEmpty else { throw FixtureError.missingPath }
        let url = URL(fileURLWithPath: path)
        guard url.lastPathComponent == filename else { throw FixtureError.wrongFilename }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError.invalidObject
        }
        return object
    }

    private func fixture() throws -> [String: Any] {
        try load(path: ProcessInfo.processInfo.environment["W4_POPULATED_CONTEXT_FIXTURE"])
    }

    private func decode(_ object: [String: Any]) throws -> ServerScoreSnapshot {
        try XCTUnwrap(ServerScoreResponse.decode(JSONSerialization.data(withJSONObject: object), requestedDay: day).snapshot)
    }

    private func state(_ snapshot: ServerScoreSnapshot, active: Set<ServerScoreMetric>? = nil,
                       configured: Bool = true, authenticated: Bool = true) -> ServerScoreViewState {
        .init(generation: UUID(), revision: 1, currentDay: day, timezone: snapshot.timezone,
              configured: configured, authenticated: authenticated, capabilities: fields, activated: active ?? fields,
              days: [day: .init(snapshot: snapshot, phase: .offline, fetchedAt: nil, cached: true,
                               pending: false, requestedInputRevision: nil, archiveStatus: nil)])
    }

    private func availability(_ view: ServerScoreViewState) -> [Bool] {
        [ServerScoreContextPresentation.cycle(day: day, state: view) != nil,
         ServerScoreContextPresentation.circadian(day: day, state: view) != nil,
         ServerScoreContextPresentation.illness(day: day, state: view) != nil]
    }

    private func family(_ name: String, in object: [String: Any]) throws -> [String: Any] {
        let details = try XCTUnwrap(object["details"] as? [String: Any])
        return try XCTUnwrap(details[name] as? [String: Any], "Dedicated fixture must contain populated \(name)")
    }

    func testDedicatedFixtureLoaderFailsMissingPathAndRejectsOldFixtureName() {
        XCTAssertThrowsError(try load(path: nil))
        XCTAssertThrowsError(try load(path: ""))
        XCTAssertThrowsError(try load(path: "/unused/W4-SNAPSHOT-V2-NATIVE-FIXTURE.json"))
    }

    func testPublishedFullSnapshotContainsEligibleContextAndRoundTrips() throws {
        let object = try fixture(), snapshot = try decode(object)
        XCTAssertEqual(snapshot.schemaVersion, 2)
        XCTAssertEqual(snapshot.userId, "10000000-0000-4000-8000-000000000001")
        XCTAssertEqual(snapshot.sourceDeviceId, "20000000-0000-4000-8000-000000000001")
        XCTAssertEqual(snapshot.algorithmVersion, "frwhoop-server-2-history")
        XCTAssertEqual(snapshot.day, day)
        XCTAssertEqual(snapshot.timezone, "UTC")
        XCTAssertGreaterThan(snapshot.inputRevision, 0)
        XCTAssertGreaterThan(snapshot.resultRevision, 0)
        XCTAssertNotNil(snapshot.dataThrough)
        let dependency = try XCTUnwrap(snapshot.dependency)
        XCTAssertEqual(dependency.stateSchemaVersion, 1)
        XCTAssertGreaterThan(dependency.profileRevision, 0)
        XCTAssertGreaterThan(dependency.configurationRevision, 0)
        XCTAssertGreaterThan(try XCTUnwrap(dependency.predecessorResultRevision), 0)
        XCTAssertEqual(dependency.sourceEra, snapshot.sourceDeviceId)
        XCTAssertEqual(snapshot.coverage.historicalStateAvailable, true)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.coverage.hrSamples), 0)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.coverage.rrIntervals), 0)
        XCTAssertTrue(fields.isSubset(of: snapshot.supported))
        XCTAssertFalse(snapshot.sleep.isEmpty)
        XCTAssertTrue(snapshot.sleep.contains { !$0.stages.isEmpty })
        XCTAssertGreaterThanOrEqual(snapshot.charts?["cycle_index"]?.count ?? 0, 42)
        XCTAssertEqual(snapshot.details?.contextPolicy, "as-of-context-v1")
        XCTAssertNotEqual(try family("cycle", in: object)["phase"] as? String, "learning")
        XCTAssertNotEqual(try family("circadian", in: object)["confidence"] as? String, "unreadable")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(family("illness", in: object)["signalCount"] as? Int), 2)
        let absentGaps = ["journal_context_not_shared", "journal_context_incomplete", "illness_baseline_learning",
                          "cycle_context_not_shared", "cycle_history_learning", "cycle_temperature_baseline_unavailable",
                          "circadian_hourly_history_unavailable", "circadian_rhythm_unreadable", "sleep_schedule_unavailable"]
        XCTAssertTrue(Set(snapshot.coverage.gaps ?? []).isDisjoint(with: absentGaps))
        for mutable in ["requestedInputRevision", "pending", "archiveStatus"] { XCTAssertNil(object[mutable]) }
        XCTAssertEqual(try ServerScoreResponse.decode(snapshot.encoded(), requestedDay: day).snapshot, snapshot)
        XCTAssertEqual(availability(state(snapshot)), [true, true, true])
        XCTAssertNotNil(ServerScoreContextPresentation.illnessDistance(day: day, state: state(snapshot)))
    }

    func testExactActualWireNotesCopyAndOrderedSignalsReachTypedEngineAdapters() throws {
        let object = try fixture(), snapshot = try decode(object), view = state(snapshot)
        let rawCycle = try family("cycle", in: object)
        let cycle = try XCTUnwrap(ServerScoreContextPresentation.cycle(day: day, state: view))
        XCTAssertEqual(cycle.note, try XCTUnwrap(rawCycle["note"] as? String))
        XCTAssertFalse(cycle.note.isEmpty)
        XCTAssertEqual(cycle.phase.rawValue, rawCycle["phase"] as? String)
        XCTAssertEqual(cycle.confidence.rawValue, rawCycle["confidence"] as? String)
        XCTAssertEqual(cycle.cycleDayLow, rawCycle["cycleDayLow"] as? Int)
        XCTAssertEqual(cycle.cycleDayHigh, rawCycle["cycleDayHigh"] as? Int)
        XCTAssertEqual(cycle.cycleLengthDays, rawCycle["cycleLengthDays"] as? Int)
        XCTAssertEqual(cycle.shiftMarkers.map(\.day), try XCTUnwrap(rawCycle["shiftMarkers"] as? [String]))
        let period = rawCycle["nextPeriodWindow"] as? [String: Any]
        XCTAssertEqual(cycle.nextPeriodWindow?.earliestDay, period?["earliestDay"] as? String)
        XCTAssertEqual(cycle.nextPeriodWindow?.latestDay, period?["latestDay"] as? String)

        let rawClock = try family("circadian", in: object)
        let clock = try XCTUnwrap(ServerScoreContextPresentation.circadian(day: day, state: view))
        XCTAssertEqual(clock.note, try XCTUnwrap(rawClock["note"] as? String))
        XCTAssertFalse(clock.note.isEmpty)
        XCTAssertEqual(clock.confidence.rawValue, rawClock["confidence"] as? String)
        XCTAssertEqual(clock.acrophaseHours, try XCTUnwrap(rawClock["acrophaseHours"] as? Double))
        XCTAssertEqual(clock.tempMinHour, snapshot.value(.circadianPhase))
        XCTAssertEqual(clock.offsetVsScheduleMinutes, snapshot.value(.circadianOffset))
        XCTAssertEqual(snapshot.metrics?[ServerScoreMetric.circadianPhase.rawValue]?.unit, "local_hour")
        XCTAssertEqual(snapshot.metrics?[ServerScoreMetric.circadianOffset.rawValue]?.unit, "min")
        XCTAssertEqual(rawClock["measuredTemperatureMinimum"] as? Bool, false)
        XCTAssertNotNil(rawClock["habitualWakeHour"] as? Double)

        let rawIllness = try family("illness", in: object)
        let illness = try XCTUnwrap(ServerScoreContextPresentation.illness(day: day, state: view))
        XCTAssertEqual(illness.copy, try XCTUnwrap(rawIllness["copy"] as? String))
        XCTAssertFalse(illness.copy.isEmpty)
        XCTAssertEqual(illness.firedSignals, try XCTUnwrap(rawIllness["firedSignals"] as? [String]))
        XCTAssertTrue(illness.firedSignals.isEmpty, "The actual caller supplies no labels; count must not fabricate them")
        XCTAssertEqual(illness.signalCount, rawIllness["signalCount"] as? Int)
        XCTAssertEqual(illness.suppressedBy, try XCTUnwrap(rawIllness["suppressedBy"] as? [String]))
        XCTAssertEqual(illness.level.rawValue, rawIllness["level"] as? String)
        XCTAssertEqual(illness.score, snapshot.value(.illnessScore))
        XCTAssertEqual(snapshot.metrics?[ServerScoreMetric.illnessScore.rawValue]?.unit, "score_0_100")
        XCTAssertEqual(snapshot.metrics?[ServerScoreMetric.illnessDistance.rawValue]?.unit, "dimensionless")
        XCTAssertNil(illness.message, "Wire copy is not permission to infer a semantic notification")
        XCTAssertEqual(rawIllness["distanceIsAlertGate"] as? Bool, false)
        XCTAssertEqual(rawIllness["wellnessOnly"] as? Bool, true)
        let distance = try XCTUnwrap(ServerScoreContextPresentation.illnessDistance(day: day, state: view))
        XCTAssertEqual(distance.distance, snapshot.value(.illnessDistance))
        XCTAssertEqual(distance.deviatingFeatures, try XCTUnwrap(rawIllness["distanceDeviatingFeatures"] as? Int))
        XCTAssertTrue((2...4).contains(distance.deviatingFeatures))
        XCTAssertEqual(distance.fires, try XCTUnwrap(rawIllness["distanceFires"] as? Bool))
        XCTAssertEqual(distance.usedDiagonalFallback, try XCTUnwrap(rawIllness["distanceUsedDiagonalFallback"] as? Bool))
        XCTAssertFalse(distance.usedDiagonalFallback)
        XCTAssertEqual(snapshot.metrics?[ServerScoreMetric.illnessDistance.rawValue]?.method, "IllnessDistance_identity_correlation")
    }

    func testOwnedNullAndMissingCurrentResultsNeverResurrectLocalValues() throws {
        var object = try fixture()
        var details = try XCTUnwrap(object["details"] as? [String: Any])
        for name in ["cycle", "circadian", "illness"] { details[name] = NSNull() }
        object["details"] = details
        var metrics = try XCTUnwrap(object["metrics"] as? [String: Any])
        for metric in fields where metric != .cyclePhase {
            var reading = try XCTUnwrap(metrics[metric.rawValue] as? [String: Any])
            reading["value"] = NSNull()
            metrics[metric.rawValue] = reading
        }
        object["metrics"] = metrics
        let view = state(try decode(object))
        XCTAssertEqual(availability(view), [false, false, false])
        XCTAssertNil(ServerScoreContextPresentation.illnessDistance(day: day, state: view))
        for metric in fields {
            XCTAssertTrue(view.owns(metric))
            XCTAssertNil(view.value(metric, day: day, local: 999))
        }
        XCTAssertNil(ServerScoreContextPresentation.cycle(day: "2026-09-14", state: view))
        XCTAssertNil(ServerScoreContextPresentation.circadian(day: "2026-09-14", state: view))
        XCTAssertNil(ServerScoreContextPresentation.illness(day: "2026-09-14", state: view))
        XCTAssertNil(ServerScoreContextPresentation.illnessDistance(day: "2026-09-14", state: view))
    }

    func testIndependentOwnershipAndPerSnapshotCapabilitiesGatePopulatedEvidence() throws {
        var object = try fixture()
        let snapshot = try decode(object)
        for view in [state(snapshot, active: []), state(snapshot, configured: false), state(snapshot, authenticated: false)] {
            XCTAssertEqual(availability(view), [false, false, false])
            XCTAssertNil(ServerScoreContextPresentation.illnessDistance(day: day, state: view))
        }
        XCTAssertEqual(availability(state(snapshot, active: [.cyclePhase])), [true, false, false])
        XCTAssertEqual(availability(state(snapshot, active: [.illnessScore])), [false, false, true])
        XCTAssertEqual(availability(state(snapshot, active: [.illnessDistance])), [false, false, false])
        XCTAssertNotNil(ServerScoreContextPresentation.illnessDistance(day: day, state: state(snapshot, active: [.illnessDistance])))
        XCTAssertNil(ServerScoreContextPresentation.illnessDistance(day: day, state: state(snapshot, active: [.illnessScore])))
        XCTAssertEqual(availability(state(snapshot, active: [.circadianPhase])), [false, false, false])
        XCTAssertEqual(availability(state(snapshot, active: [.circadianPhase, .circadianOffset])), [false, true, false])
        object["capabilities"] = (snapshot.capabilities ?? []).filter { $0 != ServerScoreMetric.circadianOffset.rawValue }
        XCTAssertEqual(availability(state(try decode(object))), [true, false, true])
        object["capabilities"] = []
        let withdrawn = state(try decode(object))
        XCTAssertTrue(withdrawn.owns(.illnessScore))
        XCTAssertEqual(availability(withdrawn), [false, false, false])
        XCTAssertNil(withdrawn.value(.illnessScore, day: day, local: 999))
        XCTAssertNil(ServerScoreContextPresentation.illnessDistance(day: day, state: withdrawn))
    }

    func testMissingExtensionFieldsAndUnknownPolicyDoNotInventEngineResults() throws {
        let original = try fixture()
        for key in ["distanceDeviatingFeatures", "distanceUsedDiagonalFallback"] {
            var object = original, details = try XCTUnwrap(original["details"] as? [String: Any])
            var changed = try family("illness", in: original)
            changed.removeValue(forKey: key)
            details["illness"] = changed; object["details"] = details
            let view = state(try decode(object))
            XCTAssertNil(ServerScoreContextPresentation.illnessDistance(day: day, state: view))
            XCTAssertEqual(availability(view), [true, true, true])
        }
        for (familyName, key, index) in [("cycle", "note", 0), ("circadian", "note", 1),
                                        ("illness", "firedSignals", 2), ("illness", "copy", 2)] {
            var object = original, details = try XCTUnwrap(original["details"] as? [String: Any])
            var changed = try family(familyName, in: original)
            changed.removeValue(forKey: key)
            details[familyName] = changed
            object["details"] = details
            var expected = [true, true, true]; expected[index] = false
            XCTAssertEqual(availability(state(try decode(object))), expected)
        }
        var object = original, details = try XCTUnwrap(original["details"] as? [String: Any])
        details["futureOptionalContext"] = ["version": 99]
        object["details"] = details
        XCTAssertEqual(availability(state(try decode(object))), [true, true, true])
        XCTAssertNotNil(ServerScoreContextPresentation.illnessDistance(day: day, state: state(try decode(object))))
        details["contextPolicy"] = "unsupported-context-policy"
        object["details"] = details
        XCTAssertEqual(availability(state(try decode(object))), [false, false, false])
        XCTAssertNil(ServerScoreContextPresentation.illnessDistance(day: day, state: state(try decode(object))))
    }

    func testUnknownEnumsAndWrongUnitsDoNotConvertSupportedScalarFamilies() throws {
        let original = try fixture()
        for key in ["unit", "method"] {
            var object = original, metrics = try XCTUnwrap(original["metrics"] as? [String: Any])
            var changed = try XCTUnwrap(metrics[ServerScoreMetric.illnessDistance.rawValue] as? [String: Any])
            changed[key] = "unsupported"
            metrics[ServerScoreMetric.illnessDistance.rawValue] = changed; object["metrics"] = metrics
            let view = state(try decode(object))
            XCTAssertNil(ServerScoreContextPresentation.illnessDistance(day: day, state: view))
            XCTAssertEqual(availability(view), [true, true, true])
        }
        for (familyName, key, index) in [("cycle", "phase", 0), ("cycle", "confidence", 0),
                                        ("circadian", "confidence", 1), ("illness", "level", 2)] {
            var object = original, details = try XCTUnwrap(original["details"] as? [String: Any])
            var changed = try family(familyName, in: original)
            changed[key] = "future-enum"
            details[familyName] = changed
            object["details"] = details
            var expected = [true, true, true]; expected[index] = false
            XCTAssertEqual(availability(state(try decode(object))), expected)
        }
        for (key, index) in [(ServerScoreMetric.illnessScore.rawValue, 2), (ServerScoreMetric.circadianPhase.rawValue, 1),
                             (ServerScoreMetric.circadianOffset.rawValue, 1)] {
            var object = original, metrics = try XCTUnwrap(original["metrics"] as? [String: Any])
            var changed = try XCTUnwrap(metrics[key] as? [String: Any])
            changed["unit"] = "unsupported-unit"
            metrics[key] = changed
            object["metrics"] = metrics
            var expected = [true, true, true]; expected[index] = false
            XCTAssertEqual(availability(state(try decode(object))), expected)
        }
    }
}
