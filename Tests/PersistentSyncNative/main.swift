import Darwin
import XCTest

let suite = XCTestSuite(name: "Persistent sync connection owner, commit lease, and resource budget")
suite.addTest(BLEConnectionOwnerTests.defaultTestSuite)
suite.addTest(HistoricalCommitLeaseTests.defaultTestSuite)
suite.addTest(ResourceBudgetTests.defaultTestSuite)
suite.addTest(RealtimeIntentControllerTests.defaultTestSuite)
suite.run()
guard let result = suite.testRun else { exit(2) }
print("PersistentSyncNative: executed=\(result.executionCount) failures=\(result.totalFailureCount) skipped=\(result.skipCount)")
guard result.executionCount == 39, result.skipCount == 0 else { exit(2) }
exit(result.hasSucceeded ? 0 : 1)
