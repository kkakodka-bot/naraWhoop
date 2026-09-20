import Foundation
import XCTest
import Darwin

if CommandLine.arguments.contains("--preference-crash-probe") {
    Task.detached {
        do { try await PreferenceCrashProbe.child(); exit(0) }
        catch { fputs("preference probe failed: \(error)\n", stderr); exit(3) }
    }
    dispatchMain()
}
let suite = XCTestSuite(name: "Scoring preference intent native")
suite.addTest(ScoringPreferenceIntentTests.defaultTestSuite)
suite.run()
guard let result = suite.testRun, result.executionCount == 26 else { exit(2) }
exit(result.hasSucceeded ? 0 : 1)
