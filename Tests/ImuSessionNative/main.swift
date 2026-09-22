import Darwin
import Foundation
import XCTest

let suite = XCTestSuite(name: "IMU session durability native")
for test in ImuSessionFileStoreTests.defaultTestSuite.tests {
    // This legacy singleton test constructs host app-support directories. Native tests use only
    // the explicit temporary-directory instances; hosted app CI retains singleton coverage.
    if !test.name.contains("testContinuousNamespaceIsSeparateFromSharedSessions") { suite.addTest(test) }
}
suite.run()
guard let result = suite.testRun, result.executionCount == 10 else { exit(2) }
exit(result.hasSucceeded ? 0 : 1)
