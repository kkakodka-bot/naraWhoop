import Foundation
import XCTest
@testable import StrandAnalytics

final class W4DailyPresentationMathTests: XCTestCase {
    private typealias M = DailyPresentationMath

    func testMeanPreservesEmptyOrderAndNonfiniteInputs() {
        XCTAssertNil(M.mean([]))
        XCTAssertEqual(M.mean([2, 4]), 3)
        XCTAssertEqual(M.mean([1e16, -1e16, 1]), 1.0 / 3.0)
        XCTAssertEqual(M.mean([1e16, 1, -1e16]), 0)
        XCTAssertTrue(M.mean([.nan, 1])!.isNaN)
        XCTAssertEqual(M.mean([.infinity]), .infinity)
        XCTAssertTrue(M.mean([.infinity, -.infinity])!.isNaN)
    }

    func testPopulationDeviationKeepsProvidedMeanAndCountGate() {
        XCTAssertEqual(M.populationSD([], mean: 10), 0)
        XCTAssertEqual(M.populationSD([1], mean: .nan), 0)
        XCTAssertEqual(M.populationSD([1, 3], mean: nil), 0)
        XCTAssertEqual(M.populationSD([1, 3], mean: 2), 1)
        XCTAssertEqual(M.populationSD([1, 3], mean: 0), 5.0.squareRoot())
        XCTAssertTrue(M.populationSD([1, 3], mean: .nan).isNaN)
    }

    func testStressBothDirectionsAndNilTerms() {
        XCTAssertEqual(raw(rhr: 63, hrMean: 60, hrSD: 3, hrv: 40, hrvMean: 50, hrvSD: 5), 3)
        XCTAssertEqual(raw(rhr: 57, hrMean: 60, hrSD: 3, hrv: 60, hrvMean: 50, hrvSD: 5), -3)
        XCTAssertEqual(raw(rhr: nil, hrMean: 60, hrSD: 3, hrv: 40, hrvMean: 50, hrvSD: 5), 2)
        XCTAssertEqual(raw(rhr: 63, hrMean: nil, hrSD: 3, hrv: 40, hrvMean: nil, hrvSD: 5), 0)
        XCTAssertEqual(raw(rhr: nil, hrMean: nil, hrSD: 0, hrv: nil, hrvMean: nil, hrvSD: 0), 0)
    }

    func testStressSpreadGateIsStrictAndNonfiniteIsNotSilentlyFiltered() {
        for sd in [-1, 0, 0.0001, Double.nan] {
            XCTAssertEqual(raw(rhr: 63, hrMean: 60, hrSD: sd, hrv: 40, hrvMean: 50, hrvSD: sd), 0)
        }
        XCTAssertGreaterThan(raw(rhr: 63, hrMean: 60, hrSD: 0.0001.nextUp,
                                hrv: nil, hrvMean: nil, hrvSD: 0), 0)
        XCTAssertTrue(raw(rhr: .nan, hrMean: 60, hrSD: 3, hrv: nil, hrvMean: nil, hrvSD: 0).isNaN)
    }

    func testStressSquashBoundaryAndSymmetry() {
        XCTAssertEqual(M.dailyStressSquash(0), 1.5)
        XCTAssertEqual(M.dailyStressSquash(.infinity), 3)
        XCTAssertEqual(M.dailyStressSquash(-.infinity), 0)
        XCTAssertEqual(M.dailyStressSquash(1) + M.dailyStressSquash(-1), 3, accuracy: 1e-15)
        XCTAssertTrue(M.dailyStressSquash(.nan).isNaN)
    }

    func testPositiveMeanAndDescriptiveNeedAreNotNormativeNeed() {
        XCTAssertNil(M.positiveMean([nil, 0, -1, .nan]))
        XCTAssertEqual(M.positiveMean([nil, 0, -1, 300, 600, .nan]), 450)
        XCTAssertEqual(M.descriptiveSleepNeed(observedMinutes: []), 450)
        XCTAssertEqual(M.descriptiveSleepNeed(observedMinutes: [300, 360]), 450)
        XCTAssertEqual(M.descriptiveSleepNeed(observedMinutes: [480, 600]), 540)
        XCTAssertEqual(M.descriptiveSleepNeed(observedMinutes: [.infinity]), .infinity)
        XCTAssertNotEqual(M.descriptiveSleepNeed(observedMinutes: [300, 360]),
                          AnalyticsEngine.Rest.personalizedNeedHours(nightlyHours: [5, 6], age: nil) * 60)
    }

    func testConsistencyMinimumAndNoonWrap() {
        for n in 0...2 { XCTAssertEqual(M.bedtimeConsistencySeries(localBedMinutes: Array(repeating: 1_380, count: n)), []) }
        XCTAssertEqual(M.bedtimeConsistencySeries(localBedMinutes: [1_380, 1_380, 1_380]), [100])
        XCTAssertEqual(M.bedtimeConsistencySeries(localBedMinutes: [719, 720, 719]), [0])
        XCTAssertEqual(M.bedtimeConsistencySeries(localBedMinutes: [0, 1_440, 0]), [100])
        XCTAssertGreaterThan(M.bedtimeConsistencySeries(localBedMinutes: [1_430, 10, 0])[0], 90)
    }

    func testConsistencyTrailingFourteenDropsOldOutlierWithoutDroppingOutput() {
        let first = [720.0] + Array(repeating: 1_380.0, count: 13)
        let fourteen = M.bedtimeConsistencySeries(localBedMinutes: first)
        let fifteen = M.bedtimeConsistencySeries(localBedMinutes: first + [1_380])
        XCTAssertEqual(fourteen.count, 12)
        XCTAssertEqual(fifteen.count, 13)
        XCTAssertEqual(Array(fifteen.dropLast()), fourteen)
        XCTAssertLessThan(fourteen.last!, 100)
        XCTAssertEqual(fifteen.last, 100)
    }

    func testExplicitLocalMinutesAcrossDSTAndTravel() throws {
        let vectors: [(String, [String], [Double])] = [
            ("America/Los_Angeles", ["2026-03-08T09:30:00Z", "2026-03-08T10:30:00Z", "2026-03-08T11:30:00Z"], [90, 210, 270]),
            ("America/Los_Angeles", ["2026-11-01T08:30:00Z", "2026-11-01T09:30:00Z", "2026-11-01T10:30:00Z"], [90, 90, 150]),
            ("Australia/Lord_Howe", ["2026-04-04T14:45:00Z", "2026-04-04T15:15:00Z", "2026-04-04T15:45:00Z"], [105, 105, 135]),
            ("Australia/Lord_Howe", ["2026-10-03T15:15:00Z", "2026-10-03T15:45:00Z", "2026-10-03T16:15:00Z"], [105, 165, 195])
        ]
        let parser = ISO8601DateFormatter()
        for (zone, instants, expectedMinutes) in vectors {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let minutes = try instants.map { text -> Double in
                let date = try XCTUnwrap(parser.date(from: text))
                return Double(calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date))
            }
            XCTAssertEqual(minutes, expectedMinutes, zone)
            XCTAssertEqual(M.bedtimeConsistencySeries(localBedMinutes: minutes),
                           M.bedtimeConsistencySeries(localBedMinutes: expectedMinutes), zone)
        }
        let instant = try XCTUnwrap(parser.date(from: "2026-01-02T07:30:00Z"))
        let travelMinutes = try ["America/Los_Angeles", "America/New_York", "UTC"].map { zone -> Double in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            return Double(calendar.component(.hour, from: instant) * 60 + calendar.component(.minute, from: instant))
        }
        XCTAssertEqual(travelMinutes, [1_410, 150, 450])
        XCTAssertEqual(M.bedtimeConsistencySeries(localBedMinutes: travelMinutes), [0])
    }

    func testEfficiencyKeepsFractionPercentNegativeAndNonfiniteSemantics() {
        XCTAssertNil(M.efficiencyPercent(nil))
        XCTAssertEqual(M.efficiencyPercent(0.85), 85)
        XCTAssertEqual(M.efficiencyPercent(1), 100)
        XCTAssertEqual(M.efficiencyPercent(1.nextUp), 1.nextUp)
        XCTAssertEqual(M.efficiencyPercent(85), 85)
        XCTAssertEqual(M.efficiencyPercent(-0.5), -50)
        XCTAssertTrue(M.efficiencyPercent(.nan)!.isNaN)
        XCTAssertEqual(M.efficiencyPercent(.infinity), .infinity)
    }

    func testHoursVsNeedDoesNotReplaceExplicitZeroOrClamp() {
        XCTAssertNil(M.hoursVsNeededPercent(asleepMin: nil, needMin: 450))
        XCTAssertNil(M.hoursVsNeededPercent(asleepMin: 0, needMin: 450))
        XCTAssertNil(M.hoursVsNeededPercent(asleepMin: 480, needMin: 0))
        XCTAssertNil(M.hoursVsNeededPercent(asleepMin: .nan, needMin: 450))
        XCTAssertNil(M.hoursVsNeededPercent(asleepMin: 480, needMin: .nan))
        XCTAssertEqual(M.hoursVsNeededPercent(asleepMin: 600, needMin: 450), 600.0 / 450 * 100)
        XCTAssertEqual(M.hoursVsNeededPercent(asleepMin: 480, needMin: .infinity), 0)
    }

    func testRestorativeMissingIsNotZeroAndStageSignsAreNotChanged() {
        XCTAssertNil(M.restorativeMinutes(deepMin: nil, remMin: 30))
        XCTAssertNil(M.restorativeMinutes(deepMin: 30, remMin: nil))
        XCTAssertEqual(M.restorativeMinutes(deepMin: 0, remMin: 0), 0)
        XCTAssertEqual(M.restorativeMinutes(deepMin: -10, remMin: 30), 20)
        XCTAssertNil(M.restorativePercent(deepMin: 20, remMin: 30, asleepMin: 0))
        XCTAssertNil(M.restorativePercent(deepMin: nil, remMin: 30, asleepMin: 100))
        XCTAssertEqual(M.restorativePercent(deepMin: 60, remMin: 60, asleepMin: 100), 120)
        XCTAssertTrue(M.restorativePercent(deepMin: .nan, remMin: 30, asleepMin: 100)!.isNaN)
    }

    private func raw(rhr: Double?, hrMean: Double?, hrSD: Double,
                     hrv: Double?, hrvMean: Double?, hrvSD: Double) -> Double {
        M.dailyStressRaw(rhrToday: rhr, meanRHR: hrMean, sdRHR: hrSD,
                         hrvToday: hrv, meanHRV: hrvMean, sdHRV: hrvSD)
    }
}
