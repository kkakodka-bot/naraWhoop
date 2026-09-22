import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

final class CanonicalWorkoutInputTests: XCTestCase {
    func testFinalHostedMergePreservesUserWindowAndNotesWithoutCombiningPhysiology() throws {
        try PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            PhoneComputeRuntime.resetTestCounters()
            let rows = [
                WorkoutRow(startTs: 100, endTs: 160, sport: "Running", source: "manual",
                    durationS: 60, energyKcal: 35, avgHr: 120, maxHr: 140, strain: 12,
                    distanceM: 200, zonesJSON: "[0,0,1,0,0]", notes: "First", steps: 100),
                WorkoutRow(startTs: 200, endTs: 290, sport: "Running", source: "manual",
                    durationS: 90, energyKcal: 50, avgHr: 150, maxHr: 180, strain: 18,
                    distanceM: 300, zonesJSON: "[0,0,0,1,0]", notes: "Second", steps: 200)
            ]
            XCTAssertTrue(WorkoutMerge.canMerge(rows))
            let merged = try XCTUnwrap(WorkoutMerge.merge(rows))
            XCTAssertEqual(merged.startTs, 100)
            XCTAssertEqual(merged.endTs, 290)
            XCTAssertEqual(merged.durationS, 150, "Timer metadata remains usable offline")
            XCTAssertEqual(merged.sport, "Running")
            XCTAssertEqual(merged.source, "manual")
            XCTAssertEqual(merged.notes, "First · Second")
            XCTAssertNil(merged.energyKcal)
            XCTAssertNil(merged.avgHr)
            XCTAssertNil(merged.maxHr)
            XCTAssertNil(merged.strain)
            XCTAssertNil(merged.zonesJSON)
            XCTAssertNil(merged.distanceM)
            XCTAssertNil(merged.steps)
            XCTAssertTrue(PhoneComputeRuntime.counters().executions.isEmpty)
        }
    }
}
