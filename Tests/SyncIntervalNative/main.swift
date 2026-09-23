import Darwin
import XCTest
let suite = SyncIntervalMetricsTests.defaultTestSuite
suite.run()
guard let result = suite.testRun else { exit(2) }
print("SyncIntervalNative: executed=\(result.executionCount) failures=\(result.totalFailureCount) skipped=\(result.skipCount)")
guard result.executionCount == 4, result.skipCount == 0 else { exit(2) }
exit(result.hasSucceeded ? 0 : 1)
