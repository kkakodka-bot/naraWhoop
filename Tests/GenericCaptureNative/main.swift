import XCTest
import Darwin

let suite = XCTestSuite(name: "Generic capture retirement native")
suite.addTest(GenericCaptureJournalTests.defaultTestSuite)
suite.run()
guard let result = suite.testRun, result.executionCount == 8 else { exit(2) }
exit(result.hasSucceeded ? 0 : 1)
