import XCTest
@testable import Strand

/// Pins the #943 Metric Explorer chip-coercion rule (Swift twin of Android VitalRangeGatingTest's
/// largestUnlockedRangeIsTheCoercionTarget). A LOCKED selection renders as the largest unlocked range
/// with a real finite window (never ALL) that is <= the selection, else WEEK; an unlocked selection is
/// kept verbatim. The rule is non-destructive - it never mutates the stored @State - so this is the
/// whole contract. Byte-identical rule to Android's coercedVitalRange.
final class ExploreRangeGatingTests: XCTestCase {

    /// Only WEEK + ALL unlocked (the first-week / calibrating state).
    private func wk1(_ r: ExploreRange) -> Bool { r == .week || r == .all }
    /// WEEK + MONTH + ALL unlocked (~10 days of history).
    private func span10(_ r: ExploreRange) -> Bool { r == .week || r == .month || r == .all }

    func testLockedSelectionCoercesToLargestUnlockedFiniteWindow() {
        // MONTH default in week 1 -> WEEK (not ALL, not MONTH which is locked).
        XCTAssertEqual(ExploreRangeGating.coerced(selection: .month, isUnlocked: wk1), .week)
        XCTAssertEqual(ExploreRangeGating.coerced(selection: .year, isUnlocked: wk1), .week)
        // With MONTH unlocked, a locked YEAR coerces DOWN to MONTH.
        XCTAssertEqual(ExploreRangeGating.coerced(selection: .year, isUnlocked: span10), .month)
    }

    func testUnlockedSelectionIsVerbatimAndAllIsAlwaysKept() {
        XCTAssertEqual(ExploreRangeGating.coerced(selection: .week, isUnlocked: wk1), .week)
        // ALL is always unlocked, so a stored ALL is never coerced away.
        XCTAssertEqual(ExploreRangeGating.coerced(selection: .all, isUnlocked: wk1), .all)
    }

    func testNothingLockedKeepsSelection() {
        XCTAssertEqual(ExploreRangeGating.coerced(selection: .quarter, isUnlocked: { _ in true }), .quarter)
    }

    func testShortHistoryCaptionDoesNotCallAContractedRangeSparseOrWidened() {
        let effective = ExploreRangeGating.coerced(selection: .month, isUnlocked: wk1)
        let widened = ExploreRangeGating.widened(selection: .month, effectiveRange: effective, isUnlocked: wk1)
        XCTAssertFalse(widened)
        XCTAssertEqual(ExploreRangeGating.readingCaption(count: 3, effectiveRange: effective, widened: widened),
                       "3 readings · week")
    }

    func testGenuineWideningCaptionNamesDisplayedWindow() {
        let widened = ExploreRangeGating.widened(selection: .week, effectiveRange: .month, isUnlocked: { _ in true })
        XCTAssertTrue(widened)
        XCTAssertEqual(ExploreRangeGating.readingCaption(count: 1, effectiveRange: .month, widened: widened),
                       "1 reading · sparse, widened to month")
    }

    func testTwoAndThreeWeekWindowsDoNotJumpToAllHistory() {
        XCTAssertEqual(ExploreRange.twoWeeks.widening.first, .twoWeeks)
        XCTAssertEqual(ExploreRange.threeWeeks.widening.first, .threeWeeks)
        XCTAssertEqual(ExploreRange.twoWeeks.widening.last, .all)
    }
}
