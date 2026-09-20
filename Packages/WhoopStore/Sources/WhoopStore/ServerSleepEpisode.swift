import Foundation

/// Server epochs retain their timestamps and binary state. Missing epochs never become stage weights.
public struct ServerSleepEpisode: Identifiable {
    public struct Band: Equatable {
        public let start: Int, end: Int
        public let state: String
    }
    public let id: String
    public let episodeType: String
    public let groupId: String?
    public let start: Int, end: Int
    public let bands: [Band]
    public let asleepMin: Double?
    public let inBedMin: Double?
    public let opportunityKind: String?
    public let reason: String?
    public var startTimezoneId: String? = nil
    public var endTimezoneId: String? = nil
    public var clockLabel: String {
        "\(Self.eventClock(start, timezoneId: startTimezoneId)) – \(Self.eventClock(end, timezoneId: endTimezoneId))"
    }
    public static func eventClock(_ timestamp: Int, timezoneId: String?) -> String {
        let zone = timezoneId.flatMap(TimeZone.init(identifier:))
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = zone ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d HH:mm XXX"
        return "\(formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))) (\(zone?.identifier ?? "UTC; event zone unavailable"))"
    }
    public var opportunityLabel: String {
        opportunityKind == "user_reported_sleep_opportunity" ? "Reported sleep opportunity" : "Estimated sleep opportunity"
    }
    public static let states = ["wake", "rem", "light", "deep", "sleep_unstaged", "unknown", "off_body"]
    public static func label(_ state: String) -> String {
        ["wake": "Awake", "rem": "REM", "light": "Light", "deep": "Deep",
         "sleep_unstaged": "Unstaged sleep", "unknown": "Unknown", "off_body": "Off body"][state] ?? "Unknown"
    }
    public static func canonicalState(stage: String, state: String) -> String {
        if state == "off_body" { return "off_body" }
        if state == "unknown" || state == "state_unknown" { return "unknown" }
        if state == "wake" || state == "awake" { return "wake" }
        if state == "sleep" || state == "sleep_unstaged" { return ["light", "deep", "rem"].contains(stage) ? stage : "sleep_unstaged" }
        return "unknown"
    }
    public static func episodes(_ cache: ServerScoreDayCache?, day: String) -> [Self] {
        guard let cache, cache.day == day, let feature = cache.features["sleep"], feature.status != "unavailable" else { return [] }
        let parser = ISO8601DateFormatter()
        func epoch(_ value: String) -> Int? {
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = parser.date(from: value) { return Int(date.timeIntervalSince1970) }
            parser.formatOptions = [.withInternetDateTime]
            return parser.date(from: value).map { Int($0.timeIntervalSince1970) }
        }
        return cache.nights.compactMap { night in
            guard let start = epoch(night.startAt), let end = epoch(night.endAt), end > start else { return nil }
            let bands = night.stages.compactMap { row -> Band? in
                let a = max(start, row.start), b = min(end, row.end)
                return b > a ? Band(start: a, end: b, state: canonicalState(stage: row.stage, state: row.state)) : nil
            }.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
            let overlap = zip(bands, bands.dropFirst()).contains { $0.0.end > $0.1.start }
            return Self(id: night.id, episodeType: night.episodeType ?? (night.isNap ? "nap" : "unclassified"),
                groupId: night.mainSleepGroupId, start: start, end: end, bands: overlap ? [] : bands,
                asleepMin: night.measurementAvailable == true ? night.asleepMin : nil,
                inBedMin: night.inBedMin,
                opportunityKind: night.opportunityKind,
                reason: overlap ? "Conflicting server epochs" : bands.isEmpty ? "No server epochs available" : nil,
                startTimezoneId: night.startTimezoneId, endTimezoneId: night.endTimezoneId)
        }.sorted { $0.start < $1.start }
    }
}
