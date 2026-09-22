import Foundation

enum ServerScoreMetric: String, CaseIterable, Codable, Sendable {
    case hrv = "hrv_rmssd_ms", sdnn = "hrv_sdnn_ms", restingHR = "resting_hr_bpm"
    case respiration = "resp_rate_bpm"
    case sleepTotal = "sleep_total_min", sleepInBed = "sleep_in_bed_min", sleepAwake = "sleep_awake_min"
    case sleepLight = "sleep_light_min", sleepDeep = "sleep_deep_min", sleepREM = "sleep_rem_min"
    case sleepEfficiency = "sleep_efficiency", disturbances
    case sleepSessions = "sleep_sessions"
    // Existing daily storage / MetricCatalog vocabulary. These require explicit capabilities.
    case recovery, strain, exerciseCount = "exercise_count", steps
    case activeKcal = "active_kcal_est", estimatedSteps = "steps_est"
    case spo2 = "spo2_pct", spo2Red = "spo2_red", spo2IR = "spo2_ir"
    case skinTemperature = "skin_temp_c", skinTemperatureDeviation = "skin_temp_dev_c"
    case averageHR = "avg_hr", maximumHR = "max_hr"
    case zones13 = "hr_zones13_min", zones45 = "hr_zones45_min", zonesAll = "hr_zones_all_min"
    case strengthDuration = "strength_min"
    case sleepPerformance = "sleep_performance", hoursVsNeeded = "hours_vs_needed_pct"
    case sleepConsistency = "sleep_consistency", restorativePercent = "restorative_pct"
    case restorativeMinutes = "restorative_min", sleepNeed = "sleep_need_min", sleepDebt = "sleep_debt_min"
    case fitnessAge = "fitness_age", estimatedVO2Max = "vo2max_est", vitality, bodyAge = "body_age", stress
    case readiness, trainingLoad = "training_load", workouts
    case acuteLoad = "acute_load", chronicLoad = "chronic_load", trainingBalance = "training_balance"
    case acwr, trainingMonotony = "training_monotony"
    case illnessScore = "illness_score", illnessDistance = "illness_distance", cyclePhase = "cycle_phase"
    case circadianPhase = "circadian_phase_hour", circadianOffset = "circadian_offset_min"
    case daytimeStress = "daytime_stress_mean", daytimeHighMinutes = "daytime_stress_high_min"
    case baevskyStressIndex = "baevsky_stress_index"

    static let vitals: Set<Self> = [.hrv, .sdnn, .restingHR, .respiration]
    static let sleep: Set<Self> = [.sleepTotal, .sleepInBed, .sleepAwake, .sleepLight, .sleepDeep,
                                  .sleepREM, .sleepEfficiency, .disturbances, .sleepSessions]
    /// Missing capability lists mean the original core, never every future enum case.
    static let schema2: Set<Self> = vitals.union(sleep)
    static let temperatureOxygen: Set<Self> = [.skinTemperature, .skinTemperatureDeviation, .spo2, .spo2Red, .spo2IR]
    static let activity: Set<Self> = [.strain, .exerciseCount, .steps, .estimatedSteps, .activeKcal,
                                    .averageHR, .maximumHR, .zones13, .zones45, .zonesAll, .strengthDuration]
    static let sleepHistory: Set<Self> = [.sleepPerformance, .hoursVsNeeded, .sleepConsistency,
                                        .restorativePercent, .restorativeMinutes, .sleepNeed, .sleepDebt]
    static let longevity: Set<Self> = [.fitnessAge, .estimatedVO2Max, .vitality, .bodyAge]

    var permitsNegative: Bool {
        [.skinTemperatureDeviation, .skinTemperature, .circadianOffset, .trainingBalance].contains(self)
    }
}

struct ServerScoreDaily: Codable, Equatable, Sendable {
    let values: [String: Double]

    init(values: [String: Double]) { self.values = values }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
        init(stringValue: String) { self.stringValue = stringValue }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        var numbers: [String: Double] = [:]
        for metric in ServerScoreMetric.allCases where metric != .sleepSessions {
            let key = Key(stringValue: metric.rawValue)
            if let value = try c.decodeIfPresent(Double.self, forKey: key) {
                guard value.isFinite, (value >= 0 || metric.permitsNegative), abs(value) <= Double(Int32.max) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Invalid metric")
                }
                numbers[metric.rawValue] = value
            }
        }
        values = numbers
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for metric in ServerScoreMetric.allCases where metric != .sleepSessions &&
            (ServerScoreMetric.schema2.contains(metric) || values[metric.rawValue] != nil) {
            try c.encode(values[metric.rawValue], forKey: Key(stringValue: metric.rawValue))
        }
    }

    subscript(_ metric: ServerScoreMetric) -> Double? { values[metric.rawValue] }
}

struct ServerScoreSleep: Codable, Equatable, Sendable, Identifiable {
    struct Stage: Codable, Equatable, Sendable {
        let start: Int64
        let end: Int64
        let stage: String
    }

    let id: String
    let startAt: String
    let endAt: String
    let isNap: Bool
    let inBedMin: Double?
    let asleepMin: Double?
    let awakeMin: Double?
    let lightMin: Double?
    let deepMin: Double?
    let remMin: Double?
    let efficiency: Double?
    let restingHrBpm: Double?
    let hrvRmssdMs: Double?
    let stages: [Stage]
    let start: Int
    let end: Int
    let originalStart: Int?
    let originalEnd: Int?
    let editEntity: String?
    /// Only the first edit of an older snapshot may use the displayed bounds as its anchor.
    /// The durable input writer must retain these values across subsequent revisions.
    var anchoredOriginalStart: Int { originalStart ?? start }
    var anchoredOriginalEnd: Int { originalEnd ?? end }
    var resolvedEditEntity: String { editEntity ?? "sleep:" + id.lowercased() }
    /// Legacy session readers consume this exact epoch-segment array. Not an additional wire field.
    let stagesJSON: String

    enum CodingKeys: String, CodingKey {
        case id, stages, efficiency, originalStart, originalEnd, editEntity
        case startAt = "start_at", endAt = "end_at", isNap = "is_nap"
        case inBedMin = "in_bed_min", asleepMin = "asleep_min", awakeMin = "awake_min"
        case lightMin = "light_min", deepMin = "deep_min", remMin = "rem_min"
        case restingHrBpm = "resting_hr_bpm", hrvRmssdMs = "hrv_rmssd_ms"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        startAt = try c.decode(String.self, forKey: .startAt)
        endAt = try c.decode(String.self, forKey: .endAt)
        guard let lo = ServerScoreDate.parse(startAt), let hi = ServerScoreDate.parse(endAt),
              lo.timeIntervalSince1970 >= 0, hi.timeIntervalSince1970 <= 253402300799 else {
            throw ServerScoreDecodeError.invalid
        }
        start = Int(lo.timeIntervalSince1970)
        end = Int(hi.timeIntervalSince1970)
        originalStart = try c.decodeIfPresent(Int.self, forKey: .originalStart)
        originalEnd = try c.decodeIfPresent(Int.self, forKey: .originalEnd)
        editEntity = try c.decodeIfPresent(String.self, forKey: .editEntity)
        isNap = try c.decode(Bool.self, forKey: .isNap)
        inBedMin = try c.decodeIfPresent(Double.self, forKey: .inBedMin)
        asleepMin = try c.decodeIfPresent(Double.self, forKey: .asleepMin)
        awakeMin = try c.decodeIfPresent(Double.self, forKey: .awakeMin)
        lightMin = try c.decodeIfPresent(Double.self, forKey: .lightMin)
        deepMin = try c.decodeIfPresent(Double.self, forKey: .deepMin)
        remMin = try c.decodeIfPresent(Double.self, forKey: .remMin)
        efficiency = try c.decodeIfPresent(Double.self, forKey: .efficiency)
        restingHrBpm = try c.decodeIfPresent(Double.self, forKey: .restingHrBpm)
        hrvRmssdMs = try c.decodeIfPresent(Double.self, forKey: .hrvRmssdMs)
        stages = try c.decode([Stage].self, forKey: .stages)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        stagesJSON = String(decoding: try encoder.encode(stages), as: UTF8.self)
    }

    func validate() throws {
        guard UUID(uuidString: id) != nil,
              let lo = ServerScoreDate.parse(startAt)?.timeIntervalSince1970,
              let hi = ServerScoreDate.parse(endAt)?.timeIntervalSince1970,
              hi > lo, hi - lo <= 7 * 86400, stages.count <= 10080 else { throw ServerScoreDecodeError.invalid }
        guard anchoredOriginalStart >= 0, anchoredOriginalEnd > anchoredOriginalStart,
              anchoredOriginalEnd <= 253402300799 else { throw ServerScoreDecodeError.invalid }
        let hasIdentity = originalStart != nil || originalEnd != nil || editEntity != nil
        guard !hasIdentity || (originalStart != nil && originalEnd != nil && editEntity != nil && anchoredOriginalStart > 0) else {
            throw ServerScoreDecodeError.invalid
        }
        if let editEntity {
            let key = String(editEntity.dropFirst(6))
            guard editEntity.hasPrefix("sleep:"), let uuid = UUID(uuidString: key),
                  uuid.uuidString.lowercased() == key, key == id.lowercased() else { throw ServerScoreDecodeError.invalid }
        }
        guard [inBedMin, asleepMin, awakeMin, lightMin, deepMin, remMin, efficiency, restingHrBpm, hrvRmssdMs]
            .compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= Double(Int32.max) }) else { throw ServerScoreDecodeError.invalid }
        var previousEnd = lo
        for segment in stages {
            guard ["wake", "awake", "light", "deep", "rem"].contains(segment.stage),
                  Double(segment.start) >= previousEnd, segment.end > segment.start,
                  Double(segment.end) <= hi else { throw ServerScoreDecodeError.invalid }
            previousEnd = Double(segment.end)
        }
    }
}

struct ServerScoreCoverage: Codable, Equatable, Sendable {
    let hrSamples: Int?
    let rrIntervals: Int?
    let gaps: [String]?
    let historicalStateAvailable: Bool?
}

/// Optional extensions are typed but do not grant ownership until their field contract is activated.
struct ServerScoreMetricReading: Codable, Equatable, Sendable {
    let value: Double?
    let unit: String?
    let status: String?
    let method: String?

    func validate() throws {
        guard value.map({ $0.isFinite && abs($0) <= Double(Int32.max) }) ?? true,
              [unit, status, method].compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 256 }) else {
            throw ServerScoreDecodeError.invalid
        }
    }
}

struct ServerScoreChartPoint: Codable, Equatable, Sendable {
    let start: Int64
    let end: Int64?
    let value: Double?
    let count: Int?
    let min: Double?
    let max: Double?

    func validate(after previousEnd: Int64?) throws {
        guard start >= 0, start <= 253402300799,
              end.map({ $0 > start && $0 <= 253402300799 }) ?? true,
              previousEnd.map({ start >= $0 }) ?? true,
              count.map({ $0 > 0 }) ?? true,
              [value, min, max].compactMap({ $0 }).allSatisfy({ $0.isFinite && abs($0) <= Double(Int32.max) }) else {
            throw ServerScoreDecodeError.invalid
        }
        if let min, let max, min > max { throw ServerScoreDecodeError.invalid }
        if let value, let min, value < min { throw ServerScoreDecodeError.invalid }
        if let value, let max, value > max { throw ServerScoreDecodeError.invalid }
    }
}

struct ServerScoreHistoryDay: Codable, Equatable, Sendable {
    let day: String
    let metrics: [String: ServerScoreMetricReading]
}

struct ServerScoreDependency: Codable, Equatable, Sendable {
    let stateSchemaVersion: Int
    let generation: Int64
    let predecessorResultRevision: Int64?
    let configurationRevision: Int64
    let profileRevision: Int64
    let sourceEra: String

    func validate() throws {
        guard stateSchemaVersion > 0, generation >= 0, configurationRevision >= 0,
              profileRevision >= 0, predecessorResultRevision.map({ $0 >= 0 }) ?? true,
              sourceEra.utf8.count <= 512 else { throw ServerScoreDecodeError.invalid }
    }
}

struct ServerScoreSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let userId: String
    let sourceDeviceId: String
    let day: String
    let timezone: String
    let algorithmVersion: String
    let inputRevision: Int64
    let resultRevision: Int64
    let computedAt: String
    let dataThrough: String?
    let status: String
    let coverage: ServerScoreCoverage
    let daily: ServerScoreDaily?
    let sleep: [ServerScoreSleep]
    let capabilities: [String]?
    let metrics: [String: ServerScoreMetricReading]?
    let charts: [String: [ServerScoreChartPoint]]?
    let history: [ServerScoreHistoryDay]?
    let dependency: ServerScoreDependency?
    let details: ServerScoreDetails?
    let chartMetadata: [String: ServerScoreChartMetadata]?

    var supported: Set<ServerScoreMetric> {
        capabilities.map { Set($0.compactMap(ServerScoreMetric.init(rawValue:))) } ?? ServerScoreMetric.schema2
    }

    /// A present typed null supersedes a legacy daily value. Capability is checked per result too,
    /// because an active algorithm/source may no longer produce a previously activated field.
    func value(_ metric: ServerScoreMetric) -> Double? {
        guard supported.contains(metric), status != "no_data" else { return nil }
        if let reading = metrics?[metric.rawValue] { return reading.value }
        return daily?[metric]
    }

    func validate() throws {
        guard schemaVersion == 2, UUID(uuidString: userId) != nil, UUID(uuidString: sourceDeviceId) != nil,
              ServerScoreDate.isDay(day), TimeZone(identifier: timezone) != nil,
              !algorithmVersion.isEmpty, algorithmVersion.utf8.count <= 512,
              inputRevision >= 0, resultRevision > 0, ServerScoreDate.parse(computedAt) != nil,
              dataThrough == nil || ServerScoreDate.parse(dataThrough!) != nil,
              ["available", "partial", "no_data"].contains(status), sleep.count <= 128,
              Set(sleep.map(\.id)).count == sleep.count else { throw ServerScoreDecodeError.invalid }
        if status == "no_data", daily != nil || !sleep.isEmpty { throw ServerScoreDecodeError.invalid }
        for session in sleep { try session.validate() }
        try validateMetrics(metrics ?? [:])
        if status == "no_data", metrics?.values.contains(where: { $0.value != nil }) == true {
            throw ServerScoreDecodeError.invalid
        }
        guard (capabilities?.count ?? 0) <= 256,
              capabilities?.allSatisfy({ $0.utf8.count <= 128 }) ?? true,
              (charts?.count ?? 0) <= 64, (history?.count ?? 0) <= 400 else { throw ServerScoreDecodeError.invalid }
        for (key, points) in charts ?? [:] {
            guard key.utf8.count <= 128, points.count <= 10080 else { throw ServerScoreDecodeError.invalid }
            var previousEnd: Int64?
            for point in points {
                try point.validate(after: previousEnd)
                previousEnd = point.end ?? point.start + 1
            }
        }
        var seen: Set<String> = []
        for entry in history ?? [] {
            guard ServerScoreDate.isDay(entry.day), entry.day <= day, seen.insert(entry.day).inserted else {
                throw ServerScoreDecodeError.invalid
            }
            try validateMetrics(entry.metrics)
        }
        try dependency?.validate()
        try details?.validate(day: day, sleep: sleep)
        guard (chartMetadata?.count ?? 0) <= 64 else { throw ServerScoreDecodeError.invalid }
        for (key, metadata) in chartMetadata ?? [:] {
            guard key.utf8.count <= 128 else { throw ServerScoreDecodeError.invalid }
            try metadata.validate()
        }
    }

    private func validateMetrics(_ metrics: [String: ServerScoreMetricReading]) throws {
        guard metrics.count <= 256 else { throw ServerScoreDecodeError.invalid }
        for (key, reading) in metrics {
            guard key.utf8.count <= 128 else { throw ServerScoreDecodeError.invalid }
            try reading.validate()
            if let metric = ServerScoreMetric(rawValue: key), !metric.permitsNegative,
               let value = reading.value, value < 0 { throw ServerScoreDecodeError.invalid }
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

enum ServerScoreDecodeError: Error, Equatable { case invalid, tooLarge, unsupportedSchema(Int) }

struct ServerScoreResponse: Equatable, Sendable {
    let day: String
    let status: String
    let snapshot: ServerScoreSnapshot?
    let userId: String?
    let timezone: String?
    let pending: Bool
    let requestedInputRevision: Int64?
    let archiveStatus: String?

    private struct Header: Decodable {
        let schemaVersion: Int
        let day: String
        let status: String
        let userId: String?
        let timezone: String?
        let requestedInputRevision: Int64?
        let pending: Bool?
        let archiveStatus: String?
    }

    static func decode(_ data: Data, requestedDay: String) throws -> Self {
        guard data.count <= 512 * 1024 else { throw ServerScoreDecodeError.tooLarge }
        let decoder = JSONDecoder()
        let h = try decoder.decode(Header.self, from: data)
        guard h.schemaVersion == 2 else { throw ServerScoreDecodeError.unsupportedSchema(h.schemaVersion) }
        guard h.day == requestedDay, ServerScoreDate.isDay(h.day),
              ["available", "partial", "no_data", "pending", "failed", "unsupported"].contains(h.status) else {
            throw ServerScoreDecodeError.invalid
        }
        var snapshot: ServerScoreSnapshot?
        if ["available", "partial", "no_data"].contains(h.status) {
            snapshot = try decoder.decode(ServerScoreSnapshot.self, from: data)
            try snapshot?.validate()
        }
        return Self(day: h.day, status: h.status, snapshot: snapshot, userId: h.userId, timezone: h.timezone,
                    pending: h.pending ?? (h.status == "pending"), requestedInputRevision: h.requestedInputRevision,
                    archiveStatus: h.archiveStatus)
    }
}

enum ServerScoreDate {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func day(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func isDay(_ value: String) -> Bool {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return value.count == 10 && f.date(from: value).map { f.string(from: $0) == value } == true
    }

    static func offsetDay(_ day: String, by offset: Int, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
              let shifted = calendar.date(byAdding: .day, value: offset, to: date) else { return day }
        return self.day(shifted, timeZone: timeZone)
    }
}

struct ServerScoreDayState: Equatable, Sendable {
    enum Phase: String, Sendable { case loading, available, partial, noData, pending, failed, unsupported, offline, authenticationRequired, timezoneMismatch }
    let snapshot: ServerScoreSnapshot?
    let phase: Phase
    let fetchedAt: Date?
    let cached: Bool
    let pending: Bool
    let requestedInputRevision: Int64?
    let archiveStatus: String?

    var note: String {
        switch phase {
        case .loading: return snapshot == nil ? "Loading server scores" : "Updating cached server scores"
        case .pending: return snapshot == nil ? "Waiting for server calculation" : "Cached server scores; update pending"
        case .failed: return "Server scores unavailable; last result retained"
        case .unsupported: return "Server score version not supported; last compatible result retained"
        case .offline: return snapshot == nil ? "Offline; no cached server scores" : "Offline; showing cached server scores"
        case .authenticationRequired: return "Sign in to read server scores"
        case .timezoneMismatch: return "Server profile timezone differs; update profile before displaying these scores"
        case .noData: return pending ? "No server data; recalculation pending" : "Server confirmed no data for this day"
        case .partial: return pending ? "Partial server data; update pending" : "Partial server data"
        case .available: return pending ? "Server scores; update pending" : (cached ? "Cached server scores" : "Server scores")
        }
    }

    func retaining(_ phase: Phase) -> Self {
        Self(snapshot: snapshot, phase: phase, fetchedAt: fetchedAt, cached: snapshot != nil,
             pending: pending, requestedInputRevision: requestedInputRevision, archiveStatus: archiveStatus)
    }

    static func empty(_ phase: Phase) -> Self {
        Self(snapshot: nil, phase: phase, fetchedAt: nil, cached: false, pending: false,
             requestedInputRevision: nil, archiveStatus: nil)
    }
}

struct ServerScoreViewState: Equatable, Sendable {
    let generation: UUID?
    let revision: UInt64
    let currentDay: String
    let timezone: String
    let configured: Bool
    let authenticated: Bool
    let capabilities: Set<ServerScoreMetric>
    let activated: Set<ServerScoreMetric>
    let days: [String: ServerScoreDayState]

    static let empty = Self(generation: nil, revision: 0, currentDay: "", timezone: "UTC", configured: false,
                            authenticated: false, capabilities: [], activated: [], days: [:])
    var hasServerOwnership: Bool { configured && authenticated && !activated.intersection(capabilities).isEmpty }
    var hasSleepPresentationOwnership: Bool {
        ServerScoreMetric.sleep.union(ServerScoreMetric.sleepHistory).union([.respiration]).contains(where: owns)
    }
    func hasScalarContent(day: String) -> Bool {
        guard hasServerOwnership, let snapshot = days[day]?.snapshot else { return false }
        return activated.intersection(capabilities).contains { snapshot.value($0) != nil }
    }
    func owns(_ metric: ServerScoreMetric) -> Bool {
        configured && authenticated && capabilities.contains(metric) && activated.contains(metric)
    }
    func value(_ metric: ServerScoreMetric, day: String, local: @autoclosure () -> Double?) -> Double? {
        owns(metric) ? days[day]?.snapshot?.value(metric) : local()
    }
}
