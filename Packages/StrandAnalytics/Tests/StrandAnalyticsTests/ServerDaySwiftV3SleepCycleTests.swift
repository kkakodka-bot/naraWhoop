import Foundation
import GRDB
import WhoopProtocol
import XCTest
@testable import StrandAnalytics

final class ServerDaySwiftV3SleepCycleTests: XCTestCase {
    private typealias C = ServerDaySwiftContract
    private typealias V = ServerDaySwiftV3Contract
    private typealias H = ServerDaySwiftHistory
    private typealias S = ServerDaySwiftV3Selection
    private typealias T = ServerDaySwiftV3Thermal
    private typealias Sleep = ServerDaySwiftV3Sleep
    private typealias Cycle = ServerDaySwiftV3Cycle
    private typealias P = ServerDaySwiftV3CoreProbe
    private typealias F = S10Fixtures

    private struct Run {
        let input: V.Input
        let seed: S.Seed
        let loaded: S.Loaded
        let prepared: H.Prepared
        let thermal: T.Anchor
        let sleep: Sleep.ResolvedSleep
        let native: AnalyticsEngine.DayResult
        func cycle(_ prior: [Cycle.PriorResolvedSleep] = []) async throws -> Cycle.CycleEvidence {
            try await Cycle.evaluate(input: input, seed: seed, prepared: prepared, sleep: sleep, priorSleep: prior)
        }
    }
    private func run(_ input: V.Input) async throws -> Run {
        let seed = try await S.seed(input), loaded = try await S.load(seed), thermal = try await T.anchor(seed)
        let prepared = try T.prepare(H.prepare(input.historyInput, history: []), history: [], anchor: thermal).0
        let sleep = try Sleep.resolve(input: input, prepared: prepared, loaded: loaded, thermal: thermal)
        let native = try Sleep.analyze(input: input, prepared: prepared, loaded: loaded, thermal: thermal, resolved: sleep)
        return Run(input: input, seed: seed, loaded: loaded, prepared: prepared, thermal: thermal, sleep: sleep, native: native)
    }
    private func configured(_ input: V.Input, _ flags: [String: C.JSON]) -> V.Input {
        var result = input, payload = input.journal[1].payload
        payload.merge(flags) { _, new in new }
        result.journal[1] = F.journal(.config, 2, day: input.day, payload: payload)
        return result
    }
    private func edit(_ input: V.Input, revision: Int64 = 3, entity: Int = 1, original: Sleep.Bounds,
                      bounds: Sleep.Bounds? = nil, nap: Bool = false, dismissed: Bool = false,
                      stages: C.JSON? = nil, deleted: Bool = false, day: String? = nil,
                      owner: UUID = F.owner, device: UUID = F.device) -> C.JournalRow {
        let b = bounds ?? original
        var payload: [String: C.JSON] = ["schemaVersion": .number(1), "originalStart": .number(Double(original.start)),
            "originalEnd": .number(Double(original.end)), "start": .number(Double(b.start)), "end": .number(Double(b.end)),
            "isNap": .bool(nap), "dismissed": .bool(dismissed)]
        payload["stages"] = stages
        return C.JournalRow(userId: owner, sourceDeviceId: device, kind: .sleepEdit,
            entity: String(format: "sleep:55555555-5555-4555-8555-%012d", entity), revision: revision,
            effectiveDay: day ?? input.day, deleted: deleted, payload: deleted ? [:] : payload)
    }
    private func stages(_ bounds: Sleep.Bounds, _ stage: String = "light") -> C.JSON {
        .array([.object(["start": .number(Double(bounds.start)), "end": .number(Double(bounds.end)), "stage": .string(stage)])])
    }
    private func fakeSession(_ b: Sleep.Bounds) -> SleepSession {
        // Policy-only interval vectors. These are never claimed to be raw-derived detections.
        SleepSession(start: b.start, end: b.end, efficiency: 1, stages: [.init(start: b.start, end: b.end, stage: "light")],
            restingHR: nil, avgHRV: nil)
    }

    func testActualAutomaticV1V2PositiveAndCompleteNoEditResultIsUnchanged() async throws {
        for v2 in [false, true] {
            let input = try F.dense("s12-automatic-\(v2)", day: "2026-06-15", v2: v2)
            let r = try await run(input)
            XCTAssertFalse(r.native.sleepSessions.isEmpty, "Positive actual detection, not an empty equality")
            XCTAssertFalse(r.native.sleepSessions.flatMap(\.stages).isEmpty)
            XCTAssertFalse(r.sleep.authoritative)
            let direct = try T.analyze(input, prepared: r.prepared, loaded: r.loaded, anchor: r.thermal)
            XCTAssertEqual(try P.reflect(r.native), try P.reflect(direct))
            XCTAssertEqual(try V.object(P.reflect(r.native)).count, 16)
            XCTAssertEqual(r.sleep.automatic, r.native.sleepSessions.map(T.Session.init))
            XCTAssertEqual(r.sleep.input.raw, input.raw)
        }
    }

    func testBoundsOnlyEditUsesActualNativeRestagingAndPreservesEverySelectedID() async throws {
        for v2 in [false, true] {
            var input = try S11Fixtures.input("2026-06-15", config: ["useSleepStagerV2": .bool(v2)])
            let lo = try V.validate(input).dayLo
            let b = Sleep.Bounds(start: lo + 7, end: lo + 10_000)
            input.journal.append(edit(input, original: .init(start: lo, end: lo + 10_800), bounds: b))
            let r = try await run(input), e = try XCTUnwrap(r.sleep.entries.first)
            let native = v2 ? SleepStagerV2.stageSession(start: b.start, end: b.end, grav: r.loaded.gravity,
                hr: r.loaded.hr, rr: r.loaded.rr, resp: r.loaded.resp)
                : SleepStager.stageSession(start: b.start, end: b.end, grav: r.loaded.gravity, hr: r.loaded.hr, rr: r.loaded.rr, resp: r.loaded.resp)
            XCTAssertTrue(r.sleep.authoritative)
            XCTAssertEqual(e.staging.unmasked, native)
            XCTAssertEqual(e.staging.stages, Sleep.mask(native, bounds: b, observed: Set(e.staging.observedEpochs)))
            XCTAssertFalse(e.staging.stages.isEmpty)
            XCTAssertEqual(e.staging.hrIDs, r.loaded.evidence.streams["hr"]!.filter { b.contains($0.ts) }.map(\.id))
            XCTAssertEqual(e.staging.gravityIDs, r.loaded.evidence.streams["gravity"]!.filter { b.contains($0.ts) }.map(\.id))
            XCTAssertNil(e.session.restingHR) // No journal physiology; the actual analysis enriches it.
            XCTAssertNotNil(r.native.sleepSessions.first?.restingHR)
            XCTAssertEqual(r.sleep.input, input)
        }
    }

    func testDismissAllHasPositiveControlTombstoneRestoresAndMovedOffDayCannotResurrect() async throws {
        let original = try S11Fixtures.input("2026-06-15")
        let before = try await run(original)
        XCTAssertFalse(before.native.sleepSessions.isEmpty)
        var dismissed = original
        for (i, s) in before.native.sleepSessions.enumerated() {
            dismissed.journal.append(edit(dismissed, revision: Int64(3 + i), entity: i + 1,
                original: .init(start: s.start, end: s.end), dismissed: true))
        }
        let empty = try await run(dismissed)
        XCTAssertTrue(empty.sleep.authoritative)
        XCTAssertTrue(empty.native.sleepSessions.isEmpty)
        XCTAssertNil(empty.native.daily.totalSleepMin)
        XCTAssertEqual(empty.sleep.automatic, before.sleep.automatic)
        XCTAssertEqual(empty.sleep.input.raw, before.sleep.input.raw)
        var restored = dismissed
        for (i, s) in before.native.sleepSessions.enumerated() {
            restored.journal.append(edit(restored, revision: Int64(100 + i), entity: i + 1,
                original: .init(start: s.start, end: s.end), deleted: true))
        }
        let undo = try await run(restored)
        XCTAssertFalse(undo.sleep.authoritative)
        XCTAssertEqual(try P.reflect(undo.native), try P.reflect(before.native))
        let s = try XCTUnwrap(before.native.sleepSessions.first)
        var moved = original
        moved.journal.append(edit(moved, original: .init(start: s.start, end: s.end),
            bounds: .init(start: original.asOfExclusive + 100, end: original.asOfExclusive + 10_000)))
        let after = try await run(moved)
        XCTAssertTrue(after.sleep.authoritative)
        XCTAssertTrue(after.native.sleepSessions.isEmpty)
        XCTAssertFalse(after.sleep.entries.isEmpty, "Future edited metadata retained separately from D's result")
        XCTAssertTrue(after.sleep.entries[0].session.stages.isEmpty)
    }

    func testSuppliedStagesAreUnmaskedAndNullOmissionAndEmptyAreDistinct() async throws {
        var input = try F.input("s12-supplied")
        let lo = try V.validate(input).dayLo, b = Sleep.Bounds(start: lo, end: lo + 3_600)
        input.journal.append(edit(input, original: b, stages: stages(b, "deep")))
        let supplied = try await run(input), e = try XCTUnwrap(supplied.sleep.entries.first)
        XCTAssertEqual(e.staging.source, "journal_supplied")
        XCTAssertFalse(e.staging.admissionMet)
        XCTAssertTrue(e.staging.observedEpochs.isEmpty)
        XCTAssertEqual(e.session.stages, [.init(start: b.start, end: b.end, stage: "deep")])
        XCTAssertNil(supplied.native.sleepSessions.first?.restingHR)
        XCTAssertNil(supplied.native.sleepSessions.first?.avgHRV)
        for (value, source) in [(nil, "native_v1_restaged_observed_epochs"), (C.JSON.array([]), "journal_supplied")] {
            var changed = input
            changed.journal[2] = edit(changed, original: b, stages: value)
            let r = try await run(changed)
            XCTAssertEqual(r.sleep.entries[0].staging.source, source)
            XCTAssertTrue(r.sleep.entries[0].session.stages.isEmpty)
            XCTAssertNil(r.native.daily.totalSleepMin)
        }
        XCTAssertThrowsError(try Sleep.parse(edit(input, original: b, stages: .null)))
        let json = try V.json(e.staging)
        XCTAssertEqual(try V.object(json)["source"], .string("journal_supplied"))
    }

    func testStrictPayloadRejectsBoundsStageOverlapExtraPhysiologyAndAnchorMutation() async throws {
        let input = try F.input(), lo = try V.validate(input).dayLo
        let b = Sleep.Bounds(start: lo, end: lo + 300)
        for (key, value) in [("restingHR", C.JSON.number(40)), ("start", .number(Double(lo) + 0.5)),
            ("end", .number(Double(lo))), ("isNap", .null), ("originalStart", .number(-1)),
            ("end", .number(Double(lo + 172_801)))] {
            let row = edit(input, original: b)
            var p = row.payload; p[key] = value
            let changed = C.JournalRow(userId: row.userId, sourceDeviceId: row.sourceDeviceId, kind: row.kind,
                entity: row.entity, revision: row.revision, effectiveDay: row.effectiveDay, deleted: false, payload: p)
            XCTAssertThrowsError(try Sleep.parse(changed), key)
        }
        for value in [C.JSON.array([try V.array(stages(b))[0], try V.array(stages(b))[0]]), stages(b, "awake"),
            stages(.init(start: b.start - 1, end: b.end)), stages(.init(start: b.start, end: b.end + 1))] {
            XCTAssertThrowsError(try Sleep.parse(edit(input, original: b, stages: value)))
        }
        var changed = input
        changed.journal += [edit(changed, original: b), edit(changed, revision: 4, original: .init(start: lo + 1, end: b.end))]
        XCTAssertThrowsError(try Sleep.edits(changed, resolution: C.resolve(changed.historyInput)))
    }

    func testOneSecondOverlapTouchingNoOverlapAndLosingOriginalSuppression() async throws {
        let r = try await run(F.input("s12-overlap")), lo = r.loaded.evidence.bounds.dayLo
        let original = Sleep.Bounds(start: lo, end: lo + 100)
        for (start, count) in [(lo + 99, 1), (lo + 100, 2), (lo + 101, 2)] {
            let newer = edit(r.input, revision: 4, entity: 2, original: .init(start: lo + 1_000, end: lo + 1_100),
                bounds: .init(start: start, end: start + 100))
            let older = edit(r.input, original: original)
            let result = Sleep.apply(try [Sleep.parse(older), Sleep.parse(newer)], detected: [], input: r.input, loaded: r.loaded)
            XCTAssertEqual(result.entries.count, count)
            XCTAssertEqual(result.gaps.contains("overlapping_sleep_edits_latest_revision_wins"), count == 1)
        }
        let oldOriginal = Sleep.Bounds(start: lo + 5_000, end: lo + 5_100)
        let loser = try Sleep.parse(edit(r.input, original: oldOriginal, bounds: original))
        let winner = try Sleep.parse(edit(r.input, revision: 4, entity: 2,
            original: .init(start: lo + 6_000, end: lo + 6_100), bounds: original))
        let result = Sleep.apply([loser, winner], detected: [fakeSession(oldOriginal)], input: r.input, loaded: r.loaded)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].identity.editEntity, winner.row.entity)
        for (b, kept) in [(Sleep.Bounds(start: lo + 99, end: lo + 120), false),
                          (.init(start: lo + 100, end: lo + 120), true), (.init(start: lo + 101, end: lo + 120), true)] {
            let dismissed = try Sleep.parse(edit(r.input, original: original, dismissed: true))
            let result = Sleep.apply([dismissed], detected: [fakeSession(b)], input: r.input, loaded: r.loaded)
            XCTAssertEqual(result.entries.count, kept ? 1 : 0)
        }
    }

    func testSparseNativeStagingRetainsHolesAndEmptyFallbackIsNotObservation() async throws {
        for v2 in [false, true] {
            var input = configured(try F.input("s12-sparse-\(v2)"), ["useSleepStagerV2": .bool(v2)])
            let lo = try V.validate(input).dayLo, b = Sleep.Bounds(start: lo + 7, end: lo + 307)
            for offset in [1, 2, 121, 122] {
                F.append(&input, .hr, b.start + offset, ["bpm": .number(55)])
                F.append(&input, .gravity, b.start + offset, ["x": .number(0), "y": .number(0), "z": .number(1)])
            }
            input.journal.append(edit(input, original: b))
            let r = try await run(input), e = r.sleep.entries[0]
            XCTAssertTrue(e.staging.admissionMet)
            XCTAssertEqual(e.staging.observedEpochs, [0, 4])
            XCTAssertFalse(e.staging.unmasked.isEmpty)
            XCTAssertFalse(e.session.stages.isEmpty)
            for segment in e.session.stages {
                for t in segment.start..<segment.end { XCTAssertTrue([0, 4].contains((t - b.start) / 30)) }
            }
            XCTAssertFalse(e.session.stages.contains { $0.start <= b.start + 60 && $0.end > b.start + 60 })
            XCTAssertFalse(e.session.stages.contains { $0.end > b.start + 150 })
            var empty = input; empty.raw = []
            let absent = try await run(empty)
            XCTAssertFalse(absent.sleep.entries[0].staging.admissionMet)
            XCTAssertTrue(absent.sleep.entries[0].session.stages.isEmpty)
            let rawFallback = v2 ? SleepStagerV2.stageSession(start: b.start, end: b.end, grav: [], hr: [], rr: [], resp: [])
                : SleepStager.stageSession(start: b.start, end: b.end, grav: [], hr: [], rr: [], resp: [])
            XCTAssertFalse(rawFallback.isEmpty, "Named native fallback disagreement must stay visible")
            XCTAssertNil(absent.native.daily.totalSleepMin)
        }
    }

    func testPresenceThresholdsUsePositiveHRAndGravityWithoutInventingValidity() async throws {
        for (v2, hrs, gravs, admitted) in [(false, 2, 0, false), (false, 0, 2, true),
            (true, 2, 0, true), (true, 0, 2, true), (true, 1, 1, false)] {
            var input = configured(try F.input(), ["useSleepStagerV2": .bool(v2)])
            let lo = try V.validate(input).dayLo, b = Sleep.Bounds(start: lo, end: lo + 300)
            for n in 0..<hrs { F.append(&input, .hr, lo + n, ["bpm": .number(55)]) }
            for n in 0..<gravs { F.append(&input, .gravity, lo + n, ["x": .number(0), "y": .number(0), "z": .number(1)]) }
            F.append(&input, .hr, lo + 5, ["bpm": .number(0)], id: "zero-hr")
            F.append(&input, .hr, b.end, ["bpm": .number(55)], id: "touching-end-hr")
            input.journal.append(edit(input, original: b))
            let r = try await run(input), support = r.sleep.entries[0].staging
            XCTAssertEqual(support.admissionMet, admitted)
            XCTAssertFalse(support.hrIDs.contains("zero-hr"))
            XCTAssertFalse(support.hrIDs.contains("touching-end-hr"))
        }
    }

    func testLatestRevisionMovesBackwardForeignFutureRowsAreRetainedAndIDsStayStable() async throws {
        var input = try F.input("s12-identity")
        let lo = try V.validate(input).dayLo, original = Sleep.Bounds(start: lo + 500, end: lo + 1_000)
        let earlier = Sleep.Bounds(start: lo + 100, end: lo + 400)
        input.journal += [edit(input, original: original), edit(input, revision: 4, original: original, bounds: earlier, day: "2026-06-14"),
            edit(input, revision: 5, original: original, dismissed: true, day: "2026-06-16"),
            edit(input, revision: 6, original: original, dismissed: true, owner: F.foreign),
            edit(input, revision: 7, original: original, dismissed: true, device: F.otherDevice)]
        F.append(&input, .hr, input.asOfExclusive, ["bpm": .number(200)], id: "future")
        F.append(&input, .gravity, earlier.start, ["x": .number(0), "y": .number(0), "z": .number(1)], id: "foreign", owner: F.foreign)
        let r = try await run(input), e = r.sleep.entries[0]
        XCTAssertEqual(e.bounds, earlier)
        XCTAssertEqual(e.identity.original, original)
        XCTAssertEqual(e.identity.id, String(input.journal[2].entity.dropFirst(6)))
        XCTAssertTrue(e.staging.hrIDs.isEmpty)
        XCTAssertTrue(e.staging.gravityIDs.isEmpty)
        XCTAssertEqual(r.sleep.input.journal, input.journal)
        XCTAssertEqual(r.sleep.input.raw, input.raw)
        let first = Sleep.detectedIdentity(input, original)
        var changed = input; changed.day = "2026-06-16"
        changed.identity = C.Identity(userId: F.owner, sourceDeviceId: F.device, algorithmVersion: "different-algorithm")
        let later = Sleep.detectedIdentity(changed, .init(start: original.start, end: original.end + 30))
        XCTAssertEqual(first.id, later.id)
        XCTAssertNotEqual(first.original, later.original)
        XCTAssertEqual(UUID(uuidString: first.id)?.uuidString.lowercased(), first.id)
        XCTAssertEqual(Array(first.id)[14], "3")
    }

    func testExplicitNapAndSplitNightKeepOriginalIndicesAndMainBoundaryID() async throws {
        var input = configured(try F.input("s12-split"), ["dayCycleMode": .string("sleep_onset")])
        let lo = try V.validate(input).dayLo
        let spans = [Sleep.Bounds(start: lo - 3_600, end: lo + 600), .init(start: lo + 1_200, end: lo + 8_400),
                     .init(start: lo + 9_000, end: lo + 16_200)]
        for (i, b) in spans.enumerated() { input.journal.append(edit(input, revision: Int64(3 + i), entity: i + 1,
            original: b, nap: i == 0, stages: stages(b))) }
        let r = try await run(input)
        XCTAssertEqual(r.native.sleepSessions.count, 3)
        let main = Sleep.mainIndices(r.native, prepared: r.prepared, resolved: r.sleep)
        XCTAssertEqual(main, [1, 2])
        let cycle = try await r.cycle()
        XCTAssertEqual(cycle.window.startInclusive, spans[1].start)
        XCTAssertEqual(cycle.window.id, r.sleep.entries[1].identity.id)
        XCTAssertEqual(cycle.window.source, "edited_sleep")
        XCTAssertTrue(cycle.openAtCutoff)
        XCTAssertEqual(cycle.window.endExclusive, input.asOfExclusive)
    }

    func testClosedCalendarDSTAndNonHourTravelUsesDNotEmptyNextDay() async throws {
        for (day, zone, seconds) in [("2026-03-08", "America/Los_Angeles", 82_800), ("2026-11-01", "America/Los_Angeles", 90_000),
            ("2026-04-05", "Australia/Lord_Howe", 88_200), ("2026-10-04", "Australia/Lord_Howe", 84_600),
            ("2026-06-15", "Asia/Kathmandu", 86_400)] {
            let input = try F.input("s12-\(day)-\(zone.replacingOccurrences(of: "/", with: "-"))", day: day, zone: zone)
            let r = try await run(input), cycle = try await r.cycle()
            let bounds = try DayCycleResolver.localDayBounds(day: day, timezone: TimeZone(identifier: zone)!)
            XCTAssertEqual(cycle.window.startInclusive, bounds.lowerBound)
            XCTAssertEqual(cycle.window.endExclusive, bounds.upperBound)
            XCTAssertEqual(bounds.count, seconds)
            XCTAssertEqual(cycle.window.id, "calendar:" + day)
            XCTAssertFalse(cycle.openAtCutoff)
            let next = DayCycleResolver.calendarWindow(now: input.asOfExclusive, offsetSec: r.loaded.evidence.bounds.tzOffsetSeconds,
                timezone: TimeZone(identifier: zone))
            XCTAssertEqual(next.startInclusive, next.endExclusive)
            XCTAssertNotEqual(cycle.window.id, next.id)
        }
    }

    func testColdFallbackNoFutureBoundaryAndForeignPriorIsRejected() async throws {
        var input = configured(try F.input("s12-cold"), ["dayCycleMode": .string("sleep_onset")])
        let b = Sleep.Bounds(start: input.asOfExclusive, end: input.asOfExclusive + 10_800)
        input.journal.append(edit(input, original: b, stages: stages(b)))
        let r = try await run(input), cycle = try await r.cycle()
        XCTAssertTrue(r.native.sleepSessions.isEmpty)
        XCTAssertEqual(cycle.window.source, "calendar")
        XCTAssertEqual(cycle.window.displayDay, input.day)
        var next = configured(try F.input("s12-next", day: "2026-06-16", zone: "Asia/Kathmandu"), ["dayCycleMode": .string("sleep_onset")])
        next.historyCaseIds = [input.id]
        let n = try await run(next), traveling = try await n.cycle([cycle.prior])
        XCTAssertEqual(traveling.window.native, try Cycle.calendar(next))
        var foreign = next
        foreign.identity = C.Identity(userId: F.foreign, sourceDeviceId: F.device, algorithmVersion: next.identity.algorithmVersion)
        let f = try await run(foreign)
        do { _ = try await f.cycle([cycle.prior]); XCTFail("Foreign prior adopted") }
        catch { XCTAssertEqual(error as? C.Failure, .invalid("s10:s12_cycle_prior_scope")) }
    }

    func testOtherDisplayDayUnavailableAndNative18And40HourSyntheticBoundaries() async throws {
        var first = configured(try F.input("s12-prior", day: "2026-06-14"), ["dayCycleMode": .string("sleep_onset")])
        let lo = try V.validate(first).dayLo
        let late = Sleep.Bounds(start: lo + 20 * 3_600, end: lo + 23 * 3_600 + 1_800)
        first.journal.append(edit(first, original: late, stages: stages(late)))
        let a = try await run(first), previous = try await a.cycle()
        XCTAssertEqual(previous.window.source, "edited_sleep", "Positive native overnight classification before testing inheritance")
        XCTAssertEqual(previous.window.startInclusive, late.start)
        var second = configured(try F.input("s12-current"), ["dayCycleMode": .string("sleep_onset")])
        second.historyCaseIds = [first.id]
        let b = try await run(second), open = try await b.cycle([previous.prior])
        XCTAssertFalse(open.appliesToDay)
        XCTAssertEqual(open.window.displayDay, first.day)
        XCTAssertNil(open.strain); XCTAssertNil(open.steps); XCTAssertNil(open.energy)
        XCTAssertTrue(open.gaps.contains("cycle_other_display_day"))
        let zone = TimeZone(identifier: first.timezone)!
        let fallback = DayCycleResolver.fallbackMidnight(after: late.start, offsetSec: 0, timezone: zone)
        XCTAssertGreaterThanOrEqual(fallback, late.start + 18 * 3_600)
        for age in [40 * 3_600 - 1, 40 * 3_600] {
            let window = DayCycleResolver.activeWindow(mode: .sleepOnset, latestSleep: previous.window.native,
                now: late.start + age, offsetSec: 0, timezone: zone)
            XCTAssertEqual(window.source, age < 40 * 3_600 ? .editedSleep : .syntheticMidnight)
            XCTAssertEqual(window.startInclusive, age < 40 * 3_600 ? late.start : fallback)
        }
        var third = configured(try F.input("s12-third", day: "2026-06-16"), ["dayCycleMode": .string("sleep_onset")])
        third.historyCaseIds = [first.id, second.id]
        let c = try await run(third), synthetic = try await c.cycle([previous.prior, open.prior])
        XCTAssertEqual(synthetic.window.source, "synthetic_midnight")
        XCTAssertEqual(synthetic.window.startInclusive, fallback)
    }

    func testNativeEighteenOClockNapAndExplicitNapDoNotCreateCycleBoundaries() async throws {
        for (hour, nap) in [(18, false), (20, true)] {
            var input = configured(try F.input("s12-nap-\(hour)"), ["dayCycleMode": .string("sleep_onset")])
            let lo = try V.validate(input).dayLo
            let b = Sleep.Bounds(start: lo + hour * 3_600, end: lo + 23 * 3_600 + 1_800)
            input.journal.append(edit(input, original: b, nap: nap, stages: stages(b)))
            let r = try await run(input), cycle = try await r.cycle()
            XCTAssertEqual(r.native.sleepSessions.count, 1)
            XCTAssertEqual(cycle.window.source, "calendar")
            XCTAssertEqual(try V.object(V.array(cycle.classification)[0])["kind"], .string("nap"))
        }
    }

    func testCycleQueriesRetainedOutsideNightRowsExplicitlyAndReportsUnobservedSpan() async throws {
        var first = configured(try F.input("s12-earlier", day: "2026-06-10"), ["dayCycleMode": .string("sleep_onset")])
        let lo = try V.validate(first).dayLo, b = Sleep.Bounds(start: lo, end: lo + 10_800)
        first.journal.append(edit(first, original: b, stages: stages(b)))
        let priorRun = try await run(first), prior = try await priorRun.cycle()
        var later = configured(try F.input("s12-later"), ["dayCycleMode": .string("sleep_onset")])
        later.historyCaseIds = [first.id]
        let fallback = DayCycleResolver.fallbackMidnight(after: lo, offsetSec: 0, timezone: TimeZone(identifier: "UTC"))
        F.append(&later, .hr, fallback + 1, ["bpm": .number(60)], id: "retained-outside-night")
        F.append(&later, .steps, fallback - 1, ["counter": .number(5)], id: "outside-predecessor")
        F.append(&later, .steps, fallback + 1, ["counter": .number(6)], id: "outside-counter")
        let r = try await run(later), cycle = try await r.cycle([prior.prior])
        XCTAssertFalse(r.loaded.evidence.streams["hr"]!.contains { $0.id == "retained-outside-night" })
        XCTAssertEqual(cycle.selected["hr"]?.map(\.id), ["retained-outside-night"])
        XCTAssertEqual(cycle.predecessor?.id, "outside-predecessor")
        XCTAssertTrue(cycle.gaps.contains("cycle_extends_night_selection_explicit_store_query"))
        XCTAssertTrue(cycle.gaps.contains("cycle_hr_start_unobserved"))
        XCTAssertTrue(cycle.gaps.contains("cycle_hr_end_unobserved"))
        XCTAssertFalse(cycle.appliesToDay)
        XCTAssertNil(cycle.energy); XCTAssertNil(cycle.strain); XCTAssertNil(cycle.steps)
        XCTAssertEqual(cycle.input.raw, later.raw)
    }

    func testHRSingleSourceActualPhysiologyAndUnsupportedScopesRemainExplicit() async throws {
        var input = try F.hrOnly()
        let baseline = try await run(input)
        XCTAssertFalse(baseline.native.sleepSessions.isEmpty)
        XCTAssertTrue(baseline.native.sleepSessions.allSatisfy(\.hrOnly))
        let first = try XCTUnwrap(baseline.native.sleepSessions.first)
        input.journal.append(edit(input, original: .init(start: first.start, end: first.end)))
        let v1 = try await run(input)
        XCTAssertTrue(v1.sleep.entries[0].session.hrOnly)
        XCTAssertTrue(v1.sleep.entries[0].session.stages.isEmpty)
        XCTAssertNotNil(v1.native.sleepSessions.first?.restingHR, "Missing motion staging does not erase actual native HR physiology")
        let v2 = try await run(configured(input, ["useSleepStagerV2": .bool(true)]))
        XCTAssertTrue(v2.sleep.entries[0].staging.admissionMet)
        XCTAssertFalse(v2.sleep.entries[0].session.stages.isEmpty)
        let futureScope = configured(input, ["journalContextEnabled": .bool(true)])
        do { _ = try await run(futureScope); XCTFail("Unimplemented full composition accepted") }
        catch { XCTAssertEqual(error as? C.Failure, .invalid("s10:outside_s12_sleep_cycle_scope")) }
        var intraday = input; intraday.asOfExclusive -= 1
        do { _ = try await run(intraday); XCTFail("Intraday fabricated") }
        catch { XCTAssertEqual(error as? C.Failure, .invalid("s10:intraday_unsupported")) }
    }

    func testUnknownFamilySelectionDisagreementIsPreservedAndNotRelabelledForComposition() async throws {
        var input = try F.input("s12-unknown", family: nil, model: "")
        F.append(&input, .rr, input.asOfExclusive - 1, F.rr(channel: nil), id: "legacy")
        F.append(&input, .rr, input.asOfExclusive, F.rr(channel: 5), id: "future-modern")
        let seed = try await S.seed(input), loaded = try await S.load(seed)
        XCTAssertEqual(loaded.evidence.rrPolicy.serverWindowIDs, ["legacy"])
        XCTAssertEqual(loaded.evidence.rrPolicy.shippedStoreIDs, [])
        XCTAssertEqual(seed.input, input)
        do { _ = try await run(input); XCTFail("Unknown source composed as known WHOOP") }
        catch { XCTAssertEqual(error as? C.Failure, .invalid("s10:thermal_unknown_family")) }
    }

    func testUndoRevisionKeepsEditIDAndOriginalAnchorsAcrossMovedBounds() async throws {
        var input = try S11Fixtures.input("2026-06-15")
        let automatic = try await run(input), s = try XCTUnwrap(automatic.native.sleepSessions.first)
        let original = Sleep.Bounds(start: s.start, end: s.end), moved = Sleep.Bounds(start: s.start + 30, end: s.end - 30)
        input.journal.append(edit(input, original: original, bounds: moved))
        let edited = try await run(input)
        input.journal.append(edit(input, revision: 4, original: original, bounds: moved, dismissed: true))
        let dismissed = try await run(input)
        XCTAssertTrue(dismissed.native.sleepSessions.isEmpty)
        input.journal.append(edit(input, revision: 5, original: original, bounds: moved))
        let undo = try await run(input)
        XCTAssertEqual(undo.sleep.entries[0].identity, edited.sleep.entries[0].identity)
        XCTAssertEqual(undo.sleep.entries[0].identity.original, original)
        XCTAssertEqual(try P.reflect(undo.native), try P.reflect(edited.native))
        XCTAssertEqual(undo.sleep.input.raw, automatic.sleep.input.raw)
    }

    func testEditedWHOOP4RetainsActualThermalAnchorAndNativeFunnel() async throws {
        var input = try S11Fixtures.input("2026-06-15", whoop4: true)
        let lo = try V.validate(input).dayLo
        input.journal.append(edit(input, original: .init(start: lo, end: lo + 10_800), bounds: .init(start: lo + 10, end: lo + 10_000)))
        let r = try await run(input)
        XCTAssertNotNil(r.thermal.learnedRaw)
        XCTAssertFalse(r.native.sleepSessions.isEmpty)
        XCTAssertNotNil(r.native.nightlySkinTempC)
        let actual = AnalyticsEngine.skinTempFunnel(r.native.sleepSessions, hr: r.loaded.hr, skinTemp: r.loaded.skinTemp,
            family: .whoop4, anchorRaw: r.thermal.resolvedRaw)
        XCTAssertEqual(r.native.nightlySkinTempC, actual.mean)
        XCTAssertEqual(r.sleep.thermal.rows.map(\.id), r.loaded.evidence.streams["skinTemp"]!.map(\.id))
        XCTAssertEqual(r.sleep.input, input)
    }

    func testInvalidActivityAndFutureProvenanceAreRetainedNotUsedAsCounterPredecessor() async throws {
        var input = try F.input("s12-scalar-admission")
        let lo = try V.validate(input).dayLo
        let future = try ScalarProvenance(origin: .whoopV26PpgDerived, algorithm: .ppgACF, sampleRateHz: 64,
            windowSettingSeconds: 8, inputStartTs: input.asOfExclusive - 7, inputEndTs: input.asOfExclusive + 1,
            inputSHA256: String(repeating: "a", count: 64))
        F.append(&input, .steps, lo - 2, ["counter": .number(1)], id: "older-valid")
        F.append(&input, .steps, lo - 1, ["counter": .number(2), "provenance": try V.json(future)], id: "nearest-future-support")
        F.append(&input, .steps, lo, ["counter": .number(3), "activityClass": .number(3)], id: "invalid-class")
        F.append(&input, .steps, lo + 1, ["counter": .number(4)], id: "one-usable")
        let r = try await run(input), cycle = try await r.cycle()
        XCTAssertNil(cycle.predecessor)
        XCTAssertEqual(cycle.rejectedStepIDs, ["nearest-future-support", "invalid-class"])
        XCTAssertEqual(cycle.selected["steps"]?.map(\.id), ["one-usable"])
        XCTAssertEqual(cycle.retainedByOwner[F.owner.uuidString.lowercased()]?["steps"], 4)
        XCTAssertTrue(cycle.gaps.contains("cycle_counter_pair_unavailable"))
        XCTAssertEqual(cycle.input.raw, input.raw)
    }

    func testRealStoreNearestCounterInvalidDoesNotRescueOlderAndRowsRemainOwned() async throws {
        var input = try F.input("s12-predecessor")
        let lo = try V.validate(input).dayLo
        for (id, ts, count) in [("older", lo - 2, 10), ("nearest-invalid", lo - 1, -1), ("at-lo", lo, 12), ("later", lo + 1, 14)] {
            F.append(&input, .steps, ts, ["counter": .number(Double(count))], id: id)
        }
        F.append(&input, .steps, lo - 1, ["counter": .number(100)], id: "other-device", device: F.otherDevice)
        F.append(&input, .steps, lo, ["counter": .number(200)], id: "other-owner", owner: F.foreign)
        F.append(&input, .steps, input.asOfExclusive, ["counter": .number(250)], id: "future")
        let r = try await run(input), cycle = try await r.cycle()
        XCTAssertNil(cycle.predecessor)
        XCTAssertEqual(cycle.rejectedStepIDs, ["nearest-invalid"])
        XCTAssertEqual(cycle.selected["steps"]?.map(\.id), ["at-lo", "later"])
        XCTAssertEqual(cycle.retainedByOwner[F.owner.uuidString.lowercased()]?["steps"], 6)
        XCTAssertEqual(cycle.retainedByOwner[F.foreign.uuidString.lowercased()]?["steps"], 1)
        XCTAssertEqual(cycle.input.raw, input.raw)
        let after = try await S.load(r.seed)
        XCTAssertEqual(after.evidence.retainedByOwner, cycle.retainedByOwner)
    }

    func testCycleCounterRolloverResetActivityRateAndPageSplittingUseActualNativeCounter() async throws {
        var input = configured(try F.input("s12-counter"), ["dayCycleMode": .string("sleep_onset")])
        let lo = try V.validate(input).dayLo, b = Sleep.Bounds(start: lo, end: lo + 10_800)
        input.journal.append(edit(input, original: b, stages: stages(b)))
        let vectors: [(Int, Int, Int?)] = [(-1, 65_534, 0), (0, 0, 1), (1, 2, 1), (2, 4, 1), (3, 6, 1), (4, 8, 1),
            (100, 10, 1), (101, 11, 0), (102, 50, 1), (103, 0, 1), (10_801, 2, 1)]
        for (index, v) in vectors.enumerated() { F.append(&input, .steps, lo + v.0,
            ["counter": .number(Double(v.1)), "activityClass": v.2.map { .number(Double($0)) } ?? .null,], id: "step-\(index)") }
        let r = try await run(input), cycle = try await r.cycle()
        let loaded = try await Cycle.load(r.seed, window: cycle.window.native)
        XCTAssertEqual(cycle.predecessor?.id, "step-0")
        func accumulate(_ pages: [[StepSample]]) -> SleepAwareStepCounter.Count {
            let acc = SleepAwareStepCounter.Accumulator(sleepSessions: r.native.sleepSessions, hasActivityClasses: true)
            acc.observeMotion(gravityCount: loaded.gravity.count, auxCount: 0)
            for page in pages { acc.acceptPage(page) }
            return acc.finish()
        }
        let count = accumulate([loaded.steps])
        XCTAssertGreaterThan(count.acceptedSleepBoutTicks, 0)
        XCTAssertGreaterThan(count.rejectedIsolatedSleepTicks, 0)
        XCTAssertGreaterThan(count.rejectedActivityClassTicks, 0)
        XCTAssertGreaterThan(count.rejectedImplausibleTicks, 0)
        XCTAssertGreaterThan(count.acceptedOutsideSleepTicks, 0)
        XCTAssertEqual(cycle.counter, try P.reflect(count))
        XCTAssertEqual(cycle.steps, count.totalTicks)
        for index in 1..<loaded.steps.count { XCTAssertEqual(count, accumulate([Array(loaded.steps.prefix(index)), Array(loaded.steps.dropFirst(index))])) }
    }

    func testNativeEnergyStrainUseExactCycleIntervalNoFutureAndNoEmptyZeroClaim() async throws {
        for method in ["EDWARDS", "BANISTER"] {
            var input = configured(try F.input("s12-energy-\(method)"), ["dayCycleMode": .string("sleep_onset"), "effortMethod": .string(method)])
            let lo = try V.validate(input).dayLo, b = Sleep.Bounds(start: lo - 3_600, end: lo + 10_800)
            input.journal.append(edit(input, original: b, stages: stages(b)))
            for (index, ts) in stride(from: b.start, to: input.asOfExclusive, by: 60).enumerated() {
                F.append(&input, .hr, ts, ["bpm": .number(Double(index % 4 == 0 ? 110 : 60))])
            }
            F.append(&input, .hr, b.start - 1, ["bpm": .number(200)], id: "before")
            F.append(&input, .hr, input.asOfExclusive, ["bpm": .number(200)], id: "future")
            let r = try await run(input), cycle = try await r.cycle()
            let loaded = try await Cycle.load(r.seed, window: cycle.window.native)
            let p = try Sleep.profile(r.loaded.evidence), maxHR = StrainScorer.tanakaHRmax(age: p.age)
            let restingHR = r.native.daily.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
            XCTAssertEqual(cycle.energy, Cycle.Energy(Calories.estimateDayEnergy(loaded.hr, profile: p, hrmax: maxHR, restingHR: restingHR)))
            XCTAssertEqual(cycle.strain, StrainScorer.strain(loaded.hr, maxHR: maxHR, restingHR: restingHR,
                method: method == "BANISTER" ? .banister : .edwards, sex: p.sex))
            XCTAssertFalse(cycle.selected["hr"]!.map(\.id).contains("future"))
            XCTAssertFalse(cycle.selected["hr"]!.map(\.id).contains("before"))
            XCTAssertEqual(cycle.activeKcalEst, cycle.energy?.totalKcal)
            XCTAssertGreaterThan(try XCTUnwrap(cycle.energy?.observedSeconds), 0)
            var empty = input; empty.raw = []
            let e = try await run(empty), noData = try await e.cycle()
            XCTAssertNil(noData.energy); XCTAssertNil(noData.strain); XCTAssertNil(noData.activeKcalEst)
            XCTAssertTrue(noData.gaps.contains("cycle_hr_unavailable"))
        }
    }

    func testCycleEvidenceExportsDiagnosticsButCannotDecodeAnExecutionPrior() async throws {
        let evidenceType: Any.Type = Cycle.CycleEvidence.self
        let priorType: Any.Type = Cycle.PriorResolvedSleep.self
        XCTAssertTrue(evidenceType is any Encodable.Type)
        XCTAssertFalse(evidenceType is any Decodable.Type, "Imported output must not mint an execution prior")
        XCTAssertFalse(priorType is any Decodable.Type)
        XCTAssertFalse(priorType is any Encodable.Type)

        let first = configured(try F.input("s12-sealed-prior", day: "2026-06-14"), ["dayCycleMode": .string("sleep_onset")])
        let firstRun = try await run(first), actualPrior = try await firstRun.cycle()
        XCTAssertEqual(actualPrior.window.native, try Cycle.calendar(first))
        var next = configured(try F.input("s12-sealed-next"), ["dayCycleMode": .string("sleep_onset")])
        next.historyCaseIds = [first.id]
        let nextRun = try await run(next), before = try await nextRun.cycle([actualPrior.prior])
        XCTAssertEqual(before.window.native, try Cycle.calendar(next))

        let originalBytes = try C.bytes(actualPrior)
        let original = try V.object(V.json(actualPrior))
        var report = original, window = try V.object(try XCTUnwrap(report["window"]))
        window["source"] = .string("edited_sleep")
        window["id"] = .string("diagnostic-only-window-with-no-native-sleep")
        window["startInclusive"] = .number(Double(try V.validate(first).dayLo + 20 * 3_600))
        window["displayDay"] = .string(next.day)
        report["window"] = .object(window)
        XCTAssertEqual(report["input"], original["input"])
        XCTAssertEqual(report["inputDigest"], original["inputDigest"])
        XCTAssertNotEqual(report["window"], original["window"])
        let diagnosticBytes = try C.bytes(C.JSON.object(report))
        XCTAssertEqual(try JSONDecoder().decode(C.JSON.self, from: diagnosticBytes), .object(report))
        XCTAssertNotEqual(diagnosticBytes, originalBytes)
        XCTAssertEqual(try C.bytes(actualPrior), originalBytes, "Diagnostic copies cannot mutate the executed evidence")
        let after = try await nextRun.cycle([actualPrior.prior])
        XCTAssertEqual(after, before)
    }

    func testIndependentStoreRepeatabilitySourceInventoryAndImmutableHistoricalManifests() async throws {
        let hashes = try Sleep.sourceHashes()
        var input = try S11Fixtures.input("2026-06-15")
        let lo = try V.validate(input).dayLo, b = Sleep.Bounds(start: lo + 10, end: lo + 10_000)
        input.journal.append(edit(input, original: .init(start: lo, end: lo + 10_800), bounds: b))
        let a = try await run(input), bRun = try await run(input)
        XCTAssertEqual(a.sleep, bRun.sleep)
        XCTAssertEqual(try P.reflect(a.native), try P.reflect(bRun.native))
        let first = try await a.cycle(), second = try await bRun.cycle()
        XCTAssertEqual(first, second)
        XCTAssertEqual(try Sleep.sourceHashes(), hashes)
        XCTAssertEqual(hashes["Tests/Fixtures/w4-whole-day-swift-v1/manifest.json"], "d948f5b7dffbd71dece63586ecce08fb3c497c87995bf2685d6469d0782fa245")
        XCTAssertEqual(hashes["Tests/Fixtures/w4-whole-day-swift-v2/manifest.json"], "a12ec687e5d075c52825c1fb45b8680d239059b403a756d81940d330b9ae5b86")
        if let directory = ProcessInfo.processInfo.environment["S12_EVIDENCE_DIRECTORY"] {
            struct Probe: Encodable {
                let schemaVersion = 1
                let recipe = "s12-actual-swift-sleep-cycle-probe-v1"
                let mode = "sleep_cycle_probe_not_server_day"
                let sourceHashes: [String: String]
                let sleep: Sleep.ResolvedSleep
                let cycle: Cycle.CycleEvidence
            }
            let bytes = try C.bytes(Probe(sourceHashes: hashes, sleep: a.sleep, cycle: first))
            let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
            guard root == root.resolvingSymlinksInPath(), root != P.repository,
                  !root.path.hasPrefix(P.repository.path + "/"), FileManager.default.fileExists(atPath: root.path) else {
                throw V.failure("s12_external_directory")
            }
            let target = root.appendingPathComponent("sleep-cycle-probe.json")
            try bytes.write(to: target, options: .withoutOverwriting)
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            XCTAssertThrowsError(try V.decode(bytes), "A sleep/cycle probe is not a server_day input/corpus")
        }
        print("S12 independent stores: actual sleep/complete DayResult/cycle equality; \(hashes.count) current source hashes and both historical manifests unchanged")
    }
}
