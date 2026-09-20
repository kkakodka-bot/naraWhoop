import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

final class SleepEvidenceTests: XCTestCase {
    struct Fixture: Decodable { let name: String; let segments: [StageSegment]; let sleepSeconds: Int; let knownSeconds: Int }
    func testSharedEvidenceOracle() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sleep_evidence_oracle", withExtension: "json", subdirectory: "Resources"))
        for f in try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url)) {
            let segments = SleepStageSemantics.normalized(f.segments, start: 0, end: 120)
            XCTAssertEqual(segments.reduce(0) { $0 + $1.end - $1.start }, 120, f.name)
            XCTAssertEqual(segments.filter(SleepStageSemantics.isSleep).reduce(0) { $0 + $1.end - $1.start }, f.sleepSeconds, f.name)
            let json = try XCTUnwrap(AnalyticsEngine.encodeStages(segments))
            XCTAssertEqual(AnalyticsEngine.decodeStages(json), segments, f.name)
            XCTAssertEqual(HypnogramCoverage.fraction(stagesJSON: json, spanSeconds: 120), Double(f.knownSeconds) / 120, f.name)
            let totals = try XCTUnwrap(SleepStageTotals.minutes(fromStagesJSON: json))
            XCTAssertEqual(totals.asleep * 60, Double(f.sleepSeconds), accuracy: 1e-9, f.name)
            XCTAssertEqual(totals.inBed * 60, 120, accuracy: 1e-9, f.name)
            XCTAssertEqual(SleepStageTotals.dailyAggregate([json]) == nil, f.knownSeconds == 0, f.name)
        }
    }
    func testEmptyAndInteriorMissingEpochsAbstain() {
        XCTAssertFalse(SleepStagerV2.stageSession(start: 0, end: 180, grav: [], hr: [], rr: [], resp: []).contains(where: SleepStageSemantics.isSleep))
        let hr = (Array(0..<60) + Array(120..<180)).map { HRSample(ts: $0, bpm: 55) }
        let segments = SleepStagerV2.stageSession(start: 0, end: 180, grav: [], hr: hr, rr: [], resp: [])
        for t in 60..<120 { XCTAssertEqual(segments.first { $0.start <= t && t < $0.end }?.state, "state_unknown") }
    }
    func testIndependentContextAndCausalFutureInvariance() {
        let base = [StageSegment(start: 0, end: 120, stage: "light")]
        let context = [SleepContextSpan(start: 0, end: 30, kind: "reading", provenance: "user", availableAt: 0),
                       SleepContextSpan(start: 30, end: 60, kind: "off_body", provenance: "event", availableAt: 30),
                       SleepContextSpan(start: 60, end: 90, kind: "sleep", provenance: "qualified_binary", qualifiedBinarySleep: true, availableAt: 60)]
        let causal = SleepStageSemantics.applyingContext(base, start: 0, end: 120, context: context, mode: "causal", observedThrough: 90)
        XCTAssertEqual(causal.map(\.state), ["awake", "off_body", "sleep_unstaged", "state_unknown"])
        let future = SleepStageSemantics.applyingContext([StageSegment(start: 0, end: 120, stage: "rem")], start: 0, end: 120,
            context: context + [SleepContextSpan(start: 0, end: 120, kind: "phone_use", provenance: "late_report", availableAt: 121)], mode: "causal", observedThrough: 90)
        XCTAssertEqual(causal, future)
        let reportOnly = SleepStageSemantics.applyingContext([], start: 0, end: 120,
            context: [SleepContextSpan(start: 0, end: 120, kind: "sleep", provenance: "manual")])
        XCTAssertFalse(reportOnly.contains(where: SleepStageSemantics.isSleep))
        let reading = SleepStageSemantics.applyingContext(base, start: 0, end: 120, context: context)
        XCTAssertEqual(reading.first?.state, "awake")
    }
    func testUnknownDayIsUnavailableAndLateShiftSleepUsesExactDayBounds() {
        let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
        let start = AnalyticsEngine.dayStartUtcSeconds("2026-11-01")
        let unknown = SleepSession(start: start + 3600, end: start + 7200, efficiency: 1, stages: [], restingHR: nil, avgHRV: nil)
        XCTAssertNil(AnalyticsEngine.analyzeDay(day: "2026-11-01", profile: profile, providedSleep: [unknown]).daily.totalSleepMin)
        let lo = start + 4 * 3600, end = lo + 25 * 3600
        let nap = SleepSession(start: end - 3600, end: end - 60, efficiency: 1,
            stages: [StageSegment(start: end - 3600, end: end - 60, stage: "light")], restingHR: nil, avgHRV: nil,
            boundaryProvenance: "manual_boundary")
        let result = AnalyticsEngine.analyzeDay(day: "2026-11-01", profile: profile, providedSleep: [nap], localDayStart: lo, localDayEndExclusive: end)
        XCTAssertEqual(result.sleepSessions.count, 1)
        XCTAssertEqual(result.sleepSessions.first?.boundaryProvenance, "manual_boundary")
        XCTAssertEqual(result.daily.totalSleepMin, 59)
    }

    func testInvalidHrAndGravityDoNotCreateEvidenceInEitherStager() {
        let hr = (0..<3600).map { HRSample(ts: $0,bpm: [0,-1,241][$0%3]) }
        let gravity = (0..<3600).map { GravitySample(ts: $0,
            x: [0,Double.nan,Double.infinity,Double.greatestFiniteMagnitude][$0%4],y: 0,z: 0) }
        for v2 in [false,true] {
            let stages = v2 ? SleepStagerV2.stageSession(start: 0,end: 3600,grav: gravity,hr: hr,rr: [],resp: [])
                : SleepStager.stageSession(start: 0,end: 3600,grav: gravity,hr: hr,rr: [],resp: [])
            XCTAssertEqual(stages.reduce(0) { $0+$1.end-$1.start },3600)
            XCTAssertTrue(stages.allSatisfy { $0.state == "state_unknown" && $0.evidenceCoverage == 0 })
        }
    }

    func testInvalidPlaceholdersCannotChangeSparseFeaturesOrCachedResults() {
        let hr = stride(from: 0,to: 3600,by: 5).map { HRSample(ts: $0,bpm: 55) }
        let gravity = hr.map { GravitySample(ts: $0.ts,x: 0,y: 0,z: 1) }
        let placeholders = (0..<3600).filter { $0%5 != 0 }
        let dirtyHr = (hr+placeholders.map { HRSample(ts: $0,bpm: 0) }).sorted { $0.ts < $1.ts }
        let dirtyGravity = (gravity+placeholders.map { GravitySample(ts: $0,
            x: $0%2 == 0 ? Double.nan : 0,y: 0,z: 0) }).sorted { $0.ts < $1.ts }
        for v2 in [false,true] {
            func stage(_ h: [HRSample],_ g: [GravitySample]) -> [StageSegment] {
                v2 ? SleepStagerV2.stageSession(start: 0,end: 3600,grav: g,hr: h,rr: [],resp: [])
                    : SleepStager.stageSession(start: 0,end: 3600,grav: g,hr: h,rr: [],resp: [])
            }
            let clean = stage(hr,gravity)
            XCTAssertEqual(stage(dirtyHr,dirtyGravity),clean)
            XCTAssertEqual(stage(hr,gravity),clean)
            if v2 { XCTAssertTrue(clean.allSatisfy { $0.state == "state_unknown" && $0.evidenceCoverage == 0.2 }) }
        }
    }
}
