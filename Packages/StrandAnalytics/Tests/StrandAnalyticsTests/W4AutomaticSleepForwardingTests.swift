import Foundation
import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class W4AutomaticSleepForwardingTests: XCTestCase {
    private typealias F = W4AutomaticSleepFixtures

    private func analyze(_ raw: F.Raw, day: String, offset: Int = 0, zone: TimeZone? = nil,
                         bounds: Range<Int>? = nil, v2: Bool = false,
                         resolved: [SleepSession]? = nil, provided: [SleepSession] = [],
                         exclusions: Set<Int> = [], trace: ((String) -> Void)? = nil) -> AnalyticsEngine.DayResult {
        AnalyticsEngine.analyzeDay(day: day, hr: raw.hr, rr: raw.rr, resp: raw.resp,
            gravity: raw.gravity, steps: raw.steps, dayHr: raw.hr, daySteps: raw.steps,
            dayGravity: raw.gravity, profile: UserProfile(), tzOffsetSeconds: offset,
            useSleepStagerV2: v2, useMotionAwareWake: false, providedSleep: provided,
            traceSink: trace, resolvedSleep: resolved, excludedMainSleepStarts: exclusions,
            localDayBounds: bounds, timezone: zone)
    }

    private func bytes(_ result: AnalyticsEngine.DayResult) throws -> Data {
        try WholeDaySwiftParityExporter.bytes(WholeDaySwiftParityExporter.encode(result))
    }

    func testAutomaticForwardingUsesTrueZoneAndFullTracedDTOEqualsCachedBothStagers() throws {
        let vector = F.boundaries[1], raw = F.boundary(vector), day = "2026-11-01"
        let zone = try XCTUnwrap(TimeZone(identifier: vector.zone))
        let bounds = try DayCycleResolver.localDayBounds(day: day, timezone: zone)
        XCTAssertEqual(bounds.count, 25 * 3600)
        for v2 in [false, true] {
            let actual = analyze(raw, day: day, offset: vector.staleOffset, zone: zone, bounds: bounds, v2: v2)
            var lines: [String] = []
            let traced = analyze(raw, day: day, offset: vector.staleOffset, zone: zone, bounds: bounds, v2: v2) { lines.append($0) }
            let stale = analyze(raw, day: day, offset: vector.staleOffset, bounds: bounds, v2: v2)
            let direct = F.detect(raw, offset: vector.staleOffset, zone: zone, v2: v2)
            XCTAssertEqual(actual.sleepSessions.count, 1)
            XCTAssertTrue(stale.sleepSessions.isEmpty, "must exercise automatic forwarding, not supplied sessions")
            XCTAssertEqual(actual.sleepSessions, direct.filter { bounds.contains($0.end) })
            XCTAssertEqual(try bytes(actual), try bytes(traced))
            XCTAssertTrue(lines.contains { $0.contains("KEPT gate=accepted") })
            XCTAssertTrue(lines.contains { $0.contains("sleep-detect summary:") })
            XCTAssertEqual(try bytes(stale), try bytes(AnalyticsEngine.analyzeDay(day: day,
                hr: raw.hr, rr: raw.rr, resp: raw.resp, gravity: raw.gravity,
                steps: raw.steps, dayHr: raw.hr, daySteps: raw.steps, dayGravity: raw.gravity,
                profile: UserProfile(), tzOffsetSeconds: vector.staleOffset, useSleepStagerV2: v2,
                resolvedSleep: nil, localDayBounds: bounds)), "omitted engine timezone stays legacy")
        }
    }

    func testAuthoritativeEmptyAndMovedSetsBypassDetectionWithoutRemovingRawConsumers() throws {
        let day = "2026-11-01", zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let bounds = try DayCycleResolver.localDayBounds(day: day, timezone: zone)
        var raw = F.boundary(F.boundaries[1])
        let workout = F.ts("2026-11-02T01:00:00Z") // 17:00 on the same local day.
        raw.append(start: workout, seconds: 1800, bpm: 145, active: true)
        raw.steps = stride(from: 0, to: 1800, by: 10).map { .init(ts: workout + $0, counter: 100 + $0 * 2) }
        let detected = analyze(raw, day: day, offset: -7 * 3600, zone: zone, bounds: bounds)
        let old = try XCTUnwrap(detected.sleepSessions.first)
        var emptyLines: [String] = []
        let empty = analyze(raw, day: day, offset: -7 * 3600, zone: zone, bounds: bounds,
                            resolved: [], provided: [old]) { emptyLines.append($0) }
        XCTAssertTrue(empty.sleepSessions.isEmpty)
        XCTAssertNil(empty.daily.totalSleepMin)
        XCTAssertNil(empty.restScore)
        XCTAssertFalse(empty.workouts.isEmpty)
        XCTAssertEqual(empty.daily.steps, 3580)
        XCTAssertEqual(empty.detectionFunnel?.hrSamples, raw.hr.count)
        XCTAssertFalse(emptyLines.contains { $0.contains("sleep-detect") || $0.contains("gate=accepted") })
        let profile = UserProfile(), maxHR = StrainScorer.tanakaHRmax(age: profile.age)
        XCTAssertEqual(empty.strain, StrainScorer.strain(raw.hr, maxHR: maxHR,
            restingHR: StrainScorer.defaultRestingHR, method: .edwards, sex: profile.sex))

        let movedStart = old.start + 600, movedEnd = old.end - 600
        let moved = SleepSession(start: movedStart, end: movedEnd, efficiency: 1,
            stages: [.init(start: movedStart, end: movedEnd, stage: "light")], restingHR: nil, avgHRV: nil)
        var movedLines: [String] = []
        let actual = analyze(raw, day: day, offset: -7 * 3600, zone: zone, bounds: bounds,
                             resolved: [moved], provided: [old]) { movedLines.append($0) }
        let only = try XCTUnwrap(actual.sleepSessions.first)
        XCTAssertEqual(actual.sleepSessions.count, 1)
        XCTAssertEqual(only.start, movedStart)
        XCTAssertEqual(only.end, movedEnd)
        XCTAssertEqual(only.stages, moved.stages)
        XCTAssertEqual(only.restingHR, SleepStager.sessionRestingHR(start: movedStart, end: movedEnd, hr: raw.hr))
        XCTAssertEqual(only.avgHRV, SleepStager.sessionAvgHRV(start: movedStart, end: movedEnd, rr: raw.rr))
        XCTAssertNotEqual(only.start, old.start)
        XCTAssertEqual(actual.daily.steps, empty.daily.steps)
        XCTAssertFalse(actual.workouts.isEmpty)
        XCTAssertFalse(movedLines.contains { $0.contains("sleep-detect") || $0.contains("gate=accepted") })
        XCTAssertEqual(raw.hr.count, 6000)
        XCTAssertEqual(raw.gravity.count, 6000)
        XCTAssertEqual(raw.rr.count, 4200)
    }

    func testResolvedMainExclusionsRetainOriginalIndicesUnderExplicitZone() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")), day = "2026-11-01"
        let bounds = try DayCycleResolver.localDayBounds(day: day, timezone: zone)
        let raw = F.boundary(F.boundaries[1])
        func session(_ start: String, minutes: Int, rhr: Int) -> SleepSession {
            let s = F.ts(start), e = s + minutes * 60
            return SleepSession(start: s, end: e, efficiency: 1,
                stages: [.init(start: s, end: e, stage: "light")], restingHR: rhr, avgHRV: 40)
        }
        let first = session("2026-11-01T08:00:00Z", minutes: 60, rhr: 55)
        let second = session("2026-11-01T09:20:00Z", minutes: 40, rhr: 56)
        let nap = session("2026-11-01T22:00:00Z", minutes: 120, rhr: 42)
        let supplied = [nap, second, first]
        var lines: [String] = []
        let result = analyze(raw, day: day, offset: 0, zone: zone, bounds: bounds,
                             resolved: supplied, exclusions: [nap.start]) { lines.append($0) }
        XCTAssertEqual(result.sleepSessions, supplied)
        XCTAssertEqual(result.daily.totalSleepMin, 100)
        XCTAssertEqual(try XCTUnwrap(result.daily.efficiency), 100.0 / 120.0, accuracy: 1e-12)
        XCTAssertEqual(result.daily.disturbances, 1)
        XCTAssertEqual(result.daily.restingHr, 42)
        XCTAssertFalse(lines.contains { $0.contains("sleep-detect") })
    }

    func testExplicitBoundsRemainIndependentAndEndMembershipIsHalfOpen() throws {
        let vector = F.boundaries[1], raw = F.boundary(vector)
        let zone = try XCTUnwrap(TimeZone(identifier: vector.zone)), day = "2026-11-01"
        let session = try XCTUnwrap(F.detect(raw, offset: vector.staleOffset, zone: zone).first)
        let excluded = analyze(raw, day: day, offset: vector.staleOffset, zone: zone,
                               bounds: session.start..<session.end)
        let admitted = analyze(raw, day: day, offset: vector.staleOffset, zone: zone,
                               bounds: session.start..<(session.end + 1))
        XCTAssertTrue(excluded.sleepSessions.isEmpty)
        XCTAssertEqual(admitted.sleepSessions, [session])
        let differentDay = "2026-11-02"
        XCTAssertTrue(analyze(raw, day: differentDay, offset: 0, zone: zone).sleepSessions.isEmpty,
                      "zone cannot silently derive or override membership")
        XCTAssertEqual(analyze(raw, day: differentDay, offset: 0, zone: zone,
            bounds: session.start..<(session.end + 1)).sleepSessions, [session])
    }
}
