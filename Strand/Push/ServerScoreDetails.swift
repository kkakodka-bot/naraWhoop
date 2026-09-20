import Foundation

/// Optional evidence for existing sleep consumers. Presence alone never grants ownership.
struct ServerScoreDetails: Codable, Equatable, Sendable {
    let sleepLedger: ServerScoreSleepLedger?
    let sleepTypicals: ServerScoreSleepTypicals?
    let baselines: [String: ServerScoreBaseline]?
    let charge: ServerScoreCharge?
    let readiness: ServerScoreReadiness?
    let effort: ServerScoreEffort?
    let rest: ServerScoreRest?
    let sleepSessions: [ServerScoreSleepDiagnostics]?
    let contextPolicy: String?
    let illness: ServerScoreIllness?
    let cycle: ServerScoreCycle?
    let circadian: ServerScoreCircadian?
    let daytimeStress: ServerScoreDaytimeStress?
    let frequencyHrv: ServerScoreFrequencyHRV?
    let workouts: [ServerScoreWorkout]?

    enum CodingKeys: String, CodingKey {
        case sleepLedger = "sleep_ledger", sleepTypicals = "sleep_typicals"
        case baselines, charge, readiness, effort, rest
        case sleepSessions = "sleep_sessions"
        case contextPolicy, illness, cycle, circadian, daytimeStress, frequencyHrv
        case workouts
    }

    func validate(day: String, sleep: [ServerScoreSleep]) throws {
        try sleepLedger?.validate(day: day)
        try sleepTypicals?.validate()
        guard (baselines?.count ?? 0) <= 64, (sleepSessions?.count ?? 0) <= 128 else { throw ServerScoreDecodeError.invalid }
        for (key, value) in baselines ?? [:] { try ServerScoreEvidenceLimit.check(strings: [key]); try value.validate() }
        try charge?.validate()
        try readiness?.validate()
        try ServerScoreEvidenceLimit.check(strings: [contextPolicy])
        try illness?.validate()
        try cycle?.validate(day: day)
        try circadian?.validate()
        try daytimeStress?.validate()
        try frequencyHrv?.validate()
        if let workouts { try ServerScoreWorkout.validateSet(workouts) }
        try ServerScoreEvidenceLimit.check(strings: [effort?.confidence, effort?.method, rest?.confidence])
        var identities: Set<String> = []
        for value in sleepSessions ?? [] {
            guard identities.insert(value.id).inserted,
                  let session = sleep.first(where: { $0.id == value.id }),
                  value.start == session.start, value.end == session.end, value.isNap == session.isNap,
                  value.editEntity == session.resolvedEditEntity else { throw ServerScoreDecodeError.invalid }
            try value.validate()
        }
    }
}

struct ServerScoreSleepLedger: Codable, Equatable, Sendable {
    struct Night: Codable, Equatable, Sendable {
        let day: String
        let sleptMin: Double
        let deltaMin: Double
    }
    let needMin: Double
    let balanceMin: Double
    let nightCount: Int
    let descriptiveNeedMin: Double
    let restDurationConsistency: Double?
    let habitualMidsleepSec: Int?
    let nights: [Night]

    func validate(day: String) throws {
        guard nightCount == nights.count, nights.count <= 14,
              [needMin, descriptiveNeedMin].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 10080 }),
              balanceMin.isFinite, abs(balanceMin) <= Double(Int32.max),
              restDurationConsistency.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
              habitualMidsleepSec.map({ (0..<86400).contains($0) }) ?? true else {
            throw ServerScoreDecodeError.invalid
        }
        var previous = ""
        for night in nights {
            guard ServerScoreDate.isDay(night.day), night.day <= day, night.day > previous,
                  night.sleptMin.isFinite, (0...10080).contains(night.sleptMin),
                  night.deltaMin.isFinite, abs(night.deltaMin) <= 10080 else {
                throw ServerScoreDecodeError.invalid
            }
            previous = night.day
        }
    }
}

struct ServerScoreSleepTypicals: Codable, Equatable, Sendable {
    let method: String
    let asleepMin: Double?
    let deepMin: Double?
    let remMin: Double?
    let lightMin: Double?

    func validate() throws {
        guard method.utf8.count <= 256,
              [asleepMin, deepMin, remMin, lightMin].compactMap({ $0 })
                .allSatisfy({ $0.isFinite && (0...10080).contains($0) }) else {
            throw ServerScoreDecodeError.invalid
        }
    }
}

struct ServerScoreChartMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let unit: String?
    let bucketSeconds: Int?
    let method: String
    let sessionId: String?
    let signal: String?
    let measured: Bool?
    let measuredHrWinsOverlap: Bool?

    func validate() throws {
        guard schemaVersion > 0,
              bucketSeconds.map({ (1...86400).contains($0) }) ?? true,
              [unit, Optional(method), sessionId, signal].compactMap({ $0 })
                .allSatisfy({ $0.utf8.count <= 256 }) else { throw ServerScoreDecodeError.invalid }
    }
}
