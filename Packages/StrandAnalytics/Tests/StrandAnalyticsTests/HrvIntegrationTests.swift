import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class HrvIntegrationTests: XCTestCase {
    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
    private var observations: [PhysiologyQuality.IntervalObservation] {
        hrvEvidence() + hrvEvidence(start: 300, pattern: [950, 1050]) + hrvEvidence(start: 600, pattern: [600, 1400])
    }
    func testEnginePublishesWindowArithmeticNotCachedVendorValueOrDeepOnlyPreference() throws {
        let provided = SleepSession(start: 0, end: 900, efficiency: 1,
            stages: [.init(start: 0, end: 900, stage: "light")], restingHR: nil, avgHRV: 999)
        let result = AnalyticsEngine.analyzeDay(day: "1970-01-01", hrvObservations: observations,
            hrvContext: [.init(start: 0, end: 900, state: "sleep", qualified: true)], inputRevision: "revision-7",
            profile: profile, providedSleep: [provided], deepHrvWindow: true, localDayStart: 0, localDayEndExclusive: 1800)
        XCTAssertEqual(try XCTUnwrap(result.daily.avgHrv), 300, accuracy: 1e-9)
        XCTAssertEqual(result.hrvNightSummary?.meanRMSSD, 300)
        XCTAssertEqual(result.sleepSessions.first?.avgHRV, 300)
        XCTAssertEqual(result.hrvMeasurements.count, 6)
        XCTAssertTrue(result.hrvMeasurements.allSatisfy { $0.inputRevision == "revision-7" })
    }
    func testSessionLegacyRowsStayUnavailableWithReason() {
        let rows = (0..<900).map { RRInterval(ts: $0, rrMs: 1000) }
        let windows = SleepStager.sessionHrvWindows(start: 0, end: 900, rr: rows, stages: [])
        XCTAssertEqual(windows.count, 3); XCTAssertTrue(windows.allSatisfy { $0.rmssd == nil && $0.unavailableReason == "continuity_unverified" })
        XCTAssertNil(SleepStager.sessionAvgHRV(start: 0, end: 900, rr: rows))
    }
    func testFinalBinarySleepContextIsUsedWithoutUserAnnotation() {
        let provided = SleepSession(start: 0, end: 900, efficiency: 1,
            stages: [.init(start: 0, end: 900, stage: "sleep_unstaged", state: "sleep_unstaged")], restingHR: nil, avgHRV: nil)
        let result = AnalyticsEngine.analyzeDay(day: "1970-01-01", hrvObservations: observations, profile: profile,
            providedSleep: [provided], localDayStart: 0, localDayEndExclusive: 1800)
        XCTAssertEqual(result.daily.avgHrv, 300)
        XCTAssertEqual(result.hrvMeasurements.first?.context, "sleep")
    }
    func testStageFeaturesUseValidityWithoutSleepLabelAndCannotBypassQuality() {
        let rows = (0..<300).map { RRInterval(ts: $0, rrMs: 1000) }
        let grid = SleepStager.buildEpochGrid(start: 0, end: 300, gravTimes: [], gravDeltas: [], hr: [], rr: rows, resp: [])
        let legacy = SleepStager.extractFeatures(grid: grid, ckFlags: [], dogHR: [], onsetIdx: 0, finalWakeIdx: 9)
        XCTAssertTrue(legacy.allSatisfy { $0.rmssd.isNaN && $0.sdnn.isNaN })
        let measurement = HrvWindow.measure(start: 0, observations: hrvEvidence(pattern: [600, 1400]))
        XCTAssertFalse(measurement.baselineEligible); XCTAssertTrue(measurement.measurementValid)
        let proven = SleepStager.extractFeatures(grid: grid, ckFlags: [], dogHR: [], onsetIdx: 0, finalWakeIdx: 9, hrvMeasurements: [measurement])
        XCTAssertTrue(proven.allSatisfy { $0.rmssd == 800 && $0.sdnn.isFinite })
    }
    func testCausalEngineExcludesIncompleteWindowsAndFutureContext() {
        let result = AnalyticsEngine.analyzeDay(day: "1970-01-01", hrvObservations: observations,
            hrvContext: [.init(start: 0, end: 900, state: "sleep", qualified: true, availableAt: 900)],
            profile: profile, localDayStart: 0, localDayEndExclusive: 1800, sleepComputationMode: "causal", sleepObservedThrough: 450)
        XCTAssertEqual(result.hrvMeasurements.count, 1)
        XCTAssertEqual(result.hrvMeasurements.first?.computationMode, "causal")
        XCTAssertEqual(result.hrvMeasurements.first?.context, "unknown")
        XCTAssertTrue(result.hrvMeasurements.first?.measurementValid == true)
        XCTAssertFalse(result.hrvMeasurements.first?.baselineEligible == true)
    }

    func testRetrospectiveMeasurementCutoffPublishesOnlyClosedWindows() {
        for cutoff in [0, 299, 300, 450, 600, 900] {
            let result = AnalyticsEngine.analyzeDay(day: "1970-01-01", hrvObservations: observations,
                hrvContext: [.init(start: 0, end: 900, state: "sleep", qualified: true)],
                profile: profile, localDayStart: 0, localDayEndExclusive: 1800,
                measurementObservedThrough: cutoff)
            XCTAssertEqual(result.hrvMeasurements.count, cutoff / 300)
            XCTAssertTrue(result.hrvMeasurements.allSatisfy { $0.end <= cutoff && $0.computationMode == "retrospective" })
        }
    }
}
