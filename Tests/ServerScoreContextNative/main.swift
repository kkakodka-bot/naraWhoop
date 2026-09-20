import Darwin
import XCTest

let suite = ServerScoreContextInteroperabilityTests.defaultTestSuite
suite.run()
guard let result = suite.testRun, result.executionCount == 7, result.skipCount == 0 else { exit(2) }
exit(result.hasSucceeded ? 0 : 1)
