import Foundation
import XCTest
@testable import Strand

final class SyncIntervalMetricsTests: XCTestCase {
    private func stage(_ metrics: SyncIntervalMetrics, _ stage: String = "ordinaryTransfer") -> [String: Any] {
        (metrics.snapshot()["stages"] as! [String: Any])[stage] as! [String: Any]
    }

    func testFailuresAndTimeoutsRemainInDurationPopulationWithUnfinishedCount() {
        var now: TimeInterval = 0
        let metrics = SyncIntervalMetrics(clock: { now })
        let success = metrics.begin(.ordinaryTransfer)
        now = 0.1; metrics.end(success, outcome: .succeeded)
        let failed = metrics.begin(.ordinaryTransfer)
        now = 0.3; metrics.end(failed, outcome: .failed)
        let timeout = metrics.begin(.ordinaryTransfer)
        now = 2.3; metrics.end(timeout, outcome: .timedOut)
        _ = metrics.begin(.ordinaryTransfer)
        now = 3.3
        let result = stage(metrics)
        XCTAssertEqual(result["started_count"] as? Int, 4)
        XCTAssertEqual(result["completed_count"] as? Int, 3)
        XCTAssertEqual(result["unfinished_count"] as? Int, 1)
        XCTAssertEqual((result["outcomes"] as? [String: Int])?["timedOut"], 1)
        XCTAssertEqual((result["outcomes"] as? [String: Int])?["failed"], 1)
        XCTAssertEqual((result["p95_bounds"] as? [String: Double])?["upper_ms"], 2_000)
        XCTAssertEqual(result["maximum_completed_ms"] as! Double, 2_000, accuracy: 0.001)
        XCTAssertEqual(result["oldest_unfinished_ms"] as! Double, 1_000, accuracy: 0.001)
    }

    func testCapacityLossAndDuplicateEndAreVisibleAndCannotBecomeSuccessfulLatency() {
        var now: TimeInterval = 0
        let metrics = SyncIntervalMetrics(maximumActive: 1, clock: { now })
        let first = metrics.begin(.ordinaryTransfer)
        let second = metrics.begin(.ordinaryTransfer)
        XCTAssertNil(second)
        now = 1; metrics.end(first, outcome: .cancelled)
        metrics.end(first, outcome: .succeeded)
        metrics.end(second, outcome: .succeeded)
        let result = stage(metrics)
        XCTAssertEqual(result["started_count"] as? Int, 2)
        XCTAssertEqual(result["completed_count"] as? Int, 1)
        XCTAssertEqual(result["untracked_start_count"] as? Int, 1)
        XCTAssertEqual((result["outcomes"] as? [String: Int])?["succeeded"], 0)
        XCTAssertEqual(metrics.snapshot()["unmatched_completion_count"] as? Int, 1)
    }

    func testMissingAndInvalidClockRemainUnknown() {
        var now: TimeInterval = 10
        let metrics = SyncIntervalMetrics(clock: { now })
        XCTAssertTrue(stage(metrics)["p95_bounds"] is NSNull)
        let first = metrics.begin(.ordinaryTransfer)
        now = 9; metrics.end(first, outcome: .failed)
        let result = stage(metrics)
        XCTAssertEqual(result["completed_count"] as? Int, 1)
        XCTAssertEqual(result["invalid_clock_count"] as? Int, 1)
        XCTAssertTrue(result["maximum_completed_ms"] is NSNull)
        XCTAssertTrue(result["p95_bounds"] is NSNull)
        XCTAssertEqual(result["duration_sample_count"] as? Double, 0)
        _ = metrics.begin(.uploadReceipt)
        now = .infinity
        let snapshot = metrics.snapshot()
        XCTAssertTrue(snapshot["observation_elapsed_ms"] is NSNull)
        XCTAssertEqual(snapshot["observation_clock_valid"] as? Bool, false)
        XCTAssertEqual(snapshot["events"] as? String, "excluded_from_interval_counts")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: snapshot))
    }

    func testLongRunExportRemainsBoundedWithoutClaimingPriorProcessOrEndToEndCoverage() throws {
        var now: TimeInterval = 0
        let metrics = SyncIntervalMetrics(clock: { now })
        for _ in 0..<10_000 {
            let id = metrics.begin(.uploadReceipt)
            now += 0.01; metrics.end(id, outcome: .waitingForServer)
        }
        let before = metrics.snapshot()
        let data = try JSONSerialization.data(withJSONObject: before, options: [.sortedKeys])
        XCTAssertLessThan(data.count, 32 * 1024)
        XCTAssertEqual(before["coverage"] as? String, "current_process_application_intervals")
        XCTAssertEqual(before["previous_process_coverage"] as? String, "NOT_MEASURED")
        XCTAssertEqual(before["end_to_end_latency"] as? String, "matched_boundary_trace_required")
        XCTAssertEqual(stage(metrics, "uploadReceipt")["completed_count"] as? Int, 10_000)
        XCTAssertEqual(metrics.snapshot()["process_generation"] as? String, before["process_generation"] as? String)
    }
}
