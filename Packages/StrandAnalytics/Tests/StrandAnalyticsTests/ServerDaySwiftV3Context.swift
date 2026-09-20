import CryptoKit
import Foundation
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

enum ServerDaySwiftV3Context {
    typealias C = ServerDaySwiftContract
    typealias V = ServerDaySwiftV3Contract
    typealias H = ServerDaySwiftHistory
    typealias S = ServerDaySwiftV3Selection
    typealias T = ServerDaySwiftV3Thermal
    typealias Sleep = ServerDaySwiftV3Sleep
    typealias Cycle = ServerDaySwiftV3Cycle
    typealias A = ServerDaySwiftV3Admission
    typealias P = ServerDaySwiftV3CoreProbe

    struct HourlyHR: Encodable, Equatable {
        let schemaVersion = 2
        let start: Int
        let meanHR: Double
        let sampleCount: Int
        let hrIDs: [String]
    }
    struct MainNight: Encodable, Equatable {
        let start: Int
        let end: Int
        let originalIDs: [String]
        let indices: [Int]
    }
    struct Aggregate: Encodable, Equatable {
        let hr: Double?
        let rmssd: Double?
        func encode(to encoder: Encoder) throws { try P.reflect(self).encode(to: encoder) }
    }
    struct Reading: Encodable, Equatable {
        let value: Double?
        let unit: String
        let method: String
        func encode(to encoder: Encoder) throws { try P.reflect(self).encode(to: encoder) }
    }
    struct DatedValue: Equatable { let day: String; let value: Double }
    struct Signal: Equatable {
        let metric: A.BaselineMetric
        let recent: [DatedValue]
        let baseline: H.State?
        let reading: IllnessSignalEngine.SignalReading
        let trusted: Bool
        let hasCurrent: Bool
    }
    struct IllnessEvidence: Equatable {
        let recentDays: [String]
        let baselineDays: [String]
        let signals: [Signal]
        let result: IllnessSignalEngine.Result?
        let distance: IllnessDistance.Result?
        let gaps: [String]
        var inputs: IllnessSignalEngine.Inputs {
            func reading(_ key: A.BaselineMetric) -> IllnessSignalEngine.SignalReading? { signals.first { $0.metric == key }?.reading }
            return .init(restingHR: reading(.restingHR), skinTemp: reading(.skinTemp), hrv: reading(.hrv), respiration: reading(.resp))
        }
    }
    struct CycleEvidence: Equatable {
        let observed: [CyclePhaseEngine.Night]
        let admitted: [CyclePhaseEngine.Night]
        let admission: [A.MetricAdmission]
        let periodDays: [String]
        let baselineUsable: Bool
        let result: CyclePhaseEngine.Result?
        let gaps: [String]
    }
    struct CircadianEvidence: Equatable {
        let from: Int
        let throughExclusive: Int
        let hourly: [HourlyHR]
        let bins: [CircadianEngine.ActivityBin]
        let observedDays: Int
        let observedWakeHour: Double?
        let nativeWakeReference: Double
        let wakeReferenceProvenance: String
        let fit: CircadianEngine.CosinorFit?
        let result: CircadianEngine.PhaseEstimate?
        let gaps: [String]
    }
    struct DaytimeEvidence: Equatable {
        let mode: DaytimeStress.ScoringMode
        let result: DaytimeStress.Result
        let aggregate: Aggregate
        let baevsky: StressIndex.Components?
        let frequency: HRVFreqDomain.Bands?
        let hrIDs: [String]
        let rrIDs: [String]
        let gravityIDs: [String]
        var personalBaseline: Bool { if case .baselineRelative = mode { return true }; return false }
    }
    struct ContextOutput: Encodable, Equatable {
        let decision: A.Decision
        let illness: IllnessEvidence
        let cycle: CycleEvidence
        let circadian: CircadianEvidence
        let daytime: DaytimeEvidence
        let metrics: [String: Reading]
        let charts: C.JSON
        let details: C.JSON
        let capabilities: [String]
        let gaps: [String]
        func encode(to encoder: Encoder) throws {
            let diagnostic = try C.JSON.object(["decision": V.json(decision), "illness": P.reflect(illness),
                "cycle": P.reflect(cycle), "circadian": P.reflect(circadian),
                "daytime": .object(["personalBaseline": .bool(daytime.personalBaseline), "result": P.reflect(daytime.result),
                    "aggregate": P.reflect(daytime.aggregate), "baevsky": P.reflect(daytime.baevsky as Any),
                    "frequency": P.reflect(daytime.frequency as Any), "hrIDs": P.reflect(daytime.hrIDs),
                    "rrIDs": P.reflect(daytime.rrIDs), "gravityIDs": P.reflect(daytime.gravityIDs)]),
                "metrics": V.json(metrics), "charts": charts, "details": details,
                "capabilities": P.reflect(capabilities), "gaps": P.reflect(gaps)])
            try diagnostic.encode(to: encoder)
        }
    }

    struct Observation: Encodable {
        let input: V.Input
        let inputDigest: String
        let selection: V.Selection
        let native: AnalyticsEngine.DayResult
        let sleep: Sleep.ResolvedSleep
        let mainNight: MainNight?
        let hourlyHR: [HourlyHR]
        let rawNight: T.RawNight
        let thermal: T.Evidence
        let daytimeAggregate: Aggregate
        let cycle: Cycle.CycleEvidence
        let checkpoint: H.Checkpoint
        fileprivate init(input: V.Input, inputDigest: String, selection: V.Selection, native: AnalyticsEngine.DayResult,
                         sleep: Sleep.ResolvedSleep, mainNight: MainNight?, hourlyHR: [HourlyHR], rawNight: T.RawNight,
                         thermal: T.Evidence, daytimeAggregate: Aggregate, cycle: Cycle.CycleEvidence, checkpoint: H.Checkpoint) {
            self.input = input; self.inputDigest = inputDigest; self.selection = selection; self.native = native; self.sleep = sleep
            self.mainNight = mainNight; self.hourlyHR = hourlyHR; self.rawNight = rawNight; self.thermal = thermal
            self.daytimeAggregate = daytimeAggregate; self.cycle = cycle; self.checkpoint = checkpoint
        }
        func encode(to encoder: Encoder) throws {
            try C.JSON.object(["input": V.json(input), "inputDigest": .string(inputDigest), "selection": V.json(selection),
                "nativeDayResult": P.reflect(native), "sleep": V.json(sleep), "mainNight": P.reflect(mainNight as Any),
                "hourlyHR": V.json(hourlyHR), "rawNight": V.json(rawNight), "thermal": V.json(thermal),
                "daytimeAggregate": V.json(daytimeAggregate), "cycle": V.json(cycle), "checkpoint": V.json(checkpoint)]).encode(to: encoder)
        }
    }
    // Encoded diagnostics are deliberately not a constructor for an execution or prior.
    struct Execution: Encodable {
        let observation: Observation
        let output: ContextOutput
        let parentDigest: String?
        let digest: String
        let reusedCheckpoint: Bool
        fileprivate init(observation: Observation, output: ContextOutput, parentDigest: String?, reusedCheckpoint: Bool) throws {
            struct Seal: Encodable { let observation: Observation; let output: ContextOutput; let parentDigest: String? }
            self.observation = observation; self.output = output; self.parentDigest = parentDigest
            self.digest = try C.digest(Seal(observation: observation, output: output, parentDigest: parentDigest))
            self.reusedCheckpoint = reusedCheckpoint
        }
        var prior: Prior { Prior(self) }
        var restart: Restart { Restart(self) }
    }
    struct Prior {
        fileprivate let observation: Observation
        fileprivate let parentDigest: String?
        fileprivate let digest: String
        fileprivate init(_ execution: Execution) {
            observation = execution.observation; parentDigest = execution.parentDigest; digest = execution.digest
        }
    }
    struct Restart {
        fileprivate let checkpoint: H.Checkpoint
        fileprivate let lineage: String
        fileprivate init(_ execution: Execution) { checkpoint = execution.observation.checkpoint; lineage = execution.digest }
    }

    static func run(_ input: V.Input, history: [Prior] = [], restart: Restart? = nil) async throws -> Execution {
        let decision = try A.resolve(input)
        guard input.historyCaseIds == history.map({ $0.observation.input.id }) else { throw A.failure("history_case_lineage") }
        var lastDay: String?, parent: String?
        for (index, prior) in history.enumerated() {
            let previous = prior.observation.input
            guard previous.identity == input.identity, previous.day < input.day,
                  previous.asOfExclusive <= input.asOfExclusive, lastDay.map({ $0 < previous.day }) ?? true,
                  previous.historyCaseIds == Array(input.historyCaseIds.prefix(index)), prior.parentDigest == parent else {
                throw A.failure("prior_scope_or_chain")
            }
            lastDay = previous.day; parent = prior.digest
        }
        if let restart {
            guard restart.lineage == parent, restart.checkpoint == history.last?.observation.checkpoint else { throw A.failure("restart_lineage") }
        }
        let observations = history.map(\.observation)
        let prepared = try H.prepare(input.historyInput, history: observations.map { $0.checkpoint.observation }, predecessor: restart?.checkpoint)
        let seed = try await S.seed(input), loaded = try await S.load(seed), anchor = try await T.anchor(seed)
        let (before, thermal) = try A.prepareThermal(prepared, history: observations, anchor: anchor)
        let sleep = try A.resolveSleep(input: input, prepared: before, loaded: loaded, thermal: anchor, decision: decision)
        let native = try Sleep.analyze(input: input, prepared: before, loaded: loaded, thermal: anchor, resolved: sleep)
        let main = Sleep.mainIndices(native, prepared: before, resolved: sleep)
        let observedMain = main.filter { index in native.sleepSessions[index].stages.contains {
            $0.end > $0.start && ["light", "deep", "rem"].contains($0.stage)
        } }
        let mainNight = observedMain.isEmpty ? nil : MainNight(start: observedMain.map { native.sleepSessions[$0].start }.min()!,
            end: observedMain.map { native.sleepSessions[$0].end }.max()!, originalIDs: observedMain.map { index in
                let s = native.sleepSessions[index]
                return sleep.entries.first { $0.session.start == s.start && $0.session.end == s.end }!.identity.id
            }, indices: observedMain)
        let cycle = try await Cycle.evaluate(input: input, seed: seed, prepared: before, sleep: sleep,
            priorSleep: observations.map { $0.cycle.prior })
        let hourly = hourlyHR(input: input, loaded: loaded)
        let cutoff = try shift(input.day, -364)
        let eligible = observations.filter { $0.checkpoint.policy.sourceEra == before.policy.sourceEra && $0.input.day >= cutoff }
        let daily = eligible.map { DailyObservation(day: $0.input.day, daily: $0.native.daily, before: $0.checkpoint.observation.baselinesBefore) }
            + [DailyObservation(day: input.day, daily: native.daily, before: before.baselinesBefore)]
        let illness = try illness(day: input.day, history: daily, before: before.baselinesBefore, decision: decision)
        let menstrual = try menstrualCycle(day: input.day, history: daily, before: before.baselinesBefore, decision: decision)
        let circadian = try circadian(day: input.day, timezone: input.timezone, hourly: eligible.flatMap(\.hourlyHR) + hourly,
            sleep: eligible.compactMap(\.mainNight) + [mainNight].compactMap { $0 })
        let daytime = try daytime(input: input, loaded: loaded, before: before.baselinesBefore, decision: decision)
        let output = try output(input: input, decision: decision, illness: illness, cycle: menstrual, circadian: circadian, daytime: daytime)
        var measurements = ServerDaySwiftV3History.measurements(native, main: main)
        measurements.values["strain"] = cycle.strain
        measurements.values["daytime_hr"] = daytime.aggregate.hr
        measurements.values["daytime_rmssd"] = daytime.aggregate.rmssd
        let checkpoint = try H.finish(before, measurements: measurements)
        let observation = Observation(input: input, inputDigest: decision.inputDigest, selection: loaded.evidence, native: native,
            sleep: sleep, mainNight: mainNight, hourlyHR: hourly, rawNight: T.rawNight(loaded, sessions: native.sleepSessions),
            thermal: thermal, daytimeAggregate: daytime.aggregate, cycle: cycle, checkpoint: checkpoint)
        return try Execution(observation: observation, output: output, parentDigest: parent, reusedCheckpoint: before.reusedCheckpoint)
    }

    struct DailyObservation { let day: String; let daily: DailyMetric; let before: [String: H.State] }
    static func shift(_ day: String, _ days: Int) throws -> String {
        C.dayKey(try C.dayBounds(day, "UTC").lowerBound + days * 86_400, zone: TimeZone(secondsFromGMT: 0)!)
    }
    static func hourlyHR(input: V.Input, loaded: S.Loaded) -> [HourlyHR] {
        let zone = TimeZone(identifier: input.timezone)!, b = loaded.evidence.bounds
        let rows = loaded.evidence.streams["hr", default: []].filter {
            b.dayRange.contains($0.ts) && ((try? V.number($0.fields["bpm"])) ?? 0) > 0
        }
        let groups = Dictionary(grouping: rows) { DaytimeStress.hourBucket($0.ts, offsetSeconds: b.tzOffsetSeconds, timezone: zone) }
        return groups.keys.sorted().map { start in
            let rows = groups[start]!
            return HourlyHR(start: start, meanHR: rows.reduce(0) { $0 + (try! V.number($1.fields["bpm"])) } / Double(rows.count),
                sampleCount: rows.count, hrIDs: rows.map(\.id))
        }
    }

    static func illness(day: String, history: [DailyObservation], before: [String: H.State], decision: A.Decision) throws -> IllnessEvidence {
        let byDay = Dictionary(uniqueKeysWithValues: history.map { ($0.day, $0.daily) })
        let recentDays = try [shift(day, -1), day], baseDays = try C.days(from: shift(day, -30), through: shift(day, -3))
        var gaps: Set<String> = [], signals: [Signal] = []
        func skin(_ d: DailyMetric) -> Double? { d.skinTempDevC.flatMap { $0.isFinite && (-10...10).contains($0) ? $0 : nil } }
        let current = byDay[day]
        let currentValues = current.map { [$0.restingHr.map(Double.init), $0.avgHrv, $0.respRateBpm, skin($0)] } ?? []
        let hasCurrent = currentValues.contains { $0?.isFinite == true }
        let known = decision.journalEnabled && decision.answers?.complete == true
        if !decision.journalEnabled { gaps.insert("journal_context_not_shared") }
        else if !known { gaps.insert("journal_context_incomplete") }
        if known && !hasCurrent { gaps.insert("current_day_physiology_unavailable") }
        if known && hasCurrent {
            func build(_ key: A.BaselineMetric, positive: Bool, select: (DailyMetric) -> Double?) throws {
                let state = try before[key.rawValue]?.native()
                guard state?.usable == true else {
                    gaps.insert(state?.status == .stale ? "illness_baseline_stale" : "illness_baseline_learning"); return
                }
                let epoch = decision.policy.epoch(key.rawValue)
                var recent: [DatedValue] = []
                for date in recentDays where Double(try C.dayBounds(date, "UTC").lowerBound) >= epoch {
                    if let d = byDay[date], let value = select(d), value.isFinite { recent.append(DatedValue(day: date, value: value)) }
                }
                guard !recent.isEmpty else { return }
                let mean = recent.reduce(0) { $0 + $1.value } / Double(recent.count)
                if key == .skinTemp {
                    signals.append(Signal(metric: key, recent: recent, baseline: nil,
                        reading: .init(zIllnessward: mean / 0.3), trusted: false, hasCurrent: recent.contains { $0.day == day }))
                    return
                }
                let values = baseDays.map { byDay[$0].flatMap(select).flatMap { $0.isFinite ? $0 : nil } }
                let base = Baselines.foldHistory(values, dayKeys: baseDays, cfg: Baselines.metricCfg[key.rawValue]!, baselineEpoch: epoch)
                guard base.usable else {
                    gaps.insert(base.status == .stale ? "illness_baseline_stale" : "illness_baseline_learning"); return
                }
                let z = Baselines.deviation(mean, state: base).z * (positive ? 1 : -1)
                signals.append(Signal(metric: key, recent: recent, baseline: H.State(base), reading: .init(zIllnessward: z),
                    trusted: base.trusted && state!.trusted, hasCurrent: recent.contains { $0.day == day }))
            }
            try build(.restingHR, positive: true) { $0.restingHr.map(Double.init) }
            try build(.hrv, positive: false) { $0.avgHrv }
            try build(.resp, positive: true) { $0.respRateBpm }
            try build(.skinTemp, positive: true, select: skin)
        }
        var result: IllnessSignalEngine.Result?, distance: IllnessDistance.Result?
        if known && hasCurrent {
            let trusted = signals.contains { [.restingHR, .hrv].contains($0.metric) && $0.trusted }
            let eligibleCurrent = signals.contains(where: \.hasCurrent)
            if !trusted { gaps.insert("illness_baseline_learning") }
            if !eligibleCurrent { gaps.insert("current_day_physiology_unavailable") }
            if trusted && eligibleCurrent {
                func reading(_ key: A.BaselineMetric) -> IllnessSignalEngine.SignalReading? { signals.first { $0.metric == key }?.reading }
                let flags = decision.answers!.flags
                let context = IllnessSignalEngine.Context(alcohol: flags["alcohol"]!.value!, stress: flags["stress"]!.value!,
                    sauna: flags["sauna"]!.value!, hardOrLateWorkout: flags["hardOrLateWorkout"]!.value!,
                    travelPhaseJump: flags["travelPhaseJump"]!.value!, alreadyUnwell: flags["alreadyUnwell"]!.value!, baselineTrusted: true)
                result = IllnessSignalEngine.evaluate(.init(restingHR: reading(.restingHR), skinTemp: reading(.skinTemp),
                    hrv: reading(.hrv), respiration: reading(.resp)), context: context, firedLabels: [:])
                distance = IllnessDistance.evaluate(features: .init(restingHR: reading(.restingHR)?.zIllnessward,
                    rmssd: reading(.hrv)?.zIllnessward, skinTemp: reading(.skinTemp)?.zIllnessward,
                    respiration: reading(.resp)?.zIllnessward), correlation: nil)
            }
        }
        return IllnessEvidence(recentDays: recentDays, baselineDays: baseDays, signals: signals, result: result, distance: distance, gaps: gaps.sorted())
    }

    static func menstrualCycle(day: String, history: [DailyObservation], before: [String: H.State], decision: A.Decision) throws -> CycleEvidence {
        guard decision.cycleEnabled else {
            return CycleEvidence(observed: [], admitted: [], admission: [], periodDays: [], baselineUsable: false, result: nil, gaps: ["cycle_context_not_shared"])
        }
        let observed = try history.map { row -> CyclePhaseEngine.Night in
            func z(_ value: Double?, _ key: String) throws -> Double? {
                guard let value, value.isFinite, let state = try row.before[key]?.native(), state.usable else { return nil }
                return Baselines.deviation(value, state: state).z
            }
            return try .init(day: row.day, tempZ: z(row.daily.skinTempC, "skin_temp"), rhrZ: z(row.daily.restingHr.map(Double.init), "resting_hr"), hrvZ: z(row.daily.avgHrv, "hrv"))
        }
        var admissions: [A.MetricAdmission] = []
        let admitted = try observed.map { night -> CyclePhaseEngine.Night in
            func value(_ value: Double?, _ key: A.BaselineMetric) throws -> Double? {
                let a = try A.eligible(day: night.day, metric: key, policy: decision.policy, before: before)
                admissions.append(a); return a.admitted ? value : nil
            }
            return try .init(day: night.day, tempZ: value(night.tempZ, .skinTemp), rhrZ: value(night.rhrZ, .restingHR), hrvZ: value(night.hrvZ, .hrv))
        }
        let periods = Array(Set(decision.periods.map(\.day).filter { $0 <= day })).sorted()
        var gaps: [String] = []
        if periods.isEmpty { gaps.append("period_history_unavailable") }
        let usable = try before["skin_temp"]?.native().usable == true && admitted.contains { $0.tempZ != nil }
        if !usable { gaps.append("cycle_temperature_baseline_unavailable") }
        let current = admitted.first { $0.day == day }
        let hasCurrent = current.flatMap { CyclePhaseEngine.fusedIndex(tempZ: $0.tempZ, rhrZ: $0.rhrZ, hrvZ: $0.hrvZ) } != nil
        if !hasCurrent { gaps.append("cycle_current_physiology_unavailable") }
        else if current?.tempZ == nil { gaps.append("cycle_current_temperature_unavailable") }
        let result = try CyclePhaseEngine.classifyCalendar(admitted, baselineUsable: usable && hasCurrent, through: day, loggedPeriodStarts: periods)
        if result.phase == .learning { gaps.append("cycle_history_learning") }
        return CycleEvidence(observed: observed, admitted: admitted, admission: admissions, periodDays: periods,
            baselineUsable: usable && hasCurrent, result: result, gaps: gaps.sorted())
    }

    static func circadian(day: String, timezone: String, hourly: [HourlyHR], sleep: [MainNight]) throws -> CircadianEvidence {
        let zone = TimeZone(identifier: timezone)!, from = try C.dayBounds(shift(day, -13), timezone).lowerBound
        let end = try C.dayBounds(day, timezone).upperBound
        let observations = hourly.filter { $0.start >= from && $0.start < end && $0.meanHR.isFinite && $0.meanHR > 0 && $0.sampleCount > 0 }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone; calendar.locale = Locale(identifier: "en_US_POSIX")
        let groups = Dictionary(grouping: observations) { calendar.component(.hour, from: Date(timeIntervalSince1970: Double($0.start))) }
        let bins = groups.keys.sorted().map { CircadianEngine.ActivityBin(hour: Double($0), activity: groups[$0]!.reduce(0) { $0 + $1.meanHR } / Double(groups[$0]!.count)) }
        let days = Set(observations.map { C.dayKey($0.start, zone: zone) }).count
        let wake = sleep.filter { $0.start < $0.end && $0.end >= from && $0.end < end }.map(\.end).max()
        let hour = wake.map { ts -> Double in
            let c = calendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: Double(ts)))
            return Double(c.hour! * 3600 + c.minute! * 60 + c.second!) / 3600
        }
        let phase = observations.count >= 24 && bins.count >= 6
            ? CircadianEngine.estimatePhase(bins: bins, daysObserved: days, habitualWakeHour: hour ?? 7, observedTempMinHour: nil) : nil
        var gaps: [String] = []
        if phase == nil { gaps.append("circadian_hourly_history_unavailable") }
        else if phase?.confidence == .unreadable { gaps.append("circadian_rhythm_unreadable") }
        if hour == nil { gaps.append("sleep_schedule_unavailable") }
        return CircadianEvidence(from: from, throughExclusive: end, hourly: observations, bins: bins, observedDays: days,
            observedWakeHour: hour, nativeWakeReference: hour ?? 7,
            wakeReferenceProvenance: hour == nil ? "default_reference_not_observed" : "observed_main_night_end",
            fit: CircadianEngine.cosinor(bins), result: phase, gaps: gaps.sorted())
    }

    static func daytime(input: V.Input, loaded: S.Loaded, before: [String: H.State], decision: A.Decision) throws -> DaytimeEvidence {
        let b = loaded.evidence.bounds, zone = TimeZone(identifier: input.timezone)!
        let hr = loaded.hr.filter { b.dayRange.contains($0.ts) && (20...250).contains($0.bpm) }
        let rr = loaded.rr.filter { b.dayRange.contains($0.ts) }, gravity = loaded.gravity.filter { b.dayRange.contains($0.ts) }
        var mode: DaytimeStress.ScoringMode = .dayRelative
        if decision.daytimePersonalBaselineEnabled, let state = try before["daytime_hr"]?.native(), state.usable {
            let rmssd = try before["daytime_rmssd"]?.native()
            mode = .baselineRelative(hr: state, rmssd: DaytimeStress.daytimeRMSSDScoringEnabled && rmssd?.usable == true ? rmssd : nil)
        }
        let result = DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity, tzOffsetSeconds: b.tzOffsetSeconds, mode: mode, timezone: zone)
        let aggregate = DaytimeStress.dayDaytimeAggregate(hr: hr, rr: rr, tzOffsetSeconds: b.tzOffsetSeconds, timezone: zone)
        return DaytimeEvidence(mode: mode, result: result, aggregate: Aggregate(hr: aggregate.hr, rmssd: aggregate.rmssd),
            baevsky: StressIndex.components(rr: rr), frequency: HRVFreqDomain.freqDomain(rr: rr),
            hrIDs: loaded.evidence.streams["hr", default: []].filter { b.dayRange.contains($0.ts) && (20...250).contains(try! V.integer($0.fields["bpm"])) }.map(\.id),
            rrIDs: loaded.evidence.streams["rr", default: []].filter { b.dayRange.contains($0.ts) }.map(\.id),
            gravityIDs: loaded.evidence.streams["gravity", default: []].filter { b.dayRange.contains($0.ts) }.map(\.id))
    }

    static func output(input: V.Input, decision: A.Decision, illness: IllnessEvidence, cycle: CycleEvidence,
                       circadian: CircadianEvidence, daytime: DaytimeEvidence) throws -> ContextOutput {
        var metrics: [String: Reading] = [:], capabilities: [String] = []
        var details: [String: C.JSON] = ["contextPolicy": .string("as-of-context-v1")], charts: [String: C.JSON] = [:]
        var gaps = illness.gaps + cycle.gaps + circadian.gaps
        func reading(_ key: String, _ value: Double?, _ unit: String, _ method: String) {
            metrics[key] = Reading(value: value, unit: unit, method: method)
            if value != nil { capabilities.append(key) }
        }
        reading("illness_score", illness.result?.score, "score_0_100", "IllnessSignalEngine")
        reading("illness_distance", illness.distance?.distance, "dimensionless", "IllnessDistance_identity_correlation")
        if let result = illness.result, let distance = illness.distance {
            details["illness"] = try .object(["level": .string(result.level.rawValue), "signalCount": P.reflect(result.signalCount),
                "firedSignals": P.reflect(result.firedSignals), "copy": .string(result.copy), "suppressedBy": P.reflect(result.suppressedBy),
                "distanceFires": .bool(distance.fires), "distanceDeviatingFeatures": P.reflect(distance.deviatingFeatures),
                "distanceUsedDiagonalFallback": .bool(distance.usedDiagonalFallback), "distanceIsAlertGate": .bool(false), "wellnessOnly": .bool(true)])
        } else { details["illness"] = .null }
        if let result = cycle.result {
            var fields = try V.object(P.reflect(result))
            fields["shiftMarkers"] = try P.reflect(result.shiftMarkers.map(\.day))
            fields["awarenessOnly"] = .bool(true); fields["baselinePolicy"] = .string("pre_observation_absolute_temperature")
            details["cycle"] = .object(fields); capabilities.append("cycle_phase")
            charts["cycle_index"] = .array(try cycle.observed.compactMap { night in
                guard let value = CyclePhaseEngine.fusedIndex(tempZ: night.tempZ, rhrZ: night.rhrZ, hrvZ: night.hrvZ) else { return nil }
                let bounds = try C.dayBounds(night.day, input.timezone)
                return .object(["start": .number(Double(bounds.lowerBound)), "end": .number(Double(bounds.upperBound)), "value": .number(value)])
            })
        } else { details["cycle"] = .null }
        let readable = circadian.result.flatMap { $0.confidence == .unreadable ? nil : $0 }
        reading("circadian_phase_hour", readable?.tempMinHour, "local_hour", "CircadianEngine_observed_hourly_hr_proxy")
        reading("circadian_offset_min", circadian.observedWakeHour == nil ? nil : readable?.offsetVsScheduleMinutes, "min", "CircadianEngine")
        if let phase = circadian.result {
            details["circadian"] = try .object(["confidence": .string(phase.confidence.rawValue), "acrophaseHours": .number(phase.acrophaseHours),
                "note": .string(phase.note), "observedDays": P.reflect(circadian.observedDays),
                "habitualWakeHour": P.reflect(circadian.observedWakeHour as Any), "measuredTemperatureMinimum": .bool(false)])
        } else { details["circadian"] = .null }
        let stress = daytime.result, scored = !daytime.result.scored.isEmpty
        reading("daytime_stress_mean", stress.dayMean, "score_0_3", "DaytimeStress")
        reading("daytime_stress_high_min", scored ? Double(stress.highStressMinutes) : nil, "min", "DaytimeStress_hourly_approximation")
        reading("baevsky_stress_index", daytime.baevsky?.si, "dimensionless", "StressIndex")
        if !scored { gaps.append("daytime_stress_insufficient_data") }
        charts["daytime_stress"] = .array(try stress.hours.map { point in
            try .object(["start": P.reflect(point.startTs), "end": P.reflect(min(input.asOfExclusive, point.startTs + DaytimeStress.bucketSeconds)),
                "value": P.reflect(point.level as Any), "meanHr": P.reflect(point.meanHR as Any), "rmssd": P.reflect(point.rmssd as Any),
                "maskedForActivity": .bool(point.maskedForActivity)])
        })
        details["daytimeStress"] = try .object(["personalBaseline": .bool(daytime.personalBaseline), "hrOnlyFallback": .bool(stress.hrOnlyFallback),
            "activityMaskedHours": P.reflect(stress.activityMaskedHours), "sustainedHigh": scored ? .bool(stress.sustainedHigh) : .null,
            "sustainedRun": scored ? P.reflect(stress.sustainedRun) : .null])
        details["frequencyHrv"] = try daytime.frequency.map { try .object(["lfPower": P.reflect($0.lf as Any),
            "hfPower": .number($0.hf), "lfHfRatio": P.reflect($0.lfhf as Any)]) } ?? .null
        return ContextOutput(decision: decision, illness: illness, cycle: cycle, circadian: circadian, daytime: daytime,
            metrics: metrics, charts: .object(charts), details: .object(details), capabilities: capabilities.sorted(), gaps: Array(Set(gaps)).sorted())
    }

    static func sourceHashes() throws -> [String: String] {
        var hashes = try Sleep.sourceHashes()
        for name in ["Admission", "Context", "ContextTests"] {
            let path = "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/ServerDaySwiftV3\(name).swift"
            hashes[path] = SHA256.hash(data: try Data(contentsOf: P.repository.appendingPathComponent(path))).map { String(format: "%02x", $0) }.joined()
        }
        return hashes
    }
}
