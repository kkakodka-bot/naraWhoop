import Foundation

struct ServerScoreIllness: Codable, Equatable, Sendable {
    let level: String
    let signalCount: Int
    let suppressedBy: [String]
    let distanceFires: Bool
    let distanceIsAlertGate: Bool
    let wellnessOnly: Bool
    let firedSignals: [String]?
    let copy: String?
    let distanceDeviatingFeatures: Int?
    let distanceUsedDiagonalFallback: Bool?
    func validate() throws {
        try ServerScoreEvidenceLimit.check(strings: [level, copy] + suppressedBy.map(Optional.some) + (firedSignals ?? []).map(Optional.some))
        guard signalCount >= 0, signalCount <= 32, suppressedBy.count <= 32, (firedSignals?.count ?? 0) <= 32,
              distanceDeviatingFeatures.map({ (0...4).contains($0) }) ?? true,
              !distanceIsAlertGate, wellnessOnly else { throw ServerScoreDecodeError.invalid }
    }
}

struct ServerScoreCycle: Codable, Equatable, Sendable {
    struct PeriodWindow: Codable, Equatable, Sendable { let earliestDay: String; let latestDay: String }
    let phase: String
    let confidence: String
    let cycleDayLow: Int?
    let cycleDayHigh: Int?
    let cycleLengthDays: Int?
    let nextPeriodWindow: PeriodWindow?
    let shiftMarkers: [String]
    let awarenessOnly: Bool
    let baselinePolicy: String
    let note: String?
    func validate(day: String) throws {
        try ServerScoreEvidenceLimit.check(strings: [phase, confidence, baselinePolicy, note])
        guard awarenessOnly, shiftMarkers.count <= 180,
              shiftMarkers.allSatisfy({ ServerScoreDate.isDay($0) && $0 <= day }),
              [cycleDayLow, cycleDayHigh, cycleLengthDays].compactMap({ $0 }).allSatisfy({ (1...366).contains($0) }) else {
            throw ServerScoreDecodeError.invalid
        }
        if let low = cycleDayLow, let high = cycleDayHigh, low > high { throw ServerScoreDecodeError.invalid }
        if let window = nextPeriodWindow {
            guard ServerScoreDate.isDay(window.earliestDay), ServerScoreDate.isDay(window.latestDay),
                  window.earliestDay <= window.latestDay else { throw ServerScoreDecodeError.invalid }
        }
    }
}

struct ServerScoreCircadian: Codable, Equatable, Sendable {
    let confidence: String
    let acrophaseHours: Double
    let observedDays: Int
    let habitualWakeHour: Double?
    let measuredTemperatureMinimum: Bool
    let note: String?
    func validate() throws {
        try ServerScoreEvidenceLimit.check(numbers: [acrophaseHours, habitualWakeHour], strings: [confidence, note])
        guard (0..<24).contains(acrophaseHours), observedDays >= 0, observedDays <= 180,
              habitualWakeHour.map({ (0..<24).contains($0) }) ?? true,
              !measuredTemperatureMinimum else { throw ServerScoreDecodeError.invalid }
    }
}

struct ServerScoreDaytimeStress: Codable, Equatable, Sendable {
    let personalBaseline: Bool
    let hrOnlyFallback: Bool
    let activityMaskedHours: Int
    let sustainedHigh: Bool?
    let sustainedRun: Int?
    func validate() throws {
        guard (0...25).contains(activityMaskedHours), sustainedRun.map({ (0...25).contains($0) }) ?? true else {
            throw ServerScoreDecodeError.invalid
        }
    }
}

struct ServerScoreFrequencyHRV: Codable, Equatable, Sendable {
    let lfPower: Double?
    let hfPower: Double
    let lfHfRatio: Double?
    func validate() throws {
        try ServerScoreEvidenceLimit.check(numbers: [lfPower, hfPower, lfHfRatio])
        guard [lfPower, hfPower, lfHfRatio].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { throw ServerScoreDecodeError.invalid }
    }
}
