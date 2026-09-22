import Foundation
import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class PhoneInferenceRetirementTests: XCTestCase {
    func testFinalHostedOptionalProducersRefuseBeforeNumericalWork() {
        PhoneComputeRuntime.resetTestCounters()
        PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            XCTAssertNil(HRVAnalyzer.rmssdRaw([800, 810, 790]))
            XCTAssertNil(HRVAnalyzer.sdnnRaw([800, 810, 790]))
            XCTAssertNil(HRVAnalyzer.rmssdGapAware([800, 810], [true, true]))
            XCTAssertNil(HRVAnalyzer.pnn50GapAware([800, 810], [true, true]))
            XCTAssertTrue(HRVAnalyzer.cleanRR([800, 810, 790]).isEmpty)
            XCTAssertNil(HRVAnalyzer.sdnnIndex([]))
            XCTAssertNil(HRVFreqDomain.freqDomain(rawRR: [800, 810, 790]))
            XCTAssertNil(CurrentHRV.derive(rows: [], nowUnix: 600))
            XCTAssertNil(SpotHrvReading.meanHrFromNN(800))
            XCTAssertNil(StressIndex.stressIndex(rawRR: [800, 810, 790]))
            XCTAssertTrue(HeartRateWindows.windows(start: 0, end: 300, hr: [], gravity: []).isEmpty)
            XCTAssertTrue(HrvSeries.windows(start: 0, end: 300, observations: []).isEmpty)
            XCTAssertNil(StepsCounter.stepsInWindow([]))
            XCTAssertNil(CircadianEngine.cosinor([]))
            XCTAssertNil(HRVReadiness.evaluate(avgHrv: [50, 51]))
            XCTAssertNil(DailyPresentationMath.mean([1, 2]))
            XCTAssertNil(DailyPresentationMath.restorativeMinutes(deepMin: 60, remMin: 90))
            XCTAssertNil(AnalyticsEngine.primarySessionRestingHR(sessions: [], hr: []))
        }
        let counters = PhoneComputeRuntime.counters()
        XCTAssertTrue(counters.executions.isEmpty, "Admission must precede all physiological work")
        XCTAssertEqual(counters.denied.values.reduce(0, +), 18)
    }

    func testFinalHostedLeavesUserTimersFormattingAndRawProvenanceOperational() {
        PhoneComputeRuntime.resetTestCounters()
        PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            XCTAssertEqual(BreathPacer.schedule(bpm: 6, cycles: 2).count, 4)
            XCTAssertEqual(BreathPacer.sessionDurationMs(bpm: 6, cycles: 2), 20_000)
            XCTAssertEqual(CurrentHRV.completedWindow(nowUnix: 650), 300..<600)
            XCTAssertEqual(HydrationGoal.litres(fromML: 1250), 1.25)
            XCTAssertEqual(DailyPresentationMath.efficiencyPercent(0.9), 90)
            XCTAssertEqual(ClockFormat.hourMinutePattern(uses24Hour: true), "HH:mm")
            XCTAssertEqual(PhysiologyQuality.legacy([], deviceId: "capture-device").count, 0)
            _ = LiveSessionEngine(config: .init(restingHR: 55, hrMax: 190, charge: nil), startTs: 0)
            XCTAssertEqual(GuidedCaptureProgress.evaluate(target: 3, nightsWithData: 1,
                nightsElapsed: 2), .capturing(done: 1, target: 3))
        }
        XCTAssertTrue(PhoneComputeRuntime.counters().executions.isEmpty)
        XCTAssertTrue(PhoneComputeRuntime.counters().denied.isEmpty)
    }

    func testReferenceModeStillExecutesRealNumericalProducer() {
        PhoneComputeRuntime.resetTestCounters()
        PhoneComputeRuntime.$testMode.withValue(.reference) {
            XCTAssertEqual(HRVAnalyzer.rmssdRaw([800, 810, 790])!, sqrt(250), accuracy: 0.000001)
        }
        XCTAssertEqual(PhoneComputeRuntime.counters().executions["swift.HRVAnalyzer.rmssdRaw"], 1)
        XCTAssertTrue(PhoneComputeRuntime.counters().denied.isEmpty)
    }

    #if os(macOS)
    /// Each child is a real XCTest process. It must stop at the producer's first instruction,
    /// including on empty input; an input-quality early return must not conceal a reachable scorer.
    func testNonoptionalEntrypointsFailLoudlyInFinalHostedMode() throws {
        let cases = ["daily", "spot", "baseline", "sleep", "recovery", "strain", "calories",
                     "stress", "cycle", "circadian", "training", "coaching", "hydration", "frequency"]
        for name in cases {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest",
                "StrandAnalyticsTests.PhoneInferenceRetirementTests/testFailLoudChild",
                Bundle(for: Self.self).bundlePath]
            var environment = ProcessInfo.processInfo.environment
            environment["NOOP_PRODUCER_DEATH_TEST"] = name
            environment["SWIFT_BACKTRACE"] = "enable=no"
            process.environment = environment
            process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let log = String(decoding: data, as: UTF8.self)
            XCTAssertNotEqual(process.terminationStatus, 0, "\(name) executed in final mode: \(log)")
            XCTAssertTrue(log.contains("Local physiology forbidden in final hosted mode"),
                          "\(name) must fail at the compute guard, not another error: \(log)")
        }
    }

    func testFailLoudChild() {
        guard let name = ProcessInfo.processInfo.environment["NOOP_PRODUCER_DEATH_TEST"] else { return }
        PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            switch name {
            case "daily": _ = AnalyticsEngine.analyzeDay(day: "2026-09-21", profile: UserProfile())
            case "spot": _ = SpotHrvReading.compute([])
            case "baseline": _ = Baselines.lambda(halfLife: 7)
            case "sleep": _ = SleepStagerV2.remLatencyGuard(0)
            case "recovery": _ = RecoveryScorer.logisticScore(compositeZ: 0)
            case "strain": _ = StrainScorer.trimpToStrain(0)
            case "calories": _ = Calories.estimateDayCalories([], profile: UserProfile(), hrmax: nil, restingHR: nil)
            case "stress": _ = DaytimeStress.squash(0)
            case "cycle": _ = CyclePhaseEngine.classify([], baselineUsable: false)
            case "circadian": _ = CircadianEngine.sleepWindowOffsetHours(tempMinHour: 4, actualWakeHour: 7)
            case "training": _ = TrainingLoadEngine.evaluateDense([])
            case "coaching": _ = HRDownPacer.next(currentHR: 70, elapsed: 0)
            case "hydration": _ = HydrationGoal.dailyGoalML(sex: "unspecified", effort: nil)
            case "frequency": _ = HRVFreqDomain.bandPower(times: [], y: [], fLow: 0, fHigh: 0)
            default: XCTFail("Unknown test producer")
            }
        }
        XCTFail("A nonoptional local producer returned in final hosted mode")
    }
    #endif
}
