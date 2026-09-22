import Darwin
import XCTest

let suite = SyncPresentationTests.defaultTestSuite
suite.run()
guard let result = suite.testRun, result.executionCount == 13, result.skipCount == 0 else { exit(2) }
exit(result.hasSucceeded ? 0 : 1)
