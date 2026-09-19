import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class HeartRateWindowsTests: XCTestCase {
    func testSerializedParityAndAdversarialWindows() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "heart_rate_windows_oracle", withExtension: "json", subdirectory: "Resources"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for c in try XCTUnwrap(root["cases"] as? [[String: Any]]) {
            let id = c["id"] as! String, rows = c["rows"] as! [[Any]]
            let result = HeartRateWindows.windows(start: c["start"] as! Int, end: c["end"] as! Int,
                hr: rows.map { HRSample(ts: $0[0] as! Int, bpm: $0[1] as! Int) },
                gravity: rows.map { GravitySample(ts: $0[0] as! Int, x: 0, y: 0, z: 1, dynAccel: $0[2] as? Double) },
                excluded: (c["excluded"] as! [[Double]]).map { .init($0[0], $0[1]) })
            if id == "leading_partial_skipped" { XCTAssertTrue(result.isEmpty); continue }
            let window = try XCTUnwrap(result.first, id)
            XCTAssertEqual(result.count, 1, id)
            XCTAssertEqual(window.start, 0, id); XCTAssertEqual(window.end, 300, id)
            XCTAssertEqual(window.meanBpm, c["mean"] as? Double, id)
            XCTAssertEqual(window.lowMotionBpm, c["quiet"] as? Double, id)
            XCTAssertEqual(window.reason, c["reason"] as? String, id)
            XCTAssertEqual(window.lowMotionReason, c["quiet_reason"] as? String, id)
        }
    }
    func testCurrentHrvReadsTheExactCompletedWindowAtAnyRefreshTime() {
        XCTAssertEqual(CurrentHRV.completedWindow(nowUnix: 459), 0..<300)
        XCTAssertEqual(CurrentHRV.completedWindow(nowUnix: 600), 300..<600)
    }

    func testMovingSecondsAreExcludedWithoutInvalidatingAnOtherwiseCoveredWindow() throws {
        let hr = (0..<300).map { HRSample(ts: $0, bpm: $0 == 10 ? 180 : 60) }
        let gravity = (0..<300).map {
            GravitySample(ts: $0, x: 0, y: 0, z: 1, dynAccel: $0 < 20 ? 0.04 : 0.01)
        }
        let window = try XCTUnwrap(HeartRateWindows.windows(start: 0, end: 300, hr: hr, gravity: gravity).first)
        XCTAssertEqual(window.lowMotionSampleFraction, 280.0 / 300.0, accuracy: 1e-12)
        XCTAssertEqual(window.lowMotionBpm, 60)
        XCTAssertNil(window.lowMotionReason)
        XCTAssertEqual(window.movingSeconds, 20)
        XCTAssertEqual(window.motionObservedSeconds, 300)

        let tooMuchMotion = gravity.map {
            GravitySample(ts: $0.ts, x: 0, y: 0, z: 1, dynAccel: $0.ts < 31 ? 0.04 : 0.01)
        }
        let rejected = try XCTUnwrap(HeartRateWindows.windows(start: 0, end: 300, hr: hr, gravity: tooMuchMotion).first)
        XCTAssertNil(rejected.lowMotionBpm)
        XCTAssertEqual(rejected.lowMotionReason, "insufficient_motion_matched_samples")
        XCTAssertEqual(rejected.movingSeconds, 31)
        XCTAssertEqual(rejected.motionObservedSeconds, 300)
    }
}
