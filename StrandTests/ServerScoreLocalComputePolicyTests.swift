import XCTest
#if !SERVER_SCORE_NATIVE_TESTS
@testable import Strand
#endif

final class ServerScoreLocalComputePolicyTests: XCTestCase {
    private func state(configured: Bool = true, authenticated: Bool = true,
                       capable: Bool = true, activated: Bool = true) -> ServerScoreViewState {
        .init(generation: UUID(), revision: 1, currentDay: "2026-09-18", timezone: "UTC",
              configured: configured, authenticated: authenticated,
              capabilities: capable ? [.sleepDebt] : [], activated: activated ? [.sleepDebt] : [], days: [:])
    }

    func testOwnedUnavailableMetricNeverCallsLocalProducer() {
        let policy = ServerScoreLocalComputePolicy(state: state())
        var calls = 0
        func local() -> Double? { calls += 1; return 123 }
        XCTAssertNil(policy.value(for: .sleepDebt, suppressed: nil, local: local()))
        XCTAssertEqual(calls, 0)
    }

    func testEachOwnershipGateMustBeSatisfiedToSuppress() {
        for state in [state(configured: false), state(authenticated: false), state(capable: false), state(activated: false)] {
            var calls = 0
            func local() -> Int { calls += 1; return 42 }
            let policy = ServerScoreLocalComputePolicy(state: state)
            XCTAssertEqual(policy.value(for: .sleepDebt, suppressed: -1, local: local()), 42)
            XCTAssertEqual(calls, 1)
        }
    }

    func testPartialCapabilityPreservesEveryOtherProducer() {
        let policy = ServerScoreLocalComputePolicy(state: state())
        for metric in ServerScoreMetric.allCases where metric != .sleepDebt {
            var calls = 0
            func local() -> Int { calls += 1; return 42 }
            XCTAssertEqual(policy.value(for: metric, suppressed: -1, local: local()), 42)
            XCTAssertEqual(calls, 1, metric.rawValue)
        }
    }
}
