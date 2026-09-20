import Foundation

/// Scalar presentation arithmetic shared with the existing sleep and stress wrappers.
/// Selection, freshness, import precedence and calendar conversion remain with callers.
public enum DailyPresentationMath {
    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public static func populationSD(_ values: [Double], mean: Double?) -> Double {
        guard let mean, values.count > 1 else { return 0 }
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        return variance.squareRoot()
    }

    public static func dailyStressRaw(
        rhrToday: Double?, meanRHR: Double?, sdRHR: Double,
        hrvToday: Double?, meanHRV: Double?, sdHRV: Double
    ) -> Double {
        var sum = 0.0
        if let r = rhrToday, let m = meanRHR, sdRHR > 0.0001 {
            sum += (r - m) / sdRHR
        }
        if let h = hrvToday, let m = meanHRV, sdHRV > 0.0001 {
            sum += (m - h) / sdHRV
        }
        return sum
    }

    public static func dailyStressSquash(_ raw: Double) -> Double {
        let score = 3.0 / (1.0 + exp(-raw))
        return min(max(score, 0), 3)
    }

    public static func positiveMean(_ values: [Double?]) -> Double? {
        mean(values.compactMap { $0 }.filter { $0 > 0 })
    }

    public static func descriptiveSleepNeed(observedMinutes: [Double?]) -> Double {
        Swift.max(450, positiveMean(observedMinutes) ?? 450)
    }

    /// Input is local hour*60+minute, before the original noon wrap, in observation order.
    public static func bedtimeConsistencySeries(localBedMinutes: [Double]) -> [Double] {
        let minutes = localBedMinutes.map { value -> Double in
            var minute = value
            if minute < 12 * 60 { minute += 24 * 60 }
            return minute
        }
        guard minutes.count >= 3 else { return [] }
        var scores: [Double] = []
        for i in minutes.indices {
            let lo = Swift.max(0, i - 13)
            let window = Array(minutes[lo...i])
            guard window.count >= 3 else { continue }
            let mean = window.reduce(0, +) / Double(window.count)
            let variance = window.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(window.count)
            let sd = variance.squareRoot()
            scores.append(Swift.max(0, Swift.min(100, 100 * (1 - sd / 120))))
        }
        return scores
    }

    public static func efficiencyPercent(_ efficiency: Double?) -> Double? {
        guard let efficiency else { return nil }
        return efficiency <= 1.0 ? efficiency * 100 : efficiency
    }

    public static func hoursVsNeededPercent(asleepMin: Double?, needMin: Double) -> Double? {
        guard let asleepMin, asleepMin > 0 else { return nil }
        guard needMin > 0 else { return nil }
        return asleepMin / needMin * 100
    }

    public static func restorativeMinutes(deepMin: Double?, remMin: Double?) -> Double? {
        guard let deepMin, let remMin else { return nil }
        return deepMin + remMin
    }

    public static func restorativePercent(deepMin: Double?, remMin: Double?, asleepMin: Double?) -> Double? {
        guard let deepMin, let remMin, let asleepMin, asleepMin > 0 else { return nil }
        return (deepMin + remMin) / asleepMin * 100
    }
}
