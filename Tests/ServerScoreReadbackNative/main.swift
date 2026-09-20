import XCTest
import Darwin

let suite = XCTestSuite(name: "W4 native readback")
suite.addTest(ServerScoreSnapshotV2Tests.defaultTestSuite)
#if SERVER_SCORE_REPOSITORY_TESTS
suite.addTest(ServerScoreRepositoryNativeTests.defaultTestSuite)
suite.addTest(ServerScoreRefreshNativeTests.defaultTestSuite)
suite.addTest(ServerScoreReadSessionOwnerTests.defaultTestSuite)
suite.addTest(ServerScoreSleepSessionTests.defaultTestSuite)
suite.addTest(ServerScoreHistoryContractTests.defaultTestSuite)
suite.addTest(ServerScoreContentReadyTraceTests.defaultTestSuite)
suite.addTest(ServerScoreReadTransportTests.defaultTestSuite)
suite.addTest(ServerScoreLocalComputePolicyTests.defaultTestSuite)
suite.addTest(ServerScoreSleepDetailsTests.defaultTestSuite)
suite.addTest(ServerScoreContextMotionTests.defaultTestSuite)
suite.addTest(ServerScoreWorkoutDetailsTests.defaultTestSuite)
let expectedCount = 119
#else
let expectedCount = 13
#endif
suite.run()
guard let result = suite.testRun, result.executionCount == expectedCount else { exit(2) }
if result.hasSucceeded, let path = CommandLine.arguments.dropFirst().first, !path.isEmpty {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let day = json?["day"] as? String,
              let snapshot = try ServerScoreResponse.decode(data, requestedDay: day).snapshot,
              try ServerScoreResponse.decode(snapshot.encoded(), requestedDay: day).snapshot == snapshot else { exit(3) }
        print("Canonical synthetic server snapshot decoded and round-tripped successfully")
    } catch { print("Canonical synthetic server fixture failed: \(error)"); exit(3) }
}
exit(result.hasSucceeded ? 0 : 1)
