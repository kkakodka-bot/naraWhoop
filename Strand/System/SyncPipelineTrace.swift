import Foundation
import os

/// Instruments intervals contain only stage names and generated signpost IDs.
enum SyncPipelineTrace {
    enum Stage: String, CaseIterable {
        case discovery, connection, bleDecode, chunkPersistence, ackWait
        case receive, localCommit, cloudAcknowledgement, projectionReady, displayFreshness
        case uploadPreparation, uploadScheduling, uploadReceipt, ordinaryTransfer
        case cacheLoad, scoreRefresh, snapshotPublication, cachedContentReady, firstUsableFrame, interaction

        fileprivate var name: StaticString {
            switch self {
            case .discovery: return "Discovery"
            case .receive: return "Receive"
            case .localCommit: return "LocalCommit"
            case .cloudAcknowledgement: return "CloudAcknowledgement"
            case .projectionReady: return "ProjectionReady"
            case .displayFreshness: return "DisplayFreshness"
            case .connection: return "Connection"
            case .bleDecode: return "BLEDecode"
            case .chunkPersistence: return "ChunkPersistence"
            case .ackWait: return "ACKWait"
            case .uploadPreparation: return "UploadPreparation"
            case .uploadScheduling: return "UploadScheduling"
            case .uploadReceipt: return "UploadReceipt"
            case .ordinaryTransfer: return "OrdinaryTransfer"
            case .cacheLoad: return "CacheLoad"
            case .scoreRefresh: return "ScoreRefresh"
            case .snapshotPublication: return "SnapshotPublication"
            case .cachedContentReady: return "CachedContentReady"
            case .firstUsableFrame: return "FirstUsableFrame"
            case .interaction: return "Interaction"
            }
        }
    }

    enum Outcome: String, CaseIterable {
        case succeeded, failed, cancelled, pending, offline, authenticationRequired
        case waitingForWiFi, waitingForOS, waitingForServer, storageFull, stale
        case timedOut
    }

    struct Interval {
        fileprivate let stage: Stage
        fileprivate let id: OSSignpostID
        let correlation: UUID
        fileprivate let measurement: UUID?
    }

    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.frwhoop.sync",
        category: "ProductionSync"
    )
    private static let measurements = SyncIntervalMetrics()

    /// Only these named application intervals are measured. This is not BLE-to-cloud or rendered
    /// display latency: those require matched boundary traces and physical installation evidence.
    static func diagnosticSnapshot() -> [String: Any] { measurements.snapshot() }

    static func begin(_ stage: Stage, correlation: UUID = UUID()) -> Interval {
        let interval = Interval(stage: stage, id: OSSignpostID(log: log), correlation: correlation,
            measurement: measurements.begin(stage))
        os_signpost(.begin, log: log, name: stage.name, signpostID: interval.id,
                    "correlation=%{public}@", correlation.uuidString)
        return interval
    }

    static func end(_ interval: Interval, outcome: Outcome = .succeeded) {
        measurements.end(interval.measurement, outcome: outcome)
        os_signpost(.end, log: log, name: interval.stage.name, signpostID: interval.id,
                    "correlation=%{public}@ outcome=%{public}@", interval.correlation.uuidString, outcome.rawValue)
    }

    static func event(_ stage: Stage, outcome: Outcome = .succeeded, correlation: UUID = UUID()) {
        os_signpost(.event, log: log, name: stage.name,
                    "correlation=%{public}@ outcome=%{public}@", correlation.uuidString, outcome.rawValue)
    }

    /// Timestamp of the source represented by a stage, independent of the event's own timestamp.
    /// A missing source timestamp remains unknown, not fresh. Contains no signal values or identifiers.
    static func freshness(_ stage: Stage, sourceDate: Date?) {
        os_signpost(.event, log: log, name: stage.name,
                    "sourceUnixSeconds=%{public}.3f", sourceDate?.timeIntervalSince1970 ?? -1)
    }

    static func sourceDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// Fixed stage/outcome keys and histogram bounds keep memory independent of notification volume.
/// No owner, source, device, packet, URL or physiological value enters this accumulator.
final class SyncIntervalMetrics: @unchecked Sendable {
    private struct Active { let stage: SyncPipelineTrace.Stage; let start: TimeInterval }
    private struct Counts {
        var started = 0, completed = 0, untracked = 0, invalidClock = 0
        var outcomes: [SyncPipelineTrace.Outcome: Int] = [:]
        var histogram = Array(repeating: 0, count: bounds.count + 1)
        var maximum: Double = 0
    }
    private static let bounds: [Double] = [0.125, 0.25, 0.5, 1, 2, 4, 8, 16, 32, 64, 125,
        200, 250, 500, 750, 1_000, 2_000, 3_000, 5_000, 10_000, 30_000, 60_000,
        300_000, 3_600_000, 14_400_000, 86_400_000]
    private let lock = NSLock()
    private let clock: () -> TimeInterval
    private let firstUptime: TimeInterval
    private let firstWallTime: TimeInterval
    private let generation = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "_")
    private let maximumActive: Int
    private var active: [UUID: Active] = [:]
    private var counts: [SyncPipelineTrace.Stage: Counts] = [:]
    private var unmatchedCompletions = 0
    private var saturated = false

    init(maximumActive: Int = 512, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.maximumActive = max(0, min(512, maximumActive))
        self.clock = clock
        firstUptime = clock()
        firstWallTime = Date().timeIntervalSince1970
    }

    private func increment(_ value: Int) -> Int {
        guard value < Int.max else { saturated = true; return value }
        return value + 1
    }

    func begin(_ stage: SyncPipelineTrace.Stage) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        var count = counts[stage, default: Counts()]
        count.started = increment(count.started)
        guard active.count < maximumActive else {
            count.untracked = increment(count.untracked); counts[stage] = count
            return nil
        }
        let id = UUID()
        active[id] = Active(stage: stage, start: clock())
        counts[stage] = count
        return id
    }

    func end(_ id: UUID?, outcome: SyncPipelineTrace.Outcome) {
        guard let id else { return }
        lock.lock(); defer { lock.unlock() }
        guard let value = active.removeValue(forKey: id) else {
            unmatchedCompletions = increment(unmatchedCompletions); return
        }
        var count = counts[value.stage, default: Counts()]
        count.completed = increment(count.completed)
        count.outcomes[outcome] = increment(count.outcomes[outcome, default: 0])
        let elapsed = (clock() - value.start) * 1_000
        if elapsed.isFinite && elapsed >= 0 {
            let bucket = Self.bounds.firstIndex { elapsed <= $0 } ?? Self.bounds.count
            count.histogram[bucket] = increment(count.histogram[bucket])
            count.maximum = max(count.maximum, elapsed)
        } else { count.invalidClock = increment(count.invalidClock) }
        counts[value.stage] = count
    }

    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        func elapsed(since start: TimeInterval) -> Double? {
            let duration = (now - start) * 1_000
            return start.isFinite && now.isFinite && duration.isFinite && duration >= 0 ? duration : nil
        }
        var stages: [String: Any] = [:]
        for stage in SyncPipelineTrace.Stage.allCases {
            let count = counts[stage, default: Counts()]
            let unfinished = active.values.filter { $0.stage == stage }
            let durationCount = count.histogram.reduce(0.0) { $0 + Double($1) }
            let unfinishedDurations = unfinished.compactMap { elapsed(since: $0.start) }
            func quantile(_ fraction: Double) -> Any {
                guard durationCount > 0 else { return NSNull() }
                let rank = max(1, ceil(durationCount * fraction))
                var total: Double = 0
                for (index, value) in count.histogram.enumerated() {
                    total += Double(value)
                    if total >= rank {
                        return ["lower_ms": index == 0 ? 0 : Self.bounds[index - 1],
                            "upper_ms": index < Self.bounds.count ? Self.bounds[index] : count.maximum]
                    }
                }
                return NSNull()
            }
            let outcomes = Dictionary(uniqueKeysWithValues: SyncPipelineTrace.Outcome.allCases.map {
                ($0.rawValue, count.outcomes[$0, default: 0])
            })
            stages[stage.rawValue] = [
                "started_count": count.started, "completed_count": count.completed,
                "unfinished_count": unfinished.count, "untracked_start_count": count.untracked,
                "invalid_clock_count": count.invalidClock, "outcomes": outcomes,
                "duration_sample_count": durationCount,
                "p50_bounds": quantile(0.5), "p95_bounds": quantile(0.95), "p99_bounds": quantile(0.99),
                "maximum_completed_ms": durationCount > 0 ? count.maximum as Any : NSNull(),
                "oldest_unfinished_ms": unfinishedDurations.count == unfinished.count
                    ? unfinishedDurations.max() as Any? ?? NSNull() : NSNull(),
                "unfinished_invalid_clock_count": unfinished.count - unfinishedDurations.count,
                "duration_population": "valid_clock_completed_intervals_including_failures",
            ]
        }
        return ["schema_version": 1, "process_generation": generation,
            "coverage": "current_process_application_intervals", "previous_process_coverage": "NOT_MEASURED",
            "end_to_end_latency": "matched_boundary_trace_required", "quantiles": "histogram_bounds_not_exact_percentiles",
            "events": "excluded_from_interval_counts",
            "first_observed_at_unix_ms": firstWallTime * 1_000,
            "observation_elapsed_ms": elapsed(since: firstUptime) as Any? ?? NSNull(),
            "observation_clock_valid": elapsed(since: firstUptime) != nil,
            "unmatched_completion_count": unmatchedCompletions, "counter_saturated": saturated,
            "stages": stages]
    }
}
