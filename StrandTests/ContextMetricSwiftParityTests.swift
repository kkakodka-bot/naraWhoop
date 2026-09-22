import Foundation
import StrandAnalytics
import WhoopProtocol
import XCTest

/// Real Swift engine outputs shared with the JVM context-orchestration regression.
/// Synthetic fixtures establish numerical compatibility, not physiological validity.
final class ContextMetricSwiftParityTests: XCTestCase {
    func testSwiftContextEnginesMatchPinnedCrossPlatformVectors() throws {
        let actual = try vectors()
        let data = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys])
        print("CONTEXT_SWIFT_VECTOR " + String(decoding: data, as: UTF8.self))
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "context-metrics-swift-v1", withExtension: "json"))
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture))
        compare(actual, expected, path: "root")
    }

    private func vectors() throws -> [String: Any] {
        let start = Int(try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-18T00:00:00Z")).timeIntervalSince1970)
        let hr = [60, 75, 100].enumerated().flatMap { index, bpm in
            (0..<300).map { HRSample(ts: start + (8 + index) * 3600 + $0, bpm: bpm) }
        }
        let rr = hr.enumerated().map { RRInterval(ts: $0.element.ts, rrMs: 800 + $0.offset % 2 * 40) }
        func stress(_ mode: DaytimeStress.ScoringMode) -> [String: Any] {
            let value = DaytimeStress.analyze(hr: hr, rr: rr, mode: mode)
            return ["mean": value.dayMean as Any? ?? NSNull(), "highMinutes": value.highStressMinutes,
                    "levels": value.hours.map { $0.level as Any? ?? NSNull() },
                    "hrOnlyFallback": value.hrOnlyFallback, "sustainedHigh": value.sustainedHigh]
        }
        let rhr = Baselines.deviation(75, state: Baselines.foldHistory(Array(repeating: 55, count: 28), cfg: Baselines.restingHRCfg)).z
        let hrv = -Baselines.deviation(15, state: Baselines.foldHistory(Array(repeating: 55, count: 28), cfg: Baselines.hrvCfg)).z
        let resp = Baselines.deviation(25, state: Baselines.foldHistory(Array(repeating: 14, count: 28), cfg: Baselines.respCfg)).z
        let signals = IllnessSignalEngine.Inputs(restingHR: .init(zIllnessward: rhr),
            skinTemp: .init(zIllnessward: 1 / 0.3), hrv: .init(zIllnessward: hrv), respiration: .init(zIllnessward: resp))
        func illness(alcohol: Bool) -> [String: Any] {
            let value = IllnessSignalEngine.evaluate(signals, context: .init(alcohol: alcohol))
            return ["score": value.score, "level": value.level.rawValue,
                    "signalCount": value.signalCount, "suppressedBy": value.suppressedBy]
        }
        let distance = IllnessDistance.evaluate(features: .init(restingHR: rhr, rmssd: hrv, skinTemp: 1 / 0.3, respiration: resp))
        let bins = (0..<24).map { CircadianEngine.ActivityBin(hour: Double($0), activity: 65 + 10 * cos(2 * .pi * Double($0 - 16) / 24)) }
        let phase = try XCTUnwrap(CircadianEngine.estimatePhase(bins: bins, daysObserved: 14, habitualWakeHour: 7))
        let format = DateFormatter(); format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "yyyy-MM-dd"
        func z(_ value: Double, _ base: Double, _ spread: Double) -> Double {
            Baselines.deviation(value, state: .init(baseline: base, spread: spread, nValid: 50, nightsSinceUpdate: 0, status: .trusted)).z
        }
        let nights = (0..<60).map { i -> CyclePhaseEngine.Night in
            let wave = sin(2 * Double.pi * Double(i) / 28)
            return .init(day: format.string(from: Date(timeIntervalSince1970: Double(start - (59 - i) * 86400))),
                         tempZ: z(35 + 0.5 * wave, 35, 0.3), rhrZ: z(Double(55 + Int(3 * wave)), 55, 2),
                         hrvZ: z(55 - 8 * wave, 55, 5))
        }
        let cycle = CyclePhaseEngine.classify(nights, baselineUsable: true, loggedPeriodStarts: ["2026-08-01", "2026-08-29"])
        let index = try XCTUnwrap(StressIndex.components(rr: rr))
        let freq = try XCTUnwrap(HRVFreqDomain.freqDomain(rr: rr))
        return ["schema": 1, "recipe": "context-engine-synthetic-v1", "timezone": "UTC",
                "dayRelative": stress(.dayRelative),
                "personalBaseline": stress(.baselineRelative(hr: .init(baseline: 50, spread: 3, nValid: 50, nightsSinceUpdate: 0, status: .trusted), rmssd: nil)),
                "illness": illness(alcohol: false), "suppressedIllness": illness(alcohol: true),
                "distance": ["value": distance.distance, "fires": distance.fires],
                "circadian": ["phaseHour": phase.tempMinHour, "offsetMinutes": phase.offsetVsScheduleMinutes,
                              "confidence": phase.confidence.rawValue, "acrophase": phase.acrophaseHours],
                "cycle": ["phase": cycle.phase.rawValue, "confidence": cycle.confidence.rawValue,
                          "dayLow": cycle.cycleDayLow as Any? ?? NSNull(), "dayHigh": cycle.cycleDayHigh as Any? ?? NSNull(),
                          "length": cycle.cycleLengthDays as Any? ?? NSNull(), "markers": cycle.shiftMarkers.map(\.day),
                          "index": nights.map { CyclePhaseEngine.fusedIndex(tempZ: $0.tempZ, rhrZ: $0.rhrZ, hrvZ: $0.hrvZ) as Any? ?? NSNull() }],
                "stressIndex": ["value": index.si, "modeSeconds": index.moSec, "modePercent": index.aMoPercent, "rangeSeconds": index.mxDMnSec],
                "frequency": ["lf": freq.lf as Any? ?? NSNull(), "hf": freq.hf, "ratio": freq.lfhf as Any? ?? NSNull()]]
    }

    private func compare(_ actual: Any, _ expected: Any, path: String) {
        if let a = actual as? [String: Any], let b = expected as? [String: Any] {
            XCTAssertEqual(Set(a.keys), Set(b.keys), path)
            for key in a.keys.sorted() { if let rhs = b[key] { compare(a[key]!, rhs, path: path + "." + key) } }
        } else if let a = actual as? [Any], let b = expected as? [Any] {
            XCTAssertEqual(a.count, b.count, path)
            for (index, pair) in zip(a, b).enumerated() { compare(pair.0, pair.1, path: path + "[\(index)]") }
        } else if let a = actual as? NSNumber, let b = expected as? NSNumber {
            XCTAssertEqual(CFGetTypeID(a) == CFBooleanGetTypeID(), CFGetTypeID(b) == CFBooleanGetTypeID(), path)
            XCTAssertEqual(a.doubleValue, b.doubleValue, accuracy: max(1e-8, abs(b.doubleValue) * 1e-9), path)
        } else {
            XCTAssertEqual(String(describing: actual), String(describing: expected), path)
        }
    }
}
