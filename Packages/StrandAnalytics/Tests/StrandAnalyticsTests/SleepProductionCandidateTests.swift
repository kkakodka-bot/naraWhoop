import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class SleepProductionCandidateTests: XCTestCase {
    private func session(_ start: Int,_ span: Int,_ accepted: Int) -> SleepSession {
        SleepSession(start: start,end: start+span,efficiency: Double(accepted)/Double(span),
            stages: [StageSegment(start: start,end: start+accepted,stage: "unknown",state: "sleep_unstaged")],
            restingHR: nil,avgHRV: nil)
    }

    func testAcceptedDurationWinsOverColdStartClockAndOuterSpanForRotatingSchedules() {
        for offset in [0,7*3600,-8*3600] {
            let sessions=[session(3600,8*3600,2*3600),session(13*3600,3*3600,3*3600)]
            XCTAssertEqual(SleepOpportunityDetector.mainSleepGroupIndices(sessions,offsetSeconds: offset),[1])
            XCTAssertEqual(SleepOpportunityDetector.mainSleepGroupIndices(sessions,offsetSeconds: offset,
                habitualMidsleepSec: 3*3600+1800),[1])
        }
        let split=[session(8*3600,3600,3600),session(9*3600+1800,3600,3600)]
        XCTAssertEqual(SleepOpportunityDetector.mainSleepGroupIndices(split,offsetSeconds: 0),[0,1])
    }

    func testStageWakeCannotRevokeBinarySleepOrMainSelection() {
        let disagreement=StageSegment(start: 0,end: 7200,stage: "wake",state: "sleep")
        XCTAssertTrue(SleepStageSemantics.isSleep(disagreement))
        XCTAssertTrue(SleepStageSemantics.isKnownState(StageSegment(start: 0,end: 30,stage: "unknown",state: "awake")))
        let original=SleepSession(start: 0,end: 7200,efficiency: 1,stages: [disagreement],restingHR: nil,avgHRV: nil)
        XCTAssertEqual(SleepOpportunityDetector.mainSleepGroupIndices([original],offsetSeconds: 0),[0])
        let staged=SleepOpportunityDetector.stagesPreservingBinarySleep([
            StageSegment(start: 0,end: 7200,stage: "wake",state: "awake")],start: 0,end: 7200)
        XCTAssertTrue(staged.allSatisfy { $0.stage=="unknown" && $0.state=="sleep_unstaged" &&
            $0.abstentionReason=="stage_binary_disagreement" })
        let binary=SleepSession(start: 0,end: 7200,efficiency: 1,stages: staged,restingHR: nil,avgHRV: nil)
        XCTAssertEqual(SleepOpportunityDetector.acceptedSleepSeconds(binary),7200)
        XCTAssertEqual(SleepOpportunityDetector.mainSleepGroupIndices([binary],offsetSeconds: 0),[0])
    }

    func testNapOtherAndUncertainAreDistinct() {
        XCTAssertEqual(SleepOpportunityDetector.episodeType(session(0,1200,1200),isMain: false),"nap")
        XCTAssertEqual(SleepOpportunityDetector.episodeType(session(0,4*3600,4*3600),isMain: false),"other_sleep")
        XCTAssertEqual(SleepOpportunityDetector.episodeType(session(0,4*3600,1200),isMain: false),"other_sleep")
        XCTAssertEqual(SleepOpportunityDetector.episodeType(session(0,17*3600,17*3600),isMain: true),"uncertain")
    }

    func testImpossibleGravityAndSingleModalitiesCannotStage() {
        let hr=(0..<600).map { HRSample(ts: $0,bpm: 55+$0%2) }
        let real=hr.map { GravitySample(ts: $0.ts,x: 0,y: 0,z: 1) }
        for g in [[],real,hr.map { GravitySample(ts: $0.ts,x: 100,y: 0,z: 0) }] {
            let h = g==real ? [] : hr
            let staged=SleepStagerV2.stageSession(start: 0,end: 600,grav: g,hr: h,rr: [],resp: [])
            XCTAssertTrue(staged.allSatisfy { $0.state=="state_unknown" })
            XCTAssertFalse(staged.contains(where: SleepStageSemantics.isSleep))
        }
        let good=SleepStagerV2.stageSession(start: 0,end: 600,grav: real,hr: hr,rr: [],resp: [])
        XCTAssertTrue(good.contains { $0.stage != "unknown" })
    }

    func testFrozenStreamsAndOverlongEpisodesBecomeUnknown() {
        let h=stride(from: 0,to: 86400,by: 5).map { HRSample(ts: $0,bpm: $0<17*3600 ? 55:80) }
        let fixed=h.map { GravitySample(ts: $0.ts,x: 0,y: 0,z: 1) }
        let frozen=SleepOpportunityDetector.detect(start: 0,end: 86400,hr: h,gravity: fixed)
        XCTAssertTrue(frozen.episodes.isEmpty)
        XCTAssertTrue(frozen.epochs.contains { $0.abstentionReason=="sensor_stale_or_constant" })
        let varying=h.map { GravitySample(ts: $0.ts,x: 0.00001*sin(Double($0.ts)),y: 0,z: 1) }
        let overlong=SleepOpportunityDetector.detect(start: 0,end: 86400,hr: h,gravity: varying)
        XCTAssertTrue(overlong.episodes.isEmpty)
        XCTAssertTrue(overlong.epochs.contains { $0.abstentionReason=="episode_exceeds_supported_duration" })
        XCTAssertFalse(overlong.epochs.contains(where: SleepStageSemantics.isSleep))
    }

    func testStagingRejectsFrozenStreamsAndFindsOffsetAcquisitionClocks() {
        let hr=(0..<2700).map { HRSample(ts: $0,bpm: 55) }
        let gravity=hr.map { GravitySample(ts: $0.ts,x: 0,y: 0,z: 1) }
        let shifted=gravity.map { GravitySample(ts: $0.ts+2,x: $0.x,y: $0.y,z: $0.z) }
        XCTAssertEqual(SleepSignalValidity.constantSensorSpans(hr: hr,gravity: shifted,minimumSeconds: 1800),[2..<2700])
        let staged=SleepStagerV2.stageSession(start: 0,end: 2700,grav: gravity,hr: hr,rr: [],resp: [])
        XCTAssertTrue(staged.allSatisfy { $0.stage=="unknown" && $0.abstentionReason=="sensor_stale_or_constant" })
        let overlong=SleepStagerV2.stageSession(start: 0,end: 17*3600,grav: [],hr: [],rr: [],resp: [])
        XCTAssertTrue(overlong.allSatisfy { $0.stage=="unknown" && $0.abstentionReason=="episode_exceeds_supported_duration" })
    }

    func testFullDayStateAndAttributedContextSurviveOutsideEpisodes() throws {
        let day=AnalyticsEngine.dayStartUtcSeconds("2026-09-17")
        let context=[("reading",0),("phone_use",1800),("quiet_rest",3600),("off_body",5400),("sleep_opportunity",7200)].map {
            SleepContextSpan(start: day+$0.1,end: day+$0.1+1800,kind: $0.0,provenance: "user_report")
        }
        let result=AnalyticsEngine.analyzeDay(day: "2026-09-17",profile: UserProfile(weightKg: 70,heightCm: 170,age: 30,sex: "nonbinary"),
            sleepContext: context,useFullDaySleepOpportunities: true)
        XCTAssertTrue(result.sleepSessions.isEmpty)
        XCTAssertEqual(result.fullDaySleepEpochs.reduce(0) { $0+$1.end-$1.start },86400)
        for c in context {
            let found=try XCTUnwrap(result.fullDaySleepEpochs.first { $0.start==c.start })
            XCTAssertEqual(found.contextKind,c.kind); XCTAssertEqual(found.contextProvenance,"user_report")
            XCTAssertFalse(SleepStageSemantics.isSleep(found))
        }
        let encoded=try XCTUnwrap(AnalyticsEngine.encodeStages(result.fullDaySleepEpochs))
        XCTAssertEqual(AnalyticsEngine.decodeStages(encoded),result.fullDaySleepEpochs)
    }
}
