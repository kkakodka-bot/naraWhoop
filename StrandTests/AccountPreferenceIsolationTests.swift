import Combine
import Foundation
import XCTest
#if !SCORING_INPUT_NATIVE_TESTS
@testable import Strand
#endif
#if !ACCOUNT_PREFERENCES_NATIVE_ONLY
import NoopPush
import WhoopStore
#endif

@MainActor
final class AccountPreferenceIsolationTests: XCTestCase {
    private struct Suite {
        let name: String
        let defaults: UserDefaults
    }

    private func suite() throws -> Suite {
        let name = "test.account-preferences." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return Suite(name: name, defaults: defaults)
    }

    private func preferences(_ suite: Suite, isCurrent: @escaping () -> Bool = { true }) -> AccountPreferences {
        AccountPreferences(defaults: suite.defaults, domainName: suite.name, isCurrent: isCurrent)
    }

    func testLegacyFallbackGrantIsNotAdoptedOrErased() async throws {
        let legacy = try suite(), a = try suite(), b = try suite()
        legacy.defaults.set(true, forKey: AccountPreferences.cycleAwarenessKey)
        legacy.defaults.set(true, forKey: AccountPreferences.cycleAwarenessHiddenKey)
        for account in [a, b] {
            // Synthetic shared-domain fallback, never the user's real standard preferences.
            account.defaults.addSuite(named: legacy.name)
            defer { account.defaults.removeSuite(named: legacy.name) }
            XCTAssertTrue(account.defaults.bool(forKey: AccountPreferences.cycleAwarenessKey))
            let captured = preferences(account)
            XCTAssertFalse(captured.cycleAwarenessEnabled)
            XCTAssertFalse(captured.cycleAwarenessHidden)
            XCTAssertNil(account.defaults.persistentDomain(forName: account.name)?[AccountPreferences.cycleAwarenessKey])
            captured.cycleAwarenessEnabled = true
            captured.cycleAwarenessEnabled = false
            XCTAssertFalse(preferences(account).cycleAwarenessEnabled)
        }
        XCTAssertTrue(legacy.defaults.bool(forKey: AccountPreferences.cycleAwarenessKey))
        XCTAssertTrue(legacy.defaults.bool(forKey: AccountPreferences.cycleAwarenessHiddenKey))
    }

    func testAccountAToBToARestoresOnlyEachAccountsChoices() async throws {
        let a = try suite(), b = try suite()
        var current = "a"
        let firstA = preferences(a, isCurrent: { current == "a" })
        firstA.cycleAwarenessEnabled = true
        firstA.cycleAwarenessHidden = true
        current = "b"
        firstA.retire()
        let firstB = preferences(b, isCurrent: { current == "b" })
        XCTAssertFalse(firstB.cycleAwarenessEnabled)
        XCTAssertFalse(firstB.cycleAwarenessHidden)
        firstB.cycleAwarenessEnabled = true
        current = "a"
        firstB.retire()
        let returnedA = preferences(a, isCurrent: { current == "a" })
        XCTAssertTrue(returnedA.cycleAwarenessEnabled)
        XCTAssertTrue(returnedA.cycleAwarenessHidden)
        returnedA.cycleAwarenessEnabled = false
        XCTAssertTrue(b.defaults.bool(forKey: AccountPreferences.cycleAwarenessKey))
        XCTAssertNil(b.defaults.persistentDomain(forName: b.name)?[AccountPreferences.cycleAwarenessHiddenKey])
    }

    func testRetiredSettersCannotOverwriteReturningSameOwner() async throws {
        let a = try suite()
        let retired = preferences(a)
        retired.cycleAwarenessEnabled = true
        retired.retire()
        let returned = preferences(a)
        returned.cycleAwarenessHidden = true
        let before = a.defaults.persistentDomain(forName: a.name) as NSDictionary?
        retired.cycleAwarenessEnabled = false
        retired.cycleAwarenessHidden = false
        XCTAssertFalse(retired.cycleAwarenessEnabled)
        XCTAssertFalse(retired.cycleAwarenessHidden)
        XCTAssertEqual(a.defaults.persistentDomain(forName: a.name) as NSDictionary?, before)
        XCTAssertTrue(returned.cycleAwarenessEnabled)
        XCTAssertTrue(returned.cycleAwarenessHidden)
    }

    func testSameOwnerGenerationChangeRejectsWritesBeforeRetireCallback() async throws {
        let a = try suite()
        let captured = UUID()
        var current = captured
        let old = preferences(a, isCurrent: { current == captured })
        old.cycleAwarenessEnabled = true
        current = UUID()
        let successor = preferences(a)
        successor.cycleAwarenessEnabled = false
        successor.cycleAwarenessHidden = true
        old.cycleAwarenessEnabled = true
        old.cycleAwarenessHidden = false
        XCTAssertFalse(old.cycleAwarenessEnabled)
        let reopened = preferences(a)
        XCTAssertFalse(reopened.cycleAwarenessEnabled)
        XCTAssertTrue(reopened.cycleAwarenessHidden)
    }

    func testThreeObserversShareOneSourceWithoutCrossAccountEvents() async throws {
        let a = preferences(try suite()), b = preferences(try suite())
        var events = [0, 0, 0]
        var otherAccountEvents = 0
        let subscriptions = (0..<3).map { index in
            a.objectWillChange.sink { events[index] += 1 }
        }
        let other = b.objectWillChange.sink { otherAccountEvents += 1 }
        defer { subscriptions.forEach { $0.cancel() }; other.cancel() }
        a.cycleAwarenessEnabled = true
        XCTAssertEqual(events, [1, 1, 1])
        XCTAssertTrue(a.cycleAwarenessEnabled)
        a.cycleAwarenessEnabled = true
        XCTAssertEqual(events, [1, 1, 1], "unchanged bindings must not create a refresh loop")
        a.cycleAwarenessHidden = true
        XCTAssertEqual(events, [2, 2, 2])
        XCTAssertEqual(otherAccountEvents, 0)
        XCTAssertFalse(b.cycleAwarenessEnabled)
        XCTAssertFalse(b.cycleAwarenessHidden)
    }

    func testSynchronousObserverAccountChangePreventsPreferenceWrite() async throws {
        let a = try suite()
        var current = true
        let captured = preferences(a, isCurrent: { current })
        let observer = captured.objectWillChange.sink { current = false }
        defer { observer.cancel() }
        captured.cycleAwarenessEnabled = true
        XCTAssertFalse(captured.cycleAwarenessEnabled)
        XCTAssertNil(a.defaults.persistentDomain(forName: a.name)?[AccountPreferences.cycleAwarenessKey])
        XCTAssertFalse(preferences(a).cycleAwarenessEnabled)
    }

    func testInactiveConstructionNeverExposesStoredGrantOrWrites() async throws {
        let a = try suite()
        a.defaults.set(true, forKey: AccountPreferences.cycleAwarenessKey)
        a.defaults.set(true, forKey: AccountPreferences.cycleAwarenessHiddenKey)
        let inactive = preferences(a, isCurrent: { false })
        XCTAssertFalse(inactive.cycleAwarenessEnabled)
        XCTAssertFalse(inactive.cycleAwarenessHidden)
        inactive.cycleAwarenessEnabled = false
        inactive.cycleAwarenessHidden = false
        XCTAssertTrue(a.defaults.bool(forKey: AccountPreferences.cycleAwarenessKey))
        XCTAssertTrue(a.defaults.bool(forKey: AccountPreferences.cycleAwarenessHiddenKey))
    }

    func testClearMomentsPersistsAcrossReopenWithoutClearingOtherOwner() async throws {
        let a = try suite(), b = try suite(), legacy = try suite()
        for account in [a, b, legacy] { account.defaults.set([123.0, 456.0], forKey: "moments") }
        XCTAssertTrue(preferences(a).clearMoments())
        let reopened = try XCTUnwrap(UserDefaults(suiteName: a.name))
        XCTAssertNil(reopened.array(forKey: "moments"))
        XCTAssertEqual(b.defaults.array(forKey: "moments") as? [Double], [123, 456])
        XCTAssertEqual(legacy.defaults.array(forKey: "moments") as? [Double], [123, 456])
    }

    func testStaleAndRetiredClearMomentsLeaveCapturedPersistenceUntouched() async throws {
        let a = try suite()
        a.defaults.set([123.0], forKey: "moments")
        var current = true
        let stale = preferences(a, isCurrent: { current })
        current = false
        XCTAssertFalse(stale.clearMoments())
        let retired = preferences(a)
        retired.retire()
        XCTAssertFalse(retired.clearMoments())
        XCTAssertEqual(a.defaults.array(forKey: "moments") as? [Double], [123])
    }

    func testHrvWindowIgnoresSharedFallbackAndRestoresOnlyItsOwner() async throws {
        let legacy = try suite(), a = try suite(), b = try suite()
        legacy.defaults.set("deep", forKey: AccountPreferences.hrvWindowKey)
        a.defaults.addSuite(named: legacy.name)
        b.defaults.addSuite(named: legacy.name)
        defer { a.defaults.removeSuite(named: legacy.name); b.defaults.removeSuite(named: legacy.name) }
        XCTAssertEqual(a.defaults.string(forKey: AccountPreferences.hrvWindowKey), "deep")
        var owner = "a"
        let firstA = preferences(a, isCurrent: { owner == "a" })
        XCTAssertEqual(firstA.hrvWindowRaw, "whole")
        firstA.hrvWindowRaw = "deep"
        owner = "b"
        firstA.retire()
        let firstB = preferences(b, isCurrent: { owner == "b" })
        XCTAssertEqual(firstB.hrvWindowRaw, "whole")
        firstA.hrvWindowRaw = "whole"
        XCTAssertEqual(a.defaults.persistentDomain(forName: a.name)?[AccountPreferences.hrvWindowKey] as? String, "deep")
        XCTAssertNil(b.defaults.persistentDomain(forName: b.name)?[AccountPreferences.hrvWindowKey])
        owner = "a"
        firstB.retire()
        XCTAssertEqual(preferences(a).hrvWindowRaw, "deep")
        XCTAssertEqual(firstB.hrvWindowRaw, "whole")
        XCTAssertEqual(legacy.defaults.string(forKey: AccountPreferences.hrvWindowKey), "deep")
    }

    func testHrvWindowRejectsInvalidValuesAndStaleReentrantWrites() async throws {
        let a = try suite()
        a.defaults.set("invalid", forKey: AccountPreferences.hrvWindowKey)
        var current = true
        let captured = preferences(a, isCurrent: { current })
        XCTAssertEqual(captured.hrvWindowRaw, "whole")
        captured.hrvWindowRaw = "DEEP"
        XCTAssertEqual(a.defaults.string(forKey: AccountPreferences.hrvWindowKey), "invalid")
        var events = 0
        let observer = captured.objectWillChange.sink { events += 1; current = false }
        defer { observer.cancel() }
        captured.hrvWindowRaw = "deep"
        XCTAssertEqual(events, 1)
        XCTAssertEqual(captured.hrvWindowRaw, "whole")
        XCTAssertEqual(a.defaults.string(forKey: AccountPreferences.hrvWindowKey), "invalid")
        captured.hrvWindowRaw = "deep"
        XCTAssertEqual(events, 1)
    }

    func testHrvWindowPublishesOnlyActualCurrentOwnerChanges() async throws {
        let a = try suite(), b = try suite()
        let first = preferences(a), second = preferences(b)
        var firstEvents = 0, secondEvents = 0
        let firstObserver = first.objectWillChange.sink { firstEvents += 1 }
        let secondObserver = second.objectWillChange.sink { secondEvents += 1 }
        defer { firstObserver.cancel(); secondObserver.cancel() }
        first.hrvWindowRaw = "deep"
        first.hrvWindowRaw = "deep"
        XCTAssertEqual(firstEvents, 1)
        XCTAssertEqual(secondEvents, 0)
        XCTAssertEqual(second.hrvWindowRaw, "whole")
        first.hrvWindowRaw = "whole"
        XCTAssertEqual(firstEvents, 2)
        XCTAssertEqual(preferences(a).hrvWindowRaw, "whole")
    }

    #if !ACCOUNT_PREFERENCES_NATIVE_ONLY
    func testActualModelForwardsPreferencesAndGuardsClearMoments() async throws {
        try XCTSkipUnless(AppRuntimeMode.isUnitTesting, "requires hermetic app construction")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("account-preference-model-" + UUID().uuidString)
        let scope = try AccountScope(projectURL: "https://" + UUID().uuidString + ".invalid", userID: UUID().uuidString)
        let context = AccountSessionContext(scope: scope, generation: UUID())
        let layout = AccountStorageLayout(baseDirectory: root, scope: scope)
        var current = context
        let nativeCurrent = PreferenceRuntimeFlag()
        let dependencies = ScoringInputCoordinator.Dependencies(
            isCurrent: { $0 == context && nativeCurrent.get() }, canUpload: { false },
            openJournal: { layout, fence in
                try ScoringInputJournal(layout: layout, fence: fence, preferenceContext: context,
                    isPreferenceContextCurrent: { $0 == context && nativeCurrent.get() })
            }, head: { _, _ in XCTFail("fixture must not contact a server"); throw ScoringInputRPC.Failure.unavailable },
            send: { _, _ in XCTFail("fixture must not contact a server"); throw ScoringInputRPC.Failure.unavailable })
        let model = AppModel(storageLayout: layout, context: context, captureAllowed: true,
            scoringInputDependencies: dependencies, nativePreferenceCurrent: { $0 == context && nativeCurrent.get() },
            preferenceScoringEnabled: { true }, isCurrent: { $0 == current })
        addTeardownBlock {
            let generic = await model.shutdownForAccountChange()
            let bleDrained = await model.ble.drainCaptureAfterAccountChange()
            let genericDrained = await generic?.drain() ?? true
            XCTAssertTrue(bleDrained); XCTAssertTrue(genericDrained)
            await model.scoringPreferences?.waitForRetirement()
            try await model.scoringInputs?.waitForRetirement()
            UserDefaults(suiteName: layout.preferencesSuite)?.removePersistentDomain(forName: layout.preferencesSuite)
            // The source coordinator owns a separate capture-store handle with no close API.
            // Retain this synthetic fixture rather than unlinking beneath that live handle.
            print("Retained app preference fixture: \(root.path)")
        }
        XCTAssertNil(model.resolvedScoringPreferenceSource)
        try await model.prepareScoringPreferences()
        await model.wireSourceCoordinator()
        XCTAssertNotNil(model.deviceRegistry?.devices.first { $0.id == model.repo.deviceId && $0.status == .active })
        XCTAssertNotNil(model.resolvedScoringPreferenceSource)
        var events = [0, 0, 0]
        let subscriptions = (0..<3).map { index in model.objectWillChange.sink { events[index] += 1 } }
        defer { subscriptions.forEach { $0.cancel() } }
        model.cycleAwarenessEnabled = true
        model.cycleAwarenessHidden = true
        XCTAssertEqual(events, [2, 2, 2], "all three EnvironmentObject readers receive both changes")
        XCTAssertTrue(model.accountPreferences.cycleAwarenessEnabled)
        XCTAssertTrue(model.accountPreferences.cycleAwarenessHidden)
        XCTAssertFalse(model.scoringContextConsent?.enabled(.cycle) == true, "local choice is not a server grant")
        XCTAssertEqual(AccountPreferences.hrvWindowKey, UnitPrefs.hrvWindowKey)
        XCTAssertEqual(Set(HrvWindow.allCases.map(\.rawValue)), Set(["whole", "deep"]))
        let configurationBefore = model.scoringConfigurationKey
        XCTAssertEqual(model.intelligence.configuredHrvWindow, .whole)
        model.hrvWindowRaw = HrvWindow.deep.rawValue
        XCTAssertEqual(model.intelligence.configuredHrvWindow, .whole, "pending is not durable acceptance")
        let acceptedDeadline = Date().addingTimeInterval(3)
        while model.scoringPreferences?.pendingCount != 0 && Date() < acceptedDeadline { await Task.yield() }
        XCTAssertEqual(model.scoringPreferences?.pendingCount, 0)
        XCTAssertNil(model.scoringPreferences?.lastError)
        XCTAssertEqual(model.acceptedScoringPreferences?.position.sequence, 1)
        XCTAssertEqual(model.intelligence.configuredHrvWindow, .deep)
        XCTAssertNotEqual(model.scoringConfigurationKey, configurationBefore)
        let changes = try model.scoringProfileChanges(now: Date(timeIntervalSince1970: 1_789_693_200),
            zone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        let config = try XCTUnwrap(changes.first { $0.kind == .config })
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: config.payload) as? [String: Any])
        XCTAssertEqual(payload["deepHrvWindow"] as? Bool, true)
        model.accountDefaults.set([123.0], forKey: "moments")
        model.moments = [Date(timeIntervalSince1970: 123)]
        model.clearMoments()
        XCTAssertTrue(model.moments.isEmpty)
        XCTAssertNil(UserDefaults(suiteName: layout.preferencesSuite)?.array(forKey: "moments"))
        model.accountDefaults.set([456.0], forKey: "moments")
        model.moments = [Date(timeIntervalSince1970: 456)]
        current = .init(scope: scope, generation: UUID())
        nativeCurrent.set(false)
        model.cycleAwarenessEnabled = false
        model.cycleAwarenessHidden = false
        model.hrvWindowRaw = HrvWindow.whole.rawValue
        model.clearMoments()
        XCTAssertEqual(model.moments, [Date(timeIntervalSince1970: 456)])
        XCTAssertEqual(model.accountDefaults.array(forKey: "moments") as? [Double], [456])
        XCTAssertTrue(model.accountDefaults.bool(forKey: AccountPreferences.cycleAwarenessKey))
        XCTAssertTrue(model.accountDefaults.bool(forKey: AccountPreferences.cycleAwarenessHiddenKey))
        XCTAssertFalse(model.cycleAwarenessEnabled)
        XCTAssertFalse(model.cycleAwarenessHidden)
        XCTAssertEqual(model.hrvWindowRaw, HrvWindow.whole.rawValue)
        XCTAssertEqual(model.intelligence.configuredHrvWindow, .whole)
        XCTAssertEqual(model.accountDefaults.string(forKey: AccountPreferences.hrvWindowKey), HrvWindow.deep.rawValue)
    }
    #endif
}
