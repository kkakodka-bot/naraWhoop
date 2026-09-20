import Foundation
import WhoopProtocol
import XCTest
@testable import StrandAnalytics

final class ServerDaySwiftV3WorkoutsTests: XCTestCase {
    private typealias F = S14Fixtures
    private typealias C = ServerDaySwiftContract
    private typealias V = ServerDaySwiftV3Contract
    private typealias X = ServerDaySwiftV3Context
    private typealias M = ServerDaySwiftV3Metrics
    private typealias W = ServerDaySwiftV3Workouts
    private typealias D = ServerDaySwiftV3Metadata
    private typealias S = ServerDaySwiftV3Selection
    private let id = "66666666-6666-4666-8666-666666666666"

    func test00TypedOutputRetainsInt64JournalRevisionsAndOriginalRowOrder() async throws {
        let x = try await X.run(S10Fixtures.input())
        // Serialization-only extremes: this does not admit them through the safe-integer input gate.
        let revisions: [Int64] = [Int64.max, 9_007_199_254_740_993, 9_007_199_254_740_991, 17, Int64.min]
        let rows: [C.JournalRow] = revisions.enumerated().map { index, revision in
            C.JournalRow(userId: S10Fixtures.owner, sourceDeviceId: S10Fixtures.device, kind: .manualWorkout,
                entity: "encoding-row-\(index)", revision: revision, effectiveDay: x.observation.input.day,
                deleted: index == 3, payload: index == 3 ? [:] : ["schemaVersion": .number(1),
                    "explicitNull": .null, "observedZero": .number(0), "flag": .bool(false),
                    "ordered": .array([.string("second"), .string("first")]), "originalText": .string("unaltered")])
        }
        let entry = W.Entry(entity: "workout:" + id, originalStart: 10, originalSport: "Running",
            start: 20, end: 30, sport: "Walking", dismissed: false, manual: true, legacySource: nil,
            energyKcal: nil, distanceM: nil, steps: nil, inputRevision: Int64.max)
        let resolution = W.Resolution(scope: D.Scope(x), originalRows: rows, originalLegacy: [],
            manual: [entry], legacy: [], retainedTombstones: [rows[3]])
        let sessions: [C.JSON] = [.object(["id": .string("second"), "avgHr": .null]),
                                  .object(["id": .string("first"), "avgHr": .number(0)])]
        let output = W.Output(resolution: resolution, sessions: sessions, count: nil, strengthMin: nil,
            selectedHrIDs: ["second": ["hr-2", "hr-1"]], rejectedEntries: ["b", "a"], gaps: ["later", "earlier"])
        struct EntryProbe: Decodable { let inputRevision: Int64? }
        struct ResolutionProbe: Decodable {
            let scope: D.Scope
            let originalRows: [C.JournalRow]
            let manual: [EntryProbe]
            let retainedTombstones: [C.JournalRow]
        }
        struct OutputProbe: Decodable {
            let resolution: ResolutionProbe
            let sessions: [C.JSON]
            let count: Int?
            let strengthMin: Double?
            let selectedHrIDs: [String: [String]]
            let rejectedEntries: [String]
            let gaps: [String]
        }
        let bytes = try JSONEncoder().encode(output)
        let decoded = try JSONDecoder().decode(OutputProbe.self, from: bytes)
        XCTAssertEqual(decoded.resolution.originalRows, rows)
        XCTAssertEqual(decoded.resolution.originalRows.map(\.revision), revisions)
        XCTAssertEqual(decoded.resolution.manual[0].inputRevision, Int64.max)
        XCTAssertEqual(decoded.resolution.retainedTombstones, [rows[3]])
        XCTAssertEqual(decoded.resolution.scope, D.Scope(x))
        XCTAssertEqual(decoded.sessions, sessions)
        XCTAssertEqual(decoded.selectedHrIDs, output.selectedHrIDs)
        XCTAssertEqual(decoded.rejectedEntries, output.rejectedEntries)
        XCTAssertEqual(decoded.gaps, output.gaps)
        XCTAssertNil(decoded.count); XCTAssertNil(decoded.strengthMin)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["resolution", "sessions", "count", "strengthMin", "selectedHrIDs", "rejectedEntries", "gaps"])
        XCTAssertTrue(object["count"] is NSNull); XCTAssertTrue(object["strengthMin"] is NSNull)
        let resolved = try XCTUnwrap(object["resolution"] as? [String: Any])
        XCTAssertEqual(Set(resolved.keys), ["scope", "originalRows", "originalLegacy", "manual", "legacy", "retainedTombstones"])
        let encodedRows = try XCTUnwrap(resolved["originalRows"] as? [[String: Any]])
        XCTAssertEqual(encodedRows.count, rows.count)
        for row in encodedRows {
            XCTAssertEqual(Set(row.keys), ["userId", "sourceDeviceId", "kind", "entity", "revision", "effectiveDay", "deleted", "payload"])
        }
        let payload = try XCTUnwrap(encodedRows[0]["payload"] as? [String: Any])
        XCTAssertTrue(payload["explicitNull"] is NSNull); XCTAssertNil(payload["absent"])
    }

    func test00TypedOutputKeepsNestedNilMembersDistinctFromObservedZero() async throws {
        let x = try await X.run(S10Fixtures.input())
        let legacy = W.Legacy(owner: S10Fixtures.owner, device: S10Fixtures.device, id: UUID(uuidString: id)!,
            start: 10, end: 20, sport: "Running", source: "synthetic", userModified: false,
            energyKcal: nil, distanceM: nil, steps: nil, updatedAt: 30, algorithmIsServerOwned: false)
        let missing = W.Entry(entity: "workout:" + id, originalStart: 10, originalSport: "Running", start: 10, end: 20,
            sport: "Running", dismissed: false, manual: true, legacySource: nil, energyKcal: nil,
            distanceM: nil, steps: nil, inputRevision: nil)
        let observed = W.Entry(entity: "workout:observed", originalStart: 10, originalSport: "Running", start: 10, end: 20,
            sport: "Running", dismissed: false, manual: false, legacySource: "synthetic", energyKcal: 0,
            distanceM: 0, steps: 0, inputRevision: 1)
        let resolution = W.Resolution(scope: D.Scope(x), originalRows: [], originalLegacy: [legacy],
            manual: [missing, observed], legacy: [missing], retainedTombstones: [])
        let output = W.Output(resolution: resolution, sessions: [], count: 0, strengthMin: 0,
            selectedHrIDs: [:], rejectedEntries: [], gaps: [])
        let bytes = try JSONEncoder().encode(output)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["count"] as? Int, 0); XCTAssertEqual(object["strengthMin"] as? Double, 0)
        let resolved = try XCTUnwrap(object["resolution"] as? [String: Any])
        let entries = try XCTUnwrap(resolved["manual"] as? [[String: Any]])
        let expectedEntryKeys: Set<String> = ["entity", "originalStart", "originalSport", "start", "end", "sport", "dismissed", "manual",
            "legacySource", "energyKcal", "distanceM", "steps", "inputRevision"]
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries[0].keys), expectedEntryKeys); XCTAssertEqual(Set(entries[1].keys), expectedEntryKeys)
        for key in ["legacySource", "energyKcal", "distanceM", "steps", "inputRevision"] { XCTAssertTrue(entries[0][key] is NSNull, key) }
        XCTAssertEqual(entries[1]["legacySource"] as? String, "synthetic")
        for key in ["energyKcal", "distanceM", "steps"] { XCTAssertEqual(entries[1][key] as? Double, 0, key) }
        XCTAssertEqual(entries[1]["inputRevision"] as? Int, 1)
        let legacyEntries = try XCTUnwrap(resolved["legacy"] as? [[String: Any]])
        for key in ["legacySource", "energyKcal", "distanceM", "steps", "inputRevision"] { XCTAssertTrue(legacyEntries[0][key] is NSNull, key) }
        let originals = try XCTUnwrap(resolved["originalLegacy"] as? [[String: Any]])
        XCTAssertEqual(Set(originals[0].keys), ["owner", "device", "id", "start", "end", "sport", "source", "userModified",
            "energyKcal", "distanceM", "steps", "updatedAt", "algorithmIsServerOwned"])
        for key in ["energyKcal", "distanceM", "steps"] { XCTAssertTrue(originals[0][key] is NSNull, key) }
        XCTAssertEqual(originals[0]["owner"] as? String, legacy.owner.uuidString)
        XCTAssertEqual(originals[0]["device"] as? String, legacy.device.uuidString)
        XCTAssertEqual(originals[0]["id"] as? String, legacy.id.uuidString)
        XCTAssertEqual(originals[0]["sport"] as? String, legacy.sport)
        XCTAssertEqual(originals[0]["source"] as? String, legacy.source)
    }

    private func assertCycleNativeWorkouts(_ out: M.Execution, file: StaticString = #filePath, line: UInt = #line) async throws {
        let o = out.native.context.observation, cycle = o.cycle
        let seed = try await S.seed(o.input)
        let selected = try await ServerDaySwiftV3Cycle.load(seed, window: cycle.window.native)
        let profile = try M.userProfile(o.selection.effectiveProfile)
        let maxHR = try C.number(o.selection.effectiveConfig, "maxHR") ?? StrainScorer.tanakaHRmax(age: profile.age)
        var funnel: WorkoutDetector.DetectionFunnel?
        let expected = WorkoutDetector.detect(hr: selected.hr, gravity: selected.gravity,
            restingHR: o.native.daily.restingHr.map(Double.init), maxHR: maxHR, age: profile.age, profile: profile,
            effortMethod: o.checkpoint.policy.effortMethod == "BANISTER" ? .banister : .edwards,
            funnel: { funnel = $0 })
        XCTAssertTrue(cycle.appliesToDay, file: file, line: line)
        XCTAssertFalse(expected.isEmpty, file: file, line: line)
        XCTAssertEqual(selected.selected, cycle.selected, file: file, line: line)
        XCTAssertEqual(out.native.workouts.sessions.count, expected.count, file: file, line: line)
        XCTAssertEqual(out.projection.details["workout_detection"], try ServerDaySwiftV3CoreProbe.reflect(funnel as Any), file: file, line: line)
        for (session, native) in zip(out.native.workouts.sessions, expected) {
            let value = try V.object(session), id = W.detectedID(D.Scope(out.native.context), native.start)
            XCTAssertEqual(value["id"], .string(id), file: file, line: line)
            XCTAssertEqual(value["start"], D.integer(native.start), file: file, line: line)
            XCTAssertEqual(value["end"], D.integer(native.end), file: file, line: line)
            XCTAssertEqual(value["strain"], D.number(native.strain), file: file, line: line)
            XCTAssertEqual(value["energyKcal"], D.number(native.caloriesKcal), file: file, line: line)
            XCTAssertEqual(value["zoneTimePct"], try ServerDaySwiftV3CoreProbe.reflect(native.zoneTimePct), file: file, line: line)
            let ids = selected.selected["hr", default: []].filter { row in
                row.ts >= native.start && row.ts < native.end && ((try? V.number(row.fields["bpm"])).map { (20...250).contains($0) } ?? false)
            }.map(\.id)
            XCTAssertEqual(out.native.workouts.selectedHrIDs[id], ids, file: file, line: line)
            XCTAssertGreaterThanOrEqual(native.start, cycle.window.startInclusive, file: file, line: line)
            XCTAssertLessThan(native.start, cycle.window.endExclusive, file: file, line: line)
            XCTAssertLessThanOrEqual(native.end, o.input.asOfExclusive, file: file, line: line)
        }
    }

    func testP2AutomaticDetectionUsesSleepOnsetWindowNotCalendarBouts() async throws {
        let input = try S14RepairFixtures.onsetDay(), x = try await X.run(input)
        let start = x.observation.cycle.window.startInclusive
        XCTAssertEqual(start, try V.validate(input).dayLo + 3_600)
        XCTAssertTrue(x.observation.native.workouts.contains { $0.start < start }, "Calendar control really detects the excluded bout")
        XCTAssertTrue(x.observation.native.workouts.contains { $0.start >= start })
        let out = try await M.evaluate(context: x, supplements: M.Supplements(x))
        try await assertCycleNativeWorkouts(out)
        XCTAssertLessThan(out.native.workouts.sessions.count, x.observation.native.workouts.count)
        XCTAssertEqual(out.native.context.observation.input.raw, input.raw)
        XCTAssertEqual(out.projection.metrics["exercise_count"]?.value, Double(out.native.workouts.sessions.count))
    }

    func testP2AutomaticDetectionIncludesPreviousEveningAndRetainsExcludedRows() async throws {
        var input = S14RepairFixtures.configured(try S10Fixtures.input("s14-evening-cycle"), ["dayCycleMode": .string("sleep_onset")])
        let lo = try V.validate(input).dayLo, workoutStart = lo - 3_600
        S14RepairFixtures.sleep(&input, start: lo - 7_200, end: lo + 10_800, awake: workoutStart..<(workoutStart + 2_101))
        S14RepairFixtures.burst(&input, start: workoutStart)
        S14RepairFixtures.burst(&input, start: lo + 36_000)
        S10Fixtures.append(&input, .hr, input.asOfExclusive, ["bpm": .number(200)], id: "future-bout-row")
        S10Fixtures.append(&input, .hr, workoutStart, ["bpm": .number(240)], id: "foreign-bout-row", owner: S10Fixtures.foreign)
        let x = try await X.run(input)
        XCTAssertEqual(x.observation.cycle.window.startInclusive, lo - 7_200)
        XCTAssertTrue(x.observation.native.workouts.allSatisfy { $0.start >= lo })
        let out = try await M.evaluate(context: x, supplements: M.Supplements(x))
        try await assertCycleNativeWorkouts(out)
        let starts = try out.native.workouts.sessions.map { try V.integer(V.object($0)["start"]) }
        XCTAssertTrue(starts.contains { $0 < lo }, "Actual native detector receives previous-evening cycle rows")
        XCTAssertEqual(out.native.context.observation.input.raw, input.raw)
        let selected = out.native.workouts.selectedHrIDs.values.flatMap { $0 }
        XCTAssertFalse(selected.contains("future-bout-row")); XCTAssertFalse(selected.contains("foreign-bout-row"))
        XCTAssertTrue(selected.contains { $0.hasPrefix("burst-hr-") })
    }

    func testP2OtherDisplayDayCannotPublishCalendarAutomaticWorkouts() async throws {
        var first = S14RepairFixtures.configured(try S10Fixtures.input("s14-workout-prior", day: "2026-06-14"), ["dayCycleMode": .string("sleep_onset")])
        let lo = try V.validate(first).dayLo
        S14RepairFixtures.sleep(&first, start: lo + 20 * 3_600, end: lo + 23 * 3_600 + 1_800)
        let prior = try await X.run(first), detail = try await M.evaluate(context: prior, supplements: M.Supplements(prior))
        XCTAssertEqual(prior.observation.cycle.window.source, "edited_sleep")
        var input = S14RepairFixtures.configured(try S10Fixtures.input("s14-workout-other-display"), ["dayCycleMode": .string("sleep_onset")])
        input.historyCaseIds = [first.id]
        S14RepairFixtures.burst(&input, start: try V.validate(input).dayLo + 36_000)
        let x = try await X.run(input, history: [prior.prior])
        XCTAssertFalse(x.observation.cycle.appliesToDay)
        XCTAssertFalse(x.observation.native.workouts.isEmpty, "Positive calendar detection must not leak across ownership")
        let out = try await M.evaluate(context: x, history: [prior], supplements: M.Supplements(x), priorDetails: [detail.prior])
        XCTAssertTrue(out.native.workouts.sessions.isEmpty)
        XCTAssertTrue(out.native.workouts.selectedHrIDs.isEmpty)
        XCTAssertNil(out.native.workouts.count); XCTAssertNil(out.projection.metrics["exercise_count"]?.value)
        XCTAssertEqual(out.projection.details["workout_detection"], .null)
        XCTAssertEqual(out.native.context.observation.input.raw, input.raw)
    }

    func testP2AdmittedMaxHROverrideAndRevisionReachDisplayAndManualNativeRescore() async throws {
        let input = S14RepairFixtures.configured(try signals(), ["maxHR": .number(180)])
        let x = try await X.run(input), supplements = M.Supplements(x)
        XCTAssertEqual(supplements.presentationPreferences.maxHR, 180)
        XCTAssertEqual(supplements.presentationPreferences.inputRevision, 2)
        XCTAssertEqual(supplements.presentationPreferences.provenance, "s13_effective_configuration")
        XCTAssertNil(supplements.presentationPreferences.customZoneLowerBounds)
        let automatic = try await M.evaluate(context: x, supplements: supplements)
        XCTAssertEqual(try V.object(automatic.projection.details["hr_zones"]!)["maxHR"], .number(180))
        XCTAssertEqual(try V.object(automatic.projection.details["hr_zones"]!)["source"], .string("manual"))
        try await assertCycleNativeWorkouts(automatic)
        let original = try XCTUnwrap(x.observation.native.workouts.first)
        XCTAssertEqual(original.hrmax, 180)
        let row = manual(x, originalStart: original.start)
        let out = try await run(x, rows: [row]), value = try V.object(XCTUnwrap(out.sessions.first))
        let loaded = try await S.load(S.seed(input)), profile = try M.userProfile(loaded.evidence.effectiveProfile)
        let start = try V.integer(row.payload["start"]), end = try V.integer(row.payload["end"])
        let hr = loaded.hr.filter { $0.ts >= start && $0.ts < end }
        let rest = x.observation.native.daily.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        XCTAssertEqual(value["strain"], D.number(StrainScorer.strain(hr, maxHR: 180, restingHR: rest, method: .edwards, sex: profile.sex)))
        XCTAssertEqual(value["energyKcal"], D.number(Calories.estimateBoutCalories(hr, profile: profile, hrmax: 180, restingHR: rest).0))
        let expectedZones = HRZones.zones(maxHR: 180, source: "manual")
        XCTAssertEqual(value["zoneSeconds"], try ServerDaySwiftV3CoreProbe.reflect(HRZones.timeInZone(hr, zoneSet: expectedZones).seconds))
        XCTAssertEqual(automatic.native.context.digest, x.digest)
    }

    private func signals() throws -> V.Input {
        var input = try S10Fixtures.input("s14-workout")
        let lo = try V.validate(input).dayLo + 36_000
        for offset in 0...2_100 {
            S10Fixtures.append(&input, .hr, lo + offset, ["bpm": .number(offset < 1_800 ? 170 : 90)])
            S10Fixtures.append(&input, .gravity, lo + offset, ["x": .number(offset % 2 == 0 ? 0 : 1), "y": .number(0), "z": .number(1)])
            if offset % 30 == 0 { S10Fixtures.append(&input, .steps, lo + offset, ["counter": .number(Double(offset)), "activityClass": .number(1)]) }
        }
        return input
    }
    private func manual(_ x: X.Execution, revision: Int64 = 100, id: String? = nil, start: Int? = nil,
                        end: Int? = nil, originalStart: Int? = nil, dismissed: Bool = false, sport: String = "Running",
                        energy: Double? = nil, distance: Double? = nil, steps: Int? = nil) -> C.JournalRow {
        let input = x.observation.input, lo = x.observation.selection.bounds.dayLo + 36_000
        let start = start ?? lo, end = end ?? (lo + 1_800)
        return .init(userId: input.identity.userId, sourceDeviceId: input.identity.sourceDeviceId, kind: .manualWorkout,
            entity: "workout:" + (id ?? self.id), revision: revision, effectiveDay: input.day, deleted: false,
            payload: ["schemaVersion": .number(1), "timezone": .string(input.timezone), "originalStart": .number(Double(originalStart ?? lo)),
                "originalSport": .string("Running"), "start": .number(Double(start)), "end": .number(Double(end)), "sport": .string(sport),
                "dismissed": .bool(dismissed), "energyKcal": D.number(energy), "distanceM": D.number(distance), "steps": D.integer(steps),
                "consent": F.consent("manual_workouts")])
    }
    private func run(_ x: X.Execution, rows: [C.JournalRow], legacy: [W.Legacy] = []) async throws -> W.Output {
        var supplements = M.Supplements(x); supplements.originalJournalRows = rows; supplements.legacyRows = legacy
        return try await M.evaluate(context: x, supplements: supplements).native.workouts
    }

    func test14AutomaticAndExplicitManualUseActualNativePhysiology() async throws {
        let x = try await X.run(signals()), lo = x.observation.selection.bounds.dayLo + 36_000
        XCTAssertFalse(x.observation.native.workouts.isEmpty)
        let automatic = try await run(x, rows: [])
        XCTAssertEqual(automatic.sessions.count, x.observation.native.workouts.count)
        let first = try V.object(automatic.sessions[0]), actual = x.observation.native.workouts[0]
        XCTAssertEqual(first["energyKcal"], D.number(actual.caloriesKcal))
        XCTAssertEqual(first["zoneTimePct"], try ServerDaySwiftV3CoreProbe.reflect(actual.zoneTimePct))
        let row = manual(x, originalStart: actual.start, energy: 123.5, distance: 4_321, steps: 99)
        let out = try await run(x, rows: [row]), value = try V.object(out.sessions[0])
        XCTAssertEqual(out.sessions.count, 1); XCTAssertEqual(value["id"], .string(id))
        XCTAssertEqual(value["energyKcal"], .number(123.5)); XCTAssertEqual(value["energyMethod"], .string("user_entered"))
        XCTAssertEqual(value["distanceM"], .number(4_321)); XCTAssertEqual(value["steps"], .number(99))
        let loaded = try await S.load(S.seed(x.observation.input)), profile = try M.userProfile(loaded.evidence.effectiveProfile)
        let hr = loaded.hr.filter { $0.ts >= lo && $0.ts < lo + 1_800 }, zones = try M.Supplements(x).presentationPreferences.zones(age: profile.age)
        XCTAssertEqual(value["avgHr"], D.number(DailyPresentationMath.mean(hr.map { Double($0.bpm) })))
        XCTAssertEqual(value["hrCoveragePct"], D.number(WorkoutDetector.hrCoveragePct(sampleTs: hr.map(\.ts), start: lo, end: lo + 1_800)))
        XCTAssertEqual(value["zoneSeconds"], try ServerDaySwiftV3CoreProbe.reflect(HRZones.timeInZone(hr, zoneSet: zones).seconds))
        let maxHR = StrainScorer.estimateHRmax(hr.map { Double($0.bpm) }, age: profile.age).0
        XCTAssertEqual(value["strain"], D.number(StrainScorer.strain(hr, maxHR: maxHR,
            restingHR: x.observation.native.daily.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR, method: .edwards, sex: profile.sex)))
    }

    func test14MoveDismissTouchOverlapAndImmutableOriginal() async throws {
        let x = try await X.run(signals()), lo = x.observation.selection.bounds.dayLo + 36_000
        let original = x.observation.native.workouts[0].start
        let dismissed = manual(x, originalStart: original, dismissed: true)
        let hidden = try await run(x, rows: [dismissed]); XCTAssertEqual(hidden.sessions, [])
        let moved = manual(x, revision: 101, start: lo + 4_000, end: lo + 4_600, originalStart: original)
        let changed = try await run(x, rows: [dismissed, moved]); XCTAssertEqual(changed.sessions.count, 1)
        XCTAssertEqual(try V.object(changed.sessions[0])["avgHr"], .null)
        XCTAssertTrue(changed.gaps.contains("manual_workout_raw_physiology_unavailable"))
        let a = manual(x, end: lo + 600, originalStart: original)
        let b = manual(x, revision: 101, id: "77777777-7777-4777-8777-777777777777", start: lo + 600, end: lo + 1_200)
        let touching = try await run(x, rows: [a, b]); XCTAssertEqual(touching.sessions.count, 2)
        let overlap = manual(x, revision: 102, id: "88888888-8888-4888-8888-888888888888", start: lo + 599, end: lo + 1_000)
        let latest = try await run(x, rows: [a, b, overlap]); XCTAssertEqual(latest.sessions.count, 1)
        XCTAssertEqual(latest.rejectedEntries.count, 2)
        var bad = moved.payload; bad["originalStart"] = .number(Double(original + 1))
        XCTAssertThrowsError(try W.resolve(scope: D.Scope(x), rows: [dismissed, F.replace(moved, payload: bad)], legacy: []))
    }

    func test14LegacyLatestUploadOwnershipAndExplicitJournalPrecedence() async throws {
        let x = try await X.run(signals()), lo = x.observation.selection.bounds.dayLo + 36_000
        func legacy(_ id: String, updated: Int, owner: UUID = S10Fixtures.owner, owned: Bool = false) -> W.Legacy {
            .init(owner: owner, device: S10Fixtures.device, id: UUID(uuidString: id)!, start: lo, end: lo + 1_800,
                sport: "Running", source: "legacy_upload", userModified: false, energyKcal: 88, distanceM: 1_000,
                steps: 12, updatedAt: updated, algorithmIsServerOwned: owned)
        }
        let a = legacy(id, updated: 1), b = legacy("77777777-7777-4777-8777-777777777777", updated: 2)
        let foreign = legacy("88888888-8888-4888-8888-888888888888", updated: 3, owner: S10Fixtures.foreign)
        let server = legacy("99999999-9999-4999-8999-999999999999", updated: 4, owned: true)
        let out = try await run(x, rows: [], legacy: [a, b, foreign, server])
        XCTAssertEqual(out.sessions.count, 1)
        let value = try V.object(out.sessions[0]); XCTAssertEqual(value["id"], .string(b.id.uuidString.lowercased()))
        XCTAssertEqual(value["energyKcal"], .number(88)); XCTAssertEqual(out.resolution.originalLegacy, [a, b, foreign, server])
        let manual = manual(x, revision: 200, originalStart: x.observation.native.workouts[0].start, energy: 99)
        let journalWins = try await run(x, rows: [manual], legacy: [a, b]); XCTAssertEqual(journalWins.sessions.count, 1)
        XCTAssertEqual(try V.object(journalWins.sessions[0])["energyKcal"], .number(99))
        XCTAssertThrowsError(try W.resolve(scope: D.Scope(x), rows: [], legacy: [a, a]))
    }

    func test15NativeCaloriesHRRAndObservedSixtySecondBuckets() async throws {
        let x = try await X.run(signals()), lo = x.observation.selection.bounds.dayLo + 36_000
        let out = try await run(x, rows: [manual(x, originalStart: x.observation.native.workouts[0].start)])
        let value = try V.object(out.sessions[0]), raw = try await S.load(S.seed(x.observation.input))
        let profile = try M.userProfile(raw.evidence.effectiveProfile), hr = raw.hr.filter { $0.ts >= lo && $0.ts < lo + 1_800 }
        let maxHR = StrainScorer.estimateHRmax(hr.map { Double($0.bpm) }, age: profile.age).0
        let energy = Calories.estimateBoutCalories(hr, profile: profile, hrmax: maxHR,
            restingHR: x.observation.native.daily.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR).0
        XCTAssertEqual(value["energyKcal"], D.number(energy))
        let zones = try M.Supplements(x).presentationPreferences.zones(age: profile.age)
        let hrr = HeartRateRecovery.calculate(samples: raw.hr, workoutStart: lo, workoutEnd: lo + 1_800, maxHR: zones.maxHR)
        XCTAssertNotNil(hrr)
        XCTAssertEqual(try V.object(value["heartRateRecovery"]!)["after1Minute"], D.integer(hrr?.after1Minute))
        XCTAssertEqual(value["hrBuckets"], try V.json(D.buckets(hr.map { ($0.ts, Double($0.bpm)) }, from: lo, to: lo + 1_800, seconds: 60)))
    }

    func test16InclusiveOnFootActualCounterAndNoPedometerFallback() async throws {
        let x = try await X.run(signals()), lo = x.observation.selection.bounds.dayLo + 36_000
        let raw = try await S.load(S.seed(x.observation.input)), entry = manual(x, originalStart: x.observation.native.workouts[0].start)
        let out = try await run(x, rows: [entry]), value = try V.object(out.sessions[0])
        let ticks = StepsCounter.stepsInWindow(raw.steps.filter { $0.ts >= lo && $0.ts <= lo + 1_800 })
        XCTAssertEqual(value["stepCounterTicks"], D.integer(ticks))
        XCTAssertEqual(value["strapSteps"], D.integer(ticks.flatMap { $0 > 0 ? $0 : nil }))
        let cycling = manual(x, originalStart: x.observation.native.workouts[0].start, sport: "Cycling")
        let offFoot = try await run(x, rows: [cycling]); XCTAssertEqual(try V.object(offFoot.sessions[0])["strapSteps"], .null)
        let empty = try await X.run(S10Fixtures.input())
        let entered = try await run(empty, rows: [manual(empty, steps: 100)])
        XCTAssertEqual(try V.object(entered.sessions[0])["steps"], .number(100))
        XCTAssertEqual(try V.object(entered.sessions[0])["strapSteps"], .null)
    }

    func test17ActualActivityCostFourEightSessionsAndNoTomorrow() throws {
        var recovery: [String: Double] = [:], dates = Set<String>()
        for index in 0..<90 { recovery[try S11Fixtures.day(index)] = 80 }
        for index in 0..<8 {
            let day = try S11Fixtures.day(index * 10)
            dates.insert(day); recovery[try X.shift(day, 1)] = 60
        }
        let all = ActivityCostEngine.evaluate(activityDaysBySport: ["Running": dates], recoveryByDay: recovery)
        XCTAssertEqual(all.count, 1); XCTAssertEqual(all[0].n, 8); XCTAssertEqual(all[0].confidence, .solid)
        let four = Set(dates.sorted().prefix(4)), limited = ActivityCostEngine.evaluate(activityDaysBySport: ["Running": four], recoveryByDay: recovery)
        XCTAssertEqual(limited.first?.n, 4); XCTAssertEqual(limited.first?.confidence, .building)
        XCTAssertEqual(ActivityCostEngine.evaluate(activityDaysBySport: ["Running": Set(four.sorted().prefix(3))], recoveryByDay: recovery), [])
        let future = try S11Fixtures.day(90)
        XCTAssertEqual(ActivityCostEngine.evaluate(activityDaysBySport: ["Running": dates.union([future])], recoveryByDay: recovery), all)
    }

    func test20FutureAndUnsupportedCachedPhysiologyElevationAreNotInputs() async throws {
        let x = try await X.run(S10Fixtures.input()), cutoff = x.observation.input.asOfExclusive
        let future = manual(x, start: cutoff - 60, end: cutoff + 60)
        let out = try await run(x, rows: [future])
        XCTAssertEqual(out.sessions, []); XCTAssertNil(out.count)
        XCTAssertTrue(out.gaps.contains("manual_workout_ends_after_asof_cutoff"))
        let row = manual(x)
        for key in ["avgHr", "strain", "zoneSeconds", "elevationM", "route", "notes"] {
            var payload = row.payload; payload[key] = .number(1)
            XCTAssertThrowsError(try W.parse(F.replace(row, payload: payload)), key)
        }
        var payload = row.payload; payload["consent"] = .null
        XCTAssertThrowsError(try W.parse(F.replace(row, payload: payload)))
    }
}
