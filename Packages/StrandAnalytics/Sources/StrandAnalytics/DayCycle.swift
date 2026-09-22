import Foundation

public enum DayCycleMode: String, CaseIterable, Sendable {
    case sleepOnset = "sleep_onset"
    case midnight = "midnight"

    public static let storageKey = "noop.dayCycleMode"
    /// Kotlin twin: `DayCycleMode.fromPersisted`.
    public static func persisted(_ value: String?) -> DayCycleMode {
        value.flatMap(Self.init(rawValue:)) ?? .sleepOnset
    }
}

public struct DayCycleWindow: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case detectedSleep, editedSleep, syntheticMidnight, calendar }
    public let id: String
    public let startInclusive: Int
    public let endExclusive: Int
    public let displayDay: String
    public let source: Source

    public init(id: String, startInclusive: Int, endExclusive: Int, displayDay: String, source: Source) {
        self.id = id; self.startInclusive = startInclusive; self.endExclusive = endExclusive
        self.displayDay = displayDay; self.source = source
    }
}

public enum DayCycleResolver {
    public static let minSyntheticMidnightAgeSeconds = 18 * 3_600
    public static let absoluteMaxOpenSeconds = 40 * 3_600

    public enum DayBoundsError: Error, Equatable { case invalidDay }

    /// Actual UTC [start,end) of a Gregorian civil day. Invalid or wholly skipped days fail
    /// explicitly; a midnight clock transition may instead make the first instant later than 00:00.
    public static func localDayBounds(day: String, timezone: TimeZone) throws -> Range<Int> {
        let bytes = Array(day.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }) else {
            throw DayBoundsError.invalidDay
        }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 0, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else {
            throw DayBoundsError.invalidDay
        }
        let calendar = zonedCalendar(timezone)
        guard let noon = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
              dayKey(noon, calendar: calendar) == day,
              let interval = calendar.dateInterval(of: .day, for: noon), interval.duration > 0 else {
            throw DayBoundsError.invalidDay
        }
        return Int(interval.start.timeIntervalSince1970)..<Int(interval.end.timeIntervalSince1970)
    }

    private static func zonedCalendar(_ timezone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timezone
        return calendar
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// Kotlin twin: `DayCycleResolver.calendarWindow`.
    public static func calendarWindow(now: Int, offsetSec: Int, timezone: TimeZone? = nil) -> DayCycleWindow {
        if let timezone {
            let calendar = zonedCalendar(timezone)
            let date = Date(timeIntervalSince1970: Double(now))
            let start = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
            let day = dayKey(date, calendar: calendar)
            return DayCycleWindow(id: "calendar:\(day)", startInclusive: start, endExclusive: now,
                                  displayDay: day, source: .calendar)
        }
        let local = now + offsetSec
        let dayNumber = Int(floor(Double(local) / Double(SleepStageTotals.secondsPerDay)))
        let start = dayNumber * SleepStageTotals.secondsPerDay - offsetSec
        let day = AnalyticsEngine.dayString(start, offsetSec: offsetSec)
        return DayCycleWindow(id: "calendar:\(day)", startInclusive: start, endExclusive: now,
                              displayDay: day, source: .calendar)
    }

    /// Kotlin twin: `DayCycleResolver.fallbackMidnightAfter`.
    public static func fallbackMidnight(after start: Int, offsetSec: Int, timezone: TimeZone? = nil) -> Int {
        let minimum = start + minSyntheticMidnightAgeSeconds
        if let timezone {
            let calendar = zonedCalendar(timezone)
            let date = Date(timeIntervalSince1970: Double(minimum))
            let midnight = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
            if midnight >= minimum { return midnight }
            // The interval's end is the next actual start of day, even across offset transitions.
            let interval = calendar.dateInterval(of: .day, for: date)!
            return Int(interval.end.timeIntervalSince1970)
        }
        let local = minimum + offsetSec
        let dayNumber = Int(floor(Double(local) / Double(SleepStageTotals.secondsPerDay)))
        let midnight = dayNumber * SleepStageTotals.secondsPerDay - offsetSec
        return midnight >= minimum ? midnight : (dayNumber + 1) * SleepStageTotals.secondsPerDay - offsetSec
    }

    /// Kotlin twin: `DayCycleResolver.activeWindow`.
    public static func activeWindow(mode: DayCycleMode, latestSleep: DayCycleWindow?, now: Int,
                                    offsetSec: Int, timezone: TimeZone? = nil) -> DayCycleWindow {
        guard mode == .sleepOnset, let latestSleep else {
            return calendarWindow(now: now, offsetSec: offsetSec, timezone: timezone)
        }
        let age = now - latestSleep.startInclusive
        let fallback = fallbackMidnight(after: latestSleep.startInclusive, offsetSec: offsetSec, timezone: timezone)
        // Sleep-onset mode stays anchored across midnight unconditionally: only the absolute safety cap
        // may synthesize a fallback boundary. An earlier design gated this on whether awake coverage was
        // reliable and carried a `reliableAwakeCoverage` parameter for it; the gate was dropped but the
        // parameter survived, unread on both platforms and passed `false` by every one of its five call
        // sites. Removed rather than left looking like a switch someone could flip.
        guard age < absoluteMaxOpenSeconds else {
            let day = timezone.map { dayKey(Date(timeIntervalSince1970: Double(fallback)), calendar: zonedCalendar($0)) }
                ?? AnalyticsEngine.dayString(fallback, offsetSec: offsetSec)
            return DayCycleWindow(id: "synthetic:\(day)", startInclusive: fallback, endExclusive: now,
                                  displayDay: day, source: .syntheticMidnight)
        }
        return DayCycleWindow(id: latestSleep.id, startInclusive: latestSleep.startInclusive,
                              endExclusive: now, displayDay: latestSleep.displayDay, source: latestSleep.source)
    }
}
