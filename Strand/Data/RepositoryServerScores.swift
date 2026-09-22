import Foundation
import WhoopStore

/// Presentation-only mapping. An owned null/pending day remains absent, never a local fallback.
enum RepositoryServerScores {
    static func metric(key: String) -> ServerScoreMetric? {
        let aliases: [String: String] = [
            "hrv": "hrv_rmssd_ms", "rhr": "resting_hr_bpm", "resp_rate": "resp_rate_bpm",
            "sleep_efficiency_pct": "sleep_efficiency", "sdnn": "hrv_sdnn_ms",
            "recovery": "recovery", "strain": "strain", "rest": "sleep_performance",
            "active_kcal": "active_kcal_est", "energy_kcal": "active_kcal_est",
            "skin_temp": "skin_temp_dev_c", "spo2": "spo2_pct", "in_bed_min": "sleep_in_bed_min"
        ]
        return ServerScoreMetric(rawValue: aliases[key] ?? key)
    }

    static func shouldOwn(key: String, source: String, deviceId: String,
                          state: ServerScoreViewState) -> Bool {
        guard ["my-whoop", "my-whoop-noop", deviceId, deviceId + "-noop", "server-snapshot"].contains(source),
              let metric = metric(key: key) else { return false }
        return state.owns(metric)
    }

    static func daily(_ local: [DailyMetric], state: ServerScoreViewState) -> [DailyMetric] {
        guard state.hasServerOwnership else { return local }
        let byDay = Dictionary(local.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        let keys = Set(byDay.keys).union(state.days.keys).union(state.currentDay.isEmpty ? [] : [state.currentDay])
        return keys.sorted().compactMap { ServerScoreDisplay.daily(local: byDay[$0], day: $0, state: state) }
    }

    static func vitals(_ local: [SourcedDailyMetric], state: ServerScoreViewState) -> [SourcedDailyMetric] {
        guard state.hasServerOwnership else { return local }
        // Keep unmigrated fields under their actual source. A separate server-only row prevents a
        // local field in a mixed daily record from being labelled as a server-derived measurement.
        let masked = local.compactMap { row -> SourcedDailyMetric? in
            ServerScoreDisplay.daily(local: row.metric, day: row.metric.day, state: state, carry: true)
                .map { SourcedDailyMetric(metric: $0, source: row.source) }
        }
        let authoritative = daily([], state: state).map { SourcedDailyMetric(metric: $0, source: .serverSnapshot) }
        return masked + authoritative
    }

    static func sleep(state: ServerScoreViewState) -> [CachedSleepSession] {
        var seen: Set<String> = []
        return state.days.keys.sorted().flatMap { state.days[$0]?.snapshot?.sleep ?? [] }
            .filter { seen.insert($0.id).inserted }.map(ServerScoreSleepPresentation.session)
            .sorted { $0.startTs < $1.startTs }
    }

    static func series(key: String, from: String, to: String,
                       state: ServerScoreViewState) -> [(day: String, value: Double)] {
        guard let metric = metric(key: key), state.owns(metric) else { return [] }
        return ServerScoreDisplay.series(metric, through: to, state: state).filter { $0.day >= from }
    }
}

extension Repository {
    func authoritativeSeries(key: String, source: String, days: Int,
                             fullHistory: Bool) -> [(day: String, value: Double)]? {
        guard RepositoryServerScores.shouldOwn(key: key, source: source, deviceId: deviceId,
                                               state: serverPresentation) else { return nil }
        let zone = TimeZone(identifier: serverPresentation.timezone) ?? .current
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let now = Date()
        let from = fullHistory ? "0000-01-01" : ServerScoreDate.day(
            calendar.date(byAdding: .day, value: -days, to: now) ?? now, timeZone: zone)
        let to = fullHistory ? "9999-12-31" : ServerScoreDate.day(now, timeZone: zone)
        return RepositoryServerScores.series(key: key, from: from, to: to, state: serverPresentation)
    }
}
