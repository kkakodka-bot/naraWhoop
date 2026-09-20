import Foundation

/// No HealthKit calls or local physiology. A committed server day is a replacement, including nulls.
struct ServerHealthWritebackPlan {
    let snapshot: ServerScoreSnapshot
    let replacedVitals: Set<ServerScoreMetric>
    let replacesSleep: Bool

    static func days(state: ServerScoreViewState, from: String, through: String) -> [Self] {
        let healthMetrics: Set<ServerScoreMetric> = [.restingHR, .sdnn, .respiration]
        return state.days.keys.sorted().filter { $0 >= from && $0 <= through }.compactMap { day in
            guard let snapshot = state.days[day]?.snapshot else { return nil }
            return Self(snapshot: snapshot,
                        replacedVitals: Set(healthMetrics.filter { state.owns($0) }),
                        replacesSleep: state.owns(.sleepSessions))
        }
    }
}
