import XCTest
@testable import StrandAnalytics

final class W4CycleCalendarTests: XCTestCase {
    private typealias F = W4FiveSeamFixtures
    private func nights(_ count: Int = 84) -> [CyclePhaseEngine.Night] {
        (0..<count).map { i in
            let high = i % 28 >= 16
            return .init(day: F.day(i), tempZ: high ? 1.4 : -0.2, rhrZ: high ? 1 : -0.1, hrvZ: high ? -1 : 0.1)
        }
    }

    func testDenseCalendarAndPeriodEvidenceMatchLegacyExactly() throws {
        let rows = nights(), periods = [F.day(0), F.day(28), F.day(56)]
        XCTAssertEqual(try CyclePhaseEngine.classifyCalendar(rows.reversed(), baselineUsable: true, through: F.day(83), loggedPeriodStarts: periods),
                       CyclePhaseEngine.classify(rows, baselineUsable: true, loggedPeriodStarts: periods))
    }

    func testUnknownDoesNotCreateFalseRisingEdge() throws {
        let rows = nights()
        let observed = try CyclePhaseEngine.classifyCalendar(rows, baselineUsable: true, through: F.day(83))
        XCTAssertEqual(observed.shiftMarkers.map(\.day), [16, 44, 72].map(F.day))
        let hole = rows.filter { $0.day != F.day(71) }
        let unknown = try CyclePhaseEngine.classifyCalendar(hole, baselineUsable: true, through: F.day(83))
        XCTAssertEqual(unknown.shiftMarkers.map(\.day), [16, 44].map(F.day))
        let explicitNil = CyclePhaseEngine.Night(day: F.day(71), tempZ: nil, rhrZ: nil, hrvZ: nil)
        XCTAssertEqual(try CyclePhaseEngine.classifyCalendar(hole + [explicitNil], baselineUsable: true, through: F.day(83)), unknown)
        let legacy = CyclePhaseEngine.classify((hole + [explicitNil]).sorted { $0.day < $1.day }, baselineUsable: true)
        XCTAssertTrue(legacy.shiftMarkers.contains { $0.day == F.day(72) }, "legacy nil-to-false behavior stays unchanged")
    }

    func testMissingCurrentNeverProducesAConfidentHistoricalPhase() throws {
        let rows = nights(), learning = CyclePhaseEngine.classify([], baselineUsable: true)
        XCTAssertEqual(try CyclePhaseEngine.classifyCalendar(Array(rows.dropLast()), baselineUsable: true, through: F.day(83)), learning)
        let current = CyclePhaseEngine.Night(day: F.day(83), tempZ: nil, rhrZ: nil, hrvZ: nil)
        XCTAssertEqual(try CyclePhaseEngine.classifyCalendar(Array(rows.dropLast()) + [current], baselineUsable: true, through: F.day(83)), learning)
        XCTAssertEqual(try CyclePhaseEngine.classifyCalendar([], baselineUsable: true, through: F.day(83)), learning)
    }

    func testCurrentAdmissionGateAndObservedCountRemainRequired() throws {
        XCTAssertEqual(try CyclePhaseEngine.classifyCalendar(nights(), baselineUsable: false, through: F.day(83)).phase, .learning)
        let sparse = nights().enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
        XCTAssertEqual(try CyclePhaseEngine.classifyCalendar(sparse, baselineUsable: true, through: sparse.last!.day).phase, .learning)
        let row = CyclePhaseEngine.Night(day: F.day(84), tempZ: nil, rhrZ: 1, hrvZ: nil)
        XCTAssertEqual(CyclePhaseEngine.fusedIndex(tempZ: row.tempZ, rhrZ: row.rhrZ, hrvZ: row.hrvZ), 1)
        XCTAssertEqual(try CyclePhaseEngine.classifyCalendar(nights() + [row], baselineUsable: false, through: row.day).phase, .learning,
                       "context/current-temperature admission is explicit, not inferred from corroborating RHR")
    }

    func testFutureNightsAndLogsDoNotChangeHistoricalResult() throws {
        let rows = nights()
        let expected = try CyclePhaseEngine.classifyCalendar(rows, baselineUsable: true, through: F.day(83), loggedPeriodStarts: [F.day(56)])
        let future = CyclePhaseEngine.Night(day: F.day(100), tempZ: 10, rhrZ: 10, hrvZ: -10)
        XCTAssertEqual(try CyclePhaseEngine.classifyCalendar(rows + [future, future], baselineUsable: true, through: F.day(83),
            loggedPeriodStarts: [F.day(56), F.day(100)]), expected)
    }

    func testStrictKeysDuplicatesAndLeapDate() throws {
        for key in ["2026-02-30", "2026-1-01", "0000-01-01", ""] {
            XCTAssertThrowsError(try CyclePhaseEngine.classifyCalendar([], baselineUsable: true, through: key)) {
                XCTAssertEqual($0 as? CyclePhaseEngine.CalendarInputError, .invalidDay(key))
            }
            XCTAssertThrowsError(try CyclePhaseEngine.classifyCalendar([], baselineUsable: true, through: F.day(83), loggedPeriodStarts: [key]))
        }
        XCTAssertNoThrow(try CyclePhaseEngine.classifyCalendar([], baselineUsable: true, through: "2024-02-29"))
        let row = nights()[0]
        XCTAssertThrowsError(try CyclePhaseEngine.classifyCalendar([row, row], baselineUsable: true, through: F.day(83))) {
            XCTAssertEqual($0 as? CyclePhaseEngine.CalendarInputError, .duplicateDay(row.day))
        }
    }
}
