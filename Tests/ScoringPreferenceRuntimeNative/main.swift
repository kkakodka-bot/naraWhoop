import Foundation
import XCTest
import Darwin

if CommandLine.arguments.contains("--preference-runtime-crash") {
    Task { @MainActor in
        do { try await PreferenceRuntimeCrashProbe.child(); exit(0) }
        catch { fputs("runtime crash probe failed: \(error)\n", stderr); exit(3) }
    }
    dispatchMain()
}
PreferenceRuntimeNativeEvidence.announce()
let suite = XCTestSuite(name: "Scoring preference runtime native")
suite.addTest(ScoringPreferenceRuntimeTests.defaultTestSuite)
suite.addTest(ScoringPreferencePublicationFenceTests.defaultTestSuite)
suite.addTest(AccountAlgorithmChoicesTests.defaultTestSuite)
suite.addTest(AccountPreferenceIsolationTests.defaultTestSuite)
suite.addTest(PreferenceRuntimeCrashTests.defaultTestSuite)
suite.run()
guard let result = suite.testRun, result.executionCount == 55 else { exit(2) }
exit(result.hasSucceeded ? 0 : 1)
