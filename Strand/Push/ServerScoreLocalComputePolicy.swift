import Foundation

/// Captured per-field ownership for local presentation builders. An unavailable owned result still
/// suppresses that producer; partial capability never suppresses unrelated local outputs.
struct ServerScoreLocalComputePolicy: Equatable, Sendable {
    let owned: Set<ServerScoreMetric>

    init(state: ServerScoreViewState = .empty) {
        owned = Set(ServerScoreMetric.allCases.filter(state.owns))
    }

    /// Unoverlaid blocks are inputs only for outputs still owned locally, never a missing-result refill.
    var requiresLocalSleepModel: Bool {
        let outputs: Set<ServerScoreMetric> = [.sleepSessions, .sleepPerformance, .sleepEfficiency,
            .sleepConsistency, .hoursVsNeeded, .restorativePercent, .respiration, .sleepDebt,
            .sleepTotal, .sleepDeep, .sleepREM, .sleepLight]
        return !outputs.isSubset(of: owned)
    }
    var requiresLocalSleepMotion: Bool { !owned.contains(.sleepSessions) }

    func value<Value>(for metric: ServerScoreMetric, suppressed: @autoclosure () -> Value,
                      local: @autoclosure () -> Value) -> Value {
        owned.contains(metric) ? suppressed() : local()
    }
}
