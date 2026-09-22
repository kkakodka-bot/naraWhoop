import XCTest
import Darwin

let suite = XCTestSuite(name: "Scoring input native")
let loopback = ProcessInfo.processInfo.environment["SCORING_INPUT_LOOPBACK_URL"] != nil
if loopback {
    suite.addTest(ScoringInputLoopbackTests.defaultTestSuite)
} else {
    suite.addTest(ScoringInputJournalTests.defaultTestSuite)
    suite.addTest(ScoringInputCoordinatorTests.defaultTestSuite)
    suite.addTest(ScoringConsentRelayTests.defaultTestSuite)
    suite.addTest(ScoringConsentCapacityTests.defaultTestSuite)
}
suite.run()
guard let result = suite.testRun, result.executionCount == (loopback ? 7 : 61) else { exit(2) }
exit(result.hasSucceeded ? 0 : 1)
