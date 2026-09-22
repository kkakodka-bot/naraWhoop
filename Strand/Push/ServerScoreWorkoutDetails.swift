import Foundation

/// WorkoutResultOrchestrator's source-local replacement set. Notes and routes are not wire members.
struct ServerScoreWorkout: Codable, Equatable, Sendable {
    struct HeartRateRecovery: Codable, Equatable, Sendable {
        let endHr: Int
        let after1Minute: Int?
        let after2Minutes: Int?
        let after5Minutes: Int?
        let unit: String
    }

    struct HeartRateBucket: Codable, Equatable, Sendable {
        let start: Int64
        let end: Int64
        let value: Double
        let min: Int
        let max: Int
        let count: Int
    }

    let id: String
    let start: Int64
    let end: Int64
    let durationS: Double
    let sport: String
    let manual: Bool
    let avgHr: Double?
    let peakHr: Int?
    let strain: Double?
    let energyKcal: Double?
    let energyKJ: Double?
    let energyMethod: String
    let editEntity: String?
    let originalStart: Int64?
    let originalSport: String?
    let inputKind: String?
    let inputSource: String?
    let distanceM: Double?
    let steps: Int?
    let hrCoveragePct: Double?
    let zoneSeconds: [Double]?
    let zoneMethod: String?
    let zoneTimePct: [String: Double]?
    let avgHrrPct: Double?
    let hrmax: Double?
    let hrmaxSource: String?
    let heartRateRecovery: HeartRateRecovery?
    let hrBuckets: [HeartRateBucket]
    let displayZoneSeconds: [Double]?
    let displayZoneSource: String
    let displayZoneLowerBounds: [Double]
    // Added after the first schema-2 extension; absent remains unknown, not zero or imported steps.
    let strapSteps: Int?
    let stepCounterTicks: Int?
    let strapStepsMethod: String?
    let stepTicksPerStep: Double?

    func validate() throws {
        guard id.utf8.count == 36, UUID(uuidString: id) != nil,
              start > 0, end > start, end <= 253402300799, end - start <= 7 * 86400,
              durationS == Double(end - start), !sport.isEmpty, sport.count <= 128,
              hrBuckets.count <= 10080 else { throw ServerScoreDecodeError.invalid }
        try ServerScoreEvidenceLimit.check(
            numbers: [avgHr, strain, energyKcal, energyKJ, distanceM, hrCoveragePct, avgHrrPct, hrmax, stepTicksPerStep],
            strings: [sport, energyMethod, editEntity, originalSport, inputKind, inputSource,
                      zoneMethod, hrmaxSource, displayZoneSource, strapStepsMethod])
        guard [energyKcal, energyKJ, distanceM].compactMap({ $0 }).allSatisfy({ $0 >= 0 }),
              avgHr.map({ (20...250).contains($0) }) ?? true,
              peakHr.map({ (20...250).contains($0) }) ?? true,
              strain.map({ (0...100).contains($0) }) ?? true,
              hrCoveragePct.map({ (0...100).contains($0) }) ?? true,
              hrmax.map({ $0 > 0 }) ?? true,
              stepTicksPerStep.map({ $0 >= 0.5 }) ?? true,
              [steps, stepCounterTicks].compactMap({ $0 }).allSatisfy({ (0...Int(Int32.max)).contains($0) }),
              strapSteps.map({ (1...Int(Int32.max)).contains($0) }) ?? true else { throw ServerScoreDecodeError.invalid }

        // Computed events have no edit anchor. Journal/upload rows carry all five identity/source fields.
        let anchored = editEntity != nil || originalStart != nil || originalSport != nil || inputKind != nil || inputSource != nil
        if anchored {
            guard editEntity == "workout:" + id.lowercased(), let originalStart,
                  originalStart > 0, originalStart <= 253402300799,
                  let originalSport, !originalSport.isEmpty, originalSport.count <= 128,
                  let inputKind, !inputKind.isEmpty, let inputSource, !inputSource.isEmpty else {
                throw ServerScoreDecodeError.invalid
            }
        } else if manual { throw ServerScoreDecodeError.invalid }
        if inputKind == "manual_workout_journal", !manual { throw ServerScoreDecodeError.invalid }

        func validateSeconds(_ values: [Double]?) throws {
            guard let values else { return }
            try ServerScoreEvidenceLimit.check(numbers: values.map(Optional.some))
            // Median-interval tail accounting can exceed the workout bound; do not renormalize it.
            guard values.count == 5, values.allSatisfy({ $0 >= 0 }) else { throw ServerScoreDecodeError.invalid }
        }
        try validateSeconds(zoneSeconds)
        try validateSeconds(displayZoneSeconds)
        try ServerScoreEvidenceLimit.check(numbers: displayZoneLowerBounds.map(Optional.some))
        guard displayZoneLowerBounds.count == 5, displayZoneLowerBounds.allSatisfy({ $0 > 0 }),
              zip(displayZoneLowerBounds, displayZoneLowerBounds.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw ServerScoreDecodeError.invalid
        }
        if let percentages = zoneTimePct {
            guard percentages.count <= 6, Set(percentages.keys).isSubset(of: Set((0...5).map(String.init))),
                  percentages.values.allSatisfy({ $0.isFinite && (0...100).contains($0) }) else {
                throw ServerScoreDecodeError.invalid
            }
        }
        if let recovery = heartRateRecovery {
            try ServerScoreEvidenceLimit.check(strings: [recovery.unit])
            guard (20...250).contains(recovery.endHr),
                  [recovery.after1Minute, recovery.after2Minutes, recovery.after5Minutes].compactMap({ $0 })
                    .allSatisfy({ (-250...250).contains($0) }) else { throw ServerScoreDecodeError.invalid }
        }
        var previousEnd = start
        for bucket in hrBuckets {
            guard bucket.start >= previousEnd, bucket.end > bucket.start, bucket.end <= end,
                  bucket.end - bucket.start <= 60, (bucket.start - start).isMultiple(of: 60),
                  bucket.value.isFinite, (20...250).contains(bucket.min), (20...250).contains(bucket.max),
                  Double(bucket.min) <= bucket.value, bucket.value <= Double(bucket.max),
                  (1...Int(Int32.max)).contains(bucket.count) else { throw ServerScoreDecodeError.invalid }
            previousEnd = bucket.end
        }
    }

    static func validateSet(_ workouts: [Self]) throws {
        guard workouts.count <= 1024, Set(workouts.map { $0.id.lowercased() }).count == workouts.count else {
            throw ServerScoreDecodeError.invalid
        }
        for workout in workouts { try workout.validate() }
    }
}
