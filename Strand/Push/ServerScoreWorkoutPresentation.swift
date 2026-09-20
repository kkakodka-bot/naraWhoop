import Foundation
import WhoopStore
#if !SERVER_SCORE_NATIVE_TESTS
import StrandAnalytics
#endif

enum ServerScoreWorkoutPresentation {
    enum Unavailable: Equatable {
        case missingIdentity, missingSnapshot, unsupportedResult, missingDetails, missingSession, invalidIdentity
    }
    enum Selection<Value: Equatable>: Equatable {
        case local
        case unavailable(Unavailable)
        case server(Value)
    }
    struct Provenance: Equatable, Sendable {
        let generation: UUID
        let userID: String
        let sourceDeviceID: String
        let day: String
        let timeZoneID: String
        let algorithmVersion: String
        let inputRevision: Int64
        let resultRevision: Int64
    }
    struct DisplayZones: Equatable, Sendable {
        let minutes: [Double]
        let source: String
        let lowerBoundsBPM: [Double]
    }
    struct StrapSteps: Equatable, Sendable {
        let count: Int
        let counterTicks: Int?
        let ticksPerStep: Double?
        let method: String
    }
    struct Projection: Equatable {
        let workout: ServerScoreWorkout
        let provenance: Provenance

        // A legacy row is only a scalar adapter, not identity. Never pass it through source-based local reloads.
        var row: WorkoutRow {
            WorkoutRow(startTs: Int(workout.start), endTs: Int(workout.end), sport: workout.sport,
                source: "server_scoring", durationS: workout.durationS, energyKcal: workout.energyKcal,
                avgHr: workout.avgHr.map { Int($0.rounded()) }, maxHr: workout.peakHr, strain: workout.strain,
                distanceM: workout.distanceM, zonesJSON: nil, notes: nil, steps: workout.steps)
        }

        var displayZones: DisplayZones? {
            guard let seconds = workout.displayZoneSeconds,
                  ["tanaka", "manual", "custom"].contains(workout.displayZoneSource) else { return nil }
            return .init(minutes: seconds.map { $0 / 60 }, source: workout.displayZoneSource,
                         lowerBoundsBPM: workout.displayZoneLowerBounds)
        }

        var heartRateRecovery: HeartRateRecovery.Result? {
            guard let recovery = workout.heartRateRecovery, recovery.unit == "bpm_drop" else { return nil }
            let result = HeartRateRecovery.Result(endHR: recovery.endHr, after1Minute: recovery.after1Minute,
                after2Minutes: recovery.after2Minutes, after5Minutes: recovery.after5Minutes)
            return result.hasMeasurement ? result : nil
        }

        var strapSteps: StrapSteps? {
            guard let count = workout.strapSteps,
                  workout.strapStepsMethod == "session_inclusive_activity_class_counter",
                  ["running", "walking", "hiking", "treadmill run", "treadmill walk"]
                    .contains(workout.sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else { return nil }
            return .init(count: count, counterTicks: workout.stepCounterTicks, ticksPerStep: workout.stepTicksPerStep,
                         method: "session_inclusive_activity_class_counter")
        }

        /// Separate chart runs preserve omitted minute buckets, without recomputing or filling gaps.
        var heartRateRuns: [[HRBucket]] {
            var runs: [[HRBucket]] = []
            var current: [HRBucket] = []
            var previousEnd: Int64?
            for bucket in workout.hrBuckets {
                if let previousEnd, bucket.start > previousEnd, !current.isEmpty {
                    runs.append(current); current = []
                }
                current.append(HRBucket(ts: Int(bucket.start), bpm: bucket.value))
                previousEnd = bucket.end
            }
            if !current.isEmpty { runs.append(current) }
            return runs
        }
    }

    /// `.local` is the only branch that authorizes a caller's local data/producer path.
    /// A completed empty set is distinct from missing detail; neither restores local sessions.
    static func day(_ day: String, state: ServerScoreViewState) -> Selection<[Projection]> {
        guard state.owns(.workouts) else { return .local }
        guard let generation = state.generation else { return .unavailable(.missingIdentity) }
        guard let snapshot = state.days[day]?.snapshot else { return .unavailable(.missingSnapshot) }
        guard snapshot.supported.contains(.workouts) else { return .unavailable(.unsupportedResult) }
        if snapshot.status == "no_data" { return .server([]) }
        guard let workouts = snapshot.details?.workouts else { return .unavailable(.missingDetails) }
        let provenance = Provenance(generation: generation, userID: snapshot.userId,
            sourceDeviceID: snapshot.sourceDeviceId, day: snapshot.day, timeZoneID: snapshot.timezone,
            algorithmVersion: snapshot.algorithmVersion, inputRevision: snapshot.inputRevision,
            resultRevision: snapshot.resultRevision)
        return .server(workouts.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            .map { Projection(workout: $0, provenance: provenance) })
    }

    /// Identity is the server UUID, never the legacy (start,sport) key or nearest overlapping event.
    static func session(id: String, day: String, state: ServerScoreViewState) -> Selection<Projection> {
        guard state.owns(.workouts) else { return .local }
        guard id.utf8.count == 36, let uuid = UUID(uuidString: id) else { return .unavailable(.invalidIdentity) }
        switch self.day(day, state: state) {
        case .local: return .local
        case .unavailable(let reason): return .unavailable(reason)
        case .server(let rows):
            guard let row = rows.first(where: { $0.workout.id.lowercased() == uuid.uuidString.lowercased() }) else {
                return .unavailable(.missingSession)
            }
            return .server(row)
        }
    }
}
