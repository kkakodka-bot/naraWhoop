import Foundation
import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// Run unchanged against the original wrappers, retain the attachment, then rerun after delegation.
final class W4DailyPresentationCompatibilityTests: XCTestCase {
    private typealias M = DailyPresentationMath

    func testOriginalMeansAndPopulationDeviationMatchHelperBitForBit() {
        let vectors: [[Double]] = [[], [0], [-0.0], [1, 3], [1e16, -1e16, 1],
                                   [1e16, 1, -1e16], [.nan, 3], [.infinity], [.infinity, -.infinity]]
        for values in vectors {
            same(SleepModel.mean(values), M.mean(values))
            same(StressMath.mean(values), M.mean(values))
            for mean in [nil, 0, M.mean(values), Double.nan] as [Double?] {
                same(StressMath.std(values, mean: mean), M.populationSD(values, mean: mean))
            }
        }
    }

    func testOriginalStressTermsAndSquashMatchAtEveryGuardBoundary() {
        let terms: [Double?] = [nil, -1, 0, 50, 60, .nan, .infinity]
        let spreads = [-1.0, 0, 0.0001, 0.0001.nextUp, 2, Double.nan, .infinity]
        for value in terms {
            for spread in spreads {
                for rhrMean in [nil, 55.0] as [Double?] {
                    let original = StressMath.rawScore(rhrToday: value, meanRHR: rhrMean, sdRHR: spread,
                                                      hrvToday: value, meanHRV: 55, sdHRV: spread)
                    let proposed = M.dailyStressRaw(rhrToday: value, meanRHR: rhrMean, sdRHR: spread,
                                                    hrvToday: value, meanHRV: 55, sdHRV: spread)
                    same(original, proposed)
                    same(StressMath.squash(original), M.dailyStressSquash(proposed))
                }
            }
        }
        for raw in [-Double.infinity, -1_000, -3, -1, 0, 1, 3, 1_000, .infinity, .nan] {
            same(StressMath.squash(raw), M.dailyStressSquash(raw))
        }
    }

    func testOriginalPositiveTypicalsAndDescriptiveFloor() {
        let values: [Double?] = [nil, 0, -1, .nan, 300, 480, 600]
        let days = values.enumerated().map { day($0.offset, asleep: $0.element, deep: $0.element, rem: $0.element) }
        same(SleepModel.typicalTotalMin(days: days), M.positiveMean(values))
        same(SleepModel.typicalStageMin(days: days, \.deepMin), M.positiveMean(values))
        same(SleepModel.typicalStageMin(days: days, \.remMin), M.positiveMean(values))
        same(SleepModel.sleepNeedMin(days: days), M.descriptiveSleepNeed(observedMinutes: values))
        for sparse in [[], [day(0)], [day(0, asleep: 300)], [day(0, asleep: .infinity)]] {
            same(SleepModel.sleepNeedMin(days: sparse), M.descriptiveSleepNeed(observedMinutes: sparse.map(\.totalSleepMin)))
        }
    }

    func testOriginalEfficiencyWrapperKeepsFiniteFiltering() {
        let values: [Double?] = [nil, -0.5, 0, 0.85, 1, 1.0.nextUp, 85, .nan, .infinity]
        let days = values.enumerated().map { day($0.offset, efficiency: $0.element) }
        sameMetric(SleepModel.efficiencySeries(days: days),
                   SleepModel.metric(days: days) { M.efficiencyPercent($0.efficiency) })
        XCTAssertEqual(SleepModel.efficiencySeries(days: days).series.count, 6)
        XCTAssertNil(SleepModel.efficiencySeries(days: days).latest, "2001 fixtures are historical, not current")
    }

    func testOriginalHoursVersusNeedKeepsExplicitZeroImportAndNoCap() {
        let days = [day(0, asleep: 600), day(1, asleep: 480), day(2, asleep: 0), day(3, asleep: nil)]
        let imported = [days[0].day: figures(need: 300), days[1].day: figures(need: 0)]
        let fallback = M.descriptiveSleepNeed(observedMinutes: days.map(\.totalSleepMin))
        let actual = SleepModel.hoursVsNeededSeries(days: days, importedSleep: imported)
        let proposed = SleepModel.metric(days: days) {
            M.hoursVsNeededPercent(asleepMin: $0.totalSleepMin, needMin: imported[$0.day]?.needMin ?? fallback)
        }
        sameMetric(actual, proposed)
        XCTAssertEqual(actual.series, [200])
        XCTAssertEqual(SleepModel.hoursVsNeededSeries(days: days, importedSleep: [:]).series.count, 2)
    }

    func testOriginalRestorativePreservesMissingNegativeAndOverHundred() {
        let days = [day(0, asleep: 100, deep: 60, rem: 60), day(1, asleep: 100, deep: -10, rem: 30),
                    day(2, asleep: 100, deep: nil, rem: 30), day(3, asleep: 0, deep: 20, rem: 30),
                    day(4, asleep: 100, deep: .nan, rem: 30)]
        let actual = SleepModel.restorativeSeries(days: days)
        sameMetric(actual, SleepModel.metric(days: days) {
            M.restorativePercent(deepMin: $0.deepMin, remMin: $0.remMin, asleepMin: $0.totalSleepMin)
        })
        XCTAssertEqual(actual.series, [120, 20])
    }

    func testOriginalBedtimeWrapperUsesEffectiveStartAndThreeFourteenFifteenWindows() throws {
        let original = try date("2001-01-01T00:00:00Z")
        let sessions = (0..<15).map { i -> CachedSleepSession in
            var calendar = Calendar.current
            calendar.timeZone = .current
            let onset = calendar.date(bySettingHour: i == 0 ? 12 : 23, minute: 0, second: 0,
                                      of: original.addingTimeInterval(Double(i * 86_400)))!
            let start = Int(onset.timeIntervalSince1970)
            return CachedSleepSession(startTs: start - 3_600, endTs: start + 7 * 3_600,
                                      efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil,
                                      userEdited: true, startTsAdjusted: start)
        }
        for count in [0, 1, 2, 3, 14, 15] {
            let input = Array(sessions.prefix(count))
            let scores = M.bedtimeConsistencySeries(localBedMinutes: minutes(input, calendar: .current))
            let actual = SleepModel.consistencySeries(days: [], sleeps: input, importedSleep: [:])
            sameMetric(actual, (scores.last, M.mean(scores), scores))
            XCTAssertEqual(actual.series.count, max(0, count - 2))
        }
        XCTAssertEqual(SleepModel.consistencySeries(days: [], sleeps: sessions, importedSleep: [:]).series.last, 100)
    }

    func testOriginalBedtimeWrapperAcrossTransitionInstantsAndTravelControls() throws {
        let strings = ["2026-03-08T09:30:00Z", "2026-03-08T10:30:00Z", "2026-11-01T08:30:00Z",
                       "2026-11-01T09:30:00Z", "2026-04-04T14:45:00Z", "2026-04-04T15:15:00Z",
                       "2026-10-03T15:15:00Z", "2026-10-03T15:45:00Z"]
        let sessions = try strings.map { value -> CachedSleepSession in
            let start = Int(try date(value).timeIntervalSince1970)
            return CachedSleepSession(startTs: start, endTs: start + 3_600, efficiency: nil,
                                      restingHr: nil, avgHrv: nil, stagesJSON: nil)
        }
        let local = M.bedtimeConsistencySeries(localBedMinutes: minutes(sessions, calendar: .current))
        sameMetric(SleepModel.consistencySeries(days: [], sleeps: sessions, importedSleep: [:]),
                   (local.last, M.mean(local), local))
        // The wrapper retains its ambient calendar. Explicit server-zone vectors are a separate helper input.
        for zone in ["America/Los_Angeles", "Australia/Lord_Howe", "UTC"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let result = M.bedtimeConsistencySeries(localBedMinutes: minutes(sessions, calendar: calendar))
            XCTAssertEqual(result.count, 6)
        }
    }

    func testOriginalImportedConsistencyLatestGateAndMissingValues() {
        let days = [day(0), day(1), day(2)]
        let imported = [days[0].day: figures(consistency: 25), days[2].day: figures(consistency: 75)]
        sameMetric(SleepModel.consistencySeries(days: days, sleeps: [], importedSleep: imported), (75, 50, [25, 75]))
        sameMetric(SleepModel.consistencySeries(days: days, sleeps: [], importedSleep: [days[0].day: figures(consistency: 25)]),
                   (nil, nil, []))
        let nonfinite = [days[0].day: figures(consistency: .nan), days[2].day: figures(consistency: .infinity)]
        let actual = SleepModel.consistencySeries(days: days, sleeps: [], importedSleep: nonfinite)
        same(actual.latest, .infinity)
        XCTAssertTrue(actual.typical!.isNaN, "this import branch does not use metric's finite filter")
    }

    func testOriginalFreshnessAndHistoricalSeriesRemainOutsideHelper() throws {
        let days = [day(0, efficiency: 0.8), day(1, efficiency: .nan), day(2, efficiency: .infinity)]
        let old = SleepModel.metric(days: days, now: try date("2001-02-01T12:00:00Z")) { M.efficiencyPercent($0.efficiency) }
        XCTAssertNil(old.latest)
        XCTAssertEqual(old.typical, 80)
        XCTAssertEqual(old.series, [80])
        var calendar = Calendar.current
        calendar.timeZone = .current
        let near = try XCTUnwrap(calendar.date(from: DateComponents(year: 2001, month: 1, day: 2, hour: 12)))
        XCTAssertEqual(SleepModel.metric(days: days, now: near) { M.efficiencyPercent($0.efficiency) }.latest, 80)
    }

    func testOriginalDebtAndPerformanceRemainNativeWithImportOverrides() {
        let days = [day(0, asleep: 360, efficiency: 0.9, deep: 70, rem: 80),
                    day(1, asleep: 480, efficiency: 0.95, deep: 90, rem: 110)]
        let need = AnalyticsEngine.Rest.personalizedNeedHours(nightlyHours: [6, 8], age: nil) * 60
        same(SleepModel.debtNeedMin(days: days), need)
        let native = SleepModel.metric(days: days) { AnalyticsEngine.Rest.composite(daily: $0) }
        sameMetric(SleepModel.performanceSeries(days: days, importedSleep: [:]), native)
        let imported = [days[1].day: figures(performance: 17.25, debt: 23.5)]
        XCTAssertEqual(SleepModel.performanceSeries(days: days, importedSleep: imported).series.last, 17.25)
        XCTAssertEqual(SleepModel.sleepDebtSeries(days: days, importedSleep: imported, napSleepMinByDay: [:]).series.last, 23.5)
        let napCredit = [days[1].day: 45.0]
        same(SleepModel.sleepDebtSeries(days: days, importedSleep: [:], napSleepMinByDay: napCredit).latest,
             SleepModel.debtLedger(days: days, napSleepMinByDay: napCredit).magnitudeMin)
    }

    func testOriginalStressModelRetainsStoredClampDuplicatePrecedenceAndCarry() throws {
        let days = (0..<31).map { day($0, rhr: 50 + $0 % 3, hrv: 40 + Double($0 % 5)) }
        let empty = day(31)
        XCTAssertNil(StressModel(days: [], stored: []))
        XCTAssertNil(StressModel(days: [empty], stored: []))
        let before = try XCTUnwrap(StressModel(days: days, stored: []))
        let carried = try XCTUnwrap(StressModel(days: days + [empty], stored: []))
        same(before.score, carried.score)
        XCTAssertEqual(before.fullTrend.map(\.value), carried.fullTrend.map(\.value))
        let stored = try XCTUnwrap(StressModel(days: days + [empty], stored: [(empty.day, -3), (empty.day, 9)]))
        XCTAssertTrue(stored.usingStored)
        XCTAssertEqual(stored.score, 3)
        XCTAssertEqual(stored.fullTrend.last?.value, 3)
        XCTAssertEqual(StressModel(days: [empty], stored: [(empty.day, -3)])?.score, 0)
    }

    func testAttachActualOriginalWrapperOutputsForRootPrePostComparison() throws {
        let days: [DailyMetric] = (0..<15).map { i -> DailyMetric in
            let asleep: Double = i == 0 ? 300 : 480 + Double(i)
            let efficiency: Double = i % 2 == 0 ? 0.85 : 91
            let deep: Double = 70 + Double(i)
            let rem: Double = 90
            let rhr: Int = 52 + i % 3
            let hrv: Double = 40 + Double(i % 5)
            return day(i, asleep: asleep, efficiency: efficiency, deep: deep, rem: rem, rhr: rhr, hrv: hrv)
        }
        let imported = [days.last!.day: figures(performance: 17.25, consistency: 81, need: 510, debt: 23.5)]
        let sessions = try ["2001-01-01T07:55:00Z", "2001-01-02T08:05:00Z", "2001-01-03T08:00:00Z"].map { value -> CachedSleepSession in
            let start = Int(try date(value).timeIntervalSince1970)
            return CachedSleepSession(startTs: start, endTs: start + 8 * 3_600, efficiency: nil,
                                      restingHr: nil, avgHrv: nil, stagesJSON: nil)
        }
        var outputs: [String: [String]] = [:]
        func capture(_ key: String, _ metric: SleepModel.Metric) {
            outputs[key] = [bits(metric.latest), bits(metric.typical)] + metric.series.map { bits($0) }
        }
        capture("efficiency", SleepModel.efficiencySeries(days: days))
        capture("hours_native", SleepModel.hoursVsNeededSeries(days: days, importedSleep: [:]))
        capture("hours_imported", SleepModel.hoursVsNeededSeries(days: days, importedSleep: imported))
        capture("restorative", SleepModel.restorativeSeries(days: days))
        capture("consistency_native", SleepModel.consistencySeries(days: days, sleeps: sessions, importedSleep: [:]))
        capture("consistency_imported", SleepModel.consistencySeries(days: days, sleeps: sessions, importedSleep: imported))
        capture("performance_native", SleepModel.performanceSeries(days: days, importedSleep: [:]))
        capture("performance_imported", SleepModel.performanceSeries(days: days, importedSleep: imported))
        capture("debt_native", SleepModel.sleepDebtSeries(days: days, importedSleep: [:], napSleepMinByDay: [days[0].day: 45]))
        capture("debt_imported", SleepModel.sleepDebtSeries(days: days, importedSleep: imported, napSleepMinByDay: [:]))
        outputs["typicals_need"] = [SleepModel.typicalTotalMin(days: days), SleepModel.typicalStageMin(days: days, \.deepMin),
                                    SleepModel.sleepNeedMin(days: days), SleepModel.debtNeedMin(days: days)].map(bits)
        let stress = try XCTUnwrap(StressModel(days: days, stored: []))
        outputs["stress"] = [bits(stress.score), bits(stress.rhrDelta), bits(stress.hrvDelta)] + stress.fullTrend.map { bits($0.value) }
        let payload: [String: Any] = ["schemaVersion": 1, "mode": "actual_app_wrapper_baseline",
                                      "timezone": Calendar.current.timeZone.identifier,
                                      "doubleEncoding": "IEEE754_binary64_hex_or_explicit_nil", "outputs": outputs]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "W4-original-wrapper-output-controls.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(outputs.count, 12)
    }

    private func day(_ index: Int, asleep: Double? = nil, efficiency: Double? = nil, deep: Double? = nil,
                     rem: Double? = nil, rhr: Int? = nil, hrv: Double? = nil) -> DailyMetric {
        let month = index < 31 ? 1 : 2
        let number = index < 31 ? index + 1 : index - 30
        return DailyMetric(day: String(format: "2001-%02d-%02d", month, number), totalSleepMin: asleep,
                           efficiency: efficiency, deepMin: deep, remMin: rem, lightMin: nil,
                           disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil)
    }

    private func figures(performance: Double? = nil, consistency: Double? = nil,
                         need: Double? = nil, debt: Double? = nil) -> ImportedSleepFigures {
        ImportedSleepFigures(performancePct: performance, consistencyPct: consistency, needMin: need, debtMin: debt)
    }

    private func date(_ text: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: text)) }

    private func minutes(_ sessions: [CachedSleepSession], calendar: Calendar) -> [Double] {
        sessions.map { session in
            let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(session.effectiveStartTs)))
            return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        }
    }

    private func bits(_ value: Double?) -> String { value.map { String($0.bitPattern, radix: 16) } ?? "nil" }

    private func same(_ actual: Double?, _ expected: Double?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(bits(actual), bits(expected), file: file, line: line)
    }

    private func sameMetric(_ actual: SleepModel.Metric, _ expected: SleepModel.Metric,
                            file: StaticString = #filePath, line: UInt = #line) {
        same(actual.latest, expected.latest, file: file, line: line)
        same(actual.typical, expected.typical, file: file, line: line)
        XCTAssertEqual(actual.series.map { bits($0) }, expected.series.map { bits($0) }, file: file, line: line)
    }
}
