import Foundation
import XCTest
import WhoopStore
@testable import StrandAnalytics

final class W4ReadinessCalendarTests: XCTestCase {
    private typealias F = W4FiveSeamFixtures

    func testDenseCalendarMatchesLegacyIncludingAllEvidenceAndConfidence() throws {
        let rows = (0...30).map { F.metric($0, hrv: Double(56 + $0 % 9), rhr: 50 + $0 % 5,
                                          strain: Double(4 + $0 % 8), resp: 13 + Double($0 % 4)) }
        XCTAssertEqual(try ReadinessEngine.evaluateCalendar(days: rows.reversed(), today: F.day(30)),
                       ReadinessEngine.evaluate(days: rows, today: F.day(30)))
    }

    func testMissingCurrentNeverUsesHistoricalOrFutureRow() throws {
        let rows = (0..<30).map { F.metric($0, strain: 10) } + [F.metric(31, strain: 100)]
        XCTAssertEqual(try ReadinessEngine.evaluateCalendar(days: rows, today: F.day(30)),
                       ReadinessEngine.evaluate(days: [], today: F.day(30)))
        XCTAssertEqual(try ReadinessEngine.evaluateCalendar(days: [], today: F.day(30)).level, .insufficient)
    }

    func testSevenValidSlotsRequiredAndBaselineUsesActualOptionalFold() throws {
        let indices = [0, 4, 8, 12, 16, 20, 24]
        let rows = indices.map { F.metric($0, hrv: Double(50 + $0), rhr: 50 + $0 % 5) }
        let result = try ReadinessEngine.evaluateCalendar(days: rows + [F.metric(30)], today: F.day(30))
        let slots: [Double?] = (0..<30).map { i in indices.contains(i) ? log(Double(50 + i)) : nil }
        let expected = Baselines.foldHistory(slots, cfg: Baselines.readinessHRVLnCfg, rejectHardOutliers: false)
        XCTAssertTrue(expected.usable)
        XCTAssertEqual(expected.nightsSinceUpdate, 5)
        let signal = try XCTUnwrap(result.signals.first { $0.key == "hrv" })
        guard case let .metric(value, baseline, unit, decimals) = signal.evidenceData else { return XCTFail("metric evidence missing") }
        XCTAssertEqual(value, 60); XCTAssertEqual(baseline, exp(expected.baseline)); XCTAssertEqual(unit, "ms"); XCTAssertEqual(decimals, 0)
        XCTAssertEqual(result.confidence, ScoreConfidence.readiness(hasRead: true, baselineNights: 7, fullWindow: 30))
        let six = try ReadinessEngine.evaluateCalendar(days: Array(rows.dropFirst()) + [F.metric(30)], today: F.day(30))
        XCTAssertFalse(six.signals.contains { $0.key == "hrv" || $0.key == "rhr" })
    }

    func testMissingCalendarTailAgesFreshnessInsteadOfCompressingIt() throws {
        let rows = (0..<7).map { F.metric($0) } + [F.metric(30)]
        let folded = Baselines.foldHistory(Array(repeating: Optional(log(60.0)), count: 7)
            + Array(repeating: nil, count: 23), cfg: Baselines.readinessHRVLnCfg, rejectHardOutliers: false)
        XCTAssertEqual(folded.status, .stale); XCTAssertEqual(folded.nightsSinceUpdate, 23)
        let calendar = try ReadinessEngine.evaluateCalendar(days: rows, today: F.day(30))
        XCTAssertFalse(calendar.signals.contains { $0.key == "hrv" || $0.key == "rhr" })
        XCTAssertTrue(ReadinessEngine.evaluate(days: rows).signals.contains { $0.key == "hrv" })
    }

    func testLoadUsesOnlyContiguousSuffixEndingToday() throws {
        let rows = (0...30).map { F.metric($0, strain: Double(3 + $0 % 7)) }
        let thirteen = try ReadinessEngine.evaluateCalendar(days: rows.filter { $0.day != F.day(17) }, today: F.day(30))
        XCTAssertNil(thirteen.acwr); XCTAssertNil(thirteen.monotony)
        let fourteen = try ReadinessEngine.evaluateCalendar(days: rows.filter { $0.day != F.day(16) }, today: F.day(30))
        let suffix = Array(rows.suffix(14)).compactMap(\.strain), week = Array(suffix.suffix(7))
        XCTAssertEqual(try XCTUnwrap(fourteen.acwr), ReadinessEngine.mean(week)! / ReadinessEngine.mean(suffix)!)
        XCTAssertEqual(try XCTUnwrap(fourteen.monotony), ReadinessEngine.mean(week)! / ReadinessEngine.sampleSD(week)!)
        let noCurrentLoad = try ReadinessEngine.evaluateCalendar(days: Array(rows.dropLast()) + [F.metric(30)], today: F.day(30))
        XCTAssertNil(noCurrentLoad.acwr); XCTAssertNil(noCurrentLoad.monotony)
    }

    func testOldAndFutureRowsCannotEnterWindowOrLoad() throws {
        let rows = (0...30).map { F.metric($0, strain: Double(4 + $0 % 6)) }
        let expected = try ReadinessEngine.evaluateCalendar(days: rows, today: F.day(30))
        let extra = [F.metric(-1, hrv: 300, rhr: 100, strain: 100),
                     F.metric(31, hrv: 300, rhr: 100, strain: 100), F.metric(31, hrv: 400)]
        XCTAssertEqual(try ReadinessEngine.evaluateCalendar(days: extra + rows.reversed(), today: F.day(30)), expected)
    }

    func testAdmittedFeatureOmissionsDoNotEraseOtherBaselines() throws {
        let rows = (0...30).map { F.metric($0, hrv: $0 < 28 ? nil : 60, rhr: 52, resp: $0 == 30 ? 20 : Double(13 + $0 % 3)) }
        let result = try ReadinessEngine.evaluateCalendar(days: rows, today: F.day(30))
        XCTAssertFalse(result.signals.contains { $0.key == "hrv" })
        XCTAssertTrue(result.signals.contains { $0.key == "rhr" })
        let respiratory = try XCTUnwrap(result.signals.first { $0.key == "respRate" })
        XCTAssertEqual(respiratory.flag, .bad)
        XCTAssertEqual(respiratory.evidenceData, .metric(value: 20, baseline: 14, unit: "rpm", decimals: 1))
    }

    func testStrictKeysDuplicatesAndLeapDay() throws {
        for key in ["2026-02-30", "2026-1-01", "0000-01-01", "2026-01-01Z", ""] {
            XCTAssertThrowsError(try ReadinessEngine.evaluateCalendar(days: [], today: key)) {
                XCTAssertEqual($0 as? ReadinessEngine.CalendarInputError, .invalidDay(key))
            }
            XCTAssertThrowsError(try ReadinessEngine.evaluateCalendar(days: [F.metric(day: key)], today: F.day(30)))
        }
        XCTAssertNoThrow(try ReadinessEngine.evaluateCalendar(days: [F.metric(day: "2024-02-29")], today: "2024-02-29"))
        XCTAssertThrowsError(try ReadinessEngine.evaluateCalendar(days: [F.metric(0), F.metric(0)], today: F.day(30))) {
            XCTAssertEqual($0 as? ReadinessEngine.CalendarInputError, .duplicateDay(F.day(0)))
        }
        XCTAssertThrowsError(try ReadinessEngine.evaluateCalendar(days: [F.metric(day: "0001-01-01")], today: "0001-01-01"))
    }
}
