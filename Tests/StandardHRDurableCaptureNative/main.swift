import XCTest
import Darwin

if CommandLine.arguments.count > 1 {
    Task { @MainActor in
        guard await StandardHRCaptureCrashProbe.runIfRequested() else { exit(64) }
    }
    dispatchMain()
} else {
    let suite = XCTestSuite(name: "StandardHR durable capture native")
    #if STANDARD_HR_CAPTURE_BASELINE
    suite.addTest(StandardHRCurrentRedTests.defaultTestSuite)
    let expected = 3
    #else
    suite.addTest(GenericCaptureJournalTests.defaultTestSuite)
    suite.addTest(RetiredCaptureDrainTests.defaultTestSuite)
    suite.addTest(StandardHRDurableCaptureTests.defaultTestSuite)
    let expected = 11 + StandardHRDurableCaptureTests.expectedNativeCount
    #endif
    suite.run()
    guard let result = suite.testRun, result.executionCount == expected else { exit(2) }
    exit(result.hasSucceeded ? 0 : 1)
}
