import Foundation
import XCTest
@testable import StrandAnalytics

final class ServerDaySwiftHistoryTests: XCTestCase {
    private typealias C = ServerDaySwiftContract
    private typealias H = ServerDaySwiftHistory
    private let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let device = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let foreign = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private var identity: C.Identity { C.Identity(userId: owner, sourceDeviceId: device, algorithmVersion: "history-test-v1") }

    private func day(_ index: Int) throws -> String {
        let start = try C.dayBounds("2026-01-01", "UTC").lowerBound
        return C.dayKey(start + index * 86_400, zone: TimeZone(secondsFromGMT: 0)!)
    }

    private func row(_ kind: C.Kind, _ revision: Int64, effective: String = "2026-01-01",
                     entity: String = "primary", deleted: Bool = false,
                     payload: [String: C.JSON] = [:], user: UUID? = nil, source: UUID? = nil) -> C.JournalRow {
        var fields = payload
        if !deleted { fields["schemaVersion"] = .number(1) }
        return C.JournalRow(userId: user ?? owner, sourceDeviceId: source ?? device, kind: kind, entity: entity,
            revision: revision, effectiveDay: effective, deleted: deleted, payload: fields)
    }

    private func input(_ index: Int, zone: String = "UTC", config: [String: C.JSON] = [:],
                       profile: [String: C.JSON] = [:]) throws -> C.Input {
        var p = profile
        p["timezone"] = .string(zone)
        return C.Input(identity: identity, day: try day(index), timezone: zone, journal: [
            row(.profile, 1, payload: p), row(.config, 2, payload: config)
        ])
    }

    private func measured(_ index: Int, hrv: Double? = nil, sleep: Double = 420) throws -> H.Measurements {
        let start = try C.dayBounds(day(index), "UTC").lowerBound
        return H.Measurements(values: ["hrv": hrv ?? Double(40 + index % 4), "resting_hr": Double(50 + index % 3),
            "resp": 15, "skin_temp": 33, "strain": Double(25 + index % 7), "daytime_hr": 66, "daytime_rmssd": 32],
            sleep: [H.SleepBlock(start: start - 2 * 3_600, end: start + 6 * 3_600, asleepMin: sleep)], mainSleepMin: sleep)
    }

    private func series(_ count: Int, correction: Int? = nil) throws -> [H.Checkpoint] {
        var checkpoints: [H.Checkpoint] = []
        for index in 0..<count {
            let prepared = try H.prepare(input(index), history: checkpoints.map(\.observation), predecessor: checkpoints.last)
            let observed = try measured(index, hrv: index == correction ? 70 : nil, sleep: index == correction ? 480 : 420)
            checkpoints.append(try H.finish(prepared, measurements: observed))
        }
        return checkpoints
    }

    private func failure(_ expected: C.Failure, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? C.Failure, expected, file: file, line: line)
        }
    }

    func testReservedContractRoundTripsNullBooleanAndRawMetadataWithoutExport() throws {
        var i = try input(0, profile: ["waistCm": .null])
        let ts = try C.dayBounds(i.day, i.timezone).lowerBound
        i.raw = [C.RawRow(id: "rr-1", userId: owner, sourceDeviceId: device, stream: .rr, ts: ts,
            fields: ["rrMs": .number(801), "tsSuspect": .bool(false), "provenance": .null])]
        let bytes = try C.bytes(i)
        let decoded = try JSONDecoder().decode(C.Input.self, from: bytes)
        XCTAssertEqual(decoded, i)
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.recipe, "w4-server-day-v1")
        XCTAssertEqual(try C.resolve(decoded).payload(.profile)["waistCm"], .null)
        XCTAssertEqual(try C.resolve(decoded).raw, i.raw)
        var stale = i; stale.schemaVersion = 1
        failure(.invalid("contract")) { _ = try C.resolve(stale) }
        stale = i; stale.recipe = "w4-whole-day-v1"
        failure(.invalid("contract")) { _ = try C.resolve(stale) }
    }

    func testJournalAsOfOrdersOrdinaryEntitiesByEffectiveDayThenRevision() throws {
        var i = try input(10)
        i.journal = [row(.profile, 9, effective: try day(1), payload: ["age": .number(60)]),
            row(.profile, 3, effective: try day(8), payload: ["age": .number(31)]),
            row(.profile, 4, effective: try day(8), payload: ["age": .number(32)]),
            row(.profile, 10, effective: try day(11), payload: ["age": .number(90)])]
        let selected = try C.resolve(i)
        XCTAssertEqual(selected.head(.profile)?.revision, 4)
        XCTAssertEqual(selected.payload(.profile)["age"], .number(32))
        i.journal.reverse()
        XCTAssertEqual(try C.resolve(i), selected)
    }

    func testMovedSleepAndWorkoutEntitiesUseLatestEligibleRevisionIncludingTombstone() throws {
        for kind in [C.Kind.sleepEdit, .manualWorkout] {
            var i = try input(10)
            i.journal = [row(kind, 1, effective: try day(8), entity: "stable"),
                row(kind, 2, effective: try day(2), entity: "stable", payload: ["marker": .string("moved")]),
                row(kind, 4, effective: try day(11), entity: "stable")]
            XCTAssertEqual(try C.resolve(i).head(kind, "stable")?.revision, 2)
            i.journal.append(row(kind, 3, effective: try day(1), entity: "stable", deleted: true))
            let head = try XCTUnwrap(C.resolve(i).head(kind, "stable"))
            XCTAssertEqual(head.revision, 3)
            XCTAssertTrue(head.deleted)
            XCTAssertTrue(head.payload.isEmpty)
        }
    }

    func testTombstonesForAllKindsDoNotResurrectValues() throws {
        for kind in C.Kind.allCases {
            var i = try input(10)
            i.journal = [row(kind, 1, payload: ["marker": .string("old")]),
                row(kind, 2, effective: try day(5), deleted: true)]
            let selected = try C.resolve(i)
            XCTAssertEqual(selected.head(kind)?.revision, 2)
            XCTAssertTrue(selected.head(kind)?.deleted == true)
            XCTAssertEqual(selected.payload(kind), [:])
        }
    }

    func testOwnerDeviceIsolationAndIndependentEntities() throws {
        var i = try input(2)
        i.journal = [row(.context, 1, entity: "a"), row(.context, 2, entity: "b"),
            row(.context, 500, entity: "a", user: foreign), row(.context, 600, entity: "b", source: foreign)]
        let ts = try C.dayBounds(i.day, "UTC").lowerBound
        i.raw = [C.RawRow(id: "own", userId: owner, sourceDeviceId: device, stream: .hr, ts: ts, fields: [:]),
            C.RawRow(id: "foreign-owner", userId: foreign, sourceDeviceId: device, stream: .hr, ts: ts, fields: [:]),
            C.RawRow(id: "foreign-device", userId: owner, sourceDeviceId: foreign, stream: .hr, ts: ts, fields: [:])]
        let result = try C.resolve(i)
        XCTAssertEqual(result.rows.map(\.revision), [1, 2])
        XCTAssertEqual(result.raw.map(\.id), ["own"])
    }

    func testTrueZoneRawWindowEdgesKeepSameSecondSiblingsWithoutCanonicalSelectionClaim() throws {
        let vectors = [("2026-03-08", "America/Los_Angeles", 82_800), ("2026-11-01", "America/Los_Angeles", 90_000),
            ("2026-04-05", "Australia/Lord_Howe", 88_200), ("2026-10-04", "Australia/Lord_Howe", 84_600),
            ("2026-06-15", "Asia/Kathmandu", 86_400), ("2000-01-15", "Africa/Khartoum", 82_800)]
        for (day, zone, duration) in vectors {
            var i = C.Input(identity: identity, day: day, timezone: zone)
            let bounds = try C.dayBounds(day, zone), lo = bounds.lowerBound - 30 * 3_600
            i.raw = [lo - 1, lo, bounds.lowerBound, bounds.upperBound - 1, bounds.upperBound].enumerated().map {
                C.RawRow(id: "\($0.offset)", userId: owner, sourceDeviceId: device, stream: .rr, ts: $0.element, fields: [:])
            }
            i.raw.append(C.RawRow(id: "sibling", userId: owner, sourceDeviceId: device, stream: .rr,
                ts: bounds.lowerBound, fields: ["seq": .number(2)]))
            let r = try C.resolve(i)
            XCTAssertEqual(r.dayBounds.count, duration)
            XCTAssertEqual(r.raw.map(\.id), ["1", "2", "sibling", "3"])
        }
    }

    func testInvalidDateZoneEnvelopeRevisionAndDuplicateIdentityFailClosed() throws {
        for (day, zone) in [("2026-02-30", "UTC"), ("2026-2-01", "UTC"), ("2011-12-30", "Pacific/Apia"),
                            ("2026-01-01", "not-a-zone")] {
            XCTAssertThrowsError(try C.resolve(C.Input(identity: identity, day: day, timezone: zone)))
        }
        var i = try input(0)
        i.journal = [row(.profile, 1), row(.config, 1)]
        failure(.invalid("journal_identity")) { _ = try C.resolve(i) }
        i.journal = [row(.config, 9_007_199_254_740_992)]
        failure(.invalid("journal_identity")) { _ = try C.resolve(i) }
        i.journal = [row(.config, 1, deleted: true, payload: ["stale": .bool(true)])]
        failure(.invalid("journal_payload_envelope")) { _ = try C.resolve(i) }
        i = try input(0)
        let r = C.RawRow(id: "same", userId: owner, sourceDeviceId: device, stream: .hr,
            ts: try C.dayBounds(i.day, "UTC").lowerBound, fields: [:])
        i.raw = [r, r]
        failure(.invalid("raw_identity")) { _ = try C.resolve(i) }
    }

    func testFutureRawAndJournalDoNotChangeDayResolutionOrHistory() throws {
        let past = try series(20), original = try input(20)
        let before = try H.prepare(original, history: past.map(\.observation), predecessor: past.last)
        let expected = try H.finish(before, measurements: measured(20))
        var added = original
        added.journal += [row(.config, 8, effective: try day(21), payload: ["sourceEra": .string("future")]),
            row(.profile, 9, effective: try day(21), payload: ["age": .number(15), "timezone": .string("Asia/Tokyo")])]
        added.raw = [C.RawRow(id: "future", userId: owner, sourceDeviceId: device, stream: .hr,
            ts: try C.dayBounds(day(21), "UTC").lowerBound, fields: ["bpm": .number(180)])]
        let actual = try H.prepare(added, history: past.map(\.observation), predecessor: past.last)
        XCTAssertEqual(actual.resolution, before.resolution)
        XCTAssertEqual(try H.finish(actual, measurements: measured(20)), expected)
    }

    func testColdStartBeforeAndAfterUseActualSwiftHelperWithoutCurrentLeak() throws {
        let p = try H.prepare(input(0), history: [])
        for (key, cfg) in Baselines.metricCfg {
            XCTAssertEqual(try p.baselinesBefore[key]?.native(), Baselines.foldHistory([], cfg: cfg))
        }
        XCTAssertNil(p.consistency)
        XCTAssertNil(p.habitualMidsleepSec)
        XCTAssertEqual(p.needHours, AnalyticsEngine.Rest.personalizedNeedHours(nightlyHours: [], age: 30))
        let m = try measured(0), c = try H.finish(p, measurements: m)
        for (key, cfg) in Baselines.metricCfg {
            XCTAssertEqual(try c.baselinesAfter[key]?.native(),
                Baselines.update(try p.baselinesBefore[key]?.native(), value: m.baselineValues[key], cfg: cfg,
                    rejectHardOutliers: key != "readiness_hrv_ln"))
            XCTAssertEqual(c.observation.baselinesBefore[key]?.nValid, 0)
        }
        XCTAssertEqual(c.baselinesAfter["hrv"]?.nValid, 1)
        XCTAssertEqual(c.sleepDebt, H.Debt(SleepDebt.ledger(series: [(try day(0), 420)], needHours: p.needHours)))
    }

    func test131DaysMatchActualSwiftFoldAndRestartSerialization() throws {
        let all = try series(131)
        for (key, cfg) in Baselines.metricCfg {
            let direct = Baselines.foldHistory(all.map { $0.observation.measurements.baselineValues[key] }, cfg: cfg,
                rejectHardOutliers: key != "readiness_hrv_ln")
            XCTAssertEqual(try all.last?.baselinesAfter[key]?.native(), direct, key)
        }
        struct Archive: Codable { let checkpoint: H.Checkpoint; let history: [H.Observation] }
        let saved = Archive(checkpoint: all[65], history: Array(all.prefix(66)).map(\.observation))
        let bytes = try C.bytes(saved)
        let restored = try JSONDecoder().decode(Archive.self, from: bytes)
        XCTAssertEqual(try C.bytes(restored), bytes)
        var history = restored.history, checkpoint = restored.checkpoint
        for index in 66..<131 {
            let prepared = try H.prepare(input(index), history: history, predecessor: checkpoint)
            XCTAssertTrue(prepared.reusedCheckpoint)
            checkpoint = try H.finish(prepared, measurements: measured(index))
            XCTAssertEqual(checkpoint, all[index], "restart day \(index)")
            history.append(checkpoint.observation)
        }
        XCTAssertEqual(checkpoint.sleepDebt.nightCount, 14)
    }

    func testCalendarHolesAgeStatesAndWarmEqualsFullReplay() throws {
        let past = try series(20)
        let warm = try H.prepare(input(45), history: past.map(\.observation), predecessor: past.last)
        let cold = try H.prepare(input(45), history: past.map(\.observation))
        XCTAssertEqual(warm.baselinesBefore, cold.baselinesBefore)
        XCTAssertEqual(warm.baselinesBefore["hrv"]?.nightsSinceUpdate, 25)
        XCTAssertEqual(warm.baselinesBefore["hrv"]?.status, "stale")
        var direct = try XCTUnwrap(past.last?.baselinesAfter["hrv"]?.native())
        for _ in 0..<25 { direct = Baselines.update(direct, value: nil, cfg: Baselines.hrvCfg) }
        XCTAssertEqual(try warm.baselinesBefore["hrv"]?.native(), direct)
    }

    func testWarmGapAcrossResetAgesOnlyEligibleDaysForEachMetricFamily() throws {
        let epoch = Double(try C.dayBounds(day(10), "UTC").lowerBound)
        for reset in ["hrvBaselineEpoch", "recoveryBaselineEpoch"] {
            let config = [reset: C.JSON.number(epoch)]
            let first = try H.finish(H.prepare(input(0, config: config), history: []), measurements: measured(0))
            let next = try input(20, config: config), history = [first.observation]
            let warm = try H.prepare(next, history: history, predecessor: first)
            let cold = try H.prepare(next, history: history)
            let resetKey = reset == "hrvBaselineEpoch" ? "hrv" : "resting_hr"
            let controlKey = reset == "hrvBaselineEpoch" ? "resting_hr" : "hrv"
            XCTAssertTrue(warm.reusedCheckpoint)
            XCTAssertEqual(warm.baselinesBefore[resetKey]?.nightsSinceUpdate, 10, reset)
            XCTAssertEqual(warm.baselinesBefore[controlKey]?.nightsSinceUpdate, 19, reset)
            XCTAssertEqual(warm.baselinesBefore, cold.baselinesBefore, reset)
            XCTAssertEqual(try H.finish(warm, measurements: measured(20)),
                try H.finish(cold, measurements: measured(20)), reset)
        }
    }

    func testWarmGapIntersectsExactFractionalAndFutureResetEpochsUsingUTCDateKeys() throws {
        // Missing dates are Jan 2...20. The target Jan 21 is admitted only by finish.
        let cases: [(day: Int, fraction: Double, age: Int)] = [
            (0, 0, 19), (0, 0.25, 19), (1, 0, 19), (10, 0, 10),
            (10, 0.25, 9), (19, 0, 1), (20, 0, 0), (20, 0.25, 0), (21, 0, 0)
        ]
        for reset in ["hrvBaselineEpoch", "recoveryBaselineEpoch"] {
            for zone in ["UTC", "Asia/Kathmandu"] {
                for c in cases {
                    let epoch = Double(try C.dayBounds(day(c.day), "UTC").lowerBound) + c.fraction
                    let config = [reset: C.JSON.number(epoch)]
                    let first = try H.finish(H.prepare(input(0, zone: zone, config: config), history: []),
                        measurements: measured(0))
                    let next = try input(20, zone: zone, config: config)
                    let warm = try H.prepare(next, history: [first.observation], predecessor: first)
                    let cold = try H.prepare(next, history: [first.observation])
                    let key = reset == "hrvBaselineEpoch" ? "hrv" : "resting_hr"
                    let label = "\(reset)/\(zone)/\(c.day)+\(c.fraction)"
                    XCTAssertTrue(warm.reusedCheckpoint, label)
                    XCTAssertEqual(warm.baselinesBefore[key]?.nightsSinceUpdate, c.age, label)
                    XCTAssertEqual(warm.baselinesBefore, cold.baselinesBefore, label)
                    let done = try H.finish(warm, measurements: measured(20))
                    XCTAssertEqual(done, try H.finish(cold, measurements: measured(20)), label)
                    let firstValid = c.day == 0 && c.fraction == 0 ? 1 : 0
                    let currentValid = c.day < 20 || c.day == 20 && c.fraction == 0 ? 1 : 0
                    XCTAssertEqual(done.baselinesAfter[key]?.nValid, firstValid + currentValid, label)
                }
            }
        }
    }

    func testSerializedWarmGapCanResumeBeforeOrOnResetWithoutAgingExcludedDays() throws {
        let epoch = Double(try C.dayBounds(day(10), "UTC").lowerBound) + 0.25
        for reset in ["hrvBaselineEpoch", "recoveryBaselineEpoch"] {
            for middleDay in [5, 10, 11] {
                let config = [reset: C.JSON.number(epoch)]
                let first = try H.finish(H.prepare(input(0, config: config), history: []), measurements: measured(0))
                let middle = try H.finish(H.prepare(input(middleDay, config: config),
                    history: [first.observation], predecessor: first), measurements: measured(middleDay))
                let restored = try JSONDecoder().decode(H.Checkpoint.self, from: C.bytes(middle))
                let history = [first.observation, restored.observation], next = try input(20, config: config)
                let warm = try H.prepare(next, history: history, predecessor: restored)
                let cold = try H.prepare(next, history: history)
                XCTAssertTrue(warm.reusedCheckpoint)
                XCTAssertEqual(warm.baselinesBefore, cold.baselinesBefore, "\(reset)/\(middleDay)")
                XCTAssertEqual(try H.finish(warm, measurements: measured(20)),
                    try H.finish(cold, measurements: measured(20)), "\(reset)/\(middleDay)")
            }
        }
    }

    func testFractionalResetSeparatesHRVFromRecoveryAndIncludesExactEpochDay() throws {
        let past = try series(30), start = Double(try C.dayBounds(day(10), "UTC").lowerBound)
        let p = try H.prepare(input(30, config: ["hrvBaselineEpoch": .number(start + 0.25)]),
            history: past.map(\.observation), predecessor: past.last)
        XCTAssertFalse(p.reusedCheckpoint)
        XCTAssertEqual(p.baselinesBefore["hrv"]?.nValid, 19)
        XCTAssertEqual(p.baselinesBefore["readiness_hrv_ln"]?.nValid, 19)
        XCTAssertEqual(p.baselinesBefore["resting_hr"]?.nValid, 30)
        let expected = Baselines.foldHistory(past.map { $0.observation.measurements.values["hrv"] },
            dayKeys: past.map(\.throughDay), cfg: Baselines.hrvCfg, baselineEpoch: start + 0.25)
        XCTAssertEqual(try p.baselinesBefore["hrv"]?.native(), expected)
        let exact = try H.prepare(input(30, config: ["recoveryBaselineEpoch": .number(start)]), history: past.map(\.observation))
        XCTAssertEqual(exact.baselinesBefore["resting_hr"]?.nValid, 20)
        XCTAssertEqual(exact.baselinesBefore["hrv"]?.nValid, 30)
        let currentReset = try H.prepare(input(30, config: ["hrvBaselineEpoch": .number(Double(C.dayBounds(day(30), "UTC").lowerBound) + 1)]),
            history: past.map(\.observation))
        XCTAssertEqual(try H.finish(currentReset, measurements: measured(30)).baselinesAfter["hrv"]?.nValid, 0)
    }

    func testSourceEraChangeExcludesOldPhysiologySleepAndDebt() throws {
        let past = try series(20)
        let p = try H.prepare(input(20, config: ["sourceEra": .string("replacement")]), history: past.map(\.observation), predecessor: past.last)
        XCTAssertFalse(p.reusedCheckpoint)
        XCTAssertTrue(p.eligibleHistory.isEmpty)
        XCTAssertEqual(p.baselinesBefore["hrv"]?.nValid, 0)
        XCTAssertNil(p.habitualMidsleepSec)
        XCTAssertEqual(p.history, past.map(\.observation))
        let next = try H.finish(p, measurements: measured(20))
        XCTAssertEqual(next.sleepDebt.nightCount, 1)
        let continued = try H.prepare(input(21, config: ["sourceEra": .string("replacement")]),
            history: past.map(\.observation) + [next.observation], predecessor: next)
        XCTAssertEqual(continued.baselinesBefore["hrv"]?.nValid, 1)
    }

    func testRecipeChangeExcludesOldStrainWithoutResettingUnrelatedMetrics() throws {
        let past = try series(20)
        let p = try H.prepare(input(20, config: ["effortMethod": .string("BANISTER")]), history: past.map(\.observation), predecessor: past.last)
        XCTAssertFalse(p.reusedCheckpoint)
        XCTAssertEqual(p.baselinesBefore["strain"]?.nValid, 0)
        XCTAssertEqual(p.baselinesBefore["hrv"], past.last?.baselinesAfter["hrv"])
        XCTAssertEqual(try H.finish(p, measurements: measured(20)).baselinesAfter["strain"]?.nValid, 1)
    }

    func testCorrectionRequiresReplayAndSuffixEqualsCleanRecomputation() throws {
        let original = try series(45), clean = try series(45, correction: 20)
        XCTAssertEqual(Array(original.prefix(20)), Array(clean.prefix(20)))
        XCTAssertNotEqual(original[21].observation.baselinesBefore["hrv"], clean[21].observation.baselinesBefore["hrv"])
        failure(.invalid("checkpoint_ancestry")) {
            _ = try H.prepare(input(45), history: clean.map(\.observation), predecessor: original.last)
        }
        var replay = Array(original.prefix(20))
        for index in 20..<45 {
            let p = try H.prepare(input(index), history: replay.map(\.observation), predecessor: replay.last)
            replay.append(try H.finish(p, measurements: measured(index, hrv: index == 20 ? 70 : nil, sleep: index == 20 ? 480 : 420)))
            XCTAssertEqual(replay.last, clean[index])
        }
        XCTAssertNotEqual(replay[20].sleepDebt, original[20].sleepDebt)
    }

    func testHistoryRejectsFutureUnorderedDuplicateForeignAndWrongAlgorithmRows() throws {
        let past = try series(3)
        for history in [past.map(\.observation), [past[1].observation, past[0].observation], [past[0].observation, past[0].observation]] {
            failure(.invalid("history_order_or_identity")) { _ = try H.prepare(input(2), history: history) }
        }
        for id in [C.Identity(userId: foreign, sourceDeviceId: device, algorithmVersion: identity.algorithmVersion),
                   C.Identity(userId: owner, sourceDeviceId: foreign, algorithmVersion: identity.algorithmVersion),
                   C.Identity(userId: owner, sourceDeviceId: device, algorithmVersion: "another-algorithm")] {
            failure(.invalid("history_order_or_identity")) {
                _ = try H.prepare(C.Input(identity: id, day: day(3), timezone: "UTC"), history: past.map(\.observation))
            }
        }
    }

    func testSleepNeedLearnsPriorAsleepTimeNotBedtimeAndMatchesActualHelpers() throws {
        var prior: [H.Checkpoint] = []
        for index in 0..<16 {
            let p = try H.prepare(input(index), history: prior.map(\.observation), predecessor: prior.last)
            prior.append(try H.finish(p, measurements: measured(index, sleep: 450 + Double(index % 4) * 10)))
        }
        let p = try H.prepare(input(16), history: prior.map(\.observation), predecessor: prior.last)
        let hours = prior.map { $0.observation.measurements.sleep[0].asleepMin! / 60 }
        XCTAssertEqual(p.needHours, AnalyticsEngine.Rest.personalizedNeedHours(nightlyHours: hours, age: 30))
        XCTAssertEqual(p.consistency, VitalityEngine.sleepConsistency(nightlyHours: hours))
        let blocks = prior.map { row -> SleepStageTotals.HistoryBlock in
            let b = row.observation.measurements.sleep[0]
            return .init(start: b.start, end: b.end, dayKey: row.throughDay)
        }
        XCTAssertEqual(p.habitualMidsleepSec, SleepStageTotals.habitualMidsleepSec(blocks, offsetSec: 0))
        XCTAssertEqual(p.habitualMidsleepSec, 2 * 3_600)
        let after = try H.finish(p, measurements: measured(16, sleep: 60))
        XCTAssertEqual(after.needHours, p.needHours)
        XCTAssertEqual(after.observation.baselinesBefore, p.baselinesBefore)
    }

    func testSleepHistoryUsesEachStoredTimezoneAtMidpointAcrossDST() throws {
        var prior: [H.Checkpoint] = []
        let dates = try C.days(from: "2026-03-01", through: "2026-03-16")
        for key in dates {
            let zone = "America/Los_Angeles", bounds = try C.dayBounds(key, zone)
            let midnightOffset = TimeZone(identifier: zone)!.secondsFromGMT(for: Date(timeIntervalSince1970: Double(bounds.lowerBound)))
            let utcDay = try C.dayBounds(key, "UTC").lowerBound
            // Keep the midpoint at local 04:00, including the actual post-transition offset.
            let noon = bounds.upperBound - 12 * 3_600
            let offset = TimeZone(identifier: zone)!.secondsFromGMT(for: Date(timeIntervalSince1970: Double(noon)))
            let midpoint = utcDay + 4 * 3_600 - offset
            let i = C.Input(identity: identity, day: key, timezone: zone)
            let p = try H.prepare(i, history: prior.map(\.observation), predecessor: prior.last)
            prior.append(try H.finish(p, measurements: H.Measurements(sleep: [.init(start: midpoint - 4 * 3_600,
                end: midpoint + 4 * 3_600, asleepMin: 450)], mainSleepMin: 450)))
            if key == "2026-03-08" { XCTAssertNotEqual(midnightOffset, offset) }
        }
        let next = C.Input(identity: identity, day: "2026-03-17", timezone: "Asia/Kathmandu")
        let p = try H.prepare(next, history: prior.map(\.observation), predecessor: prior.last)
        XCTAssertEqual(p.habitualMidsleepSec, 4 * 3_600)
    }

    func testLongestSleepBlockAndStableTieUseAsleepMinutesNotBedTime() throws {
        var history: [H.Observation] = []
        for index in 0..<16 {
            let start = try C.dayBounds(day(index), "UTC").lowerBound
            let m = H.Measurements(sleep: [
                .init(start: start + 10 * 3_600, end: start + 21 * 3_600, asleepMin: 510),
                .init(start: start - 2 * 3_600, end: start + 9 * 3_600, asleepMin: 540),
                .init(start: start - 3 * 3_600, end: start + 21 * 3_600, asleepMin: nil),
                .init(start: start + 9 * 3_600, end: start + 10 * 3_600, asleepMin: 60)
            ], mainSleepMin: 540)
            history.append(try H.finish(H.prepare(input(index), history: history), measurements: m).observation)
        }
        let p = try H.prepare(input(16), history: history)
        XCTAssertEqual(p.needHours, AnalyticsEngine.Rest.personalizedNeedHours(nightlyHours: Array(repeating: 9, count: 16), age: 30))
        XCTAssertEqual(p.needHours, 9)
        XCTAssertEqual(p.consistency, 1)
        XCTAssertEqual(p.habitualMidsleepSec, 3 * 3_600 + 1_800)
    }

    func testUnstagedSleepDoesNotInventHoursOrDebt() throws {
        let start = try C.dayBounds(day(0), "UTC").lowerBound
        var unstaged = H.Measurements()
        unstaged.sleep = [.init(start: start, end: start + 8 * 3_600, asleepMin: nil)]
        let empty = try H.finish(H.prepare(input(0), history: []), measurements: unstaged)
        XCTAssertEqual(empty.sleepDebt.nightCount, 0)
        XCTAssertNil(empty.observation.creditedSleepMin)
    }

    func testReadinessLogBaselineUsesActualSwiftRejectDisabledPath() throws {
        let past = try series(30)
        let p = try H.prepare(input(30), history: past.map(\.observation), predecessor: past.last)
        let current = try H.finish(p, measurements: measured(30, hrv: 200))
        let before = try XCTUnwrap(p.baselinesBefore["readiness_hrv_ln"]?.native())
        let expected = Baselines.update(before, value: log(200), cfg: Baselines.readinessHRVLnCfg, rejectHardOutliers: false)
        XCTAssertEqual(try current.baselinesAfter["readiness_hrv_ln"]?.native(), expected)
        XCTAssertEqual(expected.nValid, before.nValid + 1)
        XCTAssertNotEqual(expected, Baselines.update(before, value: log(200), cfg: Baselines.readinessHRVLnCfg))
    }

    func testSerializedCheckpointAfterStateCannotDisagreeWithItsObservation() throws {
        var checkpoint = try XCTUnwrap(series(20).last)
        let state = try XCTUnwrap(checkpoint.baselinesAfter["hrv"]?.native())
        checkpoint.baselinesAfter["hrv"] = H.State(BaselineState(baseline: state.baseline + 10, spread: state.spread,
            nValid: state.nValid, nightsSinceUpdate: state.nightsSinceUpdate, status: state.status))
        let restored = try JSONDecoder().decode(H.Checkpoint.self, from: C.bytes(checkpoint))
        failure(.invalid("checkpoint_after_state")) {
            _ = try H.prepare(input(20), history: series(20).map(\.observation), predecessor: restored)
        }
    }

    func testFutureSleepInsideHistoricalObservationIsRejectedOnColdReplay() throws {
        let original = try XCTUnwrap(series(1).first?.observation)
        var measurements = original.measurements
        let future = try C.dayBounds(day(3), "UTC").lowerBound
        measurements.sleep = [.init(start: future, end: future + 3_600, asleepMin: 60)]
        let altered = H.Observation(identity: original.identity, day: original.day, timezone: original.timezone,
            policy: original.policy, profileRevision: original.profileRevision, configurationRevision: original.configurationRevision,
            baselinesBefore: original.baselinesBefore, measurements: measurements, creditedSleepMin: original.creditedSleepMin)
        failure(.invalid("future_sleep")) { _ = try H.prepare(input(1), history: [altered]) }
    }

    func testDebtCountsFourteenUsableNightsAndNapCreditNotMissingDays() throws {
        var history: [H.Observation] = [], last: H.Checkpoint?
        for index in 0..<40 {
            let p = try H.prepare(input(index), history: history, predecessor: last)
            var m = index % 2 == 0 ? try measured(index) : H.Measurements()
            m.napSleepMin = 30
            last = try H.finish(p, measurements: m)
            history.append(last!.observation)
        }
        let result = try XCTUnwrap(last)
        XCTAssertEqual(result.sleepDebt.nightCount, 14)
        XCTAssertEqual(result.sleepDebt.nights.first?.day, try day(12))
        XCTAssertEqual(result.sleepDebt.nights.last?.day, try day(38))
        XCTAssertTrue(result.sleepDebt.nights.allSatisfy { $0.sleptMin == 450 })
        XCTAssertNil(history[39].creditedSleepMin)
        XCTAssertEqual(result.sleepDebt, H.Debt(SleepDebt.ledger(series: history.map { ($0.day, $0.creditedSleepMin) }, needHours: result.needHours)))
    }

    func testAsOfProfileNeedOverrideAndConfigTombstoneDoNotUseFutureHead() throws {
        var i = try input(20, config: ["sleepNeedHours": .number(10)], profile: ["age": .number(16)])
        let past = try series(20)
        XCTAssertEqual(try H.prepare(i, history: past.map(\.observation)).needHours, 10)
        i.journal.append(row(.config, 3, effective: try day(19), deleted: true))
        i.journal.append(row(.config, 4, effective: try day(21), payload: ["sleepNeedHours": .number(12)]))
        let p = try H.prepare(i, history: past.map(\.observation))
        XCTAssertEqual(p.needHours, 9)
        XCTAssertEqual(try H.finish(p, measurements: measured(20)).observation.configurationRevision, 3)
        for value in [C.JSON.bool(true), .string("10")] {
            failure(.invalid("number:sleepNeedHours")) {
                _ = try H.prepare(input(0, config: ["sleepNeedHours": value]), history: [])
            }
        }
    }

    func testMalformedMeasurementsAndCheckpointVersionCannotEnterReplay() throws {
        let p = try H.prepare(input(0), history: [])
        for m in [H.Measurements(values: ["hrv": .nan]), H.Measurements(values: ["readiness_hrv_ln": 3]),
                  H.Measurements(mainSleepMin: -1), H.Measurements(napSleepMin: -1)] {
            failure(.invalid("measurements")) { _ = try H.finish(p, measurements: m) }
        }
        var bad = try measured(0)
        bad.sleep = [.init(start: p.resolution.dayBounds.upperBound, end: p.resolution.dayBounds.upperBound + 600, asleepMin: 5)]
        failure(.invalid("future_sleep")) { _ = try H.finish(p, measurements: bad) }
        var checkpoint = try H.finish(p, measurements: measured(0))
        checkpoint.schemaVersion = 1
        failure(.invalid("checkpoint_ancestry")) {
            _ = try H.prepare(input(1), history: [checkpoint.observation], predecessor: checkpoint)
        }
    }
}
