import XCTest
import WhoopStore
#if !SERVER_SCORE_NATIVE_TESTS
@testable import Strand
#endif

final class ServerScoreWorkoutDetailsTests: XCTestCase {
    private let day = "2026-09-15"
    private let id = "40000000-0000-4000-8000-000000000001"
    private let otherID = "40000000-0000-4000-8000-000000000002"
    private let start: Int64 = 1789473600
    private var workout: [String: Any] {
        ["id": id, "start": start, "end": start + 180, "durationS": 180, "sport": "Running", "manual": true,
         "editEntity": "workout:" + id, "originalStart": start - 60, "originalSport": "Walking",
         "inputKind": "manual_workout_journal", "inputSource": "user_entered",
         "avgHr": 130.25, "peakHr": 170, "strain": 25.5, "energyKcal": 321, "energyMethod": "user_entered",
         "distanceM": 5000, "steps": 999, "hrCoveragePct": 66.7,
         "zoneSeconds": [0, 60, 0, 30, 0], "zoneMethod": "hrmax_display_zones",
         "displayZoneSeconds": [0, 60, 0, 30, 0], "displayZoneSource": "custom",
         "displayZoneLowerBounds": [90, 110, 130, 150, 170],
         "heartRateRecovery": ["endHr": 170, "after1Minute": 15, "after2Minutes": NSNull(), "after5Minutes": -3, "unit": "bpm_drop"],
         "hrBuckets": [["start": start, "end": start + 60, "value": 120.5, "min": 110, "max": 130, "count": 12],
                       ["start": start + 120, "end": start + 180, "value": 140, "min": 130, "max": 170, "count": 18]],
         "strapSteps": 3, "stepCounterTicks": 6, "stepTicksPerStep": 2,
         "strapStepsMethod": "session_inclusive_activity_class_counter"]
    }
    private func snapshot(workouts: Any? = nil, updates: [String: Any] = [:]) throws -> ServerScoreSnapshot {
        var object: [String: Any] = ["schemaVersion": 2,
            "userId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "sourceDeviceId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "day": day, "timezone": "UTC", "algorithmVersion": "fixture-workouts", "inputRevision": 3, "resultRevision": 5,
            "computedAt": "2026-09-15T13:00:00Z", "status": "partial", "coverage": [:], "sleep": [],
            "capabilities": ["workouts"], "details": ["workouts": workouts ?? [workout]]]
        object.merge(updates) { _, new in new }
        let response = try ServerScoreResponse.decode(JSONSerialization.data(withJSONObject: object), requestedDay: day)
        return try XCTUnwrap(response.snapshot)
    }
    private func state(_ snapshot: ServerScoreSnapshot?, configured: Bool = true, authenticated: Bool = true,
                       capable: Bool = true, active: Bool = true, phase: ServerScoreDayState.Phase = .partial,
                       generation: UUID? = UUID()) -> ServerScoreViewState {
        .init(generation: generation, revision: 1, currentDay: day, timezone: "UTC", configured: configured,
              authenticated: authenticated, capabilities: capable ? [.workouts] : [], activated: active ? [.workouts] : [],
              days: [day: .init(snapshot: snapshot, phase: phase, fetchedAt: Date(), cached: true,
                               pending: phase == .pending, requestedInputRevision: nil, archiveStatus: nil)])
    }
    private func projection(_ value: ServerScoreSnapshot) throws -> ServerScoreWorkoutPresentation.Projection {
        guard case .server(let projection) = ServerScoreWorkoutPresentation.session(id: id, day: day, state: state(value)) else {
            XCTFail("Expected an explicitly owned server workout"); throw ServerScoreDecodeError.invalid
        }
        return projection
    }

    func testJournalWorkoutRoundTripRetainsOriginalIdentityAndUnits() throws {
        let value = try snapshot()
        let row = try XCTUnwrap(value.details?.workouts?.first)
        XCTAssertEqual(row.editEntity, "workout:" + id)
        XCTAssertEqual(row.originalStart, start - 60)
        XCTAssertEqual(row.originalSport, "Walking")
        XCTAssertEqual(row.durationS, 180)
        XCTAssertEqual(row.energyKcal, 321)
        XCTAssertNil(row.energyKJ)
        XCTAssertEqual(row.distanceM, 5000)
        XCTAssertEqual(row.steps, 999)
        XCTAssertEqual(row.strapSteps, 3)
        XCTAssertEqual(try ServerScoreResponse.decode(value.encoded(), requestedDay: day).snapshot, value)

        // LegacyWorkoutReader supplies entered energy/distance/steps, never uploaded HR or strain.
        var uploaded = workout
        uploaded.merge(["manual": false, "inputKind": "legacy_uploaded_workout", "inputSource": "apple_health",
                        "energyMethod": "imported:apple_health", "avgHr": NSNull(), "peakHr": NSNull(),
                        "strain": NSNull(), "hrBuckets": [], "heartRateRecovery": NSNull(),
                        "displayZoneSeconds": NSNull(), "zoneSeconds": NSNull()]) { _, new in new }
        for key in ["strapSteps", "stepCounterTicks", "strapStepsMethod", "stepTicksPerStep"] { uploaded.removeValue(forKey: key) }
        let legacy = try projection(snapshot(workouts: [uploaded]))
        XCTAssertEqual(legacy.workout.energyMethod, "imported:apple_health")
        XCTAssertEqual(legacy.row.energyKcal, 321)
        XCTAssertNil(legacy.row.avgHr); XCTAssertNil(legacy.row.strain); XCTAssertNil(legacy.strapSteps)
    }

    func testComputedWorkoutPreservesHRRMetadataWithoutReusingItAsDisplayZones() throws {
        var computed = workout
        for key in ["editEntity", "originalStart", "originalSport", "inputKind", "inputSource", "zoneSeconds"] { computed.removeValue(forKey: key) }
        computed.merge(["manual": false, "sport": "Activity", "energyKJ": 1343.064, "energyMethod": "hr_estimate",
                        "zoneMethod": "edwards_hrr_samples", "zoneTimePct": ["0": 20, "1": 30, "2": 50],
                        "avgHrrPct": 45.5, "hrmax": 190, "hrmaxSource": "tanaka", "displayZoneSeconds": NSNull(),
                        "strapSteps": NSNull(), "stepCounterTicks": NSNull(), "stepTicksPerStep": NSNull()]) { _, new in new }
        let value = try snapshot(workouts: [computed])
        let displayed = try projection(value)
        XCTAssertEqual(displayed.workout.zoneTimePct, ["0": 20, "1": 30, "2": 50])
        XCTAssertEqual(displayed.workout.energyKJ, 1343.064)
        XCTAssertNil(displayed.displayZones)
        XCTAssertNil(displayed.row.zonesJSON)
        XCTAssertNil(displayed.strapSteps)
        XCTAssertEqual(try ServerScoreResponse.decode(value.encoded(), requestedDay: day).snapshot, value)
    }

    func testMalformedOrPartialIdentityAndDuplicateUUIDRejected() throws {
        for changes: [String: Any] in [["id": "not-a-uuid"], ["editEntity": "workout:" + otherID],
            ["originalStart": 0], ["originalSport": ""], ["inputSource": NSNull()], ["manual": false]] {
            var bad = workout; bad.merge(changes) { _, new in new }
            XCTAssertThrowsError(try snapshot(workouts: [bad]))
        }
        var partial = workout; partial.removeValue(forKey: "originalStart")
        XCTAssertThrowsError(try snapshot(workouts: [partial]))
        XCTAssertThrowsError(try snapshot(workouts: [workout, workout]))
    }

    func testBoundsNumbersAndZoneShapesAreValidatedWithoutClamping() throws {
        for changes: [String: Any] in [["end": start], ["durationS": 179], ["start": -1], ["energyKcal": -1],
            ["distanceM": 1e40], ["hrCoveragePct": 101], ["strapSteps": 0], ["steps": 0.5],
            ["zoneSeconds": [1, 2]], ["displayZoneSeconds": [0, 0, -1, 0, 0]],
            ["displayZoneLowerBounds": [90, 110, 100, 150, 170]], ["zoneTimePct": ["6": 20]]] {
            var bad = workout; bad.merge(changes) { _, new in new }
            XCTAssertThrowsError(try snapshot(workouts: [bad]))
        }
        var tail = workout; tail["displayZoneSeconds"] = [0, 240, 0, 0, 0]
        XCTAssertEqual(try projection(snapshot(workouts: [tail])).displayZones?.minutes, [0, 4, 0, 0, 0])
    }

    func testInvalidBucketsAreRejectedAndObservedGapsRemain() throws {
        let buckets = try XCTUnwrap(workout["hrBuckets"] as? [[String: Any]])
        for changes: [String: Any] in [["start": start - 60], ["end": start + 61], ["count": 0],
                                     ["value": 300], ["min": 125], ["max": 115]] {
            var first = buckets[0]; first.merge(changes) { _, new in new }
            var bad = workout; bad["hrBuckets"] = [first, buckets[1]]
            XCTAssertThrowsError(try snapshot(workouts: [bad]))
        }
        var duplicate = workout; duplicate["hrBuckets"] = [buckets[0], buckets[0]]
        XCTAssertThrowsError(try snapshot(workouts: [duplicate]))
        let runs = try projection(snapshot()).heartRateRuns
        XCTAssertEqual(runs.map { $0.map(\.ts) }, [[Int(start)], [Int(start + 120)]])
        XCTAssertEqual(runs.map { $0.map(\.bpm) }, [[120.5], [140]])
    }

    func testUnknownOptionalNotesAndRoutePayloadNeverEnterCacheOrProjection() throws {
        var supplied = workout
        supplied["notes"] = "PRIVATE_NOTE_FIXTURE"
        supplied["route"] = ["polyline": "PRIVATE_ROUTE_FIXTURE"]
        supplied["route_polyline"] = "PRIVATE_POLYLINE_FIXTURE"
        supplied["futureOptional"] = ["enabled": true]
        let value = try snapshot(workouts: [supplied])
        let bytes = try value.encoded()
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE_"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let encodedDetails = try XCTUnwrap(object["details"] as? [String: Any])
        let encoded = try XCTUnwrap((encodedDetails["workouts"] as? [[String: Any]])?.first)
        for key in ["notes", "route", "route_polyline", "futureOptional"] { XCTAssertNil(encoded[key]) }
        XCTAssertNil(try projection(value).row.notes)
    }

    func testEveryOwnershipGateMustHoldBeforeLocalPathIsSuppressed() throws {
        let value = try snapshot()
        for view in [state(value, configured: false), state(value, authenticated: false),
                     state(value, capable: false), state(value, active: false)] {
            XCTAssertEqual(ServerScoreWorkoutPresentation.day(day, state: view), .local)
            XCTAssertEqual(ServerScoreWorkoutPresentation.session(id: id, day: day, state: view), .local)
        }
        XCTAssertNotEqual(ServerScoreWorkoutPresentation.day(day, state: state(value)), .local)
    }

    func testOwnedMissingNullAndUnsupportedNeverSelectLocal() throws {
        XCTAssertEqual(ServerScoreWorkoutPresentation.day(day, state: state(nil)), .unavailable(.missingSnapshot))
        for updates: [String: Any] in [["details": NSNull()], ["details": [:]], ["details": ["workouts": NSNull()]]] {
            let value = try snapshot(updates: updates)
            XCTAssertEqual(ServerScoreWorkoutPresentation.day(day, state: state(value)), .unavailable(.missingDetails))
        }
        let unsupported = try snapshot(updates: ["capabilities": ["recovery"]])
        XCTAssertEqual(ServerScoreWorkoutPresentation.day(day, state: state(unsupported)), .unavailable(.unsupportedResult))
        XCTAssertEqual(ServerScoreWorkoutPresentation.day("2026-09-14", state: state(try snapshot())), .unavailable(.missingSnapshot))
    }

    func testEmptyAndNoDataAreAuthoritativeSetsNotLocalFallback() throws {
        for value in [try snapshot(workouts: []), try snapshot(updates: ["status": "no_data", "details": NSNull()])] {
            XCTAssertEqual(ServerScoreWorkoutPresentation.day(day, state: state(value)), .server([]))
            XCTAssertEqual(ServerScoreWorkoutPresentation.session(id: id, day: day, state: state(value)), .unavailable(.missingSession))
        }
    }

    func testCorrectedStableIdentityReplacesBoundsWithoutReattachingAnOldNaturalKey() throws {
        var moved = workout
        moved["start"] = start + 3600; moved["end"] = start + 3780; moved["sport"] = "Hiking"; moved["hrBuckets"] = []
        let updated = try snapshot(workouts: [moved], updates: ["inputRevision": 4, "resultRevision": 6])
        let result = try projection(updated)
        XCTAssertEqual(result.workout.id, id)
        XCTAssertEqual(result.workout.originalStart, start - 60)
        XCTAssertEqual(result.row.startTs, Int(start + 3600))
        XCTAssertEqual(result.row.sport, "Hiking")
        XCTAssertEqual(result.provenance.resultRevision, 6)
        XCTAssertTrue(result.heartRateRuns.isEmpty)
    }

    func testDifferentUUIDAtSameBoundsCannotResurrectSelectedSession() throws {
        var replacement = workout
        replacement["id"] = otherID; replacement["editEntity"] = "workout:" + otherID
        let view = state(try snapshot(workouts: [replacement]))
        XCTAssertEqual(ServerScoreWorkoutPresentation.session(id: id, day: day, state: view), .unavailable(.missingSession))
        XCTAssertEqual(ServerScoreWorkoutPresentation.session(id: "bad", day: day, state: view), .unavailable(.invalidIdentity))
        guard case .server(let row) = ServerScoreWorkoutPresentation.session(id: otherID.uppercased(), day: day, state: view) else {
            return XCTFail("Stable UUID selection should be case insensitive")
        }
        XCTAssertEqual(row.workout.id, otherID)
    }

    func testOwnedNullScalarsNeverReadLocalRowOrDerivedCalorieFallback() throws {
        var missing = workout
        for key in ["avgHr", "peakHr", "strain", "energyKcal", "distanceM", "steps", "displayZoneSeconds", "heartRateRecovery", "strapSteps"] {
            missing[key] = NSNull()
        }
        missing["energyKJ"] = 1000; missing["hrBuckets"] = []
        let row = try projection(snapshot(workouts: [missing]))
        XCTAssertNil(row.row.avgHr); XCTAssertNil(row.row.maxHr); XCTAssertNil(row.row.strain)
        XCTAssertNil(row.row.energyKcal); XCTAssertNil(row.row.distanceM); XCTAssertNil(row.row.steps)
        XCTAssertNil(row.displayZones); XCTAssertNil(row.heartRateRecovery); XCTAssertNil(row.strapSteps)
        XCTAssertTrue(row.heartRateRuns.isEmpty)
        XCTAssertEqual(row.row.source, "server_scoring")
    }

    func testDisplayZoneSecondsConvertOnlyToMinutesAndKeepActualBoundaries() throws {
        let row = try projection(snapshot())
        XCTAssertEqual(row.displayZones?.minutes, [0, 1, 0, 0.5, 0])
        XCTAssertEqual(row.displayZones?.lowerBoundsBPM, [90, 110, 130, 150, 170])
        XCTAssertEqual(row.displayZones?.source, "custom")
        XCTAssertNil(row.row.zonesJSON)
        var unknown = workout; unknown["displayZoneSource"] = "future_zone_policy"
        XCTAssertNil(try projection(snapshot(workouts: [unknown])).displayZones)
    }

    func testImportedAndStrapStepsStaySeparateWithoutPedometerOrCadenceFallback() throws {
        let row = try projection(snapshot())
        XCTAssertEqual(row.row.steps, 999)
        XCTAssertEqual(row.strapSteps?.count, 3)
        XCTAssertEqual(row.strapSteps?.counterTicks, 6)
        XCTAssertEqual(row.strapSteps?.ticksPerStep, 2)
        for changes: [String: Any] in [["strapSteps": NSNull()], ["strapStepsMethod": "future_counter"], ["sport": "Cycling"]] {
            var unknown = workout; unknown.merge(changes) { _, new in new }
            let projection = try projection(snapshot(workouts: [unknown]))
            XCTAssertNil(projection.strapSteps)
            XCTAssertEqual(projection.row.steps, 999)
        }
    }

    func testRecoveryKeepsNegativeDropAndNilMinutesAndRejectsUnknownUnitForDisplay() throws {
        let recovery = try XCTUnwrap(projection(snapshot()).heartRateRecovery)
        XCTAssertEqual(recovery.endHR, 170)
        XCTAssertEqual(recovery.after1Minute, 15)
        XCTAssertNil(recovery.after2Minutes)
        XCTAssertEqual(recovery.after5Minutes, -3)
        var unknown = workout
        unknown["heartRateRecovery"] = ["endHr": 170, "after1Minute": 15, "unit": "percent"]
        XCTAssertNil(try projection(snapshot(workouts: [unknown])).heartRateRecovery)
        unknown["heartRateRecovery"] = ["endHr": 170, "unit": "bpm_drop"]
        XCTAssertNil(try projection(snapshot(workouts: [unknown])).heartRateRecovery)
    }

    func testRetainedCachedSnapshotDuringFailureDoesNotReenableLocalPath() throws {
        let snapshot = try snapshot()
        for phase: ServerScoreDayState.Phase in [.pending, .failed, .offline, .unsupported] {
            guard case .server(let rows) = ServerScoreWorkoutPresentation.day(day, state: state(snapshot, phase: phase)) else {
                return XCTFail("Compatible retained snapshot remains authoritative")
            }
            XCTAssertEqual(rows.map(\.workout.id), [id])
        }
        XCTAssertEqual(ServerScoreWorkoutPresentation.day(day, state: state(nil, phase: .pending)), .unavailable(.missingSnapshot))
    }

    func testProjectionCarriesOwnerSourceGenerationAndResultProvenance() throws {
        let generation = UUID()
        let snapshot = try snapshot()
        XCTAssertEqual(ServerScoreWorkoutPresentation.day(day, state: state(snapshot, generation: nil)), .unavailable(.missingIdentity))
        guard case .server(let rows) = ServerScoreWorkoutPresentation.day(day, state: state(snapshot, generation: generation)) else {
            return XCTFail("Expected server set")
        }
        let provenance = try XCTUnwrap(rows.first?.provenance)
        XCTAssertEqual(provenance.generation, generation)
        XCTAssertEqual(provenance.userID, snapshot.userId)
        XCTAssertEqual(provenance.sourceDeviceID, snapshot.sourceDeviceId)
        XCTAssertEqual(provenance.timeZoneID, "UTC")
        XCTAssertEqual(provenance.day, day)
        XCTAssertEqual(provenance.algorithmVersion, "fixture-workouts")
        XCTAssertEqual(provenance.inputRevision, 3)
        XCTAssertEqual(provenance.resultRevision, 5)
    }

    func testActualServerFixtureWorkoutEnvelopeRoundTrips() throws {
        #if SERVER_SCORE_NATIVE_TESTS
        guard let path = CommandLine.arguments.dropFirst().first, !path.isEmpty else {
            throw XCTSkip("Pass the generated synthetic server fixture as the runner's fourth argument")
        }
        #else
        guard let path = ProcessInfo.processInfo.environment["W4_SERVER_SCORE_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("External generated server fixture is exercised by the native harness")
        }
        #endif
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let fixtureDay = try XCTUnwrap(object["day"] as? String)
        let rawDetails = try XCTUnwrap(object["details"] as? [String: Any])
        let rawWorkouts = try XCTUnwrap(rawDetails["workouts"] as? [[String: Any]])
        let response = try ServerScoreResponse.decode(bytes, requestedDay: fixtureDay)
        let value = try XCTUnwrap(response.snapshot)
        XCTAssertEqual(value.details?.workouts?.map(\.id), rawWorkouts.compactMap { $0["id"] as? String })
        XCTAssertEqual(try ServerScoreResponse.decode(value.encoded(), requestedDay: fixtureDay).snapshot, value)
        print("Actual synthetic server workout fixture decoded: \(rawWorkouts.count) workout(s); empty sets do not certify populated interoperability")
    }
}
