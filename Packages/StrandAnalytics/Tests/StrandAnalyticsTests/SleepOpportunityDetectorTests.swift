import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class SleepOpportunityDetectorTests: XCTestCase {
    private var day: Int { AnalyticsEngine.dayStartUtcSeconds("2026-09-17") }
    private var nap: Int { day+15*3600 }
    private func hr(_ sleep: [Range<Int>]) -> [HRSample] {
        stride(from: day,to: day+86400,by: 5).map { t in HRSample(ts: t,bpm: sleep.contains { $0.contains(t) } ? 55 : 80) }
    }
    private func gravity() -> [GravitySample] {
        stride(from: day,to: day+86400,by: 5).map { GravitySample(ts: $0,x: 0,y: 0,z: 1) }
    }
    func testTwentyMinuteAfternoonNapAndDaytimeShiftSleepHaveNoTimeOfDayGate() {
        let ranges = [(day+8*3600)..<(day+13*3600),nap..<(nap+1200)]
        let out = SleepOpportunityDetector.detect(start: day,end: day+86400,hr: hr(ranges),gravity: gravity())
        XCTAssertEqual(out.episodes.map(\.start),ranges.map(\.lowerBound))
        XCTAssertEqual(out.episodes.map(\.end),ranges.map(\.upperBound))
        XCTAssertTrue(out.episodes.last!.stages.allSatisfy { $0.state == "sleep_unstaged" && $0.sleepProbability == nil })
        XCTAssertEqual(out.referenceHr,80)
    }
    func testReadingPhoneUseAndOffBodyAreNotNapsAndStillnessAloneIsUnknown() {
        for kind in ["reading","phone_use","off_body"] {
            let out = SleepOpportunityDetector.detect(start: day,end: day+86400,hr: hr([nap..<(nap+1200)]),gravity: gravity(),
                context: [SleepContextSpan(start: nap,end: nap+1200,kind: kind,provenance: "independent_annotation")])
            XCTAssertTrue(out.episodes.isEmpty)
            XCTAssertEqual(out.epochs.first { $0.start == nap }?.state,kind == "off_body" ? "off_body" : "awake")
        }
        XCTAssertTrue(SleepOpportunityDetector.detect(start: day,end: day+86400,hr: hr([]),gravity: gravity()).episodes.isEmpty)
    }
    func testMissingMotionBreaksRunAndDuplicateBurstCannotInventCoverage() {
        let low = hr([nap..<(nap+1200)])
        XCTAssertTrue(SleepOpportunityDetector.detect(start: day,end: day+86400,hr: low,gravity: []).episodes.isEmpty)
        let gap = gravity().filter { !((nap+300)..<(nap+900)).contains($0.ts) }
        XCTAssertTrue(SleepOpportunityDetector.detect(start: day,end: day+86400,hr: low,gravity: gap).episodes.isEmpty)
        let burst = Array(repeating: GravitySample(ts: nap,x: 0,y: 0,z: 1),count: 100)
        XCTAssertTrue(SleepOpportunityDetector.detect(start: day,end: day+86400,hr: low,gravity: burst).episodes.isEmpty)
        let dynStill = stride(from: day,to: day+86400,by: 5).map { GravitySample(ts: $0,x: 0,y: 0,z: 0,dynAccel: 0) }
        let dynOut = SleepOpportunityDetector.detect(start: day,end: day+86400,hr: low,gravity: dynStill)
        XCTAssertEqual(dynOut.episodes.map(\.start), [nap])
        XCTAssertEqual(dynOut.episodes.map(\.end), [nap+1200])
    }
    func testEngineKeepsNapSeparateAndCausalModeCannotRunRetrospectiveDetector() {
        let ranges = [(day+3600)..<(day+5*3600),nap..<(nap+1200)]
        let profile = UserProfile(weightKg: 70,heightCm: 170,age: 30,sex: "nonbinary")
        let out = AnalyticsEngine.analyzeDay(day: "2026-09-17",hr: hr(ranges),gravity: gravity(),profile: profile,
            useFullDaySleepOpportunities: true)
        XCTAssertEqual(out.sleepSessions.map(\.episodeType),["main_sleep","nap"])
        XCTAssertEqual(out.sleepSessions.last?.start,nap)
        let causal = AnalyticsEngine.analyzeDay(day: "2026-09-17",hr: hr(ranges),gravity: gravity(),profile: profile,
            sleepComputationMode: "causal",sleepObservedThrough: nap,useFullDaySleepOpportunities: true)
        XCTAssertTrue(causal.sleepSessions.isEmpty)
    }
    func testNapsOnlyDayCannotBecomeMainSleepOrNocturnalHrvContext() {
        let profile = UserProfile(weightKg: 70,heightCm: 170,age: 30,sex: "nonbinary")
        let out = AnalyticsEngine.analyzeDay(day: "2026-09-17",hr: hr([nap..<(nap+1200)]),gravity: gravity(),
            profile: profile,useFullDaySleepOpportunities: true)
        XCTAssertEqual(out.sleepSessions.first?.episodeType,"nap")
        XCTAssertNil(out.hrvNightSummary)
        XCTAssertFalse(out.hrvMeasurements.contains { $0.context == "sleep" })
    }
    func testGroupedOpportunityPreservesAwakeOffBodyAndMissingInterruptionsWithoutAddingSleep() {
        let sleep = (day+3600)..<(day+5*3600), gap = (day+2*3600)..<(day+2*3600+1800)
        let profile = UserProfile(weightKg: 70,heightCm: 170,age: 30,sex: "nonbinary")
        for kind in ["reading","off_body","missing"] {
            let context = kind == "missing" ? [] : [SleepContextSpan(start: gap.lowerBound,end: gap.upperBound,kind: kind,provenance: "independent_annotation")]
            let motion = gravity().filter { kind != "missing" || !gap.contains($0.ts) }
            let result = AnalyticsEngine.analyzeDay(day: "2026-09-17",hr: hr([sleep]),gravity: motion,profile: profile,
                sleepContext: context,useFullDaySleepOpportunities: true)
            let main = result.sleepSessions.filter { $0.episodeType == "main_sleep" }
            XCTAssertEqual(main.count,2)
            XCTAssertEqual(main.last?.start,main.first?.end)
            let epochs = main.flatMap(\.stages)
            let interrupted = epochs.filter { $0.start >= gap.lowerBound && $0.end <= gap.upperBound }
            XCTAssertEqual(interrupted.reduce(0) { $0+$1.end-$1.start },1800)
            let expected = kind == "reading" ? "awake" : kind == "off_body" ? "off_body" : "state_unknown"
            XCTAssertTrue(interrupted.allSatisfy { $0.state == expected })
            XCTAssertEqual(epochs.filter(SleepStageSemantics.isSleep).reduce(0) { $0+$1.end-$1.start },12600)
            XCTAssertFalse(result.hrvMeasurements.filter { $0.start >= gap.lowerBound && $0.end <= gap.upperBound }.contains { $0.context == "sleep" })
        }
    }

    func testSharedFullDayGroupingOracleQualifiesBeforeRanking() throws {
        struct Fixture: Decodable {
            let name: String
            let sleep_ranges: [[Int]]
            let main_indices: [Int]
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sleep_group_selection_oracle", withExtension: "json", subdirectory: "Resources"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        let profile = UserProfile(weightKg: 70,heightCm: 170,age: 30,sex: "nonbinary")
        for fixture in fixtures {
            let ranges = fixture.sleep_ranges.map { (day+$0[0])..<(day+$0[1]) }
            for v2 in [false,true] {
                let result = AnalyticsEngine.analyzeDay(day: "2026-09-17",hr: hr(ranges),gravity: gravity(),
                    profile: profile,useSleepStagerV2: v2,useFullDaySleepOpportunities: true)
                XCTAssertEqual(result.sleepSessions.count,ranges.count,fixture.name)
                XCTAssertEqual(result.sleepSessions.indices.filter { result.sleepSessions[$0].episodeType == "main_sleep" },
                               fixture.main_indices,fixture.name)
                if fixture.main_indices.isEmpty { XCTAssertNil(result.daily.totalSleepMin) }
                else { XCTAssertEqual(result.daily.totalSleepMin,
                    Double(fixture.main_indices.reduce(0) { $0+ranges[$1].count })/60) }
            }
        }
    }

    func testMainGroupQualificationCountsSleepRatherThanEditedOpportunityDuration() {
        let longUncertain = SleepSession(start: day+3600,end: day+5*3600,efficiency: 0,stages: [
            StageSegment(start: day+3600,end: day+2*3600,stage: "light"),
            SleepStageSemantics.unknown(start: day+2*3600,end: day+5*3600)],restingHR: nil,avgHRV: nil)
        let shift = SleepSession(start: day+13*3600,end: day+15*3600,efficiency: 1,stages: [
            StageSegment(start: day+13*3600,end: day+15*3600,stage: "light")],restingHR: nil,avgHRV: nil)
        XCTAssertEqual(SleepOpportunityDetector.mainSleepGroupIndices([longUncertain,shift],offsetSeconds: 0),[1])
    }
}
