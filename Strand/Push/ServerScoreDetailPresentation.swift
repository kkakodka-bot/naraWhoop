import Foundation
import StrandAnalytics

/// Formats emitted evidence into existing view models; no baseline folds or scoring calls.
enum ServerScoreDetailPresentation {
    static func charge(day: String, state: ServerScoreViewState) -> (drivers: [ChargeDriver], confidence: ScoreConfidence)? {
        guard let value = ServerScoreDisplay.charge(day: day, state: state),
              let confidence = ScoreConfidence(rawValue: value.confidence) else { return nil }
        let labels = ["heart_rate_variability": "Heart rate variability", "resting_heart_rate": "Resting heart rate",
                      "sleep_quality": "Sleep quality", "respiratory_rate": "Respiratory rate", "skin_temperature": "Skin temperature"]
        let verdicts = ["above_baseline_supporting": "above baseline, supporting recovery",
            "below_baseline_supporting": "below baseline, supporting recovery", "above_baseline_limiting": "above baseline, limiting recovery",
            "below_baseline_limiting": "below baseline, limiting recovery", "at_baseline": "at baseline",
            "hrv_saturation_limiting": "below baseline, limiting recovery, though low resting HR suggests this may be parasympathetic saturation rather than fatigue",
            "strong_night_supporting": "a strong night, supporting recovery", "below_good_night_limiting": "below a good night, limiting recovery",
            "typical_night": "a typical night", "near_baseline": "near baseline",
            "warmer_than_baseline_limiting": "warmer than baseline, limiting recovery",
            "cooler_than_baseline_limiting": "cooler than baseline, limiting recovery"]
        let units: [String: (String, Int)] = ["milliseconds": (" ms", 0), "beats_per_minute": (" bpm", 0),
            "percent": ("%", 0), "breaths_per_minute": (" br/min", 1), "celsius_deviation": (" °C", 1)]
        let drivers = value.drivers.compactMap { d -> ChargeDriver? in
            guard let label = labels[d.key], let verdict = verdicts[d.verdict], let unit = units[d.unit] else { return nil }
            func format(_ n: Double) -> String { String(format: "%.*f", locale: Locale.current, unit.1, n) + unit.0 }
            return ChargeDriver(label: label, deltaPoints: d.deltaPoints, valueText: format(d.value),
                baselineText: d.baseline.map { format($0) + " baseline" } ?? "", verdict: verdict)
        }
        return (drivers, confidence)
    }

    static let unavailableReadiness = ReadinessEngine.Readiness(level: .insufficient, headline: "Readiness",
        summary: "Readiness detail is not available in this server result.", signals: [], acwr: nil, monotony: nil)

    static func readiness(day: String, state: ServerScoreViewState) -> ReadinessEngine.Readiness? {
        guard let snapshot = ServerScoreDisplay.detailSnapshot(.readiness, day: day, state: state),
              let value = snapshot.details?.readiness,
              let level = ReadinessEngine.Level(rawValue: value.level),
              let confidence = ScoreConfidence(rawValue: value.confidence) else { return nil }
        let summaries: [ReadinessEngine.Level: String] = [
            .primed: "Your signals are aligned and your load is supported. A harder session is well backed today.",
            .balanced: "Nothing's flagging. Train to feel - your body's holding steady.",
            .strained: "One of your signals is flagging. You can train, but keep it controlled and bank the recovery.",
            .rundown: "Several signals are down at once. Treat today as recovery - easy movement, real sleep tonight.",
            .insufficient: "A few more nights of data and your readiness read will sharpen."]
        let signals = value.signals.compactMap { s -> ReadinessEngine.Signal? in
            guard ["hrv", "rhr", "respRate", "acwr", "monotony"].contains(s.key),
                  let flag = ReadinessEngine.Flag(rawValue: s.flag) else { return nil }
            var evidence: ReadinessEngine.Evidence?
            if let e = s.evidence {
                switch e.kind {
                case "metric_vs_baseline":
                    if let v = e.value, let baseline = e.baseline, let unit = e.unit, ["ms", "bpm", "rpm"].contains(unit), let decimals = e.decimals {
                        evidence = .metric(value: v, baseline: baseline, unit: unit, decimals: decimals)
                    }
                case "monotony": if let v = e.value { evidence = .monotony(v) }
                case "training_load": if let acute = e.acute, let chronic = e.chronic { evidence = .trainingLoad(acute: acute, chronic: chronic) }
                default: break
                }
            }
            // Existing Today renders localized copy from key/flag and numeric evidence, never wire resource keys.
            return .init(key: s.key, label: s.key, evidenceData: evidence, detail: "", flag: flag)
        }
        return .init(level: level, headline: value.level.capitalized, summary: summaries[level] ?? "",
            signals: signals, acwr: snapshot.value(.acwr), monotony: snapshot.value(.trainingMonotony), confidence: confidence)
    }
}
