import Foundation
import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class W4DaytimeTimezoneTests: XCTestCase {
    private typealias F = W4FiveSeamFixtures

    func testExplicitLocalTruncationVectorsIncludingBothLordHoweTransitions() {
        let vectors = [
            ("America/Los_Angeles", "2026-11-01T08:30:00Z", "2026-11-01T08:00:00Z", 1),
            ("America/Los_Angeles", "2026-11-01T09:30:00Z", "2026-11-01T09:00:00Z", 1),
            ("America/Los_Angeles", "2026-03-08T09:45:00Z", "2026-03-08T09:00:00Z", 1),
            ("America/Los_Angeles", "2026-03-08T10:45:00Z", "2026-03-08T10:00:00Z", 3),
            ("Australia/Lord_Howe", "2026-04-04T14:45:00Z", "2026-04-04T14:00:00Z", 1),
            // The second 01:45 truncates to 01:00, where only the earlier +11 offset is valid.
            ("Australia/Lord_Howe", "2026-04-04T15:15:00Z", "2026-04-04T14:00:00Z", 1),
            // Missing 02:00 resolves forward by the 30-minute gap to local 02:30, not 01:30.
            ("Australia/Lord_Howe", "2026-10-03T15:45:00Z", "2026-10-03T15:30:00Z", 2),
            ("Asia/Kathmandu", "2026-06-15T00:45:00Z", "2026-06-15T00:15:00Z", 6),
            ("Africa/Khartoum", "2000-01-15T09:45:00Z", "2000-01-15T09:00:00Z", 11),
            ("Africa/Khartoum", "2000-01-15T10:15:00Z", "2000-01-15T10:00:00Z", 13)
        ]
        for (name, instant, start, hour) in vectors {
            let zone = F.zone(name), ts = F.epoch(instant)
            let key = DaytimeStress.hourBucket(ts, offsetSeconds: 12345, timezone: zone)
            XCTAssertEqual(key, F.epoch(start), "\(name) \(instant)")
            XCTAssertEqual(DaytimeStress.localHour(key, timezone: zone), hour)
            print("SWIFT_HOUR_VECTOR \(name) \(instant) \(key) \(hour)")
        }
    }

    func testFoundationElapsedHourIsNotThePartialTransitionOracle() {
        let zone = F.zone("Australia/Lord_Howe")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        for instant in ["2026-04-04T15:15:00Z", "2026-10-03T15:45:00Z"] {
            let ts = F.epoch(instant)
            let interval = cal.dateInterval(of: .hour, for: Date(timeIntervalSince1970: Double(ts)))!
            XCTAssertNotEqual(DaytimeStress.hourBucket(ts, offsetSeconds: 0, timezone: zone),
                              Int(interval.start.timeIntervalSince1970))
        }
    }

    func testCivilDayLengthsAndHalfOpenRawAdmissionUseActualBounds() throws {
        for (day, name, duration) in [
            ("2026-03-08", "America/Los_Angeles", 82_800), ("2026-11-01", "America/Los_Angeles", 90_000),
            ("2026-10-04", "Australia/Lord_Howe", 84_600), ("2026-04-05", "Australia/Lord_Howe", 88_200),
            ("2026-06-15", "Asia/Kathmandu", 86_400), ("2000-01-15", "Africa/Khartoum", 82_800)
        ] {
            let zone = F.zone(name), bounds = try DayCycleResolver.localDayBounds(day: day, timezone: zone)
            XCTAssertEqual(bounds.count, duration)
            let edge = [bounds.lowerBound - 1, bounds.lowerBound, bounds.upperBound - 1, bounds.upperBound]
            XCTAssertEqual(edge.filter(bounds.contains), [bounds.lowerBound, bounds.upperBound - 1])
            var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
            let hr = stride(from: bounds.lowerBound, to: bounds.upperBound, by: 12).map { ts in
                HRSample(ts: ts, bpm: 60 + cal.component(.hour, from: Date(timeIntervalSince1970: Double(ts))))
            }
            let actual = DaytimeStress.analyze(hr: hr, rr: [], timezone: zone)
            let expectedHours = (6..<22).filter { name != "Africa/Khartoum" || $0 != 12 }
            XCTAssertEqual(actual.hours.map(\.hour), expectedHours)
            XCTAssertEqual(actual.hours.map(\.startTs), Array(Set(actual.hours.map(\.startTs))).sorted())
            XCTAssertTrue(actual.hours.allSatisfy { bounds.contains($0.startTs) && $0.meanHR == Double(60 + $0.hour) })
            let aggregate = DaytimeStress.dayDaytimeAggregate(hr: hr, rr: [], tzOffsetSeconds: 0, timezone: zone)
            XCTAssertEqual(aggregate.hr, DaytimeStress.quantile(expectedHours.map { Double(60 + $0) }, 0.1))
            let allHourKeys = Set(hr.map { DaytimeStress.hourBucket($0.ts, offsetSeconds: 0, timezone: zone) })
            if name == "America/Los_Angeles" { XCTAssertEqual(allHourKeys.count, duration / 3600) }
        }
    }

    func testMissingMidnightSkippedDateAndNegativeEpochAreExplicit() throws {
        let bounds = try DayCycleResolver.localDayBounds(day: "2018-11-04", timezone: F.zone("America/Sao_Paulo"))
        XCTAssertEqual(bounds.lowerBound, F.epoch("2018-11-04T03:00:00Z")); XCTAssertEqual(bounds.count, 82_800)
        XCTAssertThrowsError(try DayCycleResolver.localDayBounds(day: "2011-12-30", timezone: F.zone("Pacific/Apia")))
        XCTAssertEqual(DaytimeStress.hourBucket(-1, offsetSeconds: 0, timezone: nil), -3600)
        XCTAssertEqual(DaytimeStress.localHour(-3600, timezone: nil), -1, "legacy signed remainder is unchanged")
        XCTAssertEqual(DaytimeStress.hourBucket(-1, offsetSeconds: 0, timezone: F.zone("UTC")), -3600)
        XCTAssertEqual(DaytimeStress.localHour(-3600, timezone: F.zone("UTC")), 23)
    }

    func testCacheSeparatesZonesWithMatchingEarlierOffsetsAndHonorsExplicitZone() {
        let start = F.epoch("2026-03-08T13:00:00Z"), zone = F.zone("America/Los_Angeles")
        let hr = F.hr(start), rr = F.rr(start)
        let fixed = TimeZone(secondsFromGMT: -28_800)!
        let before = Date(timeIntervalSince1970: Double(F.epoch("2026-03-08T08:00:00Z")))
        XCTAssertEqual(zone.secondsFromGMT(for: before), fixed.secondsFromGMT(for: before))
        let la = DaytimeStress.analyze(hr: hr, rr: rr, timezone: zone)
        XCTAssertEqual(la.hours.map(\.hour), [6])
        XCTAssertEqual(DaytimeStress.analyze(hr: hr, rr: rr, timezone: fixed), .empty)
        XCTAssertEqual(DaytimeStress.analyze(hr: hr, rr: rr, tzOffsetSeconds: -28_800), .empty)
        XCTAssertEqual(DaytimeStress.analyze(hr: hr, rr: rr, tzOffsetSeconds: 50_400, timezone: zone), la)
        XCTAssertEqual(DaytimeStress.analyze(hr: hr, rr: rr, timezone: F.zone("UTC")).hours.map(\.hour), [13])
        XCTAssertEqual(DaytimeStress.analyze(hr: hr, rr: rr, timezone: zone), la)
    }

    func testSharedMapsKeepRrOrderMotionGateAndCountGateAcrossMiddayTransition() throws {
        let zone = F.zone("Africa/Khartoum")
        let starts = ["2000-01-15T08:00:00Z", "2000-01-15T09:00:00Z", "2000-01-15T10:00:00Z", "2000-01-15T11:00:00Z"].map(F.epoch)
        let hr = zip(starts, [60, 110, 100, 60]).flatMap { F.hr($0.0, bpm: $0.1) }
        let rr = starts.flatMap { F.rr($0) }
        let gravity = starts.enumerated().flatMap { index, start in
            (0..<300).map { i in GravitySample(ts: start + i, x: index == 1 && i % 2 == 0 ? 1 : 0, y: 0, z: 1) }
        }
        let before = DaytimeStress.analyze(hr: hr, rr: rr, timezone: zone)
        let masked = DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity, timezone: zone)
        XCTAssertEqual(masked.hours.map(\.hour), [10, 11, 13, 14])
        XCTAssertEqual(masked.hours.map(\.startTs), starts)
        for hour in before.hours {
            let selected = rr.filter { $0.ts >= hour.startTs && $0.ts < hour.startTs + 3600 }
            XCTAssertEqual(hour.rmssd, HRVAnalyzer.analyze(rawRR: selected.map { Double($0.rrMs) }).rmssd)
        }
        XCTAssertEqual(masked.hours.map(\.maskedForActivity), [false, true, true, false])
        XCTAssertEqual(masked.activityMaskedHours, 2)
        XCTAssertEqual(masked.highStressMinutes, masked.scored.filter { $0.level! >= DaytimeStress.highBandFloor }.count * 60)
        let sparse = DaytimeStress.analyze(hr: F.hr(starts[0], count: 299), rr: [], timezone: zone)
        XCTAssertNil(sparse.hours.first?.level)
        XCTAssertNotNil(DaytimeStress.analyze(hr: F.hr(starts[0]), rr: [], timezone: zone).hours.first?.level)
    }

    func testFractionalConstantZoneMatchesLegacyModesAndFormula() {
        let start = F.epoch("2026-06-15T02:15:00Z"), zone = F.zone("Asia/Kathmandu")
        let hr = (0..<4).flatMap { F.hr(start + $0 * 3600, bpm: 60 + $0 * 8) }
        let rr = (0..<4).flatMap { F.rr(start + $0 * 3600) }
        let baseline = Baselines.foldHistory(Array(repeating: Optional(60.0), count: 8), cfg: Baselines.daytimeHRCfg)
        for mode in [DaytimeStress.ScoringMode.dayRelative, .baselineRelative(hr: baseline, rmssd: nil)] {
            XCTAssertEqual(DaytimeStress.analyze(hr: hr, rr: rr, tzOffsetSeconds: 20_700, mode: mode),
                           DaytimeStress.analyze(hr: hr, rr: rr, mode: mode, timezone: zone))
        }
    }
}
