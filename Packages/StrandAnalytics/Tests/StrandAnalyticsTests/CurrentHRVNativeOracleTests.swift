import CryptoKit
import Foundation
import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class CurrentHRVNativeOracleTests: XCTestCase {
    func testActualSwiftCoverageIncludesEctopicBeforeCleaning() throws {
        let now = 1_700_000_100
        var intervals = Array(repeating: 800, count: 24)
        intervals[12] = 5_000
        let rows = intervals.enumerated().map {
            RRInterval(ts: now - (intervals.count - 1 - $0.offset), rrMs: $0.element)
        }
        let snapshot = try XCTUnwrap(CurrentHRV.derive(rows: rows, nowUnix: now))
        XCTAssertEqual(snapshot.coverage, 1.017391304347826, accuracy: 1e-15)
        XCTAssertNotEqual(snapshot.coverage, 0.8)
        XCTAssertEqual(snapshot.cleanBeats, 23)
        XCTAssertEqual(snapshot.rmssdMs, 0)
        XCTAssertEqual(snapshot.computedAtUnix, now)
        XCTAssertEqual(intervals.reduce(0, +), 23_400)
        XCTAssertEqual(rows.last!.ts - rows.first!.ts, 23)

        let raw = intervals.map(Double.init)
        let cleaned = HRVAnalyzer.analyze(rawRR: raw)
        XCTAssertEqual(cleaned.nInput, 24)
        XCTAssertEqual(cleaned.nClean, 23)
        XCTAssertEqual(cleaned.rmssd, 0)
        XCTAssertEqual(snapshot.coverage, HRVAnalyzer.rrCoverage(tsSec: rows.map(\.ts), rrMs: raw))

        let controlNow = 1_700_000_000
        let controlRows = (0..<30).map { RRInterval(ts: controlNow - (29 - $0), rrMs: 820) }
        let control = try XCTUnwrap(CurrentHRV.derive(rows: controlRows, nowUnix: controlNow))
        XCTAssertEqual(control.coverage, 0.8482758620689655, accuracy: 1e-15)
        XCTAssertEqual(control.cleanBeats, 30)
        XCTAssertEqual(control.rmssdMs, 0)

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
            "Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift",
            "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/CurrentHRVNativeOracleTests.swift"
        ]
        var hashes: [String: String] = [:]
        for source in sourcePaths {
            hashes[source] = SHA256.hash(data: try Data(contentsOf: repository.appendingPathComponent(source)))
                .map { String(format: "%02x", $0) }.joined()
        }
        func vector(_ id: String, _ rows: [RRInterval], _ result: CurrentHRV.Snapshot) -> [String: Any] {
            ["id": id, "input": ["nowUnix": result.computedAtUnix, "windowSeconds": CurrentHRV.windowSeconds,
                "rows": rows.map { ["ts": $0.ts, "rrMs": $0.rrMs, "seq": $0.seq] }],
             "actual": ["rmssdMs": result.rmssdMs, "cleanBeats": result.cleanBeats,
                "coverage": result.coverage, "computedAtUnix": result.computedAtUnix]]
        }
        let fixture: [String: Any] = ["schemaVersion": 1, "producer": "actual-swift",
            "entrypoint": "CurrentHRV.derive", "sourceHashes": hashes,
            "cases": [vector("mid-window-ectopic", rows, snapshot), vector("fresh-steady-control", controlRows, control)]]
        let bytes = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys, .withoutEscapingSlashes])
        try bytes.write(to: destination, options: .atomic)
        print("CURRENT_HRV_NATIVE_ORACLE \(String(decoding: bytes, as: UTF8.self))")
    }

    private enum ExportError: Error { case failedAssertion, unsafePath }
}
