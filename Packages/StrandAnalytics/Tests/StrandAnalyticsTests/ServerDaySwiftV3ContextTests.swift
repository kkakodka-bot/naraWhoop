import CryptoKit
import Foundation
import WhoopProtocol
import XCTest
@testable import StrandAnalytics

private enum S13Fixtures {
    typealias C = ServerDaySwiftContract
    typealias V = ServerDaySwiftV3Contract
    typealias X = ServerDaySwiftV3Context
    typealias F = S10Fixtures
    static func configured(_ input: V.Input, _ flags: [String: C.JSON]) -> V.Input {
        var i = input, payload = i.journal[1].payload
        payload.merge(flags) { _, value in value }
        i.journal[1] = F.journal(.config, 2, day: i.day, payload: payload)
        return i
    }
    static func journal(_ input: V.Input, kind: C.Kind = .context, revision: Int64 = 10,
                        flags: [String: C.JSON] = [:], day: String? = nil, deleted: Bool = false,
                        owner: UUID = F.owner, device: UUID = F.device, entity: String? = nil) -> C.JournalRow {
        let day = day ?? input.day
        let purpose = kind == .context ? "journal_context" : "cycle_context"
        var payload: [String: C.JSON] = ["schemaVersion": .number(1), "day": .string(day), "timezone": .string(input.timezone),
            "consent": .object(["purpose": .string(purpose), "policyVersion": .number(1),
                "decisionId": .string("55555555-5555-4555-8555-555555555555")])]
        if kind == .context {
            var values = Dictionary(uniqueKeysWithValues: ServerDaySwiftV3Admission.ContextFlag.allCases.map { ($0.rawValue, C.JSON.bool(false)) })
            values.merge(flags) { _, value in value }; payload["flags"] = .object(values)
        } else { payload["event"] = .string("period_start") }
        return C.JournalRow(userId: owner, sourceDeviceId: device, kind: kind,
            entity: entity ?? (kind == .context ? "context:" + day : "period:66666666-6666-4666-8666-666666666666"),
            revision: revision, effectiveDay: day, deleted: deleted, payload: deleted ? [:] : payload)
    }
    static func edit(_ input: V.Input, start: Int, end: Int, revision: Int64 = 30, id: Int = 1,
                     original: (Int, Int)? = nil, nap: Bool = false, dismissed: Bool = false, stages: C.JSON? = nil) -> C.JournalRow {
        var p: [String: C.JSON] = ["schemaVersion": .number(1), "start": .number(Double(start)), "end": .number(Double(end)),
            "originalStart": .number(Double(original?.0 ?? start)), "originalEnd": .number(Double(original?.1 ?? end)),
            "isNap": .bool(nap), "dismissed": .bool(dismissed)]
        p["stages"] = stages
        return C.JournalRow(userId: F.owner, sourceDeviceId: F.device, kind: .sleepEdit,
            entity: String(format: "sleep:77777777-7777-4777-8777-%012d", id), revision: revision,
            effectiveDay: input.day, deleted: false, payload: p)
    }
    static func stages(_ start: Int, _ end: Int) -> C.JSON {
        .array([.object(["start": .number(Double(start)), "end": .number(Double(end)), "stage": .string("light")])])
    }
    static func replacing(_ row: C.JournalRow, _ payload: [String: C.JSON]) -> C.JournalRow {
        C.JournalRow(userId: row.userId, sourceDeviceId: row.sourceDeviceId, kind: row.kind, entity: row.entity,
            revision: row.revision, effectiveDay: row.effectiveDay, deleted: row.deleted, payload: payload)
    }
    static func night(_ index: Int, whoop4: Bool = false, enabled: Bool = true, hr: Int = 52, variation: Int = 40,
                      raw: Int? = nil, daytime: Bool = false, zone: String = "UTC", day: String? = nil) throws -> V.Input {
        var i = try S11Fixtures.input(day ?? S11Fixtures.day(index), zone: zone, whoop4: whoop4,
            raw: raw ?? (whoop4 ? 1290 : 3300), variation: variation,
            config: ["journalContextEnabled": .bool(enabled), "cycleAwarenessEnabled": .bool(enabled)])
        i.id = "s13-\(i.day)"
        if hr != 52 {
            i.raw = i.raw.map { r in
                guard r.stream == .hr else { return r }
                var fields = r.fields; fields["bpm"] = .number((try! V.number(fields["bpm"])) + Double(hr - 52))
                return C.RawRow(id: r.id, userId: r.userId, sourceDeviceId: r.sourceDeviceId, stream: r.stream, ts: r.ts, fields: fields)
            }
        }
        if enabled { i.journal.append(journal(i)) }
        if daytime { addHour(&i, hour: 9, bpm: 66); addHour(&i, hour: 15, bpm: 76) }
        return i
    }
    static func addHour(_ input: inout V.Input, hour: Int, count: Int = 300, bpm: Int = 70, rr: Bool = true, motion: Bool = false) {
        let lo = try! V.validate(input).dayLo
        for n in 0..<count {
            let ts = lo + hour * 3600 + n * 10
            F.append(&input, .hr, ts, ["bpm": .number(Double(bpm))], id: "day-hr-\(ts)")
            if rr { F.append(&input, .rr, ts, F.rr(900 + [0, 30, 0, -30][n % 4]), id: "day-rr-\(ts)") }
            if motion { F.append(&input, .gravity, ts, ["x": .number(n % 2 == 0 ? 0 : 1), "y": .number(0), "z": .number(1)], id: "day-grav-\(ts)") }
        }
    }
    static func linked(_ input: V.Input, _ history: [X.Execution], thermal: Bool = false) throws -> V.Input {
        var i = input; i.historyCaseIds = history.map { $0.observation.input.id }
        if thermal {
            let bounds = try ServerDaySwiftV3Thermal.lookback(i)
            var ids = Set(i.raw.filter { $0.stream == .skinTemp }.map(\.ts))
            for row in history.flatMap({ $0.observation.input.raw }) where row.stream == .skinTemp && bounds.contains(row.ts)
                && row.userId == i.identity.userId && row.sourceDeviceId == i.identity.sourceDeviceId {
                if ids.insert(row.ts).inserted { i.raw.append(row) }
            }
        }
        return i
    }
    static func run(_ input: V.Input, _ history: [X.Execution] = [], warm: Bool = true, thermal: Bool = false) async throws -> X.Execution {
        try await X.run(linked(input, history, thermal: thermal), history: history.map(\.prior), restart: warm ? history.last?.restart : nil)
    }
}

private actor S13HistoryCache {
    static let shared = S13HistoryCache()
    private var history: [ServerDaySwiftV3Context.Execution] = []
    func nights(_ count: Int) async throws -> [ServerDaySwiftV3Context.Execution] {
        while history.count < count {
            let index = history.count
            let input = try S13Fixtures.night(index, variation: 38 + index % 3 * 2,
                raw: index % 28 >= 14 ? 3360 : 3300, daytime: true)
            history.append(try await S13Fixtures.run(input, history))
        }
        return Array(history.prefix(count))
    }
}

final class ServerDaySwiftV3ContextTests: XCTestCase {
    private typealias F = S13Fixtures
    private typealias Raw = S10Fixtures
    private typealias C = ServerDaySwiftContract
    private typealias V = ServerDaySwiftV3Contract
    private typealias H = ServerDaySwiftHistory
    private typealias S = ServerDaySwiftV3Selection
    private typealias T = ServerDaySwiftV3Thermal
    private typealias Sleep = ServerDaySwiftV3Sleep
    private typealias A = ServerDaySwiftV3Admission
    private typealias X = ServerDaySwiftV3Context
    private typealias P = ServerDaySwiftV3CoreProbe

    private func fails(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected refusal", file: file, line: line) }
        catch { XCTAssertTrue(error is C.Failure, "\(error)", file: file, line: line) }
    }
    private func direct(_ input: V.Input) async throws -> (S.Loaded, H.Prepared, T.Anchor) {
        let seed = try await S.seed(input), loaded = try await S.load(seed), anchor = try await T.anchor(seed)
        let prepared = try T.prepare(H.prepare(input.historyInput, history: []), history: [], anchor: anchor).0
        return (loaded, prepared, anchor)
    }

    func test01StrictAnswersConsentIdentityAndNoPriorDayFill() throws {
        var i = try F.night(0)
        XCTAssertTrue(try A.resolve(i).answers!.complete)
        for flag in A.ContextFlag.allCases {
            i.journal[2] = F.journal(i, flags: [flag.rawValue: .null])
            let d = try A.resolve(i)
            XCTAssertFalse(d.answers!.complete)
            XCTAssertEqual(d.answers!.flags[flag.rawValue], .unknown)
            XCTAssertTrue(d.reasons.contains("journal_context_incomplete"))
            let encoded = try V.object(V.json(d.answers!))
            XCTAssertEqual(try V.object(encoded["flags"]!)[flag.rawValue], .null)
        }
        i.journal[2] = F.journal(i, day: "2025-12-31")
        XCTAssertNil(try A.resolve(i).answers)
        i.journal[2] = F.journal(i)
        let row = i.journal[2]
        var corrupt: [[String: C.JSON]] = []
        var p = row.payload, flags = try V.object(p["flags"]!)
        flags.removeValue(forKey: "stress"); p["flags"] = .object(flags); corrupt.append(p)
        for value: C.JSON in [.number(0), .string("false")] {
            p = row.payload; flags = try V.object(p["flags"]!); flags["stress"] = value; p["flags"] = .object(flags); corrupt.append(p)
        }
        for (key, value): (String, C.JSON) in [("notes", .string("not admitted")), ("timezone", .string("invalid")), ("day", .string("2026-02-30"))] {
            p = row.payload; p[key] = value; corrupt.append(p)
        }
        for (key, value): (String, C.JSON) in [("purpose", .string("cycle_context")), ("policyVersion", .number(2)),
            ("decisionId", .string("not-a-uuid")), ("extra", .bool(true))] {
            p = row.payload; var consent = try V.object(p["consent"]!); consent[key] = value; p["consent"] = .object(consent); corrupt.append(p)
        }
        p = row.payload; p.removeValue(forKey: "consent"); corrupt.append(p)
        for payload in corrupt { i.journal[2] = F.replacing(row, payload); XCTAssertThrowsError(try A.resolve(i)) }
        i.journal[2] = F.journal(i, entity: "context:wrong"); XCTAssertThrowsError(try A.resolve(i))
        for flag in ["journalContextEnabled", "cycleAwarenessEnabled", "daytimePersonalBaselineEnabled"] {
            XCTAssertThrowsError(try A.resolve(F.configured(try F.night(0), [flag: .null])))
        }
    }

    func test01TombstoneFutureForeignAndImmutablePeriod() throws {
        var i = try F.night(0)
        let base = try A.resolve(i)
        i.journal += [F.journal(i, revision: 11, flags: ["alcohol": .bool(true)], day: "2026-01-02"),
            F.journal(i, revision: 12, flags: ["alcohol": .bool(true)], owner: Raw.foreign),
            F.journal(i, revision: 13, flags: ["alcohol": .bool(true)], device: Raw.otherDevice)]
        XCTAssertEqual(try A.resolve(i).answers, base.answers)
        XCTAssertEqual(try A.resolve(i).ignored.count, 3)
        i.journal.append(F.journal(i, revision: 14, deleted: true))
        XCTAssertNil(try A.resolve(i).answers)
        XCTAssertEqual(try A.resolve(i).tombstoned.map(\.revision), [14])
        i.journal.append(F.journal(i, kind: .period, revision: 20, day: "2025-12-31"))
        i.journal.append(F.journal(i, kind: .period, revision: 21))
        XCTAssertThrowsError(try A.resolve(i))
        i.journal.removeLast()
        i.journal.append(F.journal(i, kind: .period, revision: 21, day: "2025-12-31", deleted: true))
        XCTAssertTrue(try A.resolve(i).periods.isEmpty)
    }

    func test02IndependentOptInsDoNotTurnUnknownIntoNegativeOrHideDaytime() async throws {
        for (journal, cycle) in [(false, false), (true, false), (false, true)] {
            let input = F.configured(try F.night(0, daytime: true), ["journalContextEnabled": .bool(journal), "cycleAwarenessEnabled": .bool(cycle)])
            let o = try await X.run(input).output
            XCTAssertNil(o.illness.result) // No trusted raw history on this first day.
            XCTAssertEqual(o.cycle.result == nil, !cycle)
            XCTAssertNotNil(o.metrics["daytime_stress_mean"]!.value)
            XCTAssertFalse(o.daytime.personalBaseline)
            XCTAssertEqual(o.decision.journalEnabled, journal)
            XCTAssertEqual(o.decision.cycleEnabled, cycle)
        }
    }

    func test03NewSleepEntryEqualsFrozenCompleteResultAndOldGuardStaysStrict() async throws {
        let disabled = try F.night(0, enabled: false)
        let (loaded, prepared, anchor) = try await direct(disabled)
        let old = try Sleep.resolve(input: disabled, prepared: prepared, loaded: loaded, thermal: anchor)
        let native = try Sleep.analyze(input: disabled, prepared: prepared, loaded: loaded, thermal: anchor, resolved: old)
        let actual = try await X.run(disabled)
        XCTAssertFalse(native.sleepSessions.isEmpty)
        XCTAssertEqual(actual.observation.sleep, old)
        XCTAssertEqual(try P.reflect(actual.observation.native), try P.reflect(native))
        let enabled = try F.night(0), e = try await direct(enabled)
        XCTAssertThrowsError(try Sleep.resolve(input: enabled, prepared: e.1, loaded: e.0, thermal: e.2))
        let admitted = try await X.run(enabled)
        XCTAssertEqual(try P.reflect(admitted.observation.native), try P.reflect(native))
        XCTAssertEqual(admitted.observation.input, enabled)
        let onset = F.configured(enabled, ["dayCycleMode": .string("sleep_onset")])
        let additive = try await X.run(onset)
        let seed = try await S.seed(onset), loadedOnset = try await S.load(seed), thermalOnset = try await T.anchor(seed)
        let before = try H.prepare(onset.historyInput, history: [])
        let resolved = try A.resolveSleep(input: onset, prepared: before, loaded: loadedOnset,
            thermal: thermalOnset, decision: A.resolve(onset))
        let cycle = try await ServerDaySwiftV3Cycle.evaluate(input: onset, seed: seed, prepared: before, sleep: resolved)
        XCTAssertEqual(additive.observation.cycle, cycle)
        XCTAssertEqual(cycle.mode, "sleep_onset")
        XCTAssertEqual(cycle.window.endExclusive, onset.asOfExclusive)
    }

    func test03ContextEntryKeepsDismissedMovedManualNapAndSplitIdentities() async throws {
        let original = try F.night(0), positive = try await X.run(original)
        let session = try XCTUnwrap(positive.observation.native.sleepSessions.first)
        for moved in [false, true] {
            var i = original
            i.journal.append(F.edit(i, start: moved ? i.asOfExclusive - 3600 : session.start,
                end: moved ? i.asOfExclusive - 1800 : session.end, original: (session.start, session.end), dismissed: !moved))
            let o = try await X.run(i)
            XCTAssertTrue(o.observation.sleep.authoritative)
            XCTAssertEqual(o.observation.input.raw, original.raw)
            XCTAssertNil(o.observation.mainNight)
            XCTAssertFalse(o.observation.native.sleepSessions.contains { $0.start == session.start })
            XCTAssertTrue(o.observation.native.sleepSessions.flatMap(\.stages).isEmpty)
        }
        var split = original
        let lo = try V.validate(split).dayLo
        split.journal += [F.edit(split, start: lo, end: lo + 3600, stages: F.stages(lo, lo + 3600)),
            F.edit(split, start: lo + 4000, end: lo + 8000, revision: 31, id: 2, stages: F.stages(lo + 4000, lo + 8000)),
            F.edit(split, start: lo + 30_000, end: lo + 32_000, revision: 32, id: 3, nap: true, stages: F.stages(lo + 30_000, lo + 32_000))]
        let o = try await X.run(split)
        XCTAssertEqual(o.observation.sleep.entries.count, 3)
        XCTAssertEqual(o.observation.mainNight?.indices, [0, 1])
        XCTAssertEqual(o.observation.mainNight?.end, lo + 8000)
        XCTAssertTrue(o.observation.sleep.entries.allSatisfy { $0.staging.source == "journal_supplied" })
        XCTAssertEqual(o.observation.mainNight?.originalIDs, Array(o.observation.sleep.entries.prefix(2)).map { $0.identity.id })
    }

    func test04RawHistoryIllnessPositiveDirectNativeAndSeparatedCalendarWindows() async throws {
        let history = try await S13HistoryCache.shared.nights(31)
        let input = try F.night(31, hr: 86, variation: 10, raw: 3420)
        let o = try await F.run(input, history), evidence = o.output.illness
        let result = try XCTUnwrap(evidence.result), distance = try XCTUnwrap(evidence.distance)
        XCTAssertEqual(evidence.baselineDays.count, 28)
        XCTAssertEqual(evidence.baselineDays.first, "2026-01-02")
        XCTAssertEqual(evidence.baselineDays.last, "2026-01-29")
        XCTAssertEqual(evidence.recentDays, ["2026-01-31", "2026-02-01"])
        XCTAssertFalse(evidence.baselineDays.contains("2026-01-30"))
        XCTAssertEqual(result.level, .raised)
        XCTAssertGreaterThanOrEqual(result.signalCount, 2)
        XCTAssertEqual(result.firedSignals, [])
        let direct = IllnessSignalEngine.evaluate(evidence.inputs, context: .init(baselineTrusted: true))
        XCTAssertEqual(result, direct)
        func z(_ key: A.BaselineMetric) -> Double? { evidence.signals.first { $0.metric == key }?.reading.zIllnessward }
        XCTAssertEqual(distance, IllnessDistance.evaluate(features: .init(restingHR: z(.restingHR), rmssd: z(.hrv), skinTemp: z(.skinTemp), respiration: z(.resp)), correlation: nil))
        for signal in evidence.signals where signal.metric != .skinTemp {
            let values = evidence.baselineDays.map { day -> Double? in
                let d = history.first { $0.observation.input.day == day }?.observation.native.daily
                return signal.metric == .hrv ? d?.avgHrv : signal.metric == .restingHR ? d?.restingHr.map(Double.init) : d?.respRateBpm
            }
            let state = Baselines.foldHistory(values, dayKeys: evidence.baselineDays, cfg: Baselines.metricCfg[signal.metric.rawValue]!,
                baselineEpoch: o.output.decision.policy.epoch(signal.metric.rawValue))
            XCTAssertEqual(signal.baseline, H.State(state))
            let mean = signal.recent.reduce(0) { $0 + $1.value } / Double(signal.recent.count)
            XCTAssertEqual(signal.reading.zIllnessward, Baselines.deviation(mean, state: state).z * (signal.metric == .hrv ? -1 : 1))
        }
    }

    func test04AllConfoundersUseNativeCopyAndDoNotRewriteDistance() async throws {
        let history = try await S13HistoryCache.shared.nights(31)
        let input = try F.night(31, hr: 86, variation: 10, raw: 3420)
        let baseline = try await F.run(input, history)
        for flag in A.ContextFlag.allCases {
            var i = input; i.journal[2] = F.journal(i, flags: [flag.rawValue: .bool(true)])
            let o = try await F.run(i, history), e = o.output.illness
            let context = IllnessSignalEngine.Context(alcohol: flag == .alcohol, stress: flag == .stress, sauna: flag == .sauna,
                hardOrLateWorkout: flag == .hardOrLateWorkout, travelPhaseJump: flag == .travelPhaseJump,
                alreadyUnwell: flag == .alreadyUnwell, baselineTrusted: true)
            XCTAssertEqual(e.result, IllnessSignalEngine.evaluate(e.inputs, context: context))
            XCTAssertEqual(e.distance, baseline.output.illness.distance)
            XCTAssertNotEqual(e.result?.level, .raised)
            XCTAssertEqual(e.result?.firedSignals, [])
        }
        let quiet = try await F.run(F.night(31), history)
        XCTAssertEqual(quiet.output.illness.result?.level, .quiet)
    }

    func test05CurrentAbsenceIndependentResetAndStaleLearningAreNotYesterdayScores() async throws {
        let history = try await S13HistoryCache.shared.nights(31)
        var i = try F.night(31); i.raw = []
        let missing = try await F.run(i, history)
        XCTAssertNil(missing.output.illness.result)
        XCTAssertTrue(missing.output.gaps.contains("current_day_physiology_unavailable"))
        i = try F.night(31, hr: 86, variation: 10)
        let epoch = Double(try C.dayBounds(i.day, "UTC").lowerBound)
        for key in ["hrvBaselineEpoch", "recoveryBaselineEpoch"] {
            let o = try await F.run(F.configured(i, [key: .number(epoch)]), history)
            let removed: A.BaselineMetric = key == "hrvBaselineEpoch" ? .hrv : .restingHR
            XCTAssertFalse(o.output.illness.signals.contains { $0.metric == removed })
        }
        let reset = try await F.run(F.configured(i, ["hrvBaselineEpoch": .number(epoch), "recoveryBaselineEpoch": .number(epoch)]), history)
        XCTAssertNil(reset.output.illness.result)
        XCTAssertTrue(reset.output.gaps.contains("illness_baseline_learning"))
        let stale = try await F.run(F.night(50), history)
        XCTAssertNil(stale.output.illness.result)
        XCTAssertTrue(stale.output.gaps.contains("illness_baseline_stale"))
        let cold = try await X.run(F.night(0))
        XCTAssertTrue(cold.output.gaps.contains("illness_baseline_learning"))
    }

    func test05CurrentIneligibleFeatureCannotUnlockYesterdayOnlyVector() async throws {
        let history = try await S13HistoryCache.shared.nights(31)
        var i = try F.night(31)
        // Only current temperature remains; no worn HR support, hence no native eligible current vital.
        i.raw = i.raw.filter { $0.stream == .skinTemp }
        let o = try await F.run(i, history)
        XCTAssertNil(o.observation.native.daily.restingHr)
        XCTAssertNil(o.observation.native.daily.avgHrv)
        XCTAssertNil(o.output.illness.result)
        XCTAssertTrue(o.output.gaps.contains("current_day_physiology_unavailable"))
    }

    func test06DirectNativeThresholdAndIdentityCorrelationControls() {
        let vector = IllnessDistance.FeatureVector(restingHR: 2, rmssd: 2)
        let distance = IllnessDistance.evaluate(features: vector, correlation: nil)
        let score = IllnessSignalEngine.evaluate(.init(restingHR: .init(zIllnessward: 2), hrv: .init(zIllnessward: 2)), context: .init())
        XCTAssertEqual(distance.deviatingFeatures, 2)
        XCTAssertTrue(distance.fires)
        XCTAssertFalse(distance.usedDiagonalFallback)
        XCTAssertEqual(score.signalCount, 0)
        let positive = IllnessSignalEngine.evaluate(.init(restingHR: .init(zIllnessward: 2.001), hrv: .init(zIllnessward: 2.001)), context: .init())
        XCTAssertEqual(positive.signalCount, 2)
    }

    func test07ActualLongHistoryCycleUsesOwnBeforeStatesAndNativeCalendar() async throws {
        let history = try await S13HistoryCache.shared.nights(58), last = history.last!
        let e = last.output.cycle, result = try XCTUnwrap(e.result)
        XCTAssertGreaterThanOrEqual(e.admitted.compactMap { CyclePhaseEngine.fusedIndex(tempZ: $0.tempZ, rhrZ: $0.rhrZ, hrvZ: $0.hrvZ) }.count, 42)
        XCTAssertNotEqual(result.phase, .learning)
        XCTAssertFalse(result.shiftMarkers.isEmpty)
        XCTAssertEqual(result, try CyclePhaseEngine.classifyCalendar(e.admitted, baselineUsable: e.baselineUsable,
            through: last.observation.input.day, loggedPeriodStarts: e.periodDays))
        let target = try XCTUnwrap(e.observed.first { $0.tempZ != nil })
        let own = history.first { $0.observation.input.day == target.day }!.observation
        let state = try own.checkpoint.observation.baselinesBefore["skin_temp"]!.native()
        XCTAssertEqual(target.tempZ, Baselines.deviation(own.native.daily.skinTempC!, state: state).z)
        let end = try last.observation.checkpoint.observation.baselinesBefore["skin_temp"]!.native()
        XCTAssertNotEqual(target.tempZ, Baselines.deviation(own.native.daily.skinTempC!, state: end).z)
    }

    func test08CycleResetPreservesObservedChartAndCurrentMissingIsNotCarriedPhase() async throws {
        let history = try await S13HistoryCache.shared.nights(58)
        let i = try F.night(58), plain = try await F.run(i, history)
        let epoch = Double(try C.dayBounds(i.day, "UTC").lowerBound)
        let reset = try await F.run(F.configured(i, ["hrvBaselineEpoch": .number(epoch)]), history)
        XCTAssertEqual(Array(reset.output.cycle.observed.dropLast()), Array(plain.output.cycle.observed.dropLast()))
        XCTAssertTrue(reset.output.cycle.admitted.allSatisfy { $0.hrvZ == nil })
        XCTAssertEqual(try V.object(reset.output.charts)["cycle_index"].map { try? V.array($0).count }!,
            try V.object(plain.output.charts)["cycle_index"].map { try? V.array($0).count }!)
        var missing = i; missing.raw = []
        let absent = try await F.run(missing, history)
        XCTAssertEqual(absent.output.cycle.result?.phase, .learning)
        XCTAssertTrue(absent.output.gaps.contains("cycle_current_physiology_unavailable"))
        var noTemp = i; noTemp.raw.removeAll { $0.stream == .skinTemp }
        let partial = try await F.run(noTemp, history)
        XCTAssertTrue(partial.output.gaps.contains("cycle_current_temperature_unavailable"))
        XCTAssertFalse(partial.output.gaps.contains("cycle_current_physiology_unavailable"))
        let changed = try await F.run(F.configured(i, ["sourceEra": .string("new-era")]), history)
        XCTAssertEqual(changed.output.cycle.observed.count, 1)
        XCTAssertEqual(changed.output.cycle.result?.phase, .learning)
        XCTAssertEqual(changed.observation.checkpoint.observation.baselinesBefore["hrv"]?.nValid, 0)
    }

    func test08PeriodsRemainOptionalOwnEventsAndCalendarHolesAreRetained() async throws {
        let history = try await S13HistoryCache.shared.nights(58)
        var i = try F.night(60)
        let period = F.journal(i, kind: .period, revision: 20, day: "2026-02-26")
        i.journal.append(period)
        let o = try await F.run(i, history)
        XCTAssertEqual(o.output.cycle.periodDays, ["2026-02-26"])
        XCTAssertFalse(o.output.gaps.contains("period_history_unavailable"))
        XCTAssertEqual(o.output.cycle.result, try CyclePhaseEngine.classifyCalendar(o.output.cycle.admitted,
            baselineUsable: o.output.cycle.baselineUsable, through: i.day, loggedPeriodStarts: ["2026-02-26"]))
        XCTAssertFalse(o.output.cycle.observed.contains { $0.day == "2026-02-28" || $0.day == "2026-03-01" })
        i.journal.append(F.journal(i, kind: .period, revision: 21, day: "2026-02-26", deleted: true))
        let deleted = try await F.run(i, history)
        XCTAssertEqual(deleted.output.cycle.periodDays, [])
        XCTAssertTrue(deleted.output.gaps.contains("period_history_unavailable"))
        XCTAssertNotNil(deleted.output.cycle.result)
    }

    func test09WHOOP4AdapterMatchesS11CompleteThermalEvidenceAndRebasesRaw() async throws {
        var own: [X.Execution] = [], reference: [ServerDaySwiftV3History.Record] = []
        for index in 0..<5 {
            let base = try F.night(index, whoop4: true, enabled: false, raw: index < 4 ? 1290 : 1320)
            let input = try F.linked(base, own, thermal: true)
            let a = try await X.run(input, history: own.map(\.prior), restart: own.last?.restart)
            let b = try await ServerDaySwiftV3History.run(input, history: reference, predecessor: reference.last?.restart)
            XCTAssertEqual(a.observation.thermal, b.record.body.thermal)
            XCTAssertEqual(a.observation.rawNight, b.record.body.rawNight)
            XCTAssertEqual(try P.reflect(a.observation.native), b.record.body.result)
            own.append(a); reference.append(b.record)
        }
        XCTAssertFalse(own.last!.observation.thermal.priorNights.isEmpty)
        let baselineInput = try F.linked(F.night(5, whoop4: true, raw: 1400), own, thermal: true)
        let baseline = try await X.run(baselineInput, history: own.map(\.prior))
        var noisy = baselineInput
        Raw.append(&noisy, .skinTemp, noisy.asOfExclusive, ["raw": .number(2000)], id: "future-thermal")
        Raw.append(&noisy, .skinTemp, noisy.asOfExclusive - 1, ["raw": .number(2000)], id: "foreign-thermal", owner: Raw.foreign)
        let after = try await X.run(noisy, history: own.map(\.prior))
        XCTAssertEqual(after.observation.thermal, baseline.observation.thermal)
        XCTAssertEqual(try P.reflect(after.observation.native), try P.reflect(baseline.observation.native))
        XCTAssertEqual(after.observation.input.raw.count, baselineInput.raw.count + 2)
        for prior in after.observation.thermal.priorNights {
            let old = own.first { $0.observation.input.id == prior.caseID }!
            let funnel = T.funnel(old.observation.rawNight, family: .whoop4, anchor: after.observation.thermal.anchor.resolvedRaw)
            XCTAssertEqual(prior.funnel, try P.reflect(funnel))
            XCTAssertEqual(prior.mean, funnel.mean)
        }
    }

    func test09EditedPriorThermalRetainsActualResolvedSupport() async throws {
        var i = try F.night(0, whoop4: true)
        let lo = try V.validate(i).dayLo
        i.journal.append(F.edit(i, start: lo + 600, end: lo + 3600, original: (lo, lo + 10_800)))
        let prior = try await X.run(i)
        XCTAssertTrue(prior.observation.sleep.authoritative)
        XCTAssertFalse(prior.observation.rawNight.sessions.isEmpty)
        XCTAssertEqual(prior.observation.rawNight.sessions, prior.observation.native.sleepSessions.map(T.Session.init))
        let next = try await F.run(F.night(1, whoop4: true, raw: 1330), [prior], thermal: true)
        let actual = try XCTUnwrap(next.observation.thermal.priorNights.first)
        XCTAssertEqual(actual.mean, T.funnel(prior.observation.rawNight, family: .whoop4, anchor: next.observation.thermal.anchor.resolvedRaw).mean)
        XCTAssertEqual(actual.inputDigest, prior.observation.inputDigest)
        XCTAssertEqual(prior.observation.input.raw, i.raw)
    }

    private func hourly(_ days: Int, day: String = "2026-06-15", zone: String = "UTC", flat: Bool = false,
                        hours: [Int] = Array(0..<24)) throws -> [X.HourlyHR] {
        var result: [X.HourlyHR] = []
        for back in (0..<days).reversed() {
            let key = try X.shift(day, -back), lo = try C.dayBounds(key, zone).lowerBound
            for h in hours {
                result.append(X.HourlyHR(start: lo + h * 3600, meanHR: flat ? 65 : 65 + 10 * cos(Double(h - 16) * .pi / 12),
                    sampleCount: h == 16 ? 500 : 1, hrIDs: ["direct-hour-\(key)-\(h)"]))
            }
        }
        return result
    }

    func test10DirectNativeCircadianCoverageConfidenceAndPoolingControls() throws {
        let day = "2026-06-15"
        for days in [1, 6, 7, 14] {
            let bins = try hourly(days)
            let e = try X.circadian(day: day, timezone: "UTC", hourly: bins, sleep: [])
            XCTAssertEqual(e.observedDays, days)
            XCTAssertEqual(e.result, CircadianEngine.estimatePhase(bins: e.bins, daysObserved: days, habitualWakeHour: 7))
            XCTAssertEqual(e.result?.confidence == .unreadable, days < 7)
        }
        let short = try X.circadian(day: day, timezone: "UTC", hourly: Array(hourly(1).prefix(23)), sleep: [])
        XCTAssertNil(short.result)
        let five = try X.circadian(day: day, timezone: "UTC", hourly: hourly(14, hours: [0, 1, 2, 3, 4]), sleep: [])
        XCTAssertNil(five.result)
        let flat = try X.circadian(day: day, timezone: "UTC", hourly: hourly(14, flat: true), sleep: [])
        XCTAssertEqual(flat.result?.confidence, .unreadable)
        var unequal = try hourly(14)
        let old = unequal[0]
        unequal[0] = X.HourlyHR(start: old.start, meanHR: old.meanHR + 20, sampleCount: 10_000, hrIDs: old.hrIDs)
        let pooled = try X.circadian(day: day, timezone: "UTC", hourly: unequal, sleep: [])
        let values = unequal.filter { $0.start % 86_400 == 0 }
        let unweighted = values.reduce(0) { $0 + $1.meanHR } / Double(values.count)
        XCTAssertEqual(pooled.bins.first?.activity, unweighted)
        let weighted = values.reduce(0) { $0 + $1.meanHR * Double($1.sampleCount) } / Double(values.reduce(0) { $0 + $1.sampleCount })
        XCTAssertNotEqual(pooled.bins.first?.activity, weighted)
    }

    func test11RawCircadianNoWakeReferenceIsDiagnosticNotObservedOffset() async throws {
        var history: [X.Execution] = []
        for index in 0..<14 {
            var i = try Raw.input("circadian-\(index)", day: S11Fixtures.day(index))
            let lo = try V.validate(i).dayLo
            // Sparse HR still triggers native HR-only sleep. Preserve that positive behavior,
            // then use an explicit authoritative dismissal for the no-observed-wake control.
            for hour in 0..<24 {
                Raw.append(&i, .hr, lo + hour * 3600, ["bpm": .number(Double(65 + Int(10 * cos(Double(hour - 16) * .pi / 12))))])
            }
            if index == 0 {
                let nativePositive = try await X.run(i)
                XCTAssertNotNil(nativePositive.observation.mainNight)
            }
            let raw = i.raw
            i.journal.append(F.edit(i, start: lo, end: i.asOfExclusive, dismissed: true))
            let execution = try await F.run(i, history)
            XCTAssertTrue(execution.observation.sleep.authoritative)
            XCTAssertTrue(execution.observation.native.sleepSessions.isEmpty)
            XCTAssertEqual(execution.observation.input.raw, raw)
            history.append(execution)
        }
        let o = history.last!, e = o.output.circadian
        XCTAssertNil(o.observation.mainNight)
        XCTAssertEqual(e.observedDays, 14)
        XCTAssertEqual(e.nativeWakeReference, 7)
        XCTAssertEqual(e.wakeReferenceProvenance, "default_reference_not_observed")
        XCTAssertNil(e.observedWakeHour)
        XCTAssertNotNil(o.output.metrics["circadian_phase_hour"]!.value)
        XCTAssertNil(o.output.metrics["circadian_offset_min"]!.value)
        XCTAssertFalse(o.output.capabilities.contains("circadian_offset_min"))
        let detail = try V.object(V.object(o.output.details)["circadian"]!)
        XCTAssertEqual(detail["habitualWakeHour"], .null)
        XCTAssertEqual(detail["measuredTemperatureMinimum"], .bool(false))
        XCTAssertEqual(detail["note"], .string(e.result!.note))
        XCTAssertEqual(e.result, CircadianEngine.estimatePhase(bins: e.bins, daysObserved: 14, habitualWakeHour: 7))
    }

    func test11ObservedWakeUsesMainGroupAndNativeFractionalLocalHour() async throws {
        var i = try F.night(0)
        let lo = try V.validate(i).dayLo
        i.journal += [F.edit(i, start: lo, end: lo + 10_815, stages: F.stages(lo, lo + 10_815)),
            F.edit(i, start: lo + 40_000, end: lo + 42_000, revision: 31, id: 2, nap: true, stages: F.stages(lo + 40_000, lo + 42_000))]
        let o = try await X.run(i)
        XCTAssertEqual(o.observation.mainNight?.end, lo + 10_815)
        XCTAssertEqual(o.output.circadian.observedWakeHour, Double(10_815) / 3600)
        XCTAssertEqual(o.output.circadian.wakeReferenceProvenance, "observed_main_night_end")
    }

    func test12DaytimeCountBoundaryModesAndRMSSDGateUseActualNativeCalls() async throws {
        let history = try await S13HistoryCache.shared.nights(8)
        var base = try F.night(8)
        F.addHour(&base, hour: 8, count: 299, bpm: 68)
        F.addHour(&base, hour: 9, count: 300, bpm: 72)
        for enabled in [false, true] {
            let i = F.configured(base, ["daytimePersonalBaselineEnabled": .bool(enabled)])
            let o = try await F.run(i, history), d = o.output.daytime
            XCTAssertEqual(d.personalBaseline, enabled)
            XCTAssertNil(d.result.hours.first { $0.hour == 8 }?.level)
            XCTAssertNotNil(d.result.hours.first { $0.hour == 9 }?.level)
            XCTAssertFalse(DaytimeStress.daytimeRMSSDScoringEnabled)
            if enabled {
                XCTAssertTrue(d.result.hrOnlyFallback)
                XCTAssertTrue(try o.observation.checkpoint.observation.baselinesBefore["daytime_rmssd"]!.native().usable)
                if case .baselineRelative(_, let rmssd) = d.mode { XCTAssertNil(rmssd) } else { XCTFail() }
            }
            let loaded = try await S.load(S.seed(o.observation.input))
            let b = loaded.evidence.bounds
            let hr = loaded.hr.filter { b.dayRange.contains($0.ts) && (20...250).contains($0.bpm) }
            let rr = loaded.rr.filter { b.dayRange.contains($0.ts) }
            XCTAssertEqual(d.result, DaytimeStress.analyze(hr: hr, rr: rr, gravity: loaded.gravity.filter { b.dayRange.contains($0.ts) },
                tzOffsetSeconds: b.tzOffsetSeconds, mode: d.mode, timezone: TimeZone(identifier: i.timezone)))
            let aggregate = DaytimeStress.dayDaytimeAggregate(hr: hr, rr: rr, tzOffsetSeconds: b.tzOffsetSeconds, timezone: TimeZone(identifier: i.timezone))
            XCTAssertEqual(d.aggregate, X.Aggregate(hr: aggregate.hr, rmssd: aggregate.rmssd))
        }
    }

    func test12ActivityShadowSustainedAndEmptyCoverageAreNotZeroPlaceholders() async throws {
        let history = try await S13HistoryCache.shared.nights(8)
        var i = F.configured(try F.night(8), ["daytimePersonalBaselineEnabled": .bool(true)])
        F.addHour(&i, hour: 8, bpm: 65, rr: false)
        F.addHour(&i, hour: 9, bpm: 95, rr: false, motion: true)
        for hour in 10...13 { F.addHour(&i, hour: hour, bpm: 95, rr: false) }
        let o = try await F.run(i, history), d = o.output.daytime.result
        XCTAssertTrue(d.hours.first { $0.hour == 9 }!.maskedForActivity)
        XCTAssertTrue(d.hours.first { $0.hour == 10 }!.maskedForActivity)
        XCTAssertFalse(d.hours.first { $0.hour == 11 }!.maskedForActivity)
        XCTAssertTrue(d.sustainedHigh)
        XCTAssertEqual(d.sustainedRun, 3)
        XCTAssertEqual(d.highStressMinutes, 180)
        XCTAssertEqual(d.activityMaskedHours, 2)
        let empty = try await X.run(Raw.input())
        XCTAssertNil(empty.output.metrics["daytime_stress_high_min"]!.value)
        XCTAssertEqual(try V.object(V.object(empty.output.details)["daytimeStress"]!)["sustainedHigh"], .null)
        XCTAssertTrue(empty.output.gaps.contains("daytime_stress_insufficient_data"))
        var rrOnly = try Raw.input()
        Raw.append(&rrOnly, .rr, rrOnly.asOfExclusive - 1, Raw.rr())
        let rr = try await X.run(rrOnly)
        XCTAssertTrue(rr.output.daytime.result.hours.isEmpty)
        XCTAssertNil(rr.output.daytime.aggregate.rmssd)
    }

    func test13FrequencyAndBaevskyPartialSpanRejectionAndExactNativeComponents() async throws {
        for count in [0, 19, 50, 100, 400] {
            var i = try Raw.input("rr-span-\(count)")
            let lo = try V.validate(i).dayLo
            for n in 0..<count { Raw.append(&i, .rr, lo + 30_000 + n, Raw.rr(900 + [0, 30, 0, -30][n % 4])) }
            let o = try await X.run(i)
            let loaded = try await S.load(S.seed(i))
            XCTAssertEqual(o.output.daytime.baevsky, StressIndex.components(rr: loaded.rr))
            XCTAssertEqual(o.output.daytime.frequency, HRVFreqDomain.freqDomain(rr: loaded.rr))
            if count < 70 { XCTAssertNil(o.output.daytime.frequency) }
            if count == 100 { XCTAssertNotNil(o.output.daytime.frequency?.hf); XCTAssertNil(o.output.daytime.frequency?.lf) }
            if count == 400 { XCTAssertNotNil(o.output.daytime.frequency?.lf); XCTAssertNotNil(o.output.daytime.frequency?.lfhf) }
        }
        for values in [Array(repeating: 900.0, count: 400), Array(repeating: 5000.0, count: 400)] {
            XCTAssertNil(StressIndex.components(rawRR: values))
        }
        let noisy = (0..<400).map { $0 % 2 == 0 ? 900.0 : 5000.0 }
        XCTAssertNil(StressIndex.components(rawRR: noisy))
    }

    func test13CanonicalSelectedRRIdentityTiesAndUnknownFamilyRefusal() async throws {
        for whoop4 in [false, true] {
            var i = try Raw.input(family: whoop4 ? "whoop4" : "whoop5", model: whoop4 ? "WHOOP 4.0" : "WHOOP 5.0")
            let ts = try V.validate(i).dayLo + 30_000
            for (id, ms, channel, ord, seq, suspect) in [("five-b", 910, 5, 1, 1, 0), ("five-a", 900, 5, 0, 2, 0),
                ("seven", 920, 7, 0, 3, 0), ("ibi", 930, 2, 0, 4, 0), ("suspect", 940, 5, 0, 5, 1)] {
                Raw.append(&i, .rr, ts, Raw.rr(ms, channel: channel, ord: ord, seq: seq, suspect: suspect), id: id)
            }
            Raw.append(&i, .rr, i.asOfExclusive, Raw.rr(), id: "future")
            Raw.append(&i, .rr, ts, Raw.rr(), id: "foreign", owner: Raw.foreign)
            let o = try await X.run(i)
            XCTAssertEqual(o.output.daytime.rrIDs, whoop4 ? ["five-a", "seven", "five-b"] : ["five-a", "five-b"])
            XCTAssertEqual(o.observation.input.raw.count, 7)
            XCTAssertEqual(o.observation.selection.retainedByOwner[Raw.owner.uuidString.lowercased()]?["rr"], 6)
        }
        var unknown = try Raw.input(family: nil, model: "")
        let ts = try V.validate(unknown).dayLo + 10
        Raw.append(&unknown, .rr, ts, Raw.rr(channel: nil), id: "legacy")
        Raw.append(&unknown, .rr, unknown.asOfExclusive, Raw.rr(channel: 5), id: "future-modern")
        let loaded = try await S.load(S.seed(unknown))
        XCTAssertEqual(loaded.evidence.rrPolicy.serverWindowIDs, ["legacy"])
        XCTAssertNotEqual(loaded.evidence.rrPolicy.shippedStoreIDs, loaded.evidence.rrPolicy.serverWindowIDs)
        await fails { _ = try await X.run(unknown) }
    }

    func test14DSTBucketVectorsOffsetsAndHalfHourTransitionsFromRealStore() async throws {
        for (day, zone, seconds) in [("2026-03-08", "America/Los_Angeles", 82_800), ("2026-11-01", "America/Los_Angeles", 90_000),
            ("2026-04-05", "Australia/Lord_Howe", 88_200), ("2026-10-04", "Australia/Lord_Howe", 84_600),
            ("2026-06-15", "Asia/Kathmandu", 86_400)] {
            var i = try Raw.input("time-\(day)", day: day, zone: zone)
            let bounds = try V.validate(i), tz = TimeZone(identifier: zone)!
            for n in stride(from: 0, to: seconds, by: 60) {
                Raw.append(&i, .hr, bounds.dayLo + n, ["bpm": .number(Double(60 + n / 3600 % 10))], id: "minute-\(n)")
            }
            let o = try await X.run(i)
            XCTAssertEqual(o.observation.selection.bounds.dayRange.count, seconds)
            XCTAssertEqual(o.observation.hourlyHR.reduce(0) { $0 + $1.sampleCount }, seconds / 60)
            let expected = Dictionary(grouping: i.raw) { DaytimeStress.hourBucket($0.ts, offsetSeconds: 0, timezone: tz) }
            XCTAssertEqual(o.observation.hourlyHR.map(\.start), expected.keys.sorted())
            for bucket in o.observation.hourlyHR {
                let rows = expected[bucket.start]!
                XCTAssertEqual(bucket.hrIDs, rows.map(\.id))
                XCTAssertEqual(bucket.sampleCount, rows.count)
                XCTAssertEqual(bucket.meanHR, rows.reduce(0) { $0 + (try! V.number($1.fields["bpm"])) } / Double(rows.count))
            }
            XCTAssertEqual(o.output.circadian.from, try C.dayBounds(X.shift(day, -13), zone).lowerBound)
            if day == "2026-11-01" {
                var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
                let repeated = o.observation.hourlyHR.filter { cal.component(.hour, from: Date(timeIntervalSince1970: Double($0.start))) == 1 }
                XCTAssertEqual(repeated.count, 2); XCTAssertEqual(repeated[1].start - repeated[0].start, 3600)
            }
            if day == "2026-04-05" {
                XCTAssertEqual(o.observation.hourlyHR.count, 24)
                XCTAssertTrue(o.observation.hourlyHR.contains { $0.sampleCount == 90 })
            }
            if day == "2026-10-04" {
                XCTAssertTrue(o.observation.hourlyHR.contains { $0.sampleCount == 30 })
            }
        }
    }

    func test14ExplicitTravelRetainsPriorBucketInstantsAndCurrentZoneLabels() async throws {
        let a = try await X.run(F.night(0, daytime: true, zone: "America/Los_Angeles"))
        let b = try await F.run(F.night(1, daytime: true, zone: "Asia/Kathmandu"), [a])
        XCTAssertEqual(a.observation.input.timezone, "America/Los_Angeles")
        XCTAssertEqual(b.observation.checkpoint.observation.timezone, "Asia/Kathmandu")
        for hour in a.observation.hourlyHR {
            XCTAssertTrue(b.output.circadian.hourly.contains(hour))
        }
        let direct = try X.circadian(day: b.observation.input.day, timezone: b.observation.input.timezone,
            hourly: a.observation.hourlyHR + b.observation.hourlyHR, sleep: [a.observation.mainNight, b.observation.mainNight].compactMap { $0 })
        XCTAssertEqual(b.output.circadian, direct)
    }

    func test15RecurrenceCurrentObservationChangesOnlyAfterAndWarmEqualsCold() async throws {
        let history = try await S13HistoryCache.shared.nights(8)
        var i = try F.night(8, daytime: true)
        i = F.configured(i, ["daytimePersonalBaselineEnabled": .bool(true)])
        let warm = try await F.run(i, history), cold = try await F.run(i, history, warm: false)
        XCTAssertTrue(warm.reusedCheckpoint); XCTAssertFalse(cold.reusedCheckpoint)
        XCTAssertEqual(warm.digest, cold.digest)
        XCTAssertEqual(try C.bytes(warm.observation), try C.bytes(cold.observation))
        XCTAssertEqual(warm.output, cold.output)
        XCTAssertEqual(warm.observation.checkpoint.observation.baselinesBefore, history.last!.observation.checkpoint.baselinesAfter)
        let state = try warm.observation.checkpoint.observation.baselinesBefore["daytime_hr"]!.native()
        XCTAssertEqual(warm.observation.checkpoint.baselinesAfter["daytime_hr"],
            H.State(Baselines.update(state, value: warm.output.daytime.aggregate.hr, cfg: Baselines.daytimeHRCfg)))
        let next = try await F.run(F.night(11), history + [warm])
        var aged = try warm.observation.checkpoint.baselinesAfter["daytime_hr"]!.native()
        for _ in 0..<2 { aged = Baselines.update(aged, value: nil, cfg: Baselines.daytimeHRCfg) }
        XCTAssertEqual(next.observation.checkpoint.observation.baselinesBefore["daytime_hr"], H.State(aged))
        let method = try await F.run(F.configured(i, ["effortMethod": .string("BANISTER")]), history)
        XCTAssertEqual(method.observation.checkpoint.observation.baselinesBefore["strain"]?.nValid, 0)
        XCTAssertEqual(method.observation.checkpoint.observation.baselinesBefore["hrv"], warm.observation.checkpoint.observation.baselinesBefore["hrv"])
    }

    func test15FutureForeignSignalsAndJournalAreRetainedWithoutInfluence() async throws {
        let history = try await S13HistoryCache.shared.nights(8)
        let i = try F.night(8, daytime: true), baseline = try await F.run(i, history)
        var changed = i
        for (owner, device) in [(Raw.foreign, Raw.device), (Raw.owner, Raw.otherDevice)] {
            Raw.append(&changed, .hr, i.asOfExclusive - 1, ["bpm": .number(180)], owner: owner, device: device)
        }
        Raw.append(&changed, .hr, i.asOfExclusive, ["bpm": .number(180)])
        changed.journal += [F.journal(i, revision: 50, flags: ["alcohol": .bool(true)], owner: Raw.foreign),
            F.journal(i, revision: 51, flags: ["alcohol": .bool(true)], day: try X.shift(i.day, 1))]
        let after = try await F.run(changed, history)
        XCTAssertEqual(after.output.metrics, baseline.output.metrics)
        XCTAssertEqual(after.output.details, baseline.output.details)
        XCTAssertEqual(after.output.charts, baseline.output.charts)
        XCTAssertEqual(after.observation.checkpoint, baseline.observation.checkpoint)
        XCTAssertEqual(after.observation.selection.streams, baseline.observation.selection.streams)
        XCTAssertNotEqual(after.observation.input.raw, baseline.observation.input.raw)
    }

    func test15IndependentColdRawHistoryMatchesOwnWarmRestart() async throws {
        var warm: [X.Execution] = [], cold: [X.Execution] = []
        for day in 0..<3 {
            let input = try F.night(day, daytime: true)
            let a = try await F.run(input, warm)
            // Every cold execution, including its historical priors, uses new disposable Stores.
            let b = try await F.run(input, cold, warm: false)
            XCTAssertEqual(a.digest, b.digest)
            XCTAssertEqual(try C.bytes(a.observation), try C.bytes(b.observation))
            XCTAssertEqual(a.output, b.output)
            XCTAssertEqual(a.observation.checkpoint, b.observation.checkpoint)
            warm.append(a); cold.append(b)
        }
        XCTAssertTrue(warm.last!.reusedCheckpoint)
        XCTAssertFalse(cold.last!.reusedCheckpoint)
    }

    func test16AdmissionPreservesFrozenResourceAndClosedDayRefusals() throws {
        var input = try Raw.input()
        input.historyCaseIds = (0...400).map { "prior-\($0)" }
        XCTAssertThrowsError(try A.resolve(input))
        input = try Raw.input()
        input.journal = Array(repeating: input.journal[0], count: 10_001)
        XCTAssertThrowsError(try A.resolve(input))
        input = try Raw.input()
        input.asOfExclusive -= 1
        XCTAssertThrowsError(try A.resolve(input))
    }

    func test16OwnLineageRefusesWrongPriorRestartOrderAndDiagnosticDecode() async throws {
        let a = try await X.run(F.night(0)), b = try await F.run(F.night(1), [a])
        let input = try F.linked(F.night(2), [a, b])
        let positive = try await X.run(input, history: [a.prior, b.prior], restart: b.restart)
        XCTAssertTrue(positive.reusedCheckpoint)
        XCTAssertFalse((X.Execution.self as Any.Type) is any Decodable.Type)
        XCTAssertFalse((X.Prior.self as Any.Type) is any Decodable.Type)
        XCTAssertFalse((X.Restart.self as Any.Type) is any Decodable.Type)
        let bytes = try C.bytes(b), diagnostic = try JSONDecoder().decode(C.JSON.self, from: bytes)
        XCTAssertNotNil(try V.object(diagnostic)["observation"])
        await fails { _ = try await X.run(input, history: [b.prior, a.prior]) }
        await fails { _ = try await X.run(input, history: [a.prior, b.prior], restart: a.restart) }
        var wrong = input; wrong.historyCaseIds = ["changed"]
        await fails { _ = try await X.run(wrong, history: [a.prior, b.prior]) }
        wrong = input; wrong.identity = C.Identity(userId: Raw.foreign, sourceDeviceId: Raw.device, algorithmVersion: input.identity.algorithmVersion)
        await fails { _ = try await X.run(wrong, history: [a.prior, b.prior]) }
        XCTAssertEqual(try C.bytes(b), bytes)
        let repeatRun = try await X.run(input, history: [a.prior, b.prior], restart: b.restart)
        XCTAssertEqual(try C.bytes(repeatRun), try C.bytes(positive))
    }

    func test16CompleteComponentsExactInventoryIndependentStoreAndExternalArtifact() async throws {
        let hashes = try X.sourceHashes(), base = try Sleep.sourceHashes()
        let added = Set(hashes.keys).subtracting(base.keys)
        XCTAssertEqual(added, Set(["Admission", "Context", "ContextTests"].map {
            "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/ServerDaySwiftV3\($0).swift"
        }))
        let input = try F.night(0, daytime: true), a = try await X.run(input), b = try await X.run(input)
        XCTAssertEqual(try C.bytes(a), try C.bytes(b))
        XCTAssertEqual(a.observation.selection, b.observation.selection)
        XCTAssertEqual(Set(a.output.metrics.keys), Set(["illness_score", "illness_distance", "circadian_phase_hour", "circadian_offset_min",
            "daytime_stress_mean", "daytime_stress_high_min", "baevsky_stress_index"]))
        XCTAssertEqual(Set(try V.object(a.output.details).keys), Set(["contextPolicy", "illness", "cycle", "circadian", "daytimeStress", "frequencyHrv"]))
        let native = try V.object(P.reflect(a.observation.native))
        XCTAssertEqual(Set(native.keys), Set(Mirror(reflecting: a.observation.native).children.compactMap(\.label)))
        XCTAssertEqual(hashes, try X.sourceHashes())
        if let directory = ProcessInfo.processInfo.environment["S13_EVIDENCE_DIRECTORY"] {
            let root = URL(fileURLWithPath: directory).standardizedFileURL
            let repository = P.repository.standardizedFileURL.resolvingSymlinksInPath()
            guard root.path.hasPrefix("/Volumes/Untitled/"), !root.path.hasPrefix(repository.path + "/"), root != repository,
                  root.resolvingSymlinksInPath() == root else { throw A.failure("evidence_directory") }
            struct Probe: Encodable {
                let schemaVersion = 1
                let producer = "actual-swift"
                let recipe = "s13-actual-swift-context-probe-v1"
                let mode = "context_probe_not_server_day"
                let sourceHashes: [String: String]
                let cases: [X.Execution]
            }
            let history = try await S13HistoryCache.shared.nights(58)
            let positive = try await F.run(F.night(58, hr: 86, variation: 10, raw: 3420), history)
            let bytes = try C.bytes(Probe(sourceHashes: hashes, cases: [a, history.last!, positive]))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try bytes.write(to: root.appendingPathComponent("context-probe.json"), options: .withoutOverwriting)
            XCTAssertEqual(hashes, try X.sourceHashes())
        }
    }
}
