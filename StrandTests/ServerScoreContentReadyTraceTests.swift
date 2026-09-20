import XCTest
#if !SERVER_SCORE_NATIVE_TESTS
@testable import Strand
#endif

final class ServerScoreContentReadyTraceTests: XCTestCase {
    @MainActor
    func testCachedContentCompletesOneIntervalWithoutClaimingFrameCompletion() {
        var begins = 0
        var outcomes: [String] = []
        let trace = ServerScoreContentReadyTrace(begin: {
            begins += 1
            return { outcomes.append($0.rawValue) }
        })
        let key = ServerScoreContentReadyTrace.Identity(generation: UUID(), day: "2026-09-18", timezone: "UTC")
        trace.appear(identity: key, ready: true)
        trace.update(identity: key, ready: true)
        trace.disappear()
        XCTAssertEqual(begins, 1)
        XCTAssertEqual(outcomes, ["succeeded"])
    }

    @MainActor
    func testAccountAndDayChangesCancelOldIntervalsBeforeStartingNewOnes() {
        var begins = 0
        var outcomes: [String] = []
        let trace = ServerScoreContentReadyTrace(begin: {
            begins += 1
            return { outcomes.append($0.rawValue) }
        })
        let first = ServerScoreContentReadyTrace.Identity(generation: UUID(), day: "2026-09-18", timezone: "UTC")
        let account = ServerScoreContentReadyTrace.Identity(generation: UUID(), day: first.day, timezone: "UTC")
        let tomorrow = ServerScoreContentReadyTrace.Identity(generation: account.generation, day: "2026-09-19", timezone: "UTC")
        trace.appear(identity: first, ready: false)
        trace.update(identity: account, ready: false)
        trace.update(identity: tomorrow, ready: false)
        trace.update(identity: tomorrow, ready: true)
        trace.disappear()
        XCTAssertEqual(begins, 3)
        XCTAssertEqual(outcomes, ["cancelled", "cancelled", "succeeded"])
    }

    @MainActor
    func testDisappearanceCancelsAndLateUpdatesCannotFinishRetiredView() {
        var outcomes: [String] = []
        let trace = ServerScoreContentReadyTrace(begin: { { outcomes.append($0.rawValue) } })
        let key = ServerScoreContentReadyTrace.Identity(generation: UUID(), day: "2026-09-18", timezone: "UTC")
        trace.appear(identity: key, ready: false)
        trace.disappear()
        trace.update(identity: key, ready: true)
        trace.disappear()
        XCTAssertEqual(outcomes, ["cancelled"])
        trace.appear(identity: key, ready: true)
        XCTAssertEqual(outcomes, ["cancelled", "succeeded"])
    }

    @MainActor
    func testInjectedNilIntervalDoesNotInventAnOutcome() {
        let trace = ServerScoreContentReadyTrace(begin: { nil })
        let key = ServerScoreContentReadyTrace.Identity(generation: UUID(), day: "2026-09-18", timezone: "UTC")
        trace.appear(identity: key, ready: false)
        trace.update(identity: key, ready: true)
        trace.disappear()
        XCTAssertFalse(ServerScoreViewState.empty.hasScalarContent(day: key.day))
    }
}
