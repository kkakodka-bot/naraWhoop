import Foundation
import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class W4ResolvedSleepSeamTests: XCTestCase {
    private let day = "2026-06-15"
    private let midnight = 1_781_481_600

    private struct Signals {
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        var gravity: [GravitySample] = []
        var steps: [StepSample] = []
    }

    private func rawSignals() -> Signals {
        var raw = Signals()
        for i in 0..<7_200 {
            let ts = midnight + 3_600 + i
            raw.hr.append(.init(ts: ts, bpm: 50))
            raw.rr.append(.init(ts: ts, rrMs: 1000 + [0, 40, 0, -40][i % 4]))
            raw.gravity.append(.init(ts: ts, x: 0, y: 0, z: 1))
        }
        for i in 0..<1_800 {
            let ts = midnight + 17 * 3_600 + i
            raw.hr.append(.init(ts: ts, bpm: 145 + (i / 60) % 7))
            raw.gravity.append(.init(ts: ts, x: Double(i % 2) * 0.5, y: 0, z: 1))
            if i % 10 == 0 { raw.steps.append(.init(ts: ts, counter: 100 + i * 2)) }
        }
        return raw
    }

    private func analyze(_ raw: Signals, provided: [SleepSession] = [], resolved: [SleepSession]? = nil,
                         exclusions: Set<Int> = [], refine: Bool = false) -> AnalyticsEngine.DayResult {
        AnalyticsEngine.analyzeDay(day: day, hr: raw.hr, rr: raw.rr, gravity: raw.gravity,
            steps: raw.steps, dayHr: raw.hr, daySteps: raw.steps, dayGravity: raw.gravity,
            profile: UserProfile(), useMotionAwareWake: refine, providedSleep: provided,
            resolvedSleep: resolved, excludedMainSleepStarts: exclusions)
    }

    private func session(_ start: Int, _ end: Int, rhr: Int? = 50, hrv: Double? = 40,
                         staged: Bool = true, hrOnly: Bool = false) -> SleepSession {
        SleepSession(start: start, end: end, efficiency: staged ? 1 : 0,
            stages: staged ? [.init(start: start, end: end, stage: "light")] : [],
            restingHR: rhr, avgHRV: hrv, hrOnly: hrOnly)
    }

    private func assertNoSleepDuration(_ result: AnalyticsEngine.DayResult,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(result.daily.totalSleepMin, file: file, line: line)
        XCTAssertNil(result.daily.efficiency, file: file, line: line)
        XCTAssertNil(result.daily.deepMin, file: file, line: line)
        XCTAssertNil(result.daily.remMin, file: file, line: line)
        XCTAssertNil(result.daily.lightMin, file: file, line: line)
        XCTAssertNil(result.daily.disturbances, file: file, line: line)
        XCTAssertNil(result.restScore, file: file, line: line)
    }

    func testExplicitDismissalSuppressesDetectionButRetainsRawDrivenWorkoutsAndActivity() throws {
        let raw = rawSignals()
        let before = analyze(raw)
        XCTAssertEqual(before.sleepSessions.count, 1, "raw control must detect sleep")
        let dismissed = analyze(raw, provided: before.sleepSessions, resolved: [], refine: true)
        XCTAssertTrue(dismissed.sleepSessions.isEmpty)
        assertNoSleepDuration(dismissed)
        XCTAssertNil(dismissed.daily.restingHr)
        XCTAssertNil(dismissed.daily.avgHrv)
        XCTAssertTrue(dismissed.sessionMotionByStart.isEmpty)
        XCTAssertFalse(dismissed.workouts.isEmpty, "suppressing sleep must not delete the raw motion input")
        XCTAssertEqual(dismissed.daily.steps, 3_580)
        XCTAssertEqual(dismissed.detectionFunnel?.hrSamples, raw.hr.count)
        let profile = UserProfile(), maxHR = StrainScorer.tanakaHRmax(age: profile.age)
        XCTAssertEqual(dismissed.strain, StrainScorer.strain(raw.hr, maxHR: maxHR,
            restingHR: StrainScorer.defaultRestingHR, method: .edwards, sex: profile.sex))
        XCTAssertEqual(dismissed.daily.activeKcalEst,
            Calories.estimateDayCalories(raw.hr, profile: profile, hrmax: maxHR, restingHR: nil))
        XCTAssertEqual(raw.hr.count, 9_000)
        XCTAssertEqual(raw.gravity.count, 9_000)
        XCTAssertEqual(raw.rr.count, 7_200)
    }

    func testMovedOnlySetRemovesOldDetectionAndEnrichesFromUnchangedRawSignals() throws {
        var raw = rawSignals()
        let detected = analyze(raw)
        let old = try XCTUnwrap(detected.sleepSessions.first)
        let start = midnight + 5 * 3_600, end = start + 1_800
        for ts in start..<end {
            raw.hr.append(.init(ts: ts, bpm: 47))
            raw.rr.append(.init(ts: ts, rrMs: 1000 + (ts % 2) * 20))
            raw.gravity.append(.init(ts: ts, x: 0, y: 0, z: 1))
        }
        raw.hr.sort { $0.ts < $1.ts }; raw.rr.sort { $0.ts < $1.ts }; raw.gravity.sort { $0.ts < $1.ts }
        let moved = session(start, end, rhr: nil, hrv: nil)
        let actual = analyze(raw, provided: [old], resolved: [moved], refine: true)
        XCTAssertEqual(actual.sleepSessions.count, 1)
        let only = try XCTUnwrap(actual.sleepSessions.first)
        XCTAssertEqual(only.start, start)
        XCTAssertEqual(only.end, end)
        XCTAssertEqual(only.stages, moved.stages)
        XCTAssertEqual(only.efficiency, moved.efficiency)
        XCTAssertEqual(only.restingHR, SleepStager.sessionRestingHR(start: start, end: end, hr: raw.hr))
        XCTAssertEqual(only.avgHRV, SleepStager.sessionAvgHRV(start: start, end: end, rr: raw.rr))
        XCTAssertEqual(only.restingHR, 47)
        XCTAssertNotNil(only.avgHRV)
        XCTAssertFalse(actual.sleepSessions.contains { $0.start == old.start })
        XCTAssertNotNil(actual.sessionMotionByStart[start])
        XCTAssertFalse(actual.workouts.isEmpty)
        XCTAssertEqual(actual.daily.steps, 3_580)
    }

    func testNilResolvedKeepsSupplementalProvidedNapAndDetectedNight() throws {
        let raw = rawSignals(), detected = analyze(raw)
        let nap = session(midnight + 12 * 3_600, midnight + 12 * 3_600 + 1_800)
        let actual = analyze(raw, provided: [nap])
        XCTAssertEqual(actual.sleepSessions, detected.sleepSessions + [nap])
        let direct = AnalyticsEngine.analyzeDay(day: day, hr: raw.hr, rr: raw.rr, gravity: raw.gravity,
            steps: raw.steps, dayHr: raw.hr, daySteps: raw.steps, dayGravity: raw.gravity,
            profile: UserProfile(), providedSleep: [nap])
        XCTAssertEqual(try WholeDaySwiftParityExporter.bytes(WholeDaySwiftParityExporter.encode(actual)),
                       try WholeDaySwiftParityExporter.bytes(WholeDaySwiftParityExporter.encode(direct)))
    }

    func testMainExclusionMapsOriginalIndicesAndRetainsNapPhysiology() throws {
        let raw = rawSignals()
        let first = session(midnight + 3_600, midnight + 7_200, rhr: 55, hrv: 30)
        let second = session(midnight + 8_400, midnight + 10_800, rhr: 56, hrv: 40)
        let nap = session(midnight + 14 * 3_600, midnight + 16 * 3_600, rhr: 42, hrv: 100)
        let input = [nap, second, first] // filtered candidates [1,2] must not be used as indices [0,1]
        let baseline = analyze(raw, resolved: input)
        let actual = analyze(raw, resolved: input, exclusions: [nap.start])
        XCTAssertEqual(actual.sleepSessions, input)
        XCTAssertEqual(actual.daily.totalSleepMin, 100)
        XCTAssertEqual(try XCTUnwrap(actual.daily.efficiency), 100.0 / 120.0, accuracy: 1e-12)
        XCTAssertEqual(actual.daily.disturbances, 1)
        XCTAssertEqual(actual.daily.restingHr, 42)
        XCTAssertEqual(actual.daily.avgHrv, baseline.daily.avgHrv)
        XCTAssertEqual(actual.daily.avgSdnn, baseline.daily.avgSdnn)
        XCTAssertEqual(actual.sessionMotionByStart, baseline.sessionMotionByStart)
        XCTAssertEqual(actual.workouts, baseline.workouts)
    }

    func testAllMainCandidatesExcludedLeaveSessionsAndPhysiologyButNoSleepDuration() throws {
        let raw = rawSignals()
        let nap = session(midnight + 3_600, midnight + 7_200, rhr: nil, hrv: nil)
        let actual = analyze(raw, resolved: [nap], exclusions: [nap.start])
        XCTAssertEqual(actual.sleepSessions.count, 1)
        assertNoSleepDuration(actual)
        XCTAssertEqual(actual.daily.restingHr, 50)
        XCTAssertNotNil(actual.daily.avgHrv)
        XCTAssertNotNil(actual.sessionMotionByStart[nap.start])
        XCTAssertFalse(actual.workouts.isEmpty)
    }

    func testUnstagedAuthoritativeIntervalIsUnavailableWithoutInventingStages() throws {
        let raw = rawSignals()
        let interval = session(midnight + 3_600, midnight + 7_200, rhr: nil, hrv: nil, staged: false, hrOnly: true)
        let actual = analyze(raw, resolved: [interval])
        assertNoSleepDuration(actual)
        XCTAssertTrue(try XCTUnwrap(actual.sleepSessions.first).stages.isEmpty)
        XCTAssertEqual(actual.sleepSessions.first?.hrOnly, true)
        XCTAssertEqual(actual.daily.restingHr, 50)
        XCTAssertNotNil(actual.daily.avgHrv)
        let legacyProvided = analyze(raw, provided: [interval])
        XCTAssertEqual(legacyProvided.daily.totalSleepMin, 0, "default evidence semantics must remain historical")
        XCTAssertEqual(legacyProvided.daily.efficiency, 0)
    }

    func testExcludedStagedNapCannotSupplyEvidenceForUnstagedMain() {
        let raw = rawSignals()
        let main = session(midnight + 3_600, midnight + 10_800, staged: false)
        let nap = session(midnight + 14 * 3_600, midnight + 15 * 3_600)
        let actual = analyze(raw, resolved: [nap, main], exclusions: [nap.start])
        assertNoSleepDuration(actual)
        XCTAssertEqual(actual.sleepSessions, [nap, main])
    }

    func testResolvedPreservesSuppliedPhysiologyAndHROnlyPreference() {
        let raw = rawSignals()
        let primary = session(midnight + 3_600, midnight + 7_200, rhr: 57, hrv: 31)
        let hrOnly = session(midnight + 8_400, midnight + 10_800, rhr: 40, hrv: 100, hrOnly: true)
        let actual = analyze(raw, resolved: [hrOnly, primary], exclusions: [hrOnly.start])
        XCTAssertEqual(actual.sleepSessions, [hrOnly, primary])
        XCTAssertEqual(actual.daily.restingHr, 57, "motion-backed physiology remains preferred")
        XCTAssertEqual(actual.daily.avgHrv, 31)
        XCTAssertEqual(actual.daily.sleepHrOnly, false)
    }
}
