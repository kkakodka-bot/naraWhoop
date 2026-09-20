import Foundation

enum ServerScoreEvidenceLimit {
    static func check(numbers: [Double?] = [], strings: [String?] = []) throws {
        guard numbers.compactMap({ $0 }).allSatisfy({ $0.isFinite && abs($0) <= Double(Int32.max) }),
              strings.compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 1024 }) else { throw ServerScoreDecodeError.invalid }
    }
}

struct ServerScoreMotionPoint: Equatable, Sendable {
    let timestamp: Int64
    let value: Double
}

struct ServerScoreBaseline: Codable, Equatable, Sendable {
    let baseline: Double
    let spread: Double
    let nValid: Int
    let nightsSinceUpdate: Int
    let status: String
    let z: Double?
    let delta: Double?
    let ratio: Double?
    let normalLow: Double?
    let normalHigh: Double?
    func validate() throws {
        try ServerScoreEvidenceLimit.check(numbers: [baseline, spread, z, delta, ratio, normalLow, normalHigh], strings: [status])
        guard spread >= 0, nValid >= 0, nightsSinceUpdate >= 0 else { throw ServerScoreDecodeError.invalid }
        if let normalLow, let normalHigh, normalLow > normalHigh { throw ServerScoreDecodeError.invalid }
    }
}

struct ServerScoreCharge: Codable, Equatable, Sendable {
    struct Driver: Codable, Equatable, Sendable {
        let key: String
        let deltaPoints: Int
        let value: Double
        let baseline: Double?
        let unit: String
        let verdict: String
    }
    let confidence: String
    let drivers: [Driver]
    func validate() throws {
        try ServerScoreEvidenceLimit.check(strings: [confidence])
        guard drivers.count <= 32, Set(drivers.map(\.key)).count == drivers.count else { throw ServerScoreDecodeError.invalid }
        for driver in drivers {
            try ServerScoreEvidenceLimit.check(numbers: [driver.value, driver.baseline], strings: [driver.key, driver.unit, driver.verdict])
            guard (-100...100).contains(driver.deltaPoints) else { throw ServerScoreDecodeError.invalid }
        }
    }
}

struct ServerScoreEffort: Codable, Equatable, Sendable { let confidence: String; let method: String }
struct ServerScoreRest: Codable, Equatable, Sendable { let confidence: String; let gravitySparse: Bool; let hrOnly: Bool? }

struct ServerScoreReadiness: Codable, Equatable, Sendable {
    struct Evidence: Codable, Equatable, Sendable {
        let kind: String
        let value: Double?
        let baseline: Double?
        let unit: String?
        let decimals: Int?
        let acute: Double?
        let chronic: Double?
    }
    struct Signal: Codable, Equatable, Sendable {
        let key: String
        let flag: String
        let label: String
        let detail: String
        let evidence: Evidence?
    }
    let level: String
    let confidence: String
    let headline: String
    let summary: String
    let signals: [Signal]
    func validate() throws {
        try ServerScoreEvidenceLimit.check(strings: [level, confidence, headline, summary])
        guard signals.count <= 32, Set(signals.map(\.key)).count == signals.count else { throw ServerScoreDecodeError.invalid }
        for signal in signals {
            let e = signal.evidence
            try ServerScoreEvidenceLimit.check(numbers: [e?.value, e?.baseline, e?.acute, e?.chronic],
                strings: [signal.key, signal.flag, signal.label, signal.detail, e?.kind, e?.unit])
            guard e?.decimals.map({ (0...6).contains($0) }) ?? true else { throw ServerScoreDecodeError.invalid }
            if let e {
                switch e.kind {
                case "metric_vs_baseline": guard e.value != nil, e.baseline != nil, e.unit != nil, e.decimals != nil else { throw ServerScoreDecodeError.invalid }
                case "training_load": guard e.acute != nil, e.chronic != nil else { throw ServerScoreDecodeError.invalid }
                case "monotony": guard e.value != nil else { throw ServerScoreDecodeError.invalid }
                default: break
                }
            }
        }
    }
}

struct ServerScoreSleepDiagnostics: Codable, Equatable, Sendable {
    struct Hypnogram: Codable, Equatable, Sendable {
        let inBedS: Double
        let asleepS: Double
        let sleepPeriodS: Double
        let sleepLatencyS: Double
        let remLatencyS: Double?
        let wakeAfterSleepOnsetS: Double
        let disturbances: Int
    }
    struct Motion: Codable, Equatable, Sendable {
        let start: Int64
        let epochSeconds: Int
        let unit: String
        let method: String
        let values: [Double?]
        let counts: [Int]
    }
    struct BandState: Codable, Equatable, Sendable {
        let start: Int64
        let epochSeconds: Int
        let values: [Int]
        let method: String
        let isDerivedStage: Bool
    }
    struct StageInsight: Codable, Equatable, Sendable {
        let stage: String
        let durationS: Double?
        let hrSampleCount: Int
        let meanHr: Double?
    }
    let id: String
    let editEntity: String
    let start: Int64
    let end: Int64
    let isNap: Bool
    let hrOnly: Bool
    let stagingSparse: Bool
    let stagedSeconds: Int64
    let stageCoverage: Double?
    let hypnogram: Hypnogram?
    let motion: Motion?
    let bandState: BandState?
    let stageInsights: [StageInsight]
    func validate() throws {
        guard end > start, stagedSeconds >= 0, stagedSeconds <= end - start,
              stageCoverage.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              stageInsights.count <= 16 else { throw ServerScoreDecodeError.invalid }
        if let h = hypnogram {
            let seconds = [h.inBedS, h.asleepS, h.sleepPeriodS, h.sleepLatencyS, h.remLatencyS, h.wakeAfterSleepOnsetS]
            try ServerScoreEvidenceLimit.check(numbers: seconds)
            guard seconds.compactMap({ $0 }).allSatisfy({ (0...Double(end - start)).contains($0) }),
                  h.disturbances >= 0 else { throw ServerScoreDecodeError.invalid }
        }
        if let m = motion {
            try ServerScoreEvidenceLimit.check(numbers: m.values, strings: [m.unit, m.method])
            guard m.start == start, m.epochSeconds == 30, m.values.count == m.counts.count,
                  m.values.count <= 20160, Int64(m.values.count) <= (end - start + 29) / 30,
                  m.counts.allSatisfy({ $0 >= 0 && $0 <= Int32.max }),
                  m.values.compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { throw ServerScoreDecodeError.invalid }
            for (value, count) in zip(m.values, m.counts) where count == 0 && value != nil { throw ServerScoreDecodeError.invalid }
        }
        if let b = bandState {
            try ServerScoreEvidenceLimit.check(strings: [b.method])
            guard b.start == start, b.epochSeconds == 30, !b.isDerivedStage, b.values.count <= 20160,
                  Int64(b.values.count) <= (end - start + 29) / 30 else { throw ServerScoreDecodeError.invalid }
        }
        for s in stageInsights {
            try ServerScoreEvidenceLimit.check(numbers: [s.durationS, s.meanHr], strings: [s.stage])
            guard s.hrSampleCount >= 0, s.durationS.map({ (0...Double(end - start)).contains($0) }) ?? true else { throw ServerScoreDecodeError.invalid }
        }
    }
}
