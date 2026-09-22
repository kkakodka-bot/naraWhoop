import CryptoKit
import Foundation
import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class CurrentHRVNativeOracleTests: XCTestCase {
    func testLegacyDeliveryCoverageIsNotAQualifiedCurrentMeasurement() throws {
        let now = 1_700_000_100
        var intervals = Array(repeating: 800, count: 24)
        intervals[12] = 5_000
        let rows = intervals.enumerated().map {
            RRInterval(ts: now - (intervals.count - 1 - $0.offset), rrMs: $0.element)
        }
        // The old oracle treated transport-second coverage as proof of consecutive beats.
        // CurrentHRV now requires an exactly closed five-minute window with verified spans;
        // retaining the old raw diagnostic below must not re-authorize coarse observations.
        let snapshot = CurrentHRV.derive(rows: rows, nowUnix: now)
        XCTAssertNil(snapshot)
        XCTAssertEqual(intervals.reduce(0, +), 23_400)
        XCTAssertEqual(rows.last!.ts - rows.first!.ts, 23)

        let raw = intervals.map(Double.init)
        let cleaned = HRVAnalyzer.analyze(rawRR: raw)
        XCTAssertEqual(cleaned.nInput, 24)
        XCTAssertEqual(cleaned.nClean, 23)
        XCTAssertEqual(cleaned.rmssd, 0)
        XCTAssertEqual(HRVAnalyzer.rrCoverage(tsSec: rows.map(\.ts), rrMs: raw), 1.017391304347826, accuracy: 1e-15)

        let controlNow = 1_700_000_000
        let controlRows = (0..<30).map { RRInterval(ts: controlNow - (29 - $0), rrMs: 820) }
        let control = CurrentHRV.derive(rows: controlRows, nowUnix: controlNow)
        XCTAssertNil(control)
        XCTAssertEqual(HRVAnalyzer.rrCoverage(tsSec: controlRows.map(\.ts), rrMs: controlRows.map { Double($0.rrMs) }),
                       0.8482758620689655, accuracy: 1e-15)
        let verified = (0..<300).map { index in
            PhysiologyQuality.IntervalObservation(originalId: "interval-\(index)", deviceId: "oracle-device",
                source: "oracle-ecg", modality: "ecg_nn", eventTime: Double(index), originalRRMs: 1000,
                startBeatId: "beat-\(index)", endBeatId: "beat-\(index + 1)", continuityGroup: "continuous",
                verifiedSpan: .init(Double(index), Double(index + 1)), timestampPrecisionSeconds: 0.001,
                decoderVersion: "oracle-v2", clockVersion: "verified-oracle-v2", ordinal: index, deviceFirmware: "fixture-v2")
        }
        let qualified = try XCTUnwrap(CurrentHRV.derive(observations: verified, nowUnix: 300))
        XCTAssertEqual(qualified.coverage, 1)
        XCTAssertEqual(qualified.cleanBeats, 300)
        XCTAssertEqual(qualified.rmssdMs, 0, "A qualified true zero must remain available")

        guard testRun?.failureCount == 0 else { throw ExportError.failedAssertion }
        guard let path = ProcessInfo.processInfo.environment["W4_CURRENT_HRV_ORACLE_PATH"] else { return }
        let destination = URL(fileURLWithPath: path).standardizedFileURL
        guard destination.lastPathComponent == "current-hrv-native-oracle.json",
              destination.resolvingSymlinksInPath() == destination else { throw ExportError.unsafePath }
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let sourcePaths = [
            "Packages/StrandAnalytics/Sources/StrandAnalytics/CurrentHRV.swift",
            "Packages/StrandAnalytics/Sources/StrandAnalytics/HRVAnalyzer.swift",
            "Packages/StrandAnalytics/Sources/StrandAnalytics/HrvWindow.swift",
            "Packages/StrandAnalytics/Sources/StrandAnalytics/HrvSeries.swift",
            "Packages/StrandAnalytics/Sources/StrandAnalytics/PhysiologyQuality.swift",
            "Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift",
            "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/CurrentHRVNativeOracleTests.swift"
        ]
        var hashes: [String: String] = [:]
        for source in sourcePaths {
            hashes[source] = SHA256.hash(data: try Data(contentsOf: repository.appendingPathComponent(source)))
                .map { String(format: "%02x", $0) }.joined()
        }
        func vector(_ id: String, _ rows: [RRInterval], _ now: Int, _ result: CurrentHRV.Snapshot?) -> [String: Any] {
            ["id": id, "input": ["nowUnix": now, "windowSeconds": CurrentHRV.windowSeconds,
                "rows": rows.map { ["ts": $0.ts, "rrMs": $0.rrMs, "seq": $0.seq] }],
             "actual": result.map { ["rmssdMs": $0.rmssdMs, "cleanBeats": $0.cleanBeats,
                "coverage": $0.coverage, "computedAtUnix": $0.computedAtUnix] as [String: Any] } as Any? ?? NSNull()]
        }
        let fixture: [String: Any] = ["schemaVersion": 2, "producer": "actual-swift",
            "entrypoint": "CurrentHRV.derive", "sourceHashes": hashes,
            "cases": [vector("mid-window-ectopic", rows, now, snapshot), vector("fresh-steady-control", controlRows, controlNow, control)]]
        let bytes = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys, .withoutEscapingSlashes])
        try bytes.write(to: destination, options: .atomic)
        print("CURRENT_HRV_NATIVE_ORACLE \(String(decoding: bytes, as: UTF8.self))")
    }

    private enum ExportError: Error { case failedAssertion, unsafePath }
}
