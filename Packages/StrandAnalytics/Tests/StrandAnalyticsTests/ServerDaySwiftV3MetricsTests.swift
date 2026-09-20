import Foundation
import WhoopProtocol
import WhoopStore
import XCTest
@testable import StrandAnalytics

enum S14Fixtures {
    typealias C = ServerDaySwiftContract
    typealias V = ServerDaySwiftV3Contract
    typealias X = ServerDaySwiftV3Context
    typealias M = ServerDaySwiftV3Metrics
    typealias I = ServerDaySwiftV3Imports
    static func consent(_ purpose: String) -> C.JSON {
        .object(["purpose": .string(purpose), "policyVersion": .number(1),
            "decisionId": .string("55555555-5555-4555-8555-555555555555")])
    }
    static func imported(_ context: X.Execution, kind: I.Kind = .apple, entity: String = "import:apple",
                         revision: Int64 = 100, values: [String: Double?], day: String? = nil, deleted: Bool = false) -> C.JournalRow {
        let i = context.observation.input, day = day ?? i.day
        let fields = values.mapValues { $0.map(C.JSON.number) ?? .null }
        let payload: [String: C.JSON] = ["schemaVersion": .number(1), "day": .string(day), "timezone": .string(i.timezone),
            "source": .object(["kind": .string(kind.rawValue), "externalDeviceId": .string(entity), "method": .string("synthetic-supplied")]),
            "values": .object(fields.mapValues { $0 }.reduce(into: [String: C.JSON]()) { result, field in
                result[field.key] = .object(["value": field.value, "unit": .string(I.units[field.key] ?? "unknown")])
            }), "consent": consent("imported_metrics")]
        return C.JournalRow(userId: i.identity.userId, sourceDeviceId: i.identity.sourceDeviceId, kind: .importedDaily,
            entity: entity, revision: revision, effectiveDay: day, deleted: deleted, payload: deleted ? [:] : payload)
    }
    static func replace(_ row: C.JournalRow, payload: [String: C.JSON]? = nil, revision: Int64? = nil,
                        day: String? = nil, deleted: Bool? = nil, owner: UUID? = nil, device: UUID? = nil) -> C.JournalRow {
        .init(userId: owner ?? row.userId, sourceDeviceId: device ?? row.sourceDeviceId, kind: row.kind,
            entity: row.entity, revision: revision ?? row.revision, effectiveDay: day ?? row.effectiveDay,
            deleted: deleted ?? row.deleted, payload: payload ?? row.payload)
    }
    static func evaluate(_ input: V.Input) async throws -> M.Execution {
        let x = try await X.run(input)
        return try await M.evaluate(context: x, supplements: M.Supplements(x))
    }
    static func history(_ count: Int) async throws -> [M.Execution] {
        var xs: [X.Execution] = [], ms: [M.Execution] = []
        for index in 0..<count {
            var input = try S11Fixtures.input(S11Fixtures.day(index), variation: 36 + index % 5 * 2)
            input.id = "s14-history-\(index)"; input.historyCaseIds = xs.map { $0.observation.input.id }
            let lo = try V.validate(input).dayLo
            for offset in stride(from: 36_000, through: 39_600, by: 30) {
                S10Fixtures.append(&input, .hr, lo + offset, ["bpm": .number(Double(90 + index % 5 * 8))])
                S10Fixtures.append(&input, .gravity, lo + offset, ["x": .number(offset % 60 == 0 ? 0 : 1), "y": .number(0), "z": .number(1)])
                S10Fixtures.append(&input, .steps, lo + offset, ["counter": .number(Double(offset - 36_000) / 30), "activityClass": .number(1)])
            }
            let x = try await X.run(input, history: xs.map(\.prior), restart: xs.last?.restart)
            var supplements = M.Supplements(x)
            supplements.originalJournalRows = [imported(x, values: ["steps_count": Double(4_000 + index * 10)])]
            let m = try await M.evaluate(context: x, history: xs, supplements: supplements, priorDetails: ms.map(\.prior))
            xs.append(x); ms.append(m)
        }
        return ms
    }
}

enum S14RepairFixtures {
    typealias C = ServerDaySwiftContract
    typealias V = ServerDaySwiftV3Contract
    static func configured(_ input: V.Input, _ flags: [String: C.JSON]) -> V.Input {
        var result = input, payload = input.journal[1].payload
        payload.merge(flags) { _, new in new }
        result.journal[1] = S10Fixtures.journal(.config, 2, day: input.day, payload: payload)
        return result
    }
    static func sleep(_ input: inout V.Input, start: Int, end: Int, awake: Range<Int>? = nil) {
        // Explicit supplied stages are input observations, not an expected native detection.
        let parts: [(Int, Int, String)] = awake.map {
            [(start, $0.lowerBound, "light"), ($0.lowerBound, $0.upperBound, "wake"), ($0.upperBound, end, "light")]
        } ?? [(start, end, "light")]
        let stages = parts.filter { $0.1 > $0.0 }.map { a, b, stage in
            C.JSON.object(["start": .number(Double(a)), "end": .number(Double(b)), "stage": .string(stage)])
        }
        let payload: [String: C.JSON] = ["schemaVersion": .number(1), "originalStart": .number(Double(start)),
            "originalEnd": .number(Double(end)), "start": .number(Double(start)), "end": .number(Double(end)),
            "isNap": .bool(false), "dismissed": .bool(false), "stages": .array(stages)]
        input.journal.append(C.JournalRow(userId: input.identity.userId, sourceDeviceId: input.identity.sourceDeviceId,
            kind: .sleepEdit, entity: String(format: "sleep:99999999-9999-4999-8999-%012d", start), revision: 30,
            effectiveDay: input.day, deleted: false, payload: payload))
        for ts in stride(from: start, to: end, by: 30) where !(awake?.contains(ts) ?? false) {
            S10Fixtures.append(&input, .hr, ts, ["bpm": .number(60)], id: "quiet-hr-\(ts)")
            S10Fixtures.append(&input, .gravity, ts, ["x": .number(0), "y": .number(0), "z": .number(1)], id: "quiet-gravity-\(ts)")
        }
    }
    static func burst(_ input: inout V.Input, start: Int) {
        for offset in 0...2_100 {
            let ts = start + offset
            S10Fixtures.append(&input, .hr, ts, ["bpm": .number(offset < 1_800 ? 170 : 60)], id: "burst-hr-\(ts)")
            S10Fixtures.append(&input, .gravity, ts, ["x": .number(offset % 2 == 0 ? 0 : 1), "y": .number(0), "z": .number(1)], id: "burst-gravity-\(ts)")
        }
    }
    static func onsetDay(_ day: String = "2026-06-15") throws -> V.Input {
        var input = configured(try S10Fixtures.input("s14-onset-\(day)", day: day), ["dayCycleMode": .string("sleep_onset")])
        let lo = try V.validate(input).dayLo
        sleep(&input, start: lo + 3_600, end: lo + 4 * 3_600)
        burst(&input, start: lo)
        burst(&input, start: lo + 10 * 3_600)
        return input
    }
}

private actor S14HistoryCache {
    static let shared = S14HistoryCache()
    private var job: Task<[ServerDaySwiftV3Metrics.Execution], Error>?
    func get() async throws -> [ServerDaySwiftV3Metrics.Execution] {
        if let job { return try await job.value }
        let task = Task { try await S14Fixtures.history(43) }; job = task
        return try await task.value
    }
}

final class ServerDaySwiftV3MetricsTests: XCTestCase {
    private typealias F = S14Fixtures
    private typealias C = ServerDaySwiftContract
    private typealias V = ServerDaySwiftV3Contract
    private typealias X = ServerDaySwiftV3Context
    private typealias M = ServerDaySwiftV3Metrics
    private typealias D = ServerDaySwiftV3Metadata
    private typealias I = ServerDaySwiftV3Imports
    private typealias P = ServerDaySwiftV3CoreProbe

    func testP2FullExecutionPreservesEveryRetainedForeignInt64Revision() async throws {
        let context = try await X.run(S10Fixtures.input("s14-foreign-int64"))
        let revisions: [Int64] = [9_007_199_254_740_993, Int64.max, Int64.min]
        let rows = revisions.enumerated().map { index, revision in
            C.JournalRow(userId: S10Fixtures.foreign, sourceDeviceId: S10Fixtures.device,
                kind: index == 1 ? .importedDaily : .manualWorkout, entity: "foreign-retained-\(index)",
                revision: revision, effectiveDay: context.observation.input.day, deleted: index == 2,
                payload: index == 2 ? [:] : ["explicitNull": .null, "observedZero": .number(0)])
        }
        var supplements = M.Supplements(context)
        supplements.originalJournalRows = rows
        let result = try await M.evaluate(context: context, supplements: supplements)
        let control = try await M.evaluate(context: context, supplements: M.Supplements(context))
        XCTAssertEqual(result.projection, control.projection)
        XCTAssertNotEqual(result.digest, control.digest)
        XCTAssertEqual(result.supplements.originalJournalRows, rows)
        struct Rows: Decodable { let originalRows: [C.JournalRow] }
        struct Workouts: Decodable { let resolution: Rows }
        struct Native: Decodable { let imports: Rows; let workouts: Workouts }
        struct Supplements: Decodable { let originalJournalRows: [C.JournalRow] }
        struct Complete: Decodable { let native: Native; let supplements: Supplements; let combinedJournal: [C.JournalRow] }
        let bytes = try C.bytes(result)
        let decoded = try JSONDecoder().decode(Complete.self, from: bytes)
        XCTAssertEqual(decoded.supplements.originalJournalRows, rows)
        XCTAssertEqual(decoded.combinedJournal, result.combinedJournal)
        XCTAssertEqual(decoded.native.imports.originalRows, result.combinedJournal)
        XCTAssertEqual(decoded.native.workouts.resolution.originalRows, result.combinedJournal)
        XCTAssertEqual(Array(decoded.native.imports.originalRows.suffix(rows.count)).map(\.revision), revisions)
        XCTAssertEqual(decoded.native.imports.originalRows.last?.payload, [:])
        XCTAssertEqual(decoded.native.workouts.resolution.originalRows.dropLast().last?.payload["explicitNull"], .null)
        XCTAssertNil(decoded.native.workouts.resolution.originalRows.dropLast().last?.payload["missing"])
        var invalid = M.Supplements(context)
        invalid.originalJournalRows = [F.replace(rows[0], owner: S10Fixtures.owner)]
        do { _ = try await M.evaluate(context: context, supplements: invalid); XCTFail("Unsafe owned revision admitted") }
        catch { XCTAssertEqual(error as? C.Failure, .invalid("journal_identity")) }
    }

    func testP2CycleHistoryLoadsMatchPublishedStrainAndKeepResetMethodFences() async throws {
        var history: [X.Execution] = [], details: [M.Execution] = []
        for index in 0..<14 {
            var input = try S14RepairFixtures.onsetDay(S11Fixtures.day(index, start: "2026-06-01"))
            input.historyCaseIds = history.map { $0.observation.input.id }
            let context = try await X.run(input, history: history.map(\.prior), restart: history.last?.restart)
            XCTAssertTrue(context.observation.cycle.appliesToDay)
            let calendar = try XCTUnwrap(context.observation.native.daily.strain)
            let cycle = try XCTUnwrap(context.observation.cycle.strain)
            XCTAssertNotEqual(calendar, cycle, "Discriminative calendar-versus-onset raw input")
            let out = try await M.evaluate(context: context, history: history, supplements: M.Supplements(context), priorDetails: details.map(\.prior))
            XCTAssertEqual(out.projection.metrics["strain"]?.value, cycle)
            XCTAssertEqual(out.native.admittedDays.last?.strain, cycle)
            XCTAssertEqual(out.native.readinessDays.last?.strain, cycle)
            history.append(context); details.append(out)
        }
        let last = try XCTUnwrap(details.last), today = last.native.context.observation.input.day
        let expected = history.map { TrainingLoadEngine.DailyLoad(day: $0.observation.input.day, load: $0.observation.cycle.strain) }
        let calendar = history.map { TrainingLoadEngine.DailyLoad(day: $0.observation.input.day, load: $0.observation.native.daily.strain) }
        XCTAssertEqual(last.native.training, TrainingLoadEngine.evaluate(days: expected, through: today))
        XCTAssertNotNil(last.native.training.chronicLoad)
        XCTAssertNotEqual(last.native.training.chronicLoad, TrainingLoadEngine.evaluate(days: calendar, through: today).chronicLoad)
        let nextDay = try X.shift(today, 1)
        let variants: [[String: C.JSON]] = [
            ["recoveryBaselineEpoch": .number(Double(try C.dayBounds(nextDay, "UTC").lowerBound))],
            ["effortMethod": .string("BANISTER")]
        ]
        for flags in variants {
            var input = S14RepairFixtures.configured(try S14RepairFixtures.onsetDay(nextDay), flags)
            input.historyCaseIds = history.map { $0.observation.input.id }
            let context = try await X.run(input, history: history.map(\.prior))
            let out = try await M.evaluate(context: context, history: history, supplements: M.Supplements(context), priorDetails: details.map(\.prior))
            XCTAssertTrue(out.native.admittedDays.dropLast().allSatisfy { $0.strain == nil })
            XCTAssertEqual(out.native.admittedDays.last?.strain, context.observation.cycle.strain)
            XCTAssertNotNil(out.native.admittedDays.last?.strain)
            XCTAssertEqual(out.native.training.contiguousDays, 1)
        }
    }

    func testP2EmptyTargetDoesNotCarryConsistencyButExplicitImportsStillWin() async throws {
        let history = try await F.history(3), last = try XCTUnwrap(history.last)
        XCTAssertNotNil(last.projection.metrics["sleep_consistency"]?.value)
        var input = try S10Fixtures.input("s14-empty-target-consistency", day: X.shift(last.native.context.observation.input.day, 1))
        input.historyCaseIds = history.map { $0.native.context.observation.input.id }
        let context = try await X.run(input, history: history.map { $0.native.context.prior })
        XCTAssertTrue(context.observation.checkpoint.observation.measurements.sleep.isEmpty)
        let base = try await M.evaluate(context: context, history: history.map(\.native.context),
            supplements: M.Supplements(context), priorDetails: history.map(\.prior))
        XCTAssertNil(base.projection.metrics["sleep_consistency"]?.value)
        XCTAssertEqual(base.projection.metrics["sleep_consistency"]?.status, .unavailable)
        for value in [0.0, 42.0] {
            var supplements = M.Supplements(context)
            supplements.originalJournalRows = [F.imported(context, values: ["sleep_consistency_pct": value])]
            let imported = try await M.evaluate(context: context, history: history.map(\.native.context),
                supplements: supplements, priorDetails: history.map(\.prior))
            XCTAssertEqual(imported.projection.metrics["sleep_consistency"]?.value, value)
            XCTAssertEqual(imported.projection.metrics["sleep_consistency"]?.method.text, "imported:apple_health:synthetic-supplied")
            XCTAssertEqual(imported.native.context.digest, base.native.context.digest)
            XCTAssertTrue(imported.native.context.observation.checkpoint.observation.measurements.sleep.isEmpty)
        }
    }

    func test01EmptyNativeComponentsAreExplicitUnknownNotWholeAdmission() async throws {
        let out = try await F.evaluate(S10Fixtures.input())
        XCTAssertEqual(out.mode, "presentation_components_not_server_day")
        XCTAssertEqual(Set(out.projection.metrics.keys), D.nativeKeys)
        XCTAssertEqual(Set(out.projection.details.keys), D.detailKeys)
        for key in ["hrv_rmssd_ms", "steps", "stress", "exercise_count", "fitness_age", "vitality"] {
            XCTAssertNil(out.projection.metrics[key]?.value, key)
            XCTAssertEqual(out.projection.metrics[key]?.status, .unavailable, key)
        }
        XCTAssertEqual(out.projection.metrics["sleep_need_min"]?.value, out.native.context.observation.checkpoint.needHours * 60)
        XCTAssertTrue(out.projection.gaps.contains("whole_combined_input_not_admitted"))
        let encoded = try V.object(V.json(out.projection.metrics["stress"]!))
        XCTAssertEqual(Set(encoded.keys), ["value", "unit", "status", "method"]); XCTAssertEqual(encoded["value"], .null)
        XCTAssertEqual(out.native.context.observation.input.raw, [])
        XCTAssertEqual(out.history, [])
    }

    func test02StrictlyPriorStressUsesExtractedNativeFormulaAndNoCarry() async throws {
        let all = try await S14HistoryCache.shared.get(), out = all.last!, current = out.native.admittedDays.last!
        let day = current.day, prior = out.native.admittedDays.filter { $0.day < day && $0.day >= (try! X.shift(day, -30)) }
        let rhr = prior.compactMap { $0.restingHr.map(Double.init) }, hrv = prior.compactMap(\.avgHrv)
        let mr = DailyPresentationMath.mean(rhr), mh = DailyPresentationMath.mean(hrv)
        let expected = DailyPresentationMath.dailyStressSquash(DailyPresentationMath.dailyStressRaw(
            rhrToday: current.restingHr.map(Double.init), meanRHR: mr, sdRHR: DailyPresentationMath.populationSD(rhr, mean: mr),
            hrvToday: current.avgHrv, meanHRV: mh, sdHRV: DailyPresentationMath.populationSD(hrv, mean: mh)))
        XCTAssertEqual(out.projection.metrics["stress"]?.value, expected)
        XCTAssertEqual(prior.count, 30)
        var empty = try S10Fixtures.input("empty-after-history", day: X.shift(day, 1))
        empty.historyCaseIds = all.map { $0.native.context.observation.input.id }
        let x = try await X.run(empty, history: all.map { $0.native.context.prior }, restart: all.last?.native.context.restart)
        let noData = try await M.evaluate(context: x, history: all.map(\.native.context), supplements: M.Supplements(x), priorDetails: all.map(\.prior))
        XCTAssertNil(noData.projection.metrics["stress"]?.value)
        XCTAssertNil(noData.projection.metrics["fitness_age"]?.value)
        XCTAssertNil(noData.projection.metrics["vitality"]?.value)
        XCTAssertEqual(noData.history.count, 30)
        XCTAssertEqual(noData.history.last, .object(["day": .string(day), "metrics": try V.json(out.projection.metrics)]))
    }

    func test03DescriptiveAndNormativeNeedRemainDistinctWithImportedZero() async throws {
        let out = try await F.evaluate(S11Fixtures.input("2026-06-15")), x = out.native.context, daily = x.observation.native.daily
        XCTAssertNotNil(daily.totalSleepMin)
        XCTAssertEqual(out.projection.metrics["hours_vs_needed_pct"]?.value,
            DailyPresentationMath.hoursVsNeededPercent(asleepMin: daily.totalSleepMin, needMin: 450))
        var s = M.Supplements(x); s.originalJournalRows = [F.imported(x, values: ["sleep_need_min": 0, "sleep_performance_pct": 77])]
        let imported = try await M.evaluate(context: x, supplements: s)
        XCTAssertNil(imported.projection.metrics["hours_vs_needed_pct"]?.value)
        XCTAssertEqual(imported.projection.metrics["sleep_performance"]?.value, 77)
        XCTAssertEqual(imported.native.context.observation.checkpoint, out.native.context.observation.checkpoint)
        XCTAssertEqual(imported.native.context.observation.native.daily, daily)
        XCTAssertNotEqual(imported.digest, out.digest)
        var combined = x.observation.input; combined.journal += s.originalJournalRows
        do { _ = try await X.run(combined); XCTFail("S13 guard must stay closed") } catch { }
    }

    func test04BedtimeBoundariesDSTTravelAndSaturdayAreNativeCalendarInputs() throws {
        let vectors = [("2026-03-08", "America/Los_Angeles", 82_800), ("2026-11-01", "America/Los_Angeles", 90_000),
            ("2026-10-04", "Australia/Lord_Howe", 84_600), ("2026-04-05", "Australia/Lord_Howe", 88_200)]
        var minutes: [Double] = []
        for (day, zone, seconds) in vectors {
            let b = try C.dayBounds(day, zone); XCTAssertEqual(b.count, seconds)
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: zone)!
            let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(b.lowerBound + 7_200)))
            minutes.append(Double(c.hour! * 60 + c.minute!))
        }
        XCTAssertEqual(DailyPresentationMath.bedtimeConsistencySeries(localBedMinutes: Array(minutes.prefix(2))), [])
        XCTAssertEqual(DailyPresentationMath.bedtimeConsistencySeries(localBedMinutes: Array(repeating: 719, count: 15)).count, 13)
        XCTAssertEqual(DailyPresentationMath.bedtimeConsistencySeries(localBedMinutes: [719, 720, 719]).last, 0)
        XCTAssertEqual(try M.weekKey("2026-06-20"), "2026-06-20")
        XCTAssertEqual(try M.weekKey("2026-06-19"), "2026-06-13")
    }

    func test05SleepDetailsUseActualHypnogramMotionAndOriginalIdentity() async throws {
        var input = try S11Fixtures.input("2026-06-15")
        let lo = try V.validate(input).dayLo
        for offset in stride(from: 0, through: 10_800, by: 30) {
            S10Fixtures.append(&input, .bandState, lo + offset, ["state": .number(1), "rawByte": .number(16)])
        }
        let out = try await F.evaluate(input), o = out.native.context.observation
        let sessions = try V.array(out.projection.details["sleep_sessions"]!)
        XCTAssertFalse(sessions.isEmpty)
        for (entry, json) in zip(o.sleep.entries, sessions) {
            let s = try V.object(json), h = SleepStager.hypnogramMetrics(entry.session.native)
            XCTAssertEqual(s["id"], .string(entry.identity.id))
            XCTAssertEqual(try V.object(s["hypnogram"]!)["asleepS"], .number(h.tstS))
            XCTAssertEqual(try V.array(s["stageInsights"]!).count, 4)
            let chart = out.projection.charts["sleep_hr:" + entry.identity.id]
            XCTAssertNotNil(chart); XCTAssertEqual(out.projection.chartMetadata["sleep_motion:" + entry.identity.id],
                D.chartMetadata(unit: "gravity_delta", session: entry.identity.id, signal: "consecutive_gravity_l2_delta"))
        }
    }

    func test06ChargeEveryNativeVerdictMapsWithoutParsingRoundedValues() throws {
        let state = BaselineState(baseline: 60, spread: 6, nValid: 20, nightsSinceUpdate: 0, status: .trusted)
        var seen = Set<String>()
        for hrv in [20.0, 59.0, 60.0, 61.0, 100.0] {
            for rhr in [40.0, 60.0, 90.0] {
                for perf in [0.2, 0.7, 0.9] {
                    for temp in [-2.0, 0, 2.0] {
                        let drivers = RecoveryScorer.chargeDrivers(hrv: hrv, rhr: rhr, resp: 15,
                            hrvBaseline: state, rhrBaseline: state, respBaseline: .init(baseline: 15, spread: 1, nValid: 20, nightsSinceUpdate: 0, status: .trusted), sleepPerf: perf, skinTempDev: temp)
                        let mapped = try D.charge(drivers, values: ["heart_rate_variability": (hrv, 60), "resting_heart_rate": (rhr, 60),
                            "respiratory_rate": (15, 15), "sleep_quality": (perf * 100, nil), "skin_temperature": (temp, nil)], confidence: "solid")
                        let projected = try V.array(V.object(mapped)["drivers"]!)
                        XCTAssertEqual(projected.count, drivers.count)
                        for (driver, json) in zip(drivers, projected) {
                            let o = try V.object(json); XCTAssertEqual(o["deltaPoints"], .number(Double(driver.deltaPoints)))
                            seen.insert(try V.string(o["key"])); XCTAssertNotNil(o["value"])
                        }
                    }
                }
            }
        }
        XCTAssertEqual(seen, ["heart_rate_variability", "resting_heart_rate", "respiratory_rate", "sleep_quality", "skin_temperature"])
        XCTAssertThrowsError(try D.charge([.init(label: "unknown", deltaPoints: 0, valueText: "0", baselineText: "", verdict: "at baseline")], values: [:], confidence: "solid"))
    }

    func test07ReadinessActualCalendarTokensAndLoadEvidence() async throws {
        let out = try await S14HistoryCache.shared.get().last!
        let native = try ReadinessEngine.evaluateCalendar(days: out.native.readinessDays, today: out.native.context.observation.input.day)
        XCTAssertEqual(out.native.readiness, native)
        XCTAssertEqual(out.projection.details["readiness"], try D.readiness(native))
        for signal in try V.array(V.object(out.projection.details["readiness"]!)["signals"]!) {
            let s = try V.object(signal)
            XCTAssertTrue(try V.string(s["label"]).hasPrefix("today_readiness_"))
            XCTAssertTrue(try V.string(s["detail"]).hasPrefix("today_readiness_"))
        }
    }

    func test08NativeLoadFortyTwoDayAndIndependentResetAdmission() async throws {
        let all = try await S14HistoryCache.shared.get(), out = all.last!, today = out.native.context.observation.input.day
        XCTAssertEqual(out.native.readinessDays.count, 31)
        XCTAssertEqual(out.native.training, TrainingLoadEngine.evaluate(days: out.native.admittedDays.map { .init(day: $0.day, load: $0.strain) }, through: today))
        var input = try S11Fixtures.input(X.shift(today, 1), config: ["hrvBaselineEpoch": .number(Double(C.dayBounds(today, "UTC").lowerBound)), "effortMethod": .string("BANISTER")])
        input.historyCaseIds = all.map { $0.native.context.observation.input.id }
        let x = try await X.run(input, history: all.map { $0.native.context.prior })
        let reset = try await M.evaluate(context: x, history: all.map(\.native.context), supplements: M.Supplements(x), priorDetails: all.map(\.prior))
        XCTAssertTrue(reset.native.admittedDays.dropLast().allSatisfy { $0.strain == nil })
        XCTAssertTrue(reset.native.admittedDays.allSatisfy { $0.avgHrv == nil })
        XCTAssertEqual(reset.native.training.contiguousDays, 1)
        XCTAssertEqual(reset.projection.metrics["chronic_load"]?.method.text, "ewma_42d_banister")
    }

    func test09FitnessVitalityMissingWaistAndActualSevenSlots() async throws {
        let out = try await S14HistoryCache.shared.get().last!, native = out.native
        XCTAssertNotNil(native.fitness); XCTAssertNil(native.fitness?.vo2max)
        XCTAssertEqual(out.projection.metrics["fitness_age"]?.value, native.fitness?.fitnessAge)
        XCTAssertEqual(out.projection.metrics["vo2max_est"]?.method.text, "uth_hr_ratio")
        XCTAssertEqual(out.projection.metrics["vitality"]?.value, native.vitality?.vitality)
        let detail = try V.object(out.projection.details["fitness_age"]!)
        XCTAssertEqual(detail["weekKey"], .string(try M.weekKey(native.context.observation.input.day)))
        let waist = try V.array(detail["inputs"]!).map { try V.object($0) }.first { $0["key"] == .string("waist") }
        XCTAssertEqual(waist?["status"], .string("missing"))
    }

    func test10DisplayCustomZonesAndManualStepFitLeaveBasePhysiologyUnchanged() async throws {
        let base = try await F.evaluate(S11Fixtures.input("2026-06-15")), x = base.native.context
        var s = M.Supplements(x)
        s.presentationPreferences = .init(maxHR: 200, customZoneLowerBounds: [50, 80, 100, 120, 150], manualStepCoefficient: 42.5,
            inputRevision: 200, provenance: "explicit_component_preference_not_whole_input")
        let custom = try await M.evaluate(context: x, supplements: s)
        XCTAssertEqual(try P.reflect(custom.native.context.observation.native), try P.reflect(base.native.context.observation.native))
        XCTAssertEqual(custom.native.calibration, StepsEstimateEngine.calibrate([], manualOverride: 42.5))
        XCTAssertEqual(try V.object(custom.projection.details["hr_zones"]!)["source"], .string("custom"))
        XCTAssertNotEqual(base.digest, custom.digest)
    }

    func test11CalibrationUsesOnlyActualOwnPriorMotionAndPhoneMeasurements() async throws {
        let all = try await S14HistoryCache.shared.get(), out = all.last!
        XCTAssertEqual(out.native.calibrationPoints.count, 42)
        for (point, prior) in zip(out.native.calibrationPoints, all.dropLast()) {
            XCTAssertEqual(point.motion, prior.native.dayMotion)
            XCTAssertEqual(point.steps, prior.native.imports.selected["steps_count"]?.value)
        }
        XCTAssertEqual(out.native.calibration, StepsEstimateEngine.calibrate(out.native.calibrationPoints))
        XCTAssertEqual(out.projection.metrics["steps_est"]?.value,
            out.native.calibration.flatMap { StepsEstimateEngine.estimate(motion: out.native.dayMotion, calibration: $0) }.map(Double.init))
    }

    func test12AllOrdinaryImportsPriorityNullZeroConsentAndTombstone() async throws {
        let x = try await X.run(S10Fixtures.input()), scope = D.Scope(x)
        let ordinary = I.units.keys.filter { !$0.hasPrefix("miband_") }
        let a = F.imported(x, values: Dictionary(uniqueKeysWithValues: ordinary.map { ($0, Optional(0.0)) }))
        let lower = F.imported(x, kind: .healthConnect, entity: "import:hc", revision: 101, values: ["steps_count": 99])
        let selected = try I.resolve(scope: scope, rows: [lower, a], day: scope.day)
        XCTAssertEqual(selected.selected.count, ordinary.count); XCTAssertEqual(selected.selected["steps_count"]?.value, 0)
        let null = F.imported(x, revision: 102, values: ["steps_count": nil])
        XCTAssertEqual(try I.resolve(scope: scope, rows: [a, lower, null], day: scope.day).selected["steps_count"]?.value, 99)
        let deleted = F.replace(null, payload: [:], revision: 103, deleted: true)
        XCTAssertEqual(try I.resolve(scope: scope, rows: [a, null, deleted, lower], day: scope.day).tombstones, [deleted])
        var payload = a.payload; payload["consent"] = .null
        XCTAssertThrowsError(try I.parse(F.replace(a, payload: payload)))
        XCTAssertEqual(try I.project(selection: selected, native: x.observation.native.daily, cycleUsesCalendar: false).metrics["imported_calendar_steps_count"]?.value, 0)
    }

    func test13AllMiNineAndStrictCrossSourceUnknownZeroRangeRejections() async throws {
        let x = try await X.run(S10Fixtures.input()), keys = I.units.keys.filter { $0.hasPrefix("miband_") }
        XCTAssertEqual(keys.count, 9)
        let values = Dictionary(uniqueKeysWithValues: keys.map { ($0, Optional(I.units[$0] == "min" ? 0.0 : 1.0)) })
        let row = F.imported(x, kind: .mi, values: values)
        let selected = try I.resolve(scope: D.Scope(x), rows: [row], day: x.observation.input.day)
        let view = try I.project(selection: selected, native: x.observation.native.daily, cycleUsesCalendar: true)
        XCTAssertEqual(Set(view.metrics.keys), Set(keys.map { "imported_" + $0 }))
        for key in keys {
            XCTAssertThrowsError(try I.parse(F.imported(x, kind: .apple, values: [key: 1])))
            XCTAssertThrowsError(try I.parse(F.imported(x, kind: .mi, values: [key: 1_000_001])))
            if I.units[key] != "min" { XCTAssertThrowsError(try I.parse(F.imported(x, kind: .mi, values: [key: 0]))) }
        }
        XCTAssertThrowsError(try I.parse(F.imported(x, values: ["elevation_m": 1])))
        var p = row.payload; p["unexpected"] = .null; XCTAssertThrowsError(try I.parse(F.replace(row, payload: p)))
    }

    func test18CompleteMetadataNullChartsAndRejectedVocabulary() async throws {
        let out = try await F.evaluate(S10Fixtures.input())
        XCTAssertEqual(Set(out.projection.chartMetadata.keys), Set(out.projection.charts.keys))
        for (key, reading) in out.projection.metrics {
            XCTAssertTrue(D.units.contains(reading.unit), key); XCTAssertTrue(D.nativeMethods.contains(reading.method.text), key)
        }
        XCTAssertThrowsError(try D.Reading(value: .nan, unit: "bpm", method: .native("calendar_day_observed_hr")))
        XCTAssertThrowsError(try D.Reading(value: 1, unit: "fake", method: .native("calendar_day_observed_hr")))
        XCTAssertThrowsError(try D.Reading(value: 1, unit: "bpm", status: .experimental, method: .native("calendar_day_observed_hr")))
        XCTAssertThrowsError(try D.Reading(value: nil, unit: "bpm", method: .native("unreviewed")))
        let buckets = try D.buckets([(0, 10), (299, 20), (600, 40), (900, 999)], from: 0, to: 900)
        XCTAssertEqual(buckets.map(\.start), [0, 600]); XCTAssertEqual(buckets.map(\.count), [2, 1])
        XCTAssertEqual(buckets.map(\.value), [15, 40]); XCTAssertEqual(buckets.map(\.end), [300, 900])
    }

    func test19RetainedForeignFutureAndOwnExecutionLineageRefuseReportSubstitution() async throws {
        var input = try S10Fixtures.input(), original = input
        let lo = try V.validate(input).dayLo
        S10Fixtures.append(&input, .hr, lo, ["bpm": .number(90)], owner: S10Fixtures.foreign)
        S10Fixtures.append(&input, .hr, input.asOfExclusive, ["bpm": .number(200)])
        let out = try await F.evaluate(input), base = try await F.evaluate(original)
        XCTAssertEqual(out.native.context.observation.input.raw, input.raw)
        XCTAssertEqual(out.projection, base.projection)
        XCTAssertNotEqual(out.digest, base.digest)
        var wrong = M.Supplements(base.native.context); wrong.auxiliaryEvidence = .object([:])
        do { _ = try await M.evaluate(context: base.native.context, supplements: wrong); XCTFail("auxiliary bypass") } catch { }
        wrong = M.Supplements(base.native.context)
        wrong.originalJournalRows = [S10Fixtures.journal(.profile, 10, payload: ["age": .number(80)])]
        do { _ = try await M.evaluate(context: base.native.context, supplements: wrong); XCTFail("profile bypass") } catch { }
        original.historyCaseIds = [input.id]
        do { _ = try await M.evaluate(context: base.native.context, history: [out.native.context], supplements: M.Supplements(base.native.context), priorDetails: [out.prior]); XCTFail("wrong chain") } catch { }
    }

    func test20ExternalDiagnosticOnlyArtifactAndNoElevationWireInvention() async throws {
        let out = try await F.evaluate(S11Fixtures.input("2026-06-15"))
        let bytes = try C.bytes(out), json = try V.object(JSONDecoder().decode(C.JSON.self, from: bytes))
        XCTAssertEqual(json["mode"], .string("presentation_components_not_server_day"))
        XCTAssertThrowsError(try V.decode(bytes))
        XCTAssertFalse(out.projection.metrics.keys.contains { $0.contains("elevation") || $0.contains("ascent") })
        XCTAssertTrue(out.projection.gaps.contains("elevation_not_in_current_input_contract"))
        if let directory = ProcessInfo.processInfo.environment["S14_ARTIFACT_DIRECTORY"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true).resolvingSymlinksInPath()
            guard root.path.hasPrefix("/Volumes/Untitled/nara-production-sync-evidence-20260918/") else { throw D.failure("artifact_directory") }
            let destination = root.appendingPathComponent("s14-components.json")
            try bytes.write(to: destination, options: .withoutOverwriting)
        }
    }
}
