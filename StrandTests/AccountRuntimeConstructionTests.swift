import Foundation
import NoopPush
import StrandAnalytics
import XCTest
@testable import Strand

@MainActor
final class AccountRuntimeConstructionTests: XCTestCase {
    func testStorageRecoveryBlocksCaptureWithoutBlockingNewOwnerPresentation() throws {
        let scope = try AccountScope(projectURL: "https://" + UUID().uuidString + ".invalid", userID: UUID().uuidString)
        let context = AccountSessionContext(scope: scope, generation: UUID())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let layout = AccountStorageLayout(baseDirectory: root, scope: scope)
        defer { UserDefaults(suiteName: layout.preferencesSuite)?.removePersistentDomain(forName: layout.preferencesSuite) }
        let held = AccountAppRuntime.buildModel(context: context, layout: layout,
            captureAllowed: false, isCurrent: { $0 == context })
        XCTAssertTrue(held.isAccountRuntimeActive)
        XCTAssertEqual(held.accountStorage?.scope, scope)
        XCTAssertFalse(held.captureAdmissionEnabled)
        XCTAssertNil(held.sourceCoordinator)
        XCTAssertNotNil(held.scoringInputs)
        held.scan()
        XCTAssertFalse(held.live.connected)
        held.shutdownForAccountChange()
        let resumed = AccountAppRuntime.buildModel(context: context, layout: layout,
            captureAllowed: true, isCurrent: { $0 == context })
        XCTAssertTrue(resumed.captureAdmissionEnabled)
        resumed.shutdownForAccountChange()
    }

    func testCapturedLayoutNeverAdoptsAChangedOwnerOrSameOwnerGeneration() throws {
        let a = try AccountScope(projectURL: "https://runtime.invalid", userID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        let b = try AccountScope(projectURL: "https://runtime.invalid", userID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        let captured = AccountSessionContext(scope: a, generation: UUID())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let layout = AccountStorageLayout(baseDirectory: root, scope: a)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: layout.preferencesSuite))
        let original = defaults.persistentDomain(forName: layout.preferencesSuite)
        defer { if let original { defaults.setPersistentDomain(original, forName: layout.preferencesSuite) }
                else { defaults.removePersistentDomain(forName: layout.preferencesSuite) } }
        defaults.set("private-a", forKey: "construction-marker")
        let before = defaults.persistentDomain(forName: layout.preferencesSuite) as NSDictionary?
        for successor in [AccountSessionContext(scope: b, generation: UUID()),
                          AccountSessionContext(scope: a, generation: UUID())] {
            var current = captured
            let model = AccountAppRuntime.buildModel(context: captured, layout: layout,
                isCurrent: { $0 == current }, beforeConstruction: { current = successor })
            XCTAssertFalse(model.isAccountRuntimeActive)
            XCTAssertNil(model.accountStorage?.scope, "rejected construction must not read the old owner's settings")
            XCTAssertTrue(model.repo.days.isEmpty)
            XCTAssertNil(model.scoringInputs)
            model.shutdownForAccountChange()
        }
        XCTAssertEqual(defaults.persistentDomain(forName: layout.preferencesSuite) as NSDictionary?, before)
    }

    func testLayoutContextMismatchAndScopedRecalibrationRemainIsolated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = try AccountScope(projectURL: "https://" + UUID().uuidString + ".invalid", userID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        let b = try AccountScope(projectURL: a.projectURL, userID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        let aContext = AccountSessionContext(scope: a, generation: UUID())
        let bContext = AccountSessionContext(scope: b, generation: UUID())
        let aLayout = AccountStorageLayout(baseDirectory: root, scope: a)
        let bLayout = AccountStorageLayout(baseDirectory: root, scope: b)
        let aDefaults = try XCTUnwrap(UserDefaults(suiteName: aLayout.preferencesSuite))
        let bDefaults = try XCTUnwrap(UserDefaults(suiteName: bLayout.preferencesSuite))
        defer { aDefaults.removePersistentDomain(forName: aLayout.preferencesSuite)
                bDefaults.removePersistentDomain(forName: bLayout.preferencesSuite) }
        let mismatched = AccountAppRuntime.buildModel(context: bContext, layout: aLayout, isCurrent: { $0 == bContext })
        XCTAssertFalse(mismatched.isAccountRuntimeActive)
        mismatched.shutdownForAccountChange()
        let aModel = AppModel(storageLayout: aLayout, context: aContext,
            scoringInputDependencies: ScoringPreferenceAppTestSupport.dependencies(context: aContext, isCurrent: { $0 == aContext }),
            nativePreferenceCurrent: { $0 == aContext }, preferenceScoringEnabled: { false }, isCurrent: { $0 == aContext })
        let bModel = AppModel(storageLayout: bLayout, context: bContext,
            scoringInputDependencies: ScoringPreferenceAppTestSupport.dependencies(context: bContext, isCurrent: { $0 == bContext }),
            nativePreferenceCurrent: { $0 == bContext }, preferenceScoringEnabled: { false }, isCurrent: { $0 == bContext })
        try await aModel.prepareScoringPreferences()
        try await bModel.prepareScoringPreferences()
        let before = aModel.scoringConfigurationKey
        let reset = try XCTUnwrap(aModel.recalibrateChargeBaseline(now: 1_789_693_200))
        _ = try await reset.acceptance()
        XCTAssertNotEqual(aModel.scoringConfigurationKey, before)
        XCTAssertEqual(Baselines.hrvBaselineEpoch(aDefaults), 1_789_693_200)
        XCTAssertEqual(Baselines.recoveryBaselineEpoch(aDefaults), 1_789_693_200)
        XCTAssertEqual(Baselines.hrvBaselineEpoch(bDefaults), 0)
        let changes = try aModel.scoringProfileChanges(now: Date(timeIntervalSince1970: 1_789_693_200),
                                                      zone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        XCTAssertEqual(changes.map(\.kind), [.profile, .config])
        XCTAssertEqual(Set(changes.map(\.device)), [PushDurabilityReceipt.canonicalDevice(owner: a.userID, device: "my-whoop")])
        XCTAssertTrue(changes.allSatisfy { $0.effectiveDay == "2026-09-18" })
        let payloads = try changes.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0.payload) as? [String: Any]) }
        XCTAssertTrue(payloads.allSatisfy { $0["schemaVersion"] as? Int == 1 })
        XCTAssertEqual(payloads[1]["hrvBaselineEpoch"] as? Double, 1_789_693_200)
        XCTAssertNil(payloads[0]["age"], "setup defaults are not confirmed profile inputs")
        let edit = try aModel.completePreferenceAction([
            .init(key: .hrZoneThresholds, value: .integers([90, 110, 130, 150, 170])),
            .init(key: .stepsManualCoefficient, value: .number(42.5))
        ])
        _ = try await edit.acceptance()
        aModel.profile.stepsCalibrationCoefficient = 999
        let configured = try aModel.scoringProfileChanges()
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: configured[1].payload) as? [String: Any])
        XCTAssertEqual(config["customHRZoneLowerBounds"] as? [Double], [90, 110, 130, 150, 170])
        XCTAssertEqual(config["stepsManualCoefficient"] as? Double, 42.5)
        XCTAssertNil(config["stepsCalibrationCoefficient"], "fitted output is not a user input")
        XCTAssertEqual(config["spo2CandidateDisplayEnabled"] as? Bool, true)
        aModel.shutdownForAccountChange(); bModel.shutdownForAccountChange()
        try await aModel.scoringInputs?.waitForRetirement()
        try await bModel.scoringInputs?.waitForRetirement()
    }

    func testExplicitContextBuilderRequiresCurrentPurposeAndNeverAdoptsOtherSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try AccountScope(projectURL: "https://" + UUID().uuidString + ".invalid", userID: UUID().uuidString)
        let context = AccountSessionContext(scope: scope, generation: UUID())
        let layout = AccountStorageLayout(baseDirectory: root, scope: scope)
        defer { UserDefaults(suiteName: layout.preferencesSuite)?.removePersistentDomain(forName: layout.preferencesSuite) }
        let model = AppModel(storageLayout: layout, context: context,
            scoringInputDependencies: ScoringPreferenceAppTestSupport.dependencies(context: context, isCurrent: { $0 == context }),
            nativePreferenceCurrent: { $0 == context }, preferenceScoringEnabled: { false }, isCurrent: { $0 == context })
        defer { model.shutdownForAccountChange() }
        try await model.prepareScoringPreferences()
        let flags = ScoringContextInput.Flags(alcohol: false, stress: nil, sauna: false,
            hardOrLateWorkout: true, travelPhaseJump: nil, alreadyUnwell: false)
        XCTAssertThrowsError(try model.scoringJournalContextChange(day: "2026-09-18", flags: flags))
        let consent = try XCTUnwrap(model.scoringContextConsent)
        await consent.load(); await consent.setEnabled(true, purpose: .journal)
        let input = try model.scoringJournalContextChange(day: "2026-09-18", flags: flags, zone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(input.device, PushDurabilityReceipt.canonicalDevice(owner: scope.userID, device: model.repo.deviceId))
        XCTAssertTrue(consent.gate.allows(input))
        XCTAssertThrowsError(try model.scoringPeriodStartChange(day: "2026-09-18", eventID: UUID()))
        await consent.setEnabled(false, purpose: .journal)
        XCTAssertFalse(consent.gate.allows(input))
        XCTAssertThrowsError(try model.scoringJournalContextChange(day: "2026-09-18", flags: flags))
        model.shutdownForAccountChange()
        try await model.scoringInputs?.waitForRetirement()
        XCTAssertThrowsError(try model.scoringJournalContextChange(day: "2026-09-18", flags: flags))
    }
}
