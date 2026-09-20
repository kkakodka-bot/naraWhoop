import Foundation
import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class W4DaytimeBaselineTimezoneTests: XCTestCase {
    private typealias F = W4FiveSeamFixtures

    func testAggregateUsesSameZoneBucketsWakingAndNativeQuantilesAsScorer() throws {
        let zone = F.zone("America/Los_Angeles")
        let start = F.epoch("2026-03-08T12:00:00Z") // 05:00 after transition, not 04:00.
        let hr = (0..<5).flatMap { F.hr(start + $0 * 3600, bpm: 60 + $0 * 3) }
        let rr = (0..<5).flatMap { F.rr(start + $0 * 3600) }
        let scored = DaytimeStress.analyze(hr: hr, rr: rr, timezone: zone)
        XCTAssertEqual(scored.hours.map(\.hour), [6, 7, 8, 9])
        let actual = DaytimeStress.dayDaytimeAggregate(hr: hr, rr: rr, tzOffsetSeconds: 123, timezone: zone)
        XCTAssertEqual(actual.hr, DaytimeStress.quantile(scored.hours.compactMap(\.meanHR).sorted(), 0.1))
        XCTAssertEqual(actual.rmssd, DaytimeStress.quantile(scored.hours.compactMap(\.rmssd).sorted(), 0.5))
        let wrongOffset = DaytimeStress.dayDaytimeAggregate(hr: hr, rr: rr, tzOffsetSeconds: -28_800, timezone: zone)
        XCTAssertEqual(actual.hr, wrongOffset.hr); XCTAssertEqual(actual.rmssd, wrongOffset.rmssd)
    }

    func testEachHistoricalDayKeepsItsOwnZoneAndMissingSlotAgesFold() throws {
        let start = F.epoch("2026-03-07T13:00:00Z")
        let zones = [F.zone("America/Los_Angeles"), F.zone("Asia/Kathmandu"), F.zone("UTC")]
        var days: [DaytimeStress.DaytimeDayStreams] = (0..<8).map { i in
            .init(hr: F.hr(start + i * 86400, bpm: 60 + i), rr: F.rr(start + i * 86400),
                  tzOffsetSeconds: 0, timezone: zones[i % zones.count])
        }
        days.append(.init(hr: [], rr: [], tzOffsetSeconds: 0, timezone: zones[0]))
        let aggregates = days.map { DaytimeStress.dayDaytimeAggregate(hr: $0.hr, rr: $0.rr, tzOffsetSeconds: 0, timezone: $0.timezone) }
        let expectedHR = Baselines.foldHistory(aggregates.map(\.hr), cfg: Baselines.daytimeHRCfg)
        let expectedRR = Baselines.foldHistory(aggregates.map(\.rmssd), cfg: Baselines.daytimeRMSSDCfg)
        let actual = DaytimeStress.foldDaytimeBaselines(days: days)
        XCTAssertEqual(actual.hr, expectedHR); XCTAssertEqual(actual.rmssd, expectedRR.usable ? expectedRR : nil)
        XCTAssertEqual(actual.hr.nightsSinceUpdate, 1)
        let wrongFallback = days.map { DaytimeStress.DaytimeDayStreams(hr: $0.hr, rr: $0.rr, tzOffsetSeconds: 50_400, timezone: $0.timezone) }
        XCTAssertEqual(DaytimeStress.foldDaytimeBaselines(days: wrongFallback).hr, actual.hr)
        XCTAssertNotEqual(DaytimeStress.foldDaytimeBaselines(days: days.map {
            .init(hr: $0.hr, rr: $0.rr, tzOffsetSeconds: 0, timezone: F.zone("UTC"))
        }).hr, actual.hr, "replacing captured historical zones changes admission")
    }

    func testEmptySparseAndRrOnlyBucketsDoNotInventBaselineData() {
        let zone = F.zone("Asia/Kathmandu"), start = F.epoch("2026-06-15T02:15:00Z")
        let empty = DaytimeStress.dayDaytimeAggregate(hr: [], rr: F.rr(start), tzOffsetSeconds: 0, timezone: zone)
        XCTAssertNil(empty.hr); XCTAssertNil(empty.rmssd)
        let sparse = DaytimeStress.dayDaytimeAggregate(hr: F.hr(start, count: 299), rr: [], tzOffsetSeconds: 0, timezone: zone)
        XCTAssertNil(sparse.hr); XCTAssertNil(sparse.rmssd)
        let differentBucket = DaytimeStress.dayDaytimeAggregate(hr: F.hr(start), rr: F.rr(start + 3600), tzOffsetSeconds: 0, timezone: zone)
        XCTAssertEqual(differentBucket.hr, 65); XCTAssertNil(differentBucket.rmssd)
        XCTAssertEqual(DaytimeStress.scoringMode(history: [.init(hr: [], rr: [], tzOffsetSeconds: 0, timezone: zone)]), .dayRelative)
    }

    func testPersonalModeKeepsRmssdFeatureGateAndStaleHistoryFallback() {
        let zone = F.zone("UTC"), start = F.epoch("2026-06-15T08:00:00Z")
        let days = (0..<8).map { i in DaytimeStress.DaytimeDayStreams(hr: F.hr(start + i * 86400),
            rr: F.rr(start + i * 86400), tzOffsetSeconds: 0, timezone: zone) }
        let folded = DaytimeStress.foldDaytimeBaselines(days: days)
        XCTAssertTrue(folded.hr.usable); XCTAssertNotNil(folded.rmssd)
        XCTAssertFalse(DaytimeStress.daytimeRMSSDScoringEnabled)
        XCTAssertEqual(DaytimeStress.scoringMode(history: days), .baselineRelative(hr: folded.hr, rmssd: nil))
        let missing = Array(repeating: DaytimeStress.DaytimeDayStreams(hr: [], rr: [], tzOffsetSeconds: 0, timezone: zone), count: 15)
        XCTAssertEqual(DaytimeStress.foldDaytimeBaselines(days: days + missing).hr.status, .stale)
        XCTAssertEqual(DaytimeStress.scoringMode(history: days + missing), .dayRelative)
    }
}
