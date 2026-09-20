import Foundation
import WhoopStore
import StrandDesign
import StrandAnalytics

/// Converts a bounded immutable snapshot to existing render models. No sleep detection or debt scoring.
extension ServerScoreSleepPresentation {
    static func model(day: String, state: ServerScoreViewState, local: SleepModel?) -> SleepModel? {
        if !state.owns(.sleepSessions) { return local.map { applyingMetrics(to: $0, day: day, state: state) } }
        guard let snapshot = ServerScoreDisplay.detailSnapshot(.sleepSessions, day: day, state: state),
              let anchor = snapshot.sleep.first else { return nil }
        let zone = TimeZone(identifier: snapshot.timezone) ?? .current
        let local = local.flatMap {
            ServerScoreDate.day(Date(timeIntervalSince1970: Double($0.night.session.endTs)), timeZone: zone) == day ? $0 : nil
        }
        let main = snapshot.sleep.filter { !$0.isNap }.sorted { $0.start < $1.start }
        let start = main.first?.start ?? anchor.start
        let end = main.last?.end ?? anchor.end
        let segments = main.flatMap(\.stages).sorted { $0.start < $1.start }
        func minutes(_ names: Set<String>) -> Double {
            segments.filter { names.contains($0.stage) }.reduce(0) { $0 + Double($1.end - $1.start) / 60 }
        }
        // Daily totals can include naps; the main-night stage card must match its own timeline.
        let stages = Stages(awake: minutes(["wake", "awake"]), light: minutes(["light"]),
                            deep: minutes(["deep"]), rem: minutes(["rem"]))
        let intervals = segments.compactMap { value -> SleepInterval? in
            let stage: SleepStage
            switch value.stage {
            case "wake", "awake": stage = .awake
            case "light": stage = .light
            case "deep": stage = .deep
            case "rem": stage = .rem
            default: return nil
            }
            return SleepInterval(stage: stage, start: Double(value.start) - Double(start), end: Double(value.end) - Double(start))
        }
        let diagnostics = ServerScoreDisplay.sleepDiagnostics(day: day, state: state)
        var night = Night(session: CachedSleepSession(startTs: start, endTs: end,
            efficiency: ServerScoreDisplay.efficiencyFraction(snapshot), restingHr: snapshot.value(.restingHR).map { Int($0.rounded()) },
            avgHrv: snapshot.value(.hrv), stagesJSON: nil), stages: stages,
            realSegments: intervals, sourceBlocks: snapshot.sleep.map { value in
                session(value, diagnostics: diagnostics.first { $0.id == value.id })
            })
        night.serverSessionIDs = snapshot.sleep.map(\.id)
        night.serverMainGroupStarts = Set(main.map(\.start))
        night.serverMotion = diagnostics.filter { !$0.isNap }.compactMap(\.motion).filter {
            $0.unit == "gravity_delta_sum" && $0.method == "existing_stager_epoch_motion_observed_mask"
        }
        let empty: SleepModel.Metric = (nil, nil, [])
        // Unmigrated fields keep their local producer. Do not derive replacements from partial results.
        var model = SleepModel(night: night, intervals: intervals, isPersistedHypnogram: !intervals.isEmpty,
            isStubNight: main.isEmpty || intervals.isEmpty,
            performance: local?.performance ?? empty, efficiency: local?.efficiency ?? empty,
            consistency: local?.consistency ?? empty, hoursVsNeeded: local?.hoursVsNeeded ?? empty,
            restorative: local?.restorative ?? empty, respiratory: local?.respiratory ?? empty,
            sleepDebt: local?.sleepDebt ?? empty, typicalTotalMin: local?.typicalTotalMin, typicalDeepMin: local?.typicalDeepMin,
            typicalRemMin: local?.typicalRemMin, typicalLightMin: local?.typicalLightMin, trendPoints: local?.trendPoints ?? [],
            sleepDebtLedger: state.owns(.sleepDebt) ? SleepDebtLedger(balanceMin: 0, nights: [], needMin: 0)
                : (local?.sleepDebtLedger ?? SleepDebtLedger(balanceMin: 0, nights: [], needMin: 0)))
        model.debtLedgerUnavailable = state.owns(.sleepDebt) || local == nil
        return applyingMetrics(to: model, day: day, state: state)
    }

    private static func applyingMetrics(to model: SleepModel, day: String, state: ServerScoreViewState) -> SleepModel {
        func metric(_ key: ServerScoreMetric, _ local: SleepModel.Metric) -> SleepModel.Metric {
            guard state.owns(key) else { return local }
            let snapshot = state.days[day]?.snapshot
            let value = snapshot?.value(key).map { value in
                ServerScoreDisplay.seriesValue(key, value: value, unit: snapshot?.metrics?[key.rawValue]?.unit)
            }
            return (value, nil, ServerScoreDisplay.series(key, through: day, state: state).map(\.value))
        }
        let serverLedger = ServerScoreDisplay.sleepLedger(day: day, state: state).map {
            SleepDebtLedger(balanceMin: $0.balanceMin,
                nights: $0.nights.map { SleepDebtNight(day: $0.day, sleptMin: $0.sleptMin, deltaMin: $0.deltaMin) },
                needMin: $0.needMin)
        }
        var result = SleepModel(night: model.night, intervals: model.intervals,
            isPersistedHypnogram: model.isPersistedHypnogram, isStubNight: model.isStubNight,
            performance: metric(.sleepPerformance, model.performance), efficiency: metric(.sleepEfficiency, model.efficiency),
            consistency: metric(.sleepConsistency, model.consistency), hoursVsNeeded: metric(.hoursVsNeeded, model.hoursVsNeeded),
            restorative: metric(.restorativePercent, model.restorative), respiratory: metric(.respiration, model.respiratory),
            sleepDebt: metric(.sleepDebt, model.sleepDebt),
            typicalTotalMin: state.owns(.sleepTotal) ? ServerScoreDisplay.sleepTypical(.sleepTotal, day: day, state: state) : model.typicalTotalMin,
            typicalDeepMin: state.owns(.sleepDeep) ? ServerScoreDisplay.sleepTypical(.sleepDeep, day: day, state: state) : model.typicalDeepMin,
            typicalRemMin: state.owns(.sleepREM) ? ServerScoreDisplay.sleepTypical(.sleepREM, day: day, state: state) : model.typicalRemMin,
            typicalLightMin: state.owns(.sleepLight) ? ServerScoreDisplay.sleepTypical(.sleepLight, day: day, state: state) : model.typicalLightMin,
            trendPoints: state.owns(.sleepTotal) ? durationTrend(day: day, state: state) : model.trendPoints,
            sleepDebtLedger: state.owns(.sleepDebt)
                ? (serverLedger ?? SleepDebtLedger(balanceMin: 0, nights: [], needMin: 0)) : model.sleepDebtLedger)
        result.debtLedgerUnavailable = state.owns(.sleepDebt) ? serverLedger == nil : model.debtLedgerUnavailable
        return result
    }

    private static func durationTrend(day: String, state: ServerScoreViewState) -> [TrendPoint] {
        ServerScoreDisplay.series(.sleepTotal, through: day, state: state).compactMap { item in
            let pieces = item.day.split(separator: "-").compactMap { Int($0) }
            guard pieces.count == 3 else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: state.timezone) ?? TimeZone(secondsFromGMT: 0)!
            guard let date = calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2], hour: 12)) else { return nil }
            return TrendPoint(date: date, value: item.value / 60, segment: "server")
        }
    }

    static func heartRate(day: String, state: ServerScoreViewState) -> [HRBucket] {
        ServerScoreDisplay.sleepHeartRatePoints(day: day, state: state).compactMap { point in
            guard let value = point.value, value.isFinite, value > 0 else { return nil }
            return HRBucket(ts: Int(point.start), bpm: value)
        }
    }
}
