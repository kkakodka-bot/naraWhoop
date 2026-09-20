import Foundation
import XCTest
import NoopPush
import Darwin

final class ReadbackSettingsNativeTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.removePersistentDomain(forName: UserDefaults.suite)
        CloudAuthClient.project = "https://readback-fixture.invalid"
        CloudPushSettings.isEnabled = true
        CloudPushSettings.termsAccepted = true
    }
    override func tearDown() { UserDefaults.standard.removePersistentDomain(forName: UserDefaults.suite) }

    func testPausingUploadsDoesNotRevokeActivatedReadbackOwnership() throws {
        let scope = try AccountScope(projectURL: CloudAuthClient.project!, userID: UUID().uuidString)
        ServerScoringSettings.setKnownCapabilities([.hrv], scope: scope)
        ServerScoringSettings.setActivated([.hrv], scope: scope)
        for permission in [(false, true), (true, false), (false, false)] {
            CloudPushSettings.isEnabled = permission.0
            CloudPushSettings.termsAccepted = permission.1
            XCTAssertNil(CloudPushSettings.enabledEndpoint(), "Write gate must stay closed")
            XCTAssertTrue(ServerScoringSettings.ready)
            XCTAssertEqual(ServerScoringSettings.supabaseProjectURL()?.absoluteString, scope.projectURL)
            let state = ServerScoreViewState(generation: UUID(), revision: 1, currentDay: "2026-09-18", timezone: "UTC",
                configured: ServerScoringSettings.ready, authenticated: true,
                capabilities: ServerScoringSettings.knownCapabilities(scope: scope),
                activated: ServerScoringSettings.activatedMetrics(scope: scope), days: [:])
            XCTAssertTrue(state.owns(.hrv))
            XCTAssertNil(state.value(.hrv, day: state.currentDay, local: 99), "Owned missing cache must not become local")
        }
    }

    func testProjectFollowsIdentityNotOldUploadDestination() {
        CloudAuthClient.project = "https://NEW-readback-fixture.invalid:443/"
        XCTAssertEqual(ServerScoringSettings.supabaseProjectURL()?.absoluteString, "https://new-readback-fixture.invalid")
        XCTAssertNotEqual(ServerScoringSettings.supabaseProjectURL()?.host, "old-upload-fixture.invalid")
    }

    func testMissingAndInvalidProjectRemainUnconfigured() {
        for project in [nil, "http://untrusted.invalid", "https://user:password@readback-fixture.invalid", "https://readback-fixture.invalid?other=project"] as [String?] {
            CloudAuthClient.project = project
            XCTAssertNil(ServerScoringSettings.supabaseProjectURL())
            XCTAssertFalse(ServerScoringSettings.ready)
        }
    }

    func testExplicitReadbackDisableStillWorksWithoutBroadProducerSkip() {
        ServerScoringSettings.setEnabled(false)
        XCTAssertFalse(ServerScoringSettings.ready)
        XCTAssertFalse(ServerScoringSettings.skipsSyncCoupledRescore)
    }
}

let suite = ReadbackSettingsNativeTests.defaultTestSuite
suite.run()
guard let result = suite.testRun, result.executionCount == 4 else { exit(2) }
exit(result.hasSucceeded ? 0 : 1)
