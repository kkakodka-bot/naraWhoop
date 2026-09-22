import Foundation
import XCTest
import WhoopProtocol
@testable import StrandAnalytics

// Synthetic raw inputs only. No provided hypnogram stands in for automatic detection.
enum W4AutomaticSleepFixtures {
    static func ts(_ text: String) -> Int {
        Int(ISO8601DateFormatter().date(from: text)!.timeIntervalSince1970)
    }

    struct Raw {
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        var resp: [RespSample] = []
        var gravity: [GravitySample] = []
        var steps: [StepSample] = []

        mutating func append(start: Int, seconds: Int, bpm: Int = 50,
                             active: Bool = false, cardiac: Bool = false) {
            for i in 0..<seconds {
                let t = start + i
                hr.append(.init(ts: t, bpm: bpm))
                gravity.append(.init(ts: t, x: active ? Double(i % 2) * 0.5 : 0, y: 0, z: 1))
                if cardiac {
                    rr.append(.init(ts: t, rrMs: 1000 + [0, 40, 0, -40][i % 4]))
                    resp.append(.init(ts: t, raw: 1000 + [0, 100, 0, -100][i % 4]))
                }
            }
        }
    }

    struct Boundary {
        let zone: String
        let center: String
        let staleOffset: Int
        let daytime: Bool
    }

    static let boundaries: [Boundary] = [
        .init(zone: "America/Los_Angeles", center: "2026-03-08T18:30:00Z", staleOffset: -8 * 3600, daytime: true),
        .init(zone: "America/Los_Angeles", center: "2026-11-01T18:30:00Z", staleOffset: -7 * 3600, daytime: false),
        .init(zone: "Australia/Lord_Howe", center: "2026-10-04T00:15:00Z", staleOffset: 10 * 3600 + 1800, daytime: true),
        .init(zone: "Australia/Lord_Howe", center: "2026-04-05T00:15:00Z", staleOffset: 11 * 3600, daytime: false),
        .init(zone: "Africa/Khartoum", center: "2000-01-15T17:30:00Z", staleOffset: 2 * 3600, daytime: false),
    ]

    static func boundary(_ v: Boundary) -> Raw {
        var raw = Raw()
        raw.append(start: ts(v.center) - 35 * 60, seconds: 70 * 60, cardiac: true)
        return raw
    }

    static func detect(_ raw: Raw, offset: Int = 0, zone: TimeZone? = nil, v2: Bool = false,
                       band: [(ts: Int, state: Int)] = [],
                       wristOff: [(start: Int, end: Int)] = [],
                       trace: ((String) -> Void)? = nil) -> [SleepSession] {
        SleepStager.detectSleep(hr: raw.hr, rr: raw.rr, resp: raw.resp, gravity: raw.gravity,
            tzOffsetSeconds: offset, wristOff: wristOff, bandSleepState: band,
            useSleepStagerV2: v2, timezone: zone, traceSink: trace)
    }

    static func traced(_ raw: Raw, offset: Int = 0, zone: TimeZone? = nil, v2: Bool = false,
                       band: [(ts: Int, state: Int)] = []) -> (sessions: [SleepSession], lines: [String]) {
        var lines: [String] = []
        let sessions = detect(raw, offset: offset, zone: zone, v2: v2, band: band) { lines.append($0) }
        return (sessions, lines)
    }
}

final class W4AutomaticSleepTimezoneTests: XCTestCase {
    private typealias F = W4AutomaticSleepFixtures

    func testDenseDefaultAndExplicitNilAreExactForBothStagersAndTraces() throws {
        var raw = F.Raw()
        raw.append(start: F.ts("2026-06-15T01:00:00Z"), seconds: 2 * 3600, cardiac: true)
        for v2 in [false, true] {
            var oldLines: [String] = [], nilLines: [String] = []
            let omitted = SleepStager.detectSleep(hr: raw.hr, rr: raw.rr, resp: raw.resp,
                gravity: raw.gravity, useSleepStagerV2: v2) { oldLines.append($0) }
            let explicitNil = F.detect(raw, v2: v2) { nilLines.append($0) }
            XCTAssertEqual(omitted.count, 1)
            let only = try XCTUnwrap(omitted.first)
            XCTAssertFalse(only.stages.isEmpty)
            XCTAssertNotNil(only.avgHRV)
            XCTAssertEqual(omitted, explicitNil)
            XCTAssertEqual(oldLines, nilLines)
            XCTAssertEqual(F.detect(raw, v2: v2), omitted)
        }
    }

    func testConstantOffsetZoneEqualsLegacyNumericOffsetIncludingTrace() {
        var raw = F.Raw()
        raw.append(start: F.ts("2026-06-14T19:30:00Z"), seconds: 2 * 3600, cardiac: true)
        let offset = 5 * 3600 + 1800
        for v2 in [false, true] {
            let legacy = F.traced(raw, offset: offset, v2: v2)
            let zoned = F.traced(raw, offset: -7 * 3600, zone: TimeZone(secondsFromGMT: offset), v2: v2)
            XCTAssertEqual(legacy.sessions.count, 1)
            XCTAssertEqual(zoned.sessions, legacy.sessions)
            XCTAssertEqual(zoned.lines, legacy.lines)
        }
    }

    func testEmptyShortAndNoHRAreUnchangedByNilOrEquivalentUTC() {
        var short = F.Raw(), noHR = F.Raw()
        short.append(start: F.ts("2026-06-15T01:00:00Z"), seconds: 30 * 60)
        noHR.append(start: F.ts("2026-06-15T01:00:00Z"), seconds: 2 * 3600)
        noHR.hr = []
        // Legacy gravity-only detection deliberately degrades to motion staging without RHR/HRV.
        for (raw, expectedCount) in [(F.Raw(), 0), (short, 0), (noHR, 1)] {
            for v2 in [false, true] {
                let old = SleepStager.detectSleep(hr: raw.hr, gravity: raw.gravity, useSleepStagerV2: v2)
                XCTAssertEqual(old, F.detect(raw, v2: v2))
                XCTAssertEqual(old, F.detect(raw, zone: TimeZone(secondsFromGMT: 0), v2: v2))
                XCTAssertEqual(old.count, expectedCount)
                XCTAssertNil(old.first?.restingHR)
                XCTAssertNil(old.first?.avgHRV)
            }
        }
        XCTAssertTrue(SleepStager.hrOnlySessions(hr: short.hr, rr: [], resp: []).isEmpty,
                      "short control cannot create an HR-only night")
    }

    func testExactLocalBandEdgesUseInstantOffsetAndIgnoreFallback() throws {
        // Each local date is on a transition day; calculate its edge's offset, not midnight's.
        for (zoneID, day) in [("America/Los_Angeles", "2026-03-08"),
                              ("America/Los_Angeles", "2026-11-01"),
                              ("Australia/Lord_Howe", "2026-10-04"),
                              ("Australia/Lord_Howe", "2026-04-05")] {
            let zone = try XCTUnwrap(TimeZone(identifier: zoneID))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let bounds = try DayCycleResolver.localDayBounds(day: day, timezone: zone)
            let date = Date(timeIntervalSince1970: Double(bounds.lowerBound))
            for hour in [11, 20] {
                let edgeDate = try XCTUnwrap(calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date))
                let edge = Int(edgeDate.timeIntervalSince1970)
                for delta in [-1, 0, 1] {
                    let instant = edge + delta
                    let expected = hour == 11 ? delta >= 0 : delta < 0
                    let period = SleepStager.Period(stage: "sleep", start: instant - 30, end: instant + 30)
                    for fallback in [-12 * 3600, 14 * 3600] {
                        XCTAssertEqual(SleepStager.isDaytimeCenter(period, tzOffsetSeconds: fallback, timezone: zone),
                                       expected, "\(zoneID) \(day) \(hour) \(delta)")
                        XCTAssertEqual(SleepStager.isOvernightOnset(instant, tzOffsetSeconds: fallback, timezone: zone),
                                       !expected)
                    }
                }
            }
        }
    }

    func testNegativeEpochFlooredModuloAndDistinctOnsetCenterInstants() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        for (instant, daytime) in [(-46_801, false), (-46_800, true), (-14_401, true), (-14_400, false), (-1, false)] {
            let period = SleepStager.Period(stage: "sleep", start: instant - 30, end: instant + 30)
            XCTAssertEqual(SleepStager.isDaytimeCenter(period, tzOffsetSeconds: 0), daytime)
            XCTAssertEqual(SleepStager.isDaytimeCenter(period, tzOffsetSeconds: 3600, timezone: utc), daytime)
            XCTAssertEqual(SleepStager.isOvernightOnset(instant, tzOffsetSeconds: 3600, timezone: utc), !daytime)
        }
        let zone = try XCTUnwrap(TimeZone(identifier: "Africa/Khartoum"))
        let start = F.ts("2000-01-15T08:30:00Z"), end = F.ts("2000-01-15T14:30:00Z")
        XCTAssertEqual(zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(start))), 7200)
        XCTAssertEqual(zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(start + (end - start) / 2))), 10800)
        XCTAssertTrue(SleepStager.isOvernightOnset(start, tzOffsetSeconds: 10800, timezone: zone))
        XCTAssertFalse(SleepStager.isOvernightOnset(start, tzOffsetSeconds: 10800))
        XCTAssertTrue(SleepStager.isDaytimeCenter(.init(stage: "sleep", start: start, end: end),
                                                tzOffsetSeconds: 0, timezone: zone))
    }

    func testActualSeventyMinuteBoundaryRunsChangeOnlyClockAdmissionForBothStagers() throws {
        print("W4 automatic sleep Foundation tzdb=\(TimeZone.timeZoneDataVersion)")
        for vector in F.boundaries {
            let zone = try XCTUnwrap(TimeZone(identifier: vector.zone)), raw = F.boundary(vector)
            for v2 in [false, true] {
                let named = F.traced(raw, offset: vector.staleOffset, zone: zone, v2: v2)
                let stale = F.traced(raw, offset: vector.staleOffset, v2: v2)
                XCTAssertEqual(named.sessions.count, vector.daytime ? 0 : 1, "\(vector.zone) \(vector.center) v2=\(v2)")
                XCTAssertEqual(stale.sessions.count, vector.daytime ? 1 : 0)
                let dropped = vector.daytime ? named : stale
                let kept = vector.daytime ? stale : named
                XCTAssertTrue(dropped.lines.contains { $0.contains("DROPPED gate=daytimeGuard") })
                XCTAssertTrue(kept.lines.contains { $0.contains("KEPT gate=accepted") && $0.contains("daytime=false") })
                let session = try XCTUnwrap(kept.sessions.first)
                XCTAssertGreaterThan(session.end - session.start, 60 * 60)
                XCTAssertLessThan(session.end - session.start, 90 * 60)
                XCTAssertEqual(F.detect(raw, offset: vector.staleOffset, zone: zone, v2: v2), named.sessions)
            }
        }
    }

    func testRealOvernightsPhysicallyCrossBothOneHourAndHalfHourTransitions() throws {
        let vectors = [
            ("America/Los_Angeles", "2026-03-08T08:00:00Z", 3600),
            ("America/Los_Angeles", "2026-11-01T07:00:00Z", -3600),
            ("Australia/Lord_Howe", "2026-10-03T13:30:00Z", 1800),
            ("Australia/Lord_Howe", "2026-04-04T13:00:00Z", -1800),
        ]
        for (zoneID, startText, shift) in vectors {
            let zone = try XCTUnwrap(TimeZone(identifier: zoneID)), start = F.ts(startText)
            var raw = F.Raw()
            raw.append(start: start, seconds: 6 * 3600, cardiac: true)
            let before = zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(start)))
            let after = zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(start + 6 * 3600 - 1)))
            XCTAssertEqual(after - before, shift)
            for v2 in [false, true] {
                let named = F.traced(raw, offset: before, zone: zone, v2: v2)
                let fixed = F.traced(raw, offset: after, v2: v2)
                XCTAssertEqual(named.sessions.count, 1)
                XCTAssertEqual(named.sessions, fixed.sessions, "clock shift must not stretch epoch physiology")
                XCTAssertEqual(named.lines, fixed.lines)
                XCTAssertEqual(F.detect(raw, offset: before, zone: zone, v2: v2), named.sessions)
                let session = try XCTUnwrap(named.sessions.first)
                XCTAssertEqual(session.end - session.start, 6 * 3600 - 1)
                XCTAssertEqual(session.stages.first?.start, session.start)
                // Epoch staging may end at the next 30-second grid edge, just as the fixed-offset control.
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(session.stages.last?.end), session.end)
                for pair in zip(session.stages, session.stages.dropFirst()) { XCTAssertEqual(pair.0.end, pair.1.start) }
            }
        }
    }

    func testNoonTransitionOnsetKeepsRealDaytimeTailThatWrongPostOffsetLoses() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Africa/Khartoum"))
        let start = F.ts("2000-01-15T08:30:00Z"), end = start + 6 * 3600, tailStart = end + 40 * 60
        var raw = F.Raw()
        raw.append(start: start - 8 * 3600, seconds: 8 * 3600, bpm: 80, active: true)
        raw.append(start: start, seconds: 6 * 3600, cardiac: true)
        raw.append(start: end, seconds: 40 * 60, bpm: 80, active: true)
        raw.append(start: tailStart, seconds: 70 * 60, bpm: 75, cardiac: true)
        for v2 in [false, true] {
            let named = F.traced(raw, offset: 10800, zone: zone, v2: v2)
            let wrongOnset = F.traced(raw, offset: 10800, v2: v2)
            XCTAssertEqual(named.sessions.count, 2, named.lines.joined(separator: "\n"))
            XCTAssertEqual(wrongOnset.sessions.count, 1, wrongOnset.lines.joined(separator: "\n"))
            XCTAssertEqual(named.sessions.first, wrongOnset.sessions.first)
            let first = try XCTUnwrap(named.sessions.first), tail = try XCTUnwrap(named.sessions.last)
            // Pinned from actual Swift dense rolling-window mechanics, not supplied session bounds.
            XCTAssertEqual(first.start, start + 181)
            XCTAssertEqual(first.end, end - 180)
            XCTAssertEqual(tail.start, tailStart + 181)
            XCTAssertEqual(tail.end, tailStart + 70 * 60 - 1)
            XCTAssertLessThan(tail.start - first.end, 90 * 60)
            XCTAssertGreaterThan(tail.end - tail.start, 60 * 60)
            XCTAssertLessThan(tail.end - tail.start, 90 * 60)
            XCTAssertTrue(named.lines.filter { $0.contains("KEPT gate=accepted") }.allSatisfy { $0.contains("daytime=true") })
            XCTAssertTrue(wrongOnset.lines.contains { $0.contains("DROPPED gate=daytimeGuard") })
            XCTAssertEqual(F.detect(raw, offset: 10800, zone: zone, v2: v2), named.sessions)
            print("W4 Khartoum v2=\(v2) first=\(first.start)..<\(first.end) tail=\(tail.start)..<\(tail.end)")
        }
    }

    func testActualSpringOvernightKeepsSplitTailPastDaytimeBand() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = F.ts("2026-03-08T08:00:00Z"), end = start + 10 * 3600
        var raw = F.Raw()
        raw.append(start: start, seconds: 10 * 3600)
        raw.append(start: end, seconds: 40 * 60, bpm: 70, active: true)
        raw.append(start: end + 40 * 60, seconds: 2 * 3600)
        XCTAssertEqual(zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(start))), -8 * 3600)
        XCTAssertEqual(zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(end))), -7 * 3600)
        for v2 in [false, true] {
            let actual = F.traced(raw, offset: -8 * 3600, zone: zone, v2: v2)
            XCTAssertEqual(actual.sessions.count, 2, actual.lines.joined(separator: "\n"))
            let first = try XCTUnwrap(actual.sessions.first), tail = try XCTUnwrap(actual.sessions.last)
            XCTAssertLessThan(tail.start - first.end, 90 * 60)
            XCTAssertTrue(SleepStager.isDaytimeCenter(.init(stage: "sleep", start: tail.start, end: tail.end),
                                                     tzOffsetSeconds: 0, timezone: zone))
            XCTAssertFalse(SleepStager.passesDaytimeGuard(.init(stage: "sleep", start: tail.start, end: tail.end),
                                                         restingHR: tail.restingHR, baseline: 50))
            XCTAssertTrue(actual.lines.contains { $0.contains("KEPT gate=accepted") && $0.contains("daytime=true") })
            XCTAssertEqual(actual.sessions, F.detect(raw, offset: -7 * 3600, v2: v2))
            XCTAssertEqual(actual.sessions, F.detect(raw, offset: -8 * 3600, zone: zone, v2: v2))
        }
    }

    func testElapsedContinuationMorningThresholdAndBandRescueRemainUnchanged() throws {
        let start = F.ts("2026-06-15T04:00:00Z"), end = start + 6 * 3600
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        func chain(gap: Int, tailHR: Int) -> F.Raw {
            var raw = F.Raw()
            raw.append(start: start - 8 * 3600, seconds: 8 * 3600, bpm: 80, active: true)
            raw.append(start: start, seconds: 6 * 3600)
            raw.append(start: end, seconds: gap * 60, bpm: 80, active: true)
            raw.append(start: end + gap * 60, seconds: 2 * 3600, bpm: tailHR)
            return raw
        }
        let tail = F.traced(chain(gap: 40, tailHR: 74), zone: utc)
        XCTAssertEqual(tail.sessions.count, 2, tail.lines.joined(separator: "\n"))
        let morningRaw = chain(gap: 120, tailHR: 74)
        let morning = F.traced(morningRaw, zone: utc)
        XCTAssertEqual(morning.sessions.count, 1)
        XCTAssertTrue(morning.lines.contains { $0.contains("DROPPED gate=morningStillness") })
        let band = stride(from: end + 120 * 60, to: end + 240 * 60, by: 30).map { (ts: $0, state: 2) }
        XCTAssertEqual(F.detect(morningRaw, zone: utc, band: band).count, 2)
        XCTAssertEqual(F.detect(chain(gap: 120, tailHR: 70), zone: utc).count, 2)
        XCTAssertEqual(F.detect(chain(gap: 200, tailHR: 74), zone: utc).count, 2)
        XCTAssertEqual(F.detect(morningRaw), morning.sessions, "explicit UTC cannot alter elapsed/H7 policy")
        var isolated = F.Raw()
        isolated.append(start: F.ts("2026-06-15T13:00:00Z"), seconds: 70 * 60)
        let noAnchor = F.traced(isolated, zone: utc)
        XCTAssertTrue(noAnchor.sessions.isEmpty)
        XCTAssertTrue(noAnchor.lines.contains { $0.contains("DROPPED gate=daytimeGuard") })
    }

    func testTimezoneIsPartOfCacheKeyAndTraceAlwaysExecutesBothStagers() throws {
        let vector = F.boundaries[0], raw = F.boundary(vector)
        let named = try XCTUnwrap(TimeZone(identifier: vector.zone))
        let fixed = try XCTUnwrap(TimeZone(secondsFromGMT: vector.staleOffset))
        let beforeTransition = Date(timeIntervalSince1970: Double(F.ts("2026-03-08T08:00:00Z")))
        XCTAssertEqual(named.secondsFromGMT(for: beforeTransition), fixed.secondsFromGMT(for: beforeTransition))
        for v2 in [false, true] {
            let a = F.traced(raw, offset: vector.staleOffset, zone: named, v2: v2)
            let b = F.traced(raw, offset: vector.staleOffset, zone: fixed, v2: v2)
            XCTAssertTrue(a.sessions.isEmpty)
            XCTAssertEqual(b.sessions.count, 1)
            for zone in [named, fixed, named] {
                let expected = zone == named ? a : b
                XCTAssertEqual(F.detect(raw, offset: vector.staleOffset, zone: zone, v2: v2), expected.sessions)
                let tracedAfterCache = F.traced(raw, offset: vector.staleOffset, zone: zone, v2: v2)
                XCTAssertEqual(tracedAfterCache.sessions, expected.sessions)
                XCTAssertEqual(tracedAfterCache.lines, expected.lines)
                XCTAssertTrue(tracedAfterCache.lines.contains { $0.contains("sleep-detect summary:") })
            }
            XCTAssertEqual(F.detect(raw, offset: vector.staleOffset, v2: v2), b.sessions)
            XCTAssertEqual(F.detect(raw, offset: 14 * 3600, zone: named, v2: v2), a.sessions)
            let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            XCTAssertEqual(F.traced(raw, zone: utc, v2: v2).sessions, F.traced(raw, v2: v2).sessions)
        }
    }

    func testExplicitZoneCannotBypassOffWristOrSixteenHourCap() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = F.ts("2026-03-08T08:00:00Z")
        var raw = F.Raw()
        raw.append(start: start, seconds: 6 * 3600)
        var lines: [String] = []
        XCTAssertTrue(F.detect(raw, zone: zone, wristOff: [(start, start + 4 * 3600)]) { lines.append($0) }.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("DROPPED gate=offWrist") })
        XCTAssertEqual(F.detect(raw, zone: zone, wristOff: [(start, start + 20 * 60)]).count, 1)
        var tooLong = F.Raw()
        tooLong.append(start: start, seconds: 17 * 3600)
        let capped = F.traced(tooLong, zone: zone)
        XCTAssertTrue(capped.sessions.isEmpty)
        XCTAssertTrue(capped.lines.contains { $0.contains("DROPPED gate=maxMainSleepSpanS") })
    }
}
