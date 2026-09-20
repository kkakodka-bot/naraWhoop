import Foundation
import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class W4TrueZoneSeamTests: XCTestCase {
    private typealias Vector = (day: String, zone: String, start: String, end: String, duration: Int)
    private let vectors: [Vector] = [
        ("2026-03-08", "America/Los_Angeles", "2026-03-08T08:00:00Z", "2026-03-09T07:00:00Z", 82_800),
        ("2026-11-01", "America/Los_Angeles", "2026-11-01T07:00:00Z", "2026-11-02T08:00:00Z", 90_000),
        ("2026-04-05", "Australia/Lord_Howe", "2026-04-04T13:00:00Z", "2026-04-05T13:30:00Z", 88_200),
        ("2026-10-04", "Australia/Lord_Howe", "2026-10-03T13:30:00Z", "2026-10-04T13:00:00Z", 84_600),
        ("2026-06-15", "Asia/Kathmandu", "2026-06-14T18:15:00Z", "2026-06-15T18:15:00Z", 86_400),
        ("2026-06-15", "UTC", "2026-06-15T00:00:00Z", "2026-06-16T00:00:00Z", 86_400),
        ("2000-01-15", "Africa/Khartoum", "2000-01-14T22:00:00Z", "2000-01-15T21:00:00Z", 82_800)
    ]

    private func epoch(_ text: String) throws -> Int {
        Int(try XCTUnwrap(ISO8601DateFormatter().date(from: text)).timeIntervalSince1970)
    }

    private func sleep(ending end: Int) -> SleepSession {
        SleepSession(start: end - 60, end: end, efficiency: 1,
            stages: [.init(start: end - 60, end: end, stage: "light")], restingHR: 50, avgHRV: 40)
    }

    func testActualCivilDayBoundsAcrossHourHalfHourAndMiddayTransitions() throws {
        for vector in vectors {
            let zone = try XCTUnwrap(TimeZone(identifier: vector.zone))
            let bounds = try DayCycleResolver.localDayBounds(day: vector.day, timezone: zone)
            XCTAssertEqual(bounds.lowerBound, try epoch(vector.start), vector.zone)
            XCTAssertEqual(bounds.upperBound, try epoch(vector.end), vector.zone)
            XCTAssertEqual(bounds.count, vector.duration, vector.zone)
        }
    }

    func testBoundsRejectMalformedNormalizedAndWhollySkippedDates() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        for day in ["", "2026-2-03", "2026-02-30", "2026-13-01", "2026-00-01", "2026-01-00",
                    "0000-01-01", "2026-01-01Z", "2026/01/01", "２０２６-01-01"] {
            XCTAssertThrowsError(try DayCycleResolver.localDayBounds(day: day, timezone: utc), day) {
                XCTAssertEqual($0 as? DayCycleResolver.DayBoundsError, .invalidDay)
            }
        }
        XCTAssertEqual(try DayCycleResolver.localDayBounds(day: "2024-02-29", timezone: utc).count, 86_400)
        let apia = try XCTUnwrap(TimeZone(identifier: "Pacific/Apia"))
        XCTAssertThrowsError(try DayCycleResolver.localDayBounds(day: "2011-12-30", timezone: apia))
        let saoPaulo = try XCTUnwrap(TimeZone(identifier: "America/Sao_Paulo"))
        let missingMidnight = try DayCycleResolver.localDayBounds(day: "2018-11-04", timezone: saoPaulo)
        XCTAssertEqual(missingMidnight.lowerBound, try epoch("2018-11-04T03:00:00Z"))
        XCTAssertEqual(missingMidnight.count, 82_800)
    }

    func testSessionAndRawAdditiveAdmissionAtEveryTrueDayEdge() throws {
        for vector in vectors {
            let zone = try XCTUnwrap(TimeZone(identifier: vector.zone))
            let bounds = try DayCycleResolver.localDayBounds(day: vector.day, timezone: zone)
            let lo = bounds.lowerBound, end = bounds.upperBound
            let points = [lo - 1, lo, lo + 1, end - 2, end - 1, end, end + 1]
            let sessions = points.map(sleep)
            let hr = points.enumerated().map { HRSample(ts: $0.element, bpm: 60 + $0.offset) }
            let gravity = points.map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
            let steps = points.enumerated().map { StepSample(ts: $0.element, counter: 100 + $0.offset * 2) }
            let result = AnalyticsEngine.analyzeDay(day: vector.day, hr: hr, gravity: gravity,
                steps: steps, dayHr: hr, daySteps: steps, dayGravity: gravity, profile: UserProfile(),
                resolvedSleep: sessions, localDayBounds: bounds, timezone: zone)
            XCTAssertEqual(result.sleepSessions.map(\.end), [lo, lo + 1, end - 2, end - 1], vector.zone)
            XCTAssertEqual(result.daily.steps, 6, vector.zone)
            let expectedCalories = Calories.estimateDayCalories(hr.filter { bounds.contains($0.ts) },
                profile: UserProfile(), hrmax: StrainScorer.tanakaHRmax(age: 30), restingHR: 50)
            XCTAssertEqual(result.daily.activeKcalEst, expectedCalories, vector.zone)
            XCTAssertEqual(hr.count, 7)
            XCTAssertEqual(gravity.count, 7)
        }
    }

    func testTwentyFiveHourDayKeepsBothEdgesWithoutShiftingEpochs() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let bounds = try DayCycleResolver.localDayBounds(day: "2026-11-01", timezone: zone)
        let sessions = [sleep(ending: bounds.lowerBound + 1_800), sleep(ending: bounds.upperBound - 1_800)]
        let hr = sessions.map { HRSample(ts: $0.start, bpm: 60) }
        let actual = AnalyticsEngine.analyzeDay(day: "2026-11-01", hr: hr, profile: UserProfile(),
            tzOffsetSeconds: -25_200, resolvedSleep: sessions, localDayBounds: bounds, timezone: zone)
        XCTAssertEqual(actual.sleepSessions, sessions)
        let zoneOnly = AnalyticsEngine.analyzeDay(day: "2026-11-01", hr: hr, profile: UserProfile(),
            tzOffsetSeconds: -25_200, resolvedSleep: sessions, timezone: zone)
        XCTAssertEqual(zoneOnly.sleepSessions, [sessions[0]], "timezone alone must not override legacy membership")
        let boundsOnly = AnalyticsEngine.analyzeDay(day: "2026-11-01", hr: hr, profile: UserProfile(),
            resolvedSleep: sessions, localDayBounds: bounds)
        XCTAssertEqual(boundsOnly.sleepSessions, sessions)
    }

    func testEmptyExplicitRangeAdmitsNoSleepStepsOrCalorieSamples() {
        let ts = 1_781_481_600
        let result = AnalyticsEngine.analyzeDay(day: "2026-06-15", hr: [.init(ts: ts, bpm: 65)],
            steps: [.init(ts: ts, counter: 100), .init(ts: ts + 1, counter: 120)], profile: UserProfile(),
            resolvedSleep: [sleep(ending: ts + 60)], localDayBounds: ts..<ts)
        XCTAssertTrue(result.sleepSessions.isEmpty)
        XCTAssertNil(result.daily.totalSleepMin)
        XCTAssertNil(result.daily.steps)
        XCTAssertNil(result.daily.activeKcalEst)
    }

    func testZoneCalendarAndFallbackUseActualMidnightWithElapsedMinimum() throws {
        for vector in vectors {
            let zone = try XCTUnwrap(TimeZone(identifier: vector.zone))
            let lo = try epoch(vector.start), end = try epoch(vector.end)
            for now in [lo, lo + 1, end - 1] {
                let actual = DayCycleResolver.calendarWindow(now: now, offsetSec: 123, timezone: zone)
                XCTAssertEqual(actual.startInclusive, lo, vector.zone)
                XCTAssertEqual(actual.endExclusive, now)
                XCTAssertEqual(actual.displayDay, vector.day)
                XCTAssertEqual(actual.id, "calendar:\(vector.day)")
                XCTAssertEqual(actual.source, .calendar)
                XCTAssertEqual(DayCycleResolver.activeWindow(mode: .midnight, latestSleep: nil,
                    now: now, offsetSec: 123, timezone: zone), actual)
            }
            let age = DayCycleResolver.minSyntheticMidnightAgeSeconds
            XCTAssertEqual(DayCycleResolver.fallbackMidnight(after: lo - age, offsetSec: 123, timezone: zone), lo)
            XCTAssertEqual(DayCycleResolver.fallbackMidnight(after: lo - age + 1, offsetSec: 123, timezone: zone), end)
            XCTAssertEqual(DayCycleResolver.fallbackMidnight(after: end - age - 1, offsetSec: 123, timezone: zone), end)
            XCTAssertEqual(DayCycleResolver.fallbackMidnight(after: end - age, offsetSec: 123, timezone: zone), end)
        }
    }

    func testSleepCycleRetainsFortyHourCapAcrossOffsetTransitions() throws {
        for vector in vectors {
            let zone = try XCTUnwrap(TimeZone(identifier: vector.zone))
            let lo = try epoch(vector.start), end = try epoch(vector.end)
            let sleep = DayCycleWindow(id: "edited", startInclusive: lo, endExclusive: lo + 500,
                displayDay: vector.day, source: .editedSleep)
            let cap = DayCycleResolver.absoluteMaxOpenSeconds
            let retained = DayCycleResolver.activeWindow(mode: .sleepOnset, latestSleep: sleep,
                now: lo + cap - 1, offsetSec: 0, timezone: zone)
            XCTAssertEqual(retained.id, "edited")
            XCTAssertEqual(retained.startInclusive, lo)
            XCTAssertEqual(retained.endExclusive, lo + cap - 1)
            let expired = DayCycleResolver.activeWindow(mode: .sleepOnset, latestSleep: sleep,
                now: lo + cap, offsetSec: 0, timezone: zone)
            XCTAssertEqual(expired.source, .syntheticMidnight)
            XCTAssertEqual(expired.startInclusive, end)
            XCTAssertEqual(expired.endExclusive, lo + cap)
            let next = DayCycleResolver.calendarWindow(now: end, offsetSec: 0, timezone: zone)
            XCTAssertEqual(expired.displayDay, next.displayDay)
            XCTAssertEqual(expired.id, "synthetic:\(next.displayDay)")
        }
    }

    func testNilZoneAndConstantZonePreserveLegacyDayCycleValues() throws {
        for offset in [-28_800, 0, 20_700, 39_600] {
            let zone = try XCTUnwrap(TimeZone(secondsFromGMT: offset))
            for now in [-86_500, 0, 86_500, 1_781_500_000] {
                let legacy = DayCycleResolver.calendarWindow(now: now, offsetSec: offset)
                XCTAssertEqual(legacy, DayCycleResolver.calendarWindow(now: now, offsetSec: offset, timezone: nil))
                XCTAssertEqual(legacy, DayCycleResolver.calendarWindow(now: now, offsetSec: 0, timezone: zone))
                let boundary = DayCycleResolver.fallbackMidnight(after: now, offsetSec: offset)
                XCTAssertEqual(boundary, DayCycleResolver.fallbackMidnight(after: now, offsetSec: 0, timezone: zone))
            }
        }
    }

    func testNightTailBridgeUsesOffsetAtEachFragmentOnset() throws {
        typealias Block = SleepStageTotals.NightBlock
        let cases = [
            ("America/Los_Angeles", "2026-03-08T18:30:00Z", -28_800, false), // 11:30, not stale 10:30
            ("America/Los_Angeles", "2026-11-01T18:30:00Z", -25_200, true),  // 10:30, not stale 11:30
            ("Australia/Lord_Howe", "2026-10-04T00:15:00Z", 37_800, false), // 11:15, not stale 10:45
            ("Australia/Lord_Howe", "2026-04-05T00:15:00Z", 39_600, true)   // 10:45, not stale 11:15
        ]
        for (name, instant, staleOffset, bridge) in cases {
            let zone = try XCTUnwrap(TimeZone(identifier: name)), onset = try epoch(instant)
            let blocks = [Block(start: onset - 3 * 3_600, end: onset - 70 * 60), Block(start: onset, end: onset + 3_600)]
            let actual = SleepStageTotals.bridgedNightGroups(blocks, offsetSec: staleOffset, timezone: zone)
            XCTAssertEqual(actual.map(\.indices), bridge ? [[0, 1]] : [[0], [1]], instant)
            XCTAssertEqual(actual.first?.gaps.count, bridge ? 1 : 0)
            let legacy = SleepStageTotals.bridgedNightGroups(blocks, offsetSec: staleOffset)
            XCTAssertNotEqual(actual, legacy, "control must detect a stale-offset implementation")
        }
    }

    func testMainNightRankingUsesOffsetAtEachMidpointAndKeepsOriginalIndices() throws {
        typealias Block = SleepStageTotals.NightBlock
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let earlyMid = try epoch("2026-03-08T08:30:00Z") // 00:30 before the transition
        let lateMid = try epoch("2026-03-08T14:00:00Z")  // 07:00 after, not 06:00
        let blocks = [Block(start: lateMid - 7_200, end: lateMid + 7_200),
                      Block(start: earlyMid - 6_300, end: earlyMid + 6_300)]
        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: -28_800, habitualMidsleepSec: 3 * 3_600), 0)
        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: -28_800,
            habitualMidsleepSec: 3 * 3_600, timezone: zone), 1)
        XCTAssertEqual(SleepStageTotals.mainNightGroupIndices(blocks, offsetSec: -28_800,
            habitualMidsleepSec: 3 * 3_600, timezone: zone), [1])
        let same = [blocks[1], blocks[1]]
        XCTAssertEqual(SleepStageTotals.mainNightIndex(same, offsetSec: 123, timezone: zone), 0)
        XCTAssertNil(SleepStageTotals.mainNightGroupIndices([], offsetSec: 123, timezone: zone))
    }
}
