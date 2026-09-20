import Foundation
@testable import StrandAnalytics

/// Historical orchestration over observed inputs; no staging, snapshot assembly, or fixture writes.
enum ServerDaySwiftHistory {
    typealias C = ServerDaySwiftContract

    struct State: Codable, Equatable {
        let baseline: Double
        let spread: Double
        let nValid: Int
        let nightsSinceUpdate: Int
        let status: String

        init(_ state: BaselineState) {
            baseline = state.baseline; spread = state.spread; nValid = state.nValid
            nightsSinceUpdate = state.nightsSinceUpdate; status = state.status.rawValue
        }
        func native() throws -> BaselineState {
            guard baseline.isFinite, spread.isFinite, spread >= 0, nValid >= 0, nightsSinceUpdate >= 0,
                  Double(nValid) <= C.safeInteger, Double(nightsSinceUpdate) <= C.safeInteger,
                  let flag = BaselineStatus(rawValue: status),
                  flag == Baselines.computeStatus(nValid: nValid, nightsSinceUpdate: nightsSinceUpdate) else {
                throw C.Failure.invalid("baseline_state")
            }
            return BaselineState(baseline: baseline, spread: spread, nValid: nValid,
                nightsSinceUpdate: nightsSinceUpdate, status: flag)
        }
    }

    struct SleepBlock: Codable, Equatable {
        let start: Int
        let end: Int
        let asleepMin: Double?
    }

    /// Synthetic observations in this increment, later supplied by actual Swift scoring.
    struct Measurements: Codable, Equatable {
        var values: [String: Double] = [:]
        var sleep: [SleepBlock] = []
        var mainSleepMin: Double? = nil
        var napSleepMin: Double = 0

        func validate() throws {
            guard Set(values.keys).isSubset(of: Set(Baselines.metricCfg.keys).subtracting(["readiness_hrv_ln"])),
                  values.values.allSatisfy(\.isFinite), napSleepMin.isFinite, napSleepMin >= 0,
                  mainSleepMin.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw C.Failure.invalid("measurements") }
            var starts = Set<Int>()
            for block in sleep {
                guard abs(Double(block.start)) <= C.safeInteger, abs(Double(block.end)) <= C.safeInteger,
                      block.start < block.end, starts.insert(block.start).inserted,
                      block.asleepMin.map({ $0.isFinite && $0 >= 0 && $0 <= Double(block.end - block.start) / 60 }) ?? true else {
                    throw C.Failure.invalid("sleep_block")
                }
            }
        }
        var baselineValues: [String: Double] {
            var result = values
            if let hrv = values["hrv"], hrv > 0 { result["readiness_hrv_ln"] = log(hrv) }
            return result
        }
    }

    struct Observation: Codable, Equatable {
        let identity: C.Identity
        let day: String
        let timezone: String
        let policy: C.Policy
        let profileRevision: Int64
        let configurationRevision: Int64
        let baselinesBefore: [String: State]
        let measurements: Measurements
        let creditedSleepMin: Double?
    }

    struct Debt: Codable, Equatable {
        struct Night: Codable, Equatable {
            let day: String
            let sleptMin: Double
            let deltaMin: Double
        }
        let needMin: Double
        let balanceMin: Double
        let magnitudeMin: Double
        let nightCount: Int
        let nights: [Night]
        init(_ ledger: SleepDebtLedger) {
            needMin = ledger.needMin; balanceMin = ledger.balanceMin; magnitudeMin = ledger.magnitudeMin
            nightCount = ledger.nightCount
            nights = ledger.nights.map { Night(day: $0.day, sleptMin: $0.sleptMin, deltaMin: $0.deltaMin) }
        }
    }

    struct Checkpoint: Codable, Equatable {
        var schemaVersion = C.schemaVersion
        var recipe = C.recipe
        let identity: C.Identity
        let throughDay: String
        let policy: C.Policy
        let historyDigest: String
        var baselinesAfter: [String: State]
        let observation: Observation
        let needHours: Double
        let sleepDebt: Debt
    }

    struct Prepared {
        let input: C.Input
        let resolution: C.Resolution
        let policy: C.Policy
        let history: [Observation]
        let eligibleHistory: [Observation]
        let baselinesBefore: [String: State]
        let needHours: Double
        let consistency: Double?
        let habitualMidsleepSec: Int?
        let reusedCheckpoint: Bool
    }

    static func prepare(_ input: C.Input, history: [Observation], predecessor: Checkpoint? = nil) throws -> Prepared {
        let resolution = try C.resolve(input)
        let policy = try C.policy(resolution, identity: input.identity)
        var previousDay: String?
        for row in history {
            guard row.identity == input.identity, row.day < input.day,
                  previousDay.map({ $0 < row.day }) ?? true else { throw C.Failure.invalid("history_order_or_identity") }
            let bounds = try C.dayBounds(row.day, row.timezone)
            try row.measurements.validate()
            guard row.measurements.sleep.allSatisfy({ $0.end <= bounds.upperBound }) else {
                throw C.Failure.invalid("future_sleep")
            }
            try validateStates(row.baselinesBefore)
            guard row.creditedSleepMin == SleepDebt.creditedSleepMin(mainSleepMin: row.measurements.mainSleepMin,
                napSleepMin: row.measurements.napSleepMin) else { throw C.Failure.invalid("credited_sleep") }
            previousDay = row.day
        }
        if let predecessor {
            guard predecessor.schemaVersion == C.schemaVersion, predecessor.recipe == C.recipe,
                  predecessor.identity == input.identity, predecessor.throughDay == history.last?.day,
                  predecessor.observation == history.last, predecessor.policy == history.last?.policy,
                  predecessor.historyDigest == (try C.digest(history)) else { throw C.Failure.invalid("checkpoint_ancestry") }
            try validateStates(predecessor.baselinesAfter)
            let expected = try advance(predecessor.observation.baselinesBefore,
                measurements: predecessor.observation.measurements, day: predecessor.throughDay, policy: predecessor.policy)
            guard predecessor.baselinesAfter == expected else { throw C.Failure.invalid("checkpoint_after_state") }
        }
        let eligible = history.filter { $0.policy.sourceEra == policy.sourceEra }
        let reused = predecessor?.policy == policy
        var before: [String: State] = [:]
        if reused, let predecessor {
            for (key, cfg) in Baselines.metricCfg {
                var state = try predecessor.baselinesAfter[key]!.native()
                for day in try C.days(from: predecessor.throughDay, through: input.day).dropFirst().dropLast() {
                    guard try baselineDayIsEligible(day, metric: key, policy: policy) else { continue }
                    state = Baselines.update(state, value: nil, cfg: cfg, rejectHardOutliers: key != "readiness_hrv_ln")
                }
                before[key] = State(state)
            }
        } else {
            let byDay = Dictionary(uniqueKeysWithValues: eligible.map { ($0.day, $0) })
            let dates = try C.days(from: eligible.first?.day ?? input.day, through: input.day).dropLast()
            for (key, cfg) in Baselines.metricCfg {
                var state: BaselineState?
                for day in dates {
                    guard try baselineDayIsEligible(day, metric: key, policy: policy) else { continue }
                    let row = byDay[day]
                    let value = key == "strain" && row?.policy.effortMethod != policy.effortMethod
                        ? nil : row?.measurements.baselineValues[key]
                    state = Baselines.update(state, value: value, cfg: cfg, rejectHardOutliers: key != "readiness_hrv_ln")
                }
                before[key] = State(state ?? Baselines.foldHistory([], cfg: cfg))
            }
        }
        let blocks = try sleepHistory(eligible)
        var longest: [String: (SleepStageTotals.HistoryBlock, Double)] = [:]
        for (block, asleep) in blocks {
            if let old = longest[block.dayKey], old.0.durationS > block.durationS ||
                (old.0.durationS == block.durationS && old.0.start <= block.start) { continue }
            longest[block.dayKey] = (block, asleep)
        }
        let hours = longest.keys.sorted().map { longest[$0]!.1 / 60 }
        let age = try C.number(resolution.payload(.profile), "age") ?? 30
        let override = try C.number(resolution.payload(.config), "sleepNeedHours")
        guard age > 0, age <= 500, override.map({ $0 >= 3 && $0 <= 14 }) ?? true else { throw C.Failure.invalid("sleep_profile") }
        let need = override ?? AnalyticsEngine.Rest.personalizedNeedHours(nightlyHours: hours, age: Int(age))
        return Prepared(input: input, resolution: resolution, policy: policy, history: history, eligibleHistory: eligible,
            baselinesBefore: before, needHours: need,
            consistency: VitalityEngine.sleepConsistency(nightlyHours: Array(hours.suffix(28))),
            habitualMidsleepSec: SleepStageTotals.habitualMidsleepSec(blocks.map(\.0), offsetSec: 0), reusedCheckpoint: reused)
    }

    static func finish(_ prepared: Prepared, measurements: Measurements) throws -> Checkpoint {
        try measurements.validate()
        // Current sleep cannot extend beyond the explicit observation day.
        guard measurements.sleep.allSatisfy({ $0.end <= prepared.resolution.dayBounds.upperBound }) else {
            throw C.Failure.invalid("future_sleep")
        }
        let after = try advance(prepared.baselinesBefore, measurements: measurements, day: prepared.input.day, policy: prepared.policy)
        let credited = SleepDebt.creditedSleepMin(mainSleepMin: measurements.mainSleepMin, napSleepMin: measurements.napSleepMin)
        let observation = Observation(identity: prepared.input.identity, day: prepared.input.day, timezone: prepared.input.timezone,
            policy: prepared.policy, profileRevision: prepared.resolution.head(.profile)?.revision ?? 0,
            configurationRevision: prepared.resolution.head(.config)?.revision ?? 0,
            baselinesBefore: prepared.baselinesBefore, measurements: measurements, creditedSleepMin: credited)
        let debt = SleepDebt.ledger(series: (prepared.eligibleHistory + [observation]).map { ($0.day, $0.creditedSleepMin) },
            needHours: prepared.needHours)
        return Checkpoint(identity: prepared.input.identity, throughDay: prepared.input.day, policy: prepared.policy,
            historyDigest: try C.digest(prepared.history + [observation]), baselinesAfter: after,
            observation: observation, needHours: prepared.needHours, sleepDebt: Debt(debt))
    }

    private static func advance(_ before: [String: State], measurements: Measurements, day: String,
                                policy: C.Policy) throws -> [String: State] {
        var after = before
        for (key, cfg) in Baselines.metricCfg {
            if try baselineDayIsEligible(day, metric: key, policy: policy) {
                after[key] = State(Baselines.update(try after[key]!.native(), value: measurements.baselineValues[key],
                    cfg: cfg, rejectHardOutliers: key != "readiness_hrv_ln"))
            }
        }
        return after
    }

    /// Missing days and observations obey the same per-metric UTC epoch-day admission rule.
    private static func baselineDayIsEligible(_ day: String, metric: String, policy: C.Policy) throws -> Bool {
        Double(try C.dayBounds(day, "UTC").lowerBound) >= policy.epoch(metric)
    }

    static func validateStates(_ states: [String: State]) throws {
        guard Set(states.keys) == Set(Baselines.metricCfg.keys) else { throw C.Failure.invalid("baseline_keys") }
        for value in states.values { _ = try value.native() }
    }

    private static func sleepHistory(_ history: [Observation]) throws -> [(SleepStageTotals.HistoryBlock, Double)] {
        var seen: [Int: SleepBlock] = [:]
        var result: [(SleepStageTotals.HistoryBlock, Double)] = []
        for row in history {
            guard let zone = TimeZone(identifier: row.timezone) else { throw C.Failure.invalid("history_timezone") }
            for block in row.measurements.sleep {
                guard let asleep = block.asleepMin else { continue }
                if let prior = seen[block.start] {
                    guard prior == block else { throw C.Failure.invalid("conflicting_sleep_identity") }
                    continue
                }
                seen[block.start] = block
                let midpoint = block.start + (block.end - block.start) / 2
                let offset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(midpoint)))
                result.append((SleepStageTotals.HistoryBlock(start: block.start + offset, end: block.end + offset,
                    dayKey: C.dayKey(midpoint, zone: zone)), asleep))
            }
        }
        return result
    }
}
