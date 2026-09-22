import Foundation
import WhoopStore

/// Maps server score cache onto Today/Sleep display fields when `serverScoring` is on.
enum ServerScoreDisplay {
    static func illness(day: String, state: ServerScoreViewState) -> ServerScoreIllness? {
        detailSnapshot(.illnessScore, day: day, state: state)?.details?.illness
    }
    static func cycle(day: String, state: ServerScoreViewState) -> ServerScoreCycle? {
        detailSnapshot(.cyclePhase, day: day, state: state)?.details?.cycle
    }
    static func circadian(day: String, state: ServerScoreViewState) -> ServerScoreCircadian? {
        detailSnapshot(.circadianPhase, day: day, state: state)?.details?.circadian
    }
    static func daytimeStress(day: String, state: ServerScoreViewState) -> ServerScoreDaytimeStress? {
        detailSnapshot(.daytimeStress, day: day, state: state)?.details?.daytimeStress
    }

    static func motionRuns(_ segments: [ServerScoreSleepDiagnostics.Motion]) -> [[ServerScoreMotionPoint]] {
        var runs: [[ServerScoreMotionPoint]] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            guard segment.epochSeconds == 30, segment.unit == "gravity_delta_sum",
                  segment.method == "existing_stager_epoch_motion_observed_mask" else { continue }
            var current: [ServerScoreMotionPoint] = []
            for (index, value) in segment.values.enumerated() {
                if let value, value.isFinite, value >= 0, segment.counts.indices.contains(index), segment.counts[index] > 0 {
                    current.append(.init(timestamp: segment.start + Int64(index) * 30, value: value))
                } else if !current.isEmpty { runs.append(current); current = [] }
            }
            if !current.isEmpty { runs.append(current) }
        }
        return runs
    }

    static func detailSnapshot(_ metric: ServerScoreMetric, day: String, state: ServerScoreViewState) -> ServerScoreSnapshot? {
        guard state.owns(metric), let snapshot = state.days[day]?.snapshot,
              snapshot.status != "no_data", snapshot.supported.contains(metric) else { return nil }
        return snapshot
    }

    static func charge(day: String, state: ServerScoreViewState) -> ServerScoreCharge? {
        guard let snapshot = detailSnapshot(.recovery, day: day, state: state),
              snapshot.capabilities?.contains("charge") == true else { return nil }
        return snapshot.details?.charge
    }

    static func baseline(_ key: String, ownedBy metric: ServerScoreMetric, day: String,
                         state: ServerScoreViewState) -> ServerScoreBaseline? {
        guard let snapshot = detailSnapshot(metric, day: day, state: state),
              snapshot.capabilities?.contains("baselines") == true else { return nil }
        return snapshot.details?.baselines?[key]
    }

    static func sleepDiagnostics(day: String, state: ServerScoreViewState) -> [ServerScoreSleepDiagnostics] {
        detailSnapshot(.sleepSessions, day: day, state: state)?.details?.sleepSessions ?? []
    }

    /// A current-day headline is not the tail of a historical chart once this field is owned.
    static func headline(_ metric: ServerScoreMetric?, day: String, state: ServerScoreViewState,
                         local: @autoclosure () -> Double?) -> Double? {
        guard let metric else { return local() }
        return state.value(metric, day: day, local: local())
    }

    /// Select by explicit field ownership, never by value magnitude or a missing preferred reading.
    static func temperatureMetric(prefersAbsolute: Bool, state: ServerScoreViewState) -> ServerScoreMetric? {
        let preferred: ServerScoreMetric = prefersAbsolute ? .skinTemperature : .skinTemperatureDeviation
        let other: ServerScoreMetric = prefersAbsolute ? .skinTemperatureDeviation : .skinTemperature
        if state.owns(preferred) { return preferred }
        return state.owns(other) ? other : nil
    }

    /// Field ownership, not non-nil coalescing, decides whether local data may be read.
    static func daily(local: DailyMetric?, day: String, state: ServerScoreViewState,
                      carry: Bool = false) -> DailyMetric? {
        guard state.hasServerOwnership else { return local }
        func value(_ metric: ServerScoreMetric, _ local: Double?) -> Double? {
            if state.owns(metric) { return carry ? nil : state.days[day]?.snapshot?.value(metric) }
            return local
        }
        return DailyMetric(day: day,
            totalSleepMin: value(.sleepTotal, local?.totalSleepMin),
            efficiency: state.owns(.sleepEfficiency)
                ? (carry ? nil : efficiencyFraction(state.days[day]?.snapshot)) : local?.efficiency,
            deepMin: value(.sleepDeep, local?.deepMin), remMin: value(.sleepREM, local?.remMin),
            lightMin: value(.sleepLight, local?.lightMin), disturbances: value(.disturbances, local?.disturbances.map(Double.init)).map { Int($0.rounded()) },
            restingHr: value(.restingHR, local?.restingHr.map(Double.init)).map { Int($0.rounded()) },
            avgHrv: value(.hrv, local?.avgHrv), recovery: value(.recovery, local?.recovery), strain: value(.strain, local?.strain),
            exerciseCount: value(.exerciseCount, local?.exerciseCount.map(Double.init)).map { Int($0.rounded()) },
            spo2Pct: value(.spo2, local?.spo2Pct), skinTempDevC: value(.skinTemperatureDeviation, local?.skinTempDevC),
            respRateBpm: value(.respiration, local?.respRateBpm),
            steps: value(.steps, local?.steps.map(Double.init)).map { Int($0.rounded()) },
            activeKcalEst: value(.activeKcal, local?.activeKcalEst),
            spo2Red: value(.spo2Red, local?.spo2Red.map(Double.init)).map { Int($0.rounded()) },
            spo2Ir: value(.spo2IR, local?.spo2Ir.map(Double.init)).map { Int($0.rounded()) },
            avgSdnn: value(.sdnn, local?.avgSdnn), skinTempC: value(.skinTemperature, local?.skinTempC),
            sleepHrOnly: state.owns(.sleepSessions) ? nil : local?.sleepHrOnly)
    }

    static func carry(_ local: DailyMetric?, state: ServerScoreViewState) -> DailyMetric? {
        guard let local else { return nil }
        return daily(local: local, day: local.day, state: state, carry: true)
    }

    static func series(_ metric: ServerScoreMetric, through day: String, state: ServerScoreViewState) -> [(day: String, value: Double)] {
        guard state.owns(metric) else { return [] }
        var values: [String: Double] = [:]
        // Use one history envelope, not a union of potentially incompatible source/algorithm eras.
        // An individually requested day always wins, even when its value is null or still pending.
        let anchor = state.days.keys.sorted().reversed().compactMap { state.days[$0]?.snapshot }
            .first { $0.timezone == state.timezone }
        if let anchor, anchor.supported.contains(metric) {
            for entry in anchor.history ?? [] where entry.day <= day && state.days[entry.day] == nil {
                if let reading = entry.metrics[metric.rawValue], let value = reading.value {
                    values[entry.day] = seriesValue(metric, value: value, unit: reading.unit)
                }
            }
        }
        for (key, entry) in state.days where key <= day {
            if let snapshot = entry.snapshot, let value = snapshot.value(metric) {
                values[key] = seriesValue(metric, value: value, unit: snapshot.metrics?[metric.rawValue]?.unit)
            }
        }
        return values.keys.sorted().map { (day: $0, value: values[$0]!) }
    }

    /// Existing scalar catalog efficiency is percent; legacy daily rows stored a 0...1 fraction.
    /// An explicitly typed percent below 1 is already percent and must not be multiplied again.
    static func seriesValue(_ metric: ServerScoreMetric, value: Double, unit: String?) -> Double {
        metric == .sleepEfficiency && unit != "percent" && value <= 1 ? value * 100 : value
    }

    /// DailyMetric and CachedSleepSession retain the legacy fraction; chart/catalog readers use percent.
    static func efficiencyFraction(_ snapshot: ServerScoreSnapshot?) -> Double? {
        guard let snapshot, let value = snapshot.value(.sleepEfficiency) else { return nil }
        return snapshot.metrics?[ServerScoreMetric.sleepEfficiency.rawValue]?.unit == "percent" ? value / 100 : value
    }

    static func sleepLedger(day: String, state: ServerScoreViewState) -> ServerScoreSleepLedger? {
        guard state.owns(.sleepDebt), let snapshot = state.days[day]?.snapshot,
              snapshot.status != "no_data", snapshot.supported.contains(.sleepDebt),
              snapshot.capabilities?.contains("sleep_ledger") == true else { return nil }
        return snapshot.details?.sleepLedger
    }

    static func sleepTypical(_ metric: ServerScoreMetric, day: String, state: ServerScoreViewState) -> Double? {
        guard state.owns(metric), let snapshot = state.days[day]?.snapshot,
              snapshot.status != "no_data", snapshot.supported.contains(metric),
              snapshot.capabilities?.contains("sleep_typicals") == true,
              let typicals = snapshot.details?.sleepTypicals,
              typicals.method == "strictly_prior_observed_nights" else { return nil }
        switch metric {
        case .sleepTotal: return typicals.asleepMin
        case .sleepDeep: return typicals.deepMin
        case .sleepREM: return typicals.remMin
        case .sleepLight: return typicals.lightMin
        default: return nil
        }
    }

    static func sleepHeartRatePoints(day: String, state: ServerScoreViewState) -> [ServerScoreChartPoint] {
        guard state.owns(.sleepSessions), let snapshot = state.days[day]?.snapshot,
              snapshot.status != "no_data", snapshot.supported.contains(.sleepSessions) else { return [] }
        return snapshot.sleep.filter { !$0.isNap }.flatMap { session -> [ServerScoreChartPoint] in
            let key = "sleep_hr:" + session.id
            guard snapshot.capabilities?.contains(key) == true,
                  let metadata = snapshot.chartMetadata?[key], metadata.schemaVersion == 1,
                  metadata.sessionId == session.id, metadata.unit == "bpm", metadata.bucketSeconds == 300,
                  metadata.method == "observed_mean_min_max" else { return [] }
            return (snapshot.charts?[key] ?? []).filter {
                $0.start < session.end && ($0.end ?? $0.start + 1) > session.start
            }
        }.sorted { $0.start < $1.start }
    }

    static func sparks(local: [String: [Double]], through day: String, state: ServerScoreViewState) -> [String: [Double]] {
        var result = local
        let keys: [String: ServerScoreMetric] = ["hrv": .hrv, "rhr": .restingHR, "resp_rate": .respiration,
            "sleep_total_min": .sleepTotal, "sleep_deep_min": .sleepDeep, "sleep_rem_min": .sleepREM, "sleep_light_min": .sleepLight,
            "recovery": .recovery, "strain": .strain, "sleep_performance": .sleepPerformance,
            "spo2": .spo2, "skin_temp": .skinTemperatureDeviation, "steps": .steps,
            "energy_kcal": .activeKcal, "active_kcal": .activeKcal]
        for (key, metric) in keys where state.owns(metric) { result[key] = series(metric, through: day, state: state).map(\.value) }
        return result
    }

    static func hrvRmssd(day: String, overlay: ServerScoreDayCache?) -> Double? {
        guard ServerScoringSettings.isEnabled, let daily = overlay?.daily else { return nil }
        return daily.hrvRmssdMs
    }

    static func restingHr(day: String, overlay: ServerScoreDayCache?) -> Int? {
        guard ServerScoringSettings.isEnabled, let daily = overlay?.daily else { return nil }
        return daily.restingHrBpm
    }

    static func sleepTotalMin(day: String, overlay: ServerScoreDayCache?) -> Double? {
        guard ServerScoringSettings.isEnabled, let daily = overlay?.daily else { return nil }
        return daily.sleepTotalMin
    }

    static func sleepStageMin(_ key: String, overlay: ServerScoreDayCache?) -> Double? {
        guard ServerScoringSettings.isEnabled, let daily = overlay?.daily else { return nil }
        switch key {
        case "light": return daily.sleepLightMin
        case "deep": return daily.sleepDeepMin
        case "rem": return daily.sleepRemMin
        case "awake": return daily.sleepAwakeMin
        default: return nil
        }
    }

    static func staleNote(overlay: ServerScoreDayCache?) -> String? {
        guard ServerScoringSettings.isEnabled, let overlay else { return nil }
        guard overlay.stale || overlay.daily == nil else { return nil }
        if let computed = overlay.computedAt {
            return String(localized: "Server score from \(computed)")
        }
        return String(localized: "Waiting for server score")
    }
}
