import Foundation
import XCTest
@testable import StrandAnalytics

final class W4PhysiologicalStepsTimezoneTests: XCTestCase {
    private typealias F = W4FiveSeamFixtures
    private typealias Block = PhysiologicalSteps.SleepBlock

    private func mainIDs(_ blocks: [Block], offset: Int, zone: TimeZone?, habitual: Int? = nil) -> [String] {
        PhysiologicalSteps.classifyForCycle(blocks, offsetSec: offset,
            habitualMidsleepSec: habitual, timezone: zone).filter { $0.kind == .mainSleep }.map(\.id)
    }

    func testThreeHourGateUsesEachOnsetOffset() {
        let cases = [
            ("America/Los_Angeles", "2026-03-08T18:30:00Z", -28_800, false),
            ("America/Los_Angeles", "2026-11-01T18:30:00Z", -25_200, true),
            ("Australia/Lord_Howe", "2026-10-04T00:15:00Z", 37_800, false),
            ("Australia/Lord_Howe", "2026-04-05T00:15:00Z", 39_600, true)
        ]
        for (name, instant, staleOffset, overnight) in cases {
            let zone = F.zone(name), onset = F.epoch(instant)
            let block = Block(onset: onset, end: onset + 10_800, id: "gate")
            XCTAssertEqual(mainIDs([block], offset: staleOffset, zone: zone), overnight ? ["gate"] : [], instant)
            XCTAssertNotEqual(mainIDs([block], offset: staleOffset, zone: nil),
                              mainIDs([block], offset: staleOffset, zone: zone), "stale-offset control")
            XCTAssertEqual(SleepStageTotals.isOvernightOnset(onset,
                offsetSec: zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(onset)))), overnight)
            XCTAssertTrue(mainIDs([Block(onset: onset, end: onset + 10_799)],
                                  offset: staleOffset, zone: zone).isEmpty)
        }
    }

    func testTailBridgeForwardsZoneAndRetainsOriginalOrder() {
        let cases = [
            ("America/Los_Angeles", "2026-03-08T18:30:00Z", -28_800, false),
            ("America/Los_Angeles", "2026-11-01T18:30:00Z", -25_200, true),
            ("Australia/Lord_Howe", "2026-10-04T00:15:00Z", 37_800, false),
            ("Australia/Lord_Howe", "2026-04-05T00:15:00Z", 39_600, true)
        ]
        for (name, instant, staleOffset, bridge) in cases {
            let zone = F.zone(name), onset = F.epoch(instant)
            let blocks = [Block(onset: onset, end: onset + 3600, id: "tail"),
                          Block(onset: onset - 14_400, end: onset - 4200, id: "head")]
            let groups = SleepStageTotals.bridgedNightGroups(blocks.map {
                .init(start: $0.effectiveOnset, end: $0.end)
            }, offsetSec: staleOffset, timezone: zone)
            XCTAssertEqual(groups.count, bridge ? 1 : 2)
            XCTAssertEqual(mainIDs(blocks, offset: staleOffset, zone: zone), bridge ? ["tail", "head"] : [])
            XCTAssertNotEqual(mainIDs(blocks, offset: staleOffset, zone: nil),
                              mainIDs(blocks, offset: staleOffset, zone: zone), instant)
        }
    }

    func testMidpointRankingUsesZoneAndOriginalIdentities() {
        let zone = F.zone("America/Los_Angeles")
        let earlyMid = F.epoch("2026-03-08T08:30:00Z"), lateMid = F.epoch("2026-03-08T14:00:00Z")
        let blocks = [Block(onset: lateMid - 7200, end: lateMid + 7200, id: "late"),
                      Block(onset: earlyMid - 6300, end: earlyMid + 6300, id: "early")]
        XCTAssertEqual(mainIDs(blocks, offset: -28_800, zone: nil, habitual: 10_800), ["late"])
        XCTAssertEqual(mainIDs(blocks, offset: -28_800, zone: zone, habitual: 10_800), ["early"])
        let picked = SleepStageTotals.mainNightGroupIndices(blocks.map {
            .init(start: $0.effectiveOnset, end: $0.end)
        }, offsetSec: -28_800, habitualMidsleepSec: 10_800, timezone: zone)
        XCTAssertEqual(picked, [1])
    }

    func testEditsExplicitKindsAndLongDaytimeNapRemainAuthoritative() {
        let zone = F.zone("America/Los_Angeles"), onset = F.epoch("2026-03-08T18:30:00Z")
        let edited = Block(onset: onset, end: onset + 7200, id: "edited", editedOnset: onset - 3600)
        let longNap = Block(onset: onset + 10_800, end: onset + 43_200, id: "long-nap", kind: .nap)
        XCTAssertEqual(mainIDs([longNap, edited], offset: -28_800, zone: zone), ["edited"])
        let explicit = Block(onset: onset, end: onset + 60, id: "explicit", kind: .mainSleep)
        let input = [longNap, edited, explicit]
        let output = PhysiologicalSteps.classifyForCycle(input, offsetSec: 123,
            habitualMidsleepSec: nil, timezone: zone)
        XCTAssertEqual(output.map(\.id), input.map(\.id))
        XCTAssertEqual(output.map(\.onset), input.map(\.onset))
        XCTAssertEqual(output.map(\.end), input.map(\.end))
        XCTAssertEqual(output.map(\.editedOnset), input.map(\.editedOnset))
        XCTAssertEqual(output.filter { $0.kind == .mainSleep }.map(\.id), ["explicit"])
        XCTAssertTrue(mainIDs([], offset: 0, zone: zone).isEmpty)
    }

    func testNilDefaultConstantZoneAndUnrelatedOwnershipStayExact() {
        let start = F.epoch("2026-06-14T22:00:00Z")
        let blocks = [Block(onset: start, end: start + 25_200, id: "night"),
                      Block(onset: start + 57_600, end: start + 86_400, id: "daytime")]
        let legacy = PhysiologicalSteps.classifyForCycle(blocks, offsetSec: 0, habitualMidsleepSec: nil)
        XCTAssertEqual(legacy.map(\.kind), PhysiologicalSteps.classifyForCycle(blocks,
            offsetSec: 0, habitualMidsleepSec: nil, timezone: nil).map(\.kind))
        XCTAssertEqual(legacy.map(\.kind), PhysiologicalSteps.classifyForCycle(blocks,
            offsetSec: 123, habitualMidsleepSec: nil, timezone: F.zone("UTC")).map(\.kind))
        XCTAssertEqual(legacy.filter { $0.kind == .mainSleep }.map(\.id), ["night"])
        let windows = PhysiologicalSteps.cycleWindows([
            .init(sleepId: "a", onset: 100), .init(sleepId: "b", onset: 200)
        ], now: 300)
        XCTAssertEqual(windows, [.init(sleepId: "a", onset: 100, endExclusive: 200),
                                 .init(sleepId: "b", onset: 200, endExclusive: 300)])
        XCTAssertEqual(PhysiologicalSteps.ownerSegmentsFromCoverage(windows[0], coverage: [
            .init(owner: "sensor", onset: 130, endExclusive: 170, priority: 1)
        ], fallbackOwner: "fallback"), [.init(owner: "fallback", onset: 100, endExclusive: 130),
                                       .init(owner: "sensor", onset: 130, endExclusive: 200)])
    }
}
