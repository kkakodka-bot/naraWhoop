import Combine
import Foundation
import NoopPush
import WhoopStore
import XCTest
@testable import Strand

/// Calls the handlers used by all three C views with a real scoped AppModel and journal.
/// This is an app-host action test, not a SwiftUI click-through or render assertion.
@MainActor
final class ScoringPreferenceActionTests: XCTestCase {
    private final class Identity: @unchecked Sendable {
        private let lock = NSLock()
        private var context: AccountSessionContext
        init(_ context: AccountSessionContext) { self.context = context }
        func matches(_ value: AccountSessionContext) -> Bool {
            lock.lock(); defer { lock.unlock() }; return value == context
        }
        func replace(_ value: AccountSessionContext) { lock.lock(); context = value; lock.unlock() }
    }

    /// Stops the next actual journal owner check, off MainActor. It is armed only after hydration.
    private final class JournalGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var armed = false
        private var released = false
        private var entered: XCTestExpectation?
        private var expired = false
        func arm(_ expectation: XCTestExpectation) {
            condition.lock(); defer { condition.unlock() }
            armed = true; released = false; entered = expectation
        }
        func pass() -> Bool {
            condition.lock(); defer { condition.unlock() }
            guard armed else { return true }
            armed = false; entered?.fulfill()
            let limit = Date().addingTimeInterval(5)
            while !released {
                if !condition.wait(until: limit) { expired = true; return false }
            }
            return true
        }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
        var timedOut: Bool { condition.lock(); defer { condition.unlock() }; return expired }
    }
    @MainActor private final class Policy { var coupled: Bool; init(_ value: Bool) { coupled = value } }
    private final class AdmissionAvailability: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        func allows() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ next: Bool) { lock.lock(); value = next; lock.unlock() }
    }
    @MainActor private final class Fixture {
        let root: URL
        let context: AccountSessionContext
        let layout: AccountStorageLayout
        let identity: Identity
        let policy: Policy
        let gate = JournalGate()
        let admission = AdmissionAvailability()
        let model: AppModel
        let actions = ScoringPreferenceActions()

        init(coupled: Bool) throws {
            let temporary = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory
            root = temporary.appendingPathComponent("preference-actions-" + UUID().uuidString)
            let scope = try AccountScope(projectURL: "https://" + UUID().uuidString + ".invalid", userID: UUID().uuidString)
            context = .init(scope: scope, generation: UUID())
            layout = .init(baseDirectory: root, scope: scope)
            identity = Identity(context); policy = Policy(coupled)
            let context = context, identity = identity, gate = gate, policy = policy, admission = admission
            let dependencies = ScoringInputCoordinator.Dependencies(isCurrent: { identity.matches($0) },
                canUpload: { false }, openJournal: { layout, fence in
                    try ScoringInputJournal(layout: layout, fence: fence, preferenceContext: context,
                        isPreferenceContextCurrent: { gate.pass() && identity.matches($0) })
                }, head: { _, _ in throw ScoringInputJournal.Failure.held },
                send: { _, _ in throw ScoringInputJournal.Failure.held }, allowsChange: { _ in admission.allows() })
            model = AppModel(storageLayout: layout, context: context, captureAllowed: true,
                scoringInputDependencies: dependencies, nativePreferenceCurrent: { identity.matches($0) },
                preferenceScoringEnabled: { policy.coupled }, isCurrent: { $0.map(identity.matches) == true })
        }
        func close() async throws {
            gate.release()
            let captured = model.shutdownForAccountChange()
            let bleDrained = await model.ble.drainCaptureAfterAccountChange()
            let genericDrained = await captured?.drain() ?? true
            XCTAssertTrue(bleDrained); XCTAssertTrue(genericDrained)
            await actions.waitForCompletion()
            await model.scoringPreferences?.waitForRetirement()
            try await model.scoringInputs?.waitForRetirement()
            XCTAssertFalse(gate.timedOut, "the real journal barrier must be explicitly released")
            UserDefaults(suiteName: layout.preferencesSuite)?.removePersistentDomain(forName: layout.preferencesSuite)
            // A connected registry owns a separate capture handle. Keep the failed or successful
            // fixture rather than unlinking a live SQLite handle during app-host teardown.
            print("Retained action fixture: \(root.path)")
        }
    }

    private func fixture(coupled: Bool = false, prepare: Bool = true) async throws -> Fixture {
        try XCTSkipUnless(AppRuntimeMode.isUnitTesting, "requires hermetic app construction")
        let f = try Fixture(coupled: coupled)
        addTeardownBlock { try await f.close() }
        if prepare { try await f.model.prepareScoringPreferences() }
        return f
    }
    private func projection(_ f: Fixture) async throws -> ScoringPreferenceProjection {
        try await XCTUnwrap(f.model.scoringInputs).preferenceProjection()
    }
    private func receipt(_ actions: ScoringPreferenceActions) throws -> ScoringPreferenceAdmission {
        guard case .accepted(let result) = try XCTUnwrap(actions.ticket).state else {
            XCTFail("handler did not receive actual durable acceptance"); throw ScoringInputJournal.Failure.held
        }
        return result
    }
    private func connect(_ f: Fixture) async throws {
        await f.model.wireSourceCoordinator()
        XCTAssertNotNil(f.model.deviceRegistry)
        XCTAssertNotNil(f.model.resolvedScoringPreferenceSource)
    }

    func testOnboardingDraftDoesNotWriteAndSaveCommitsExactDOBPairOnce() async throws {
        let f = try await fixture()
        let dob = Date(timeIntervalSince1970: 631_152_000)
        let oldDOB = f.model.profile.dateOfBirth
        f.actions.stageDateOfBirth(dob, model: f.model)
        f.actions.stage(.weightKg, value: .number(86.5), model: f.model)
        f.actions.stage(.heightCm, value: .number(182), model: f.model)
        f.actions.stage(.sex, value: .text("female"), model: f.model)
        XCTAssertEqual(f.model.profile.dateOfBirth, oldDOB)
        XCTAssertEqual(f.model.profile.weightKg, 75)
        let before = try await projection(f)
        XCTAssertEqual(before.position, .initial)
        var advances = 0
        f.actions.saveOnboarding(model: f.model) { advances += 1 }
        XCTAssertEqual(advances, 0)
        XCTAssertEqual(f.actions.phase, .saving)
        await f.actions.waitForCompletion()
        XCTAssertEqual(advances, 1)
        XCTAssertEqual(f.actions.phase, .saved)
        XCTAssertTrue(f.actions.draft.isEmpty)
        XCTAssertEqual(f.model.profile.dateOfBirth, dob)
        XCTAssertEqual(f.model.profile.weightKg, 86.5)
        XCTAssertEqual(f.model.profile.heightCm, 182)
        XCTAssertEqual(f.model.profile.sex, "female")
        let result = try await projection(f)
        XCTAssertEqual(result.position.sequence, 1)
        XCTAssertEqual(Set(result.entries.map(\.key)), [.dateOfBirth, .ageExplicit, .weightKg, .heightCm, .sex])
        XCTAssertEqual(result.entries.first { $0.key == .ageExplicit }?.value, .boolean(true))
    }

    func testUntouchedOnboardingContinueAndHydrationAreNotCompletedActions() async throws {
        let f = try await fixture()
        var advances = 0
        f.actions.saveOnboarding(model: f.model) { advances += 1 }
        try await f.model.prepareScoringPreferences()
        XCTAssertEqual(advances, 1)
        XCTAssertNil(f.actions.ticket)
        let result = try await projection(f)
        XCTAssertEqual(result.position, .initial)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testSettingsDOBGestureWritesAgeExplicitAlongsideDate() async throws {
        let f = try await fixture()
        let dob = Date(timeIntervalSince1970: 662_688_000)
        f.actions.changeDateOfBirth(dob, model: f.model)
        await f.actions.waitForCompletion()
        let result = try await projection(f)
        XCTAssertEqual(result.position.sequence, 1)
        XCTAssertEqual(Set(result.entries.map(\.key)), [.dateOfBirth, .ageExplicit])
        XCTAssertEqual(f.model.profile.dateOfBirth, dob)
        XCTAssertEqual(result.entries.first { $0.key == .ageExplicit }?.value, .boolean(true))
    }

    func testAllFiveAlgorithmHandlersReadAcceptedChoicesWithoutGlobalFallthrough() async throws {
        let f = try await fixture()
        let choices: [(ScoringPreferenceKey, Bool)] = [(.effortMethod, true), (.useSleepStagerV2, false),
            (.useMotionAwareWake, true), (.daytimePersonalBaselineEnabled, true), (.spo2CandidateDisplayEnabled, false)]
        for (key, choice) in choices {
            let original = f.actions.algorithm(key, model: f.model)
            f.actions.setAlgorithm(key, enabled: choice, model: f.model)
            XCTAssertEqual(f.actions.algorithm(key, model: f.model), original)
            await f.actions.waitForCompletion()
            XCTAssertEqual(f.actions.algorithm(key, model: f.model), choice)
            XCTAssertEqual(f.actions.phase, .saved)
        }
        let result = try await projection(f)
        XCTAssertEqual(result.position.sequence, 5)
        XCTAssertEqual(Set(result.entries.map(\.key)), Set(choices.map(\.0)))
        XCTAssertEqual(result.entries.first { $0.key == .effortMethod }?.value, .text("BANISTER"))
        f.model.accountDefaults.set(false, forKey: "noopBanisterEffort")
        f.model.scheduleScoringProfileInputs()
        XCTAssertTrue(f.actions.algorithm(.effortMethod, model: f.model))
        let afterEcho = try await projection(f)
        XCTAssertEqual(afterEcho.position, result.position)
    }

    func testProfileSteppersZonesAndClearUseActualCompletedHandlers() async throws {
        let f = try await fixture()
        for part in [ScoringPreferenceIntent.Patch(key: .sex, value: .text("nonbinary")),
                     .init(key: .weightKg, value: .number(85)), .init(key: .heightCm, value: .number(181)),
                     .init(key: .waistCm, value: .number(82)), .init(key: .waistCm, value: .clear),
                     .init(key: .stepTicksPerStep, value: .number(2.5))] {
            f.actions.change(part.key, value: part.value, model: f.model)
            await f.actions.waitForCompletion()
            XCTAssertEqual(f.actions.phase, .saved)
        }
        XCTAssertEqual(f.model.profile.sex, "nonbinary")
        XCTAssertEqual(f.model.profile.weightKg, 85)
        XCTAssertEqual(f.model.profile.heightCm, 181)
        XCTAssertEqual(f.model.profile.waistCm, 0)
        XCTAssertEqual(f.model.profile.stepTicksPerStep, 2.5)
        let estimate = f.model.profile.hrMax
        f.actions.stepMaxHR(up: true, model: f.model)
        await f.actions.waitForCompletion()
        XCTAssertEqual(f.model.profile.hrMaxOverride, min(230, max(80, estimate)))
        f.actions.change(.hrMaxOverride, value: .number(80), model: f.model)
        await f.actions.waitForCompletion()
        f.actions.stepMaxHR(up: false, model: f.model)
        await f.actions.waitForCompletion()
        XCTAssertEqual(f.model.profile.hrMaxOverride, 0)
        f.actions.setZonesEnabled(true, model: f.model)
        await f.actions.waitForCompletion()
        let zones = f.model.profile.hrZoneThresholds
        XCTAssertEqual(zones.count, 5)
        f.actions.stepZone(0, up: true, model: f.model)
        await f.actions.waitForCompletion()
        XCTAssertEqual(f.model.profile.hrZoneThresholds.first, zones.first.map { $0 + 1 })
        f.actions.setZonesEnabled(false, model: f.model)
        await f.actions.waitForCompletion()
        XCTAssertTrue(f.model.profile.hrZoneThresholds.isEmpty)
        let result = try await projection(f)
        XCTAssertEqual(result.entries.first { $0.key == .hrZoneThresholds }?.value, .clear)
        XCTAssertEqual(result.entries.first { $0.key == .waistCm }?.value, .clear)
        XCTAssertEqual(result.entries.first { $0.key == .hrMaxOverride }?.value, .clear)
    }

    func testSliderStagesManyValuesButReleaseSavesOnlyOneAndZeroClears() async throws {
        let f = try await fixture()
        for value in [5.0, 12.0, 21.5] {
            f.actions.stage(.stepsManualCoefficient, value: .number(value), model: f.model)
            f.actions.finishStepsSlider(editing: true, model: f.model)
        }
        XCTAssertEqual(f.model.profile.stepsManualCoefficient, 0)
        let before = try await projection(f)
        XCTAssertEqual(before.position, .initial)
        f.actions.finishStepsSlider(editing: false, model: f.model)
        await f.actions.waitForCompletion()
        XCTAssertEqual(f.model.profile.stepsManualCoefficient, 21.5)
        XCTAssertEqual(try receipt(f.actions).position.sequence, 1)
        f.actions.finishStepsSlider(editing: false, model: f.model)
        XCTAssertEqual(try receipt(f.actions).position.sequence, 1, "duplicate end without a draft is not another action")
        f.actions.stage(.stepsManualCoefficient, value: .number(0), model: f.model)
        f.actions.finishStepsSlider(editing: false, model: f.model)
        await f.actions.waitForCompletion()
        XCTAssertEqual(f.model.profile.stepsManualCoefficient, 0)
        let after = try await projection(f)
        XCTAssertEqual(after.position.sequence, 2)
        XCTAssertEqual(after.entries.first { $0.key == .stepsManualCoefficient }?.value, .clear)
    }

    func testSliderDraftAndOnboardingDisappearanceDoNotInventActions() async throws {
        let f = try await fixture()
        f.actions.stage(.stepsManualCoefficient, value: .number(15), model: f.model)
        f.actions.suspendPresentation()
        XCTAssertEqual(f.model.profile.stepsManualCoefficient, 0)
        XCTAssertNil(f.actions.ticket)
        let result = try await projection(f)
        XCTAssertEqual(result.position, .initial)
    }

    func testResetWaitsForRealJournalAndPublishesExactEpochPair() async throws {
        let f = try await fixture()
        let barrier = expectation(description: "journal owner check reached")
        f.gate.arm(barrier)
        var success = 0
        let epoch = 1_789_693_200.125
        f.actions.recalibrate(model: f.model, now: epoch) { success += 1 }
        await fulfillment(of: [barrier], timeout: 3)
        XCTAssertEqual(success, 0)
        XCTAssertEqual(f.actions.phase, .saving)
        XCTAssertEqual(f.model.acceptedScoringPreferences?.hrvBaselineEpoch, 0)
        XCTAssertEqual(f.model.acceptedScoringPreferences?.recoveryBaselineEpoch, 0)
        f.gate.release()
        await f.actions.waitForCompletion()
        XCTAssertEqual(success, 1)
        XCTAssertEqual(f.actions.phase, .saved)
        XCTAssertEqual(f.model.acceptedScoringPreferences?.hrvBaselineEpoch, epoch)
        XCTAssertEqual(f.model.acceptedScoringPreferences?.recoveryBaselineEpoch, epoch)
        let result = try await projection(f)
        XCTAssertEqual(result.position.sequence, 1)
        XCTAssertEqual(Set(result.entries.map(\.key)), [.hrvBaselineEpoch, .recoveryBaselineEpoch])
    }

    func testResetOnUnpreparedOrRetiredAccountCannotAnnounceSuccess() async throws {
        let f = try await fixture(prepare: false)
        var success = 0
        f.actions.recalibrate(model: f.model) { success += 1 }
        XCTAssertEqual(f.actions.phase, .failed)
        XCTAssertNil(f.actions.ticket)
        XCTAssertEqual(success, 0)
        try await f.model.prepareScoringPreferences()
        let result = try await projection(f)
        XCTAssertEqual(result.position, .initial)
        f.actions.discard(model: f.model)
        f.model.shutdownForAccountChange()
        f.actions.recalibrate(model: f.model) { success += 1 }
        XCTAssertEqual(f.actions.phase, .retired)
        XCTAssertEqual(success, 0)
    }

    func testMissingSourceHeldOriginalMustBeDiscardedBeforeExplicitNewGesture() async throws {
        let f = try await fixture(coupled: true)
        f.actions.change(.weightKg, value: .number(88), model: f.model)
        await f.actions.waitForCompletion()
        let original = try XCTUnwrap(f.actions.ticket)
        XCTAssertEqual(original.state, .held(.missingSource))
        XCTAssertFalse(f.actions.canRetry)
        try await connect(f)
        f.actions.retry(model: f.model)
        XCTAssertEqual(original.state, .held(.missingSource))
        XCTAssertEqual(f.model.profile.weightKg, 75)
        f.actions.change(.weightKg, value: .number(89), model: f.model)
        XCTAssertTrue(f.actions.ticket === original)
        f.actions.discard(model: f.model)
        XCTAssertEqual(original.state, .discarded)
        XCTAssertEqual(f.actions.phase, .idle)
        f.actions.change(.weightKg, value: .number(89), model: f.model)
        await f.actions.waitForCompletion()
        XCTAssertNotEqual(f.actions.ticket?.id, original.id)
        XCTAssertNotNil(try receipt(f.actions).profileMutationID)
        XCTAssertEqual(f.model.profile.weightKg, 89)
    }

    func testMissingPermitIsNotRecapturedByRetryPreparationOrModeChange() async throws {
        let f = try await fixture(coupled: true)
        try await connect(f)
        try XCTUnwrap(f.model.scoringContextConsent).gate.holdAdmission()
        f.actions.change(.heightCm, value: .number(185), model: f.model)
        await f.actions.waitForCompletion()
        let original = try XCTUnwrap(f.actions.ticket)
        XCTAssertEqual(original.state, .held(.missingPermit))
        XCTAssertFalse(f.actions.canRetry)
        try await f.model.prepareScoringPreferences()
        f.policy.coupled = false
        f.actions.retry(model: f.model)
        XCTAssertTrue(f.actions.ticket === original)
        XCTAssertEqual(original.state, .held(.missingPermit))
        XCTAssertEqual(f.model.profile.heightCm, 178)
        let result = try await projection(f)
        XCTAssertEqual(result.position, .initial)
    }

    func testRetryKeepsRevokedOriginalAndDiscardRemovesDependentUnacceptedSuffix() async throws {
        let f = try await fixture(coupled: true)
        try await connect(f)
        let barrier = expectation(description: "captured permit at actual journal admission")
        f.gate.arm(barrier)
        f.actions.change(.weightKg, value: .number(87), model: f.model,
                         now: Date(timeIntervalSince1970: 1_789_693_200), zone: TimeZone(secondsFromGMT: 0)!)
        await fulfillment(of: [barrier], timeout: 3)
        try XCTUnwrap(f.model.scoringContextConsent).gate.holdAdmission()
        f.gate.release()
        await f.actions.waitForCompletion()
        let original = try XCTUnwrap(f.actions.ticket)
        XCTAssertEqual(original.state, .held(.held))
        XCTAssertTrue(f.actions.canRetry)
        let later = try f.model.completePreferenceAction([.init(key: .heightCm, value: .number(183))])
        XCTAssertEqual(f.model.scoringPreferences?.pendingCount, 2)
        try await f.model.prepareScoringPreferences()
        f.actions.retry(model: f.model)
        await f.actions.waitForCompletion()
        XCTAssertTrue(f.actions.ticket === original)
        XCTAssertEqual(original.state, .held(.held), "retry cannot borrow the newly prepared permit")
        XCTAssertEqual(f.model.profile.weightKg, 75)
        let result = try await projection(f)
        XCTAssertEqual(result.position, .initial)
        f.actions.discard(model: f.model)
        XCTAssertEqual(original.state, .discarded)
        XCTAssertEqual(later.state, .discarded)
        XCTAssertEqual(f.model.scoringPreferences?.pendingCount, 0)
        XCTAssertEqual(f.model.profile.heightCm, 178)
    }

    func testModeChangeDuringJournalSuspensionDoesNotPromoteLocalOnlyAction() async throws {
        let f = try await fixture()
        let barrier = expectation(description: "captured local-only action reaches journal")
        f.gate.arm(barrier)
        f.actions.change(.hrvWindow, value: .text("deep"), model: f.model)
        await fulfillment(of: [barrier], timeout: 3)
        f.policy.coupled = true
        f.gate.release()
        await f.actions.waitForCompletion()
        XCTAssertNil(try receipt(f.actions).profileMutationID)
        XCTAssertNil(try receipt(f.actions).configMutationID)
        XCTAssertEqual(f.actions.hrvWindow(model: f.model), "deep")
        XCTAssertTrue(f.actions.message.contains("No server change was queued"))
        f.model.scheduleScoringProfileInputs()
        let result = try await projection(f)
        XCTAssertEqual(result.position.sequence, 1)
        XCTAssertEqual(result.entries.first?.disposition, .localOnly)
    }

    func testSuspendedJournalOwnerReplacementHasNoOldSuccessOrNewAccountWrite() async throws {
        let f = try await fixture(), replacement = try await fixture()
        let barrier = expectation(description: "old account actual journal admission")
        f.gate.arm(barrier)
        f.actions.stage(.weightKg, value: .number(93), model: f.model)
        var advances = 0
        f.actions.saveOnboarding(model: f.model) { advances += 1 }
        await fulfillment(of: [barrier], timeout: 3)
        f.identity.replace(replacement.context)
        f.model.shutdownForAccountChange()
        f.gate.release()
        await f.actions.waitForCompletion()
        XCTAssertEqual(advances, 0)
        XCTAssertEqual(f.actions.phase, .retired)
        XCTAssertNil(f.model.acceptedScoringPreferences)
        f.actions.change(.weightKg, value: .number(99), model: replacement.model)
        XCTAssertEqual(replacement.model.profile.weightKg, 75)
        let untouched = try await projection(replacement)
        XCTAssertEqual(untouched.position, .initial)
    }

    func testDisappearanceSuppressesLateNavigationButDoesNotCancelAcceptedChange() async throws {
        let f = try await fixture()
        let barrier = expectation(description: "onboarding journal suspended")
        f.gate.arm(barrier)
        f.actions.stage(.weightKg, value: .number(91), model: f.model)
        var advances = 0
        f.actions.saveOnboarding(model: f.model) { advances += 1 }
        await fulfillment(of: [barrier], timeout: 3)
        f.actions.suspendPresentation()
        f.gate.release()
        await f.actions.waitForCompletion()
        XCTAssertEqual(advances, 0)
        XCTAssertEqual(f.actions.phase, .saved)
        XCTAssertEqual(f.model.profile.weightKg, 91)
        XCTAssertEqual(try receipt(f.actions).position.sequence, 1)
    }

    func testReentrantPresentationObserverRetirementPreventsSuccessCallback() async throws {
        let f = try await fixture()
        var success = 0
        f.actions.recalibrate(model: f.model) { success += 1 }
        // The helper clears drafts only after ticket acceptance. A synchronous Combine observer
        // can retire the owner during that publication, before the success text/callback.
        let observer = f.actions.$draft.dropFirst().sink { _ in
            f.identity.replace(.init(scope: f.context.scope, generation: UUID()))
        }
        await f.actions.waitForCompletion()
        withExtendedLifetime(observer) { }
        XCTAssertEqual(success, 0)
        XCTAssertEqual(f.actions.phase, .retired)
        XCTAssertNil(f.model.acceptedScoringPreferences)
    }

    func testLoadingFailureDoesNotResubmitOnHydration() async throws {
        let f = try await fixture(prepare: false)
        f.actions.change(.weightKg, value: .number(89), model: f.model)
        XCTAssertEqual(f.actions.phase, .failed)
        XCTAssertNil(f.actions.ticket)
        try await f.model.prepareScoringPreferences()
        XCTAssertEqual(f.model.profile.weightKg, 75)
        XCTAssertEqual(f.actions.phase, .failed)
        XCTAssertFalse(f.actions.canRetry)
        f.actions.discard(model: f.model)
        let result = try await projection(f)
        XCTAssertEqual(result.position, .initial)
    }

    func testSignedOutAlgorithmAndHRVGesturesKeepLegacyLocalOnlyWithoutAcceptanceClaim() async throws {
        try XCTSkipUnless(AppRuntimeMode.isUnitTesting, "requires hermetic app construction")
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let root = temporary.appendingPathComponent("preference-guest-action-" + UUID().uuidString)
        let suite = "preference-guest-action-" + UUID().uuidString
        let localDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { localDefaults.removePersistentDomain(forName: suite) }
        let guest = AppModel(storageLayout: .init(baseDirectory: root, scope: nil), context: nil,
                             presentationAllowed: false, captureAllowed: false,
                             guestPreferenceDefaults: localDefaults, isCurrent: { $0 == nil })
        defer { guest.shutdownForAccountChange() }
        XCTAssertTrue(guest.isAccountRuntimeActive)
        let actions = ScoringPreferenceActions(legacyDefaults: localDefaults)
        actions.setAlgorithm(.effortMethod, enabled: true, model: guest)
        XCTAssertTrue(actions.algorithm(.effortMethod, model: guest))
        XCTAssertEqual(actions.phase, .local)
        XCTAssertNil(actions.ticket)
        actions.change(.hrvWindow, value: .text("deep"), model: guest)
        XCTAssertEqual(actions.hrvWindow(model: guest), "deep")
        XCTAssertEqual(actions.phase, .local)
        XCTAssertNil(actions.ticket)
        XCTAssertNil(guest.scoringInputs)
        XCTAssertNil(guest.scoringPreferences)
        XCTAssertTrue(actions.message.contains("updated locally"))
        XCTAssertTrue(actions.message.contains("No server change was queued"))
        XCTAssertFalse(actions.message.contains("saved"))
    }

    func testReopenHeldMissingSourceUsesSameHeadWithoutRecaptureAndCanDiscard() async throws {
        let f = try await fixture(coupled: true)
        var firstView: ScoringPreferenceActions? = ScoringPreferenceActions()
        weak var releasedView = firstView
        firstView?.resumePendingChange(model: f.model)
        firstView?.change(.weightKg, value: .number(88), model: f.model)
        await firstView?.waitForCompletion()
        let original = try XCTUnwrap(firstView?.ticket)
        XCTAssertEqual(original.state, .held(.missingSource))
        firstView?.suspendPresentation(); firstView = nil
        XCTAssertNil(releasedView, "the runtime, not a dismissed view, retains the exact FIFO head")

        let reopened = ScoringPreferenceActions()
        reopened.resumePendingChange(model: f.model)
        XCTAssertTrue(reopened.ticket === original)
        XCTAssertTrue(f.model.scoringPreferences?.pendingHeadTicket === original)
        XCTAssertEqual(reopened.phase, .held)
        XCTAssertFalse(reopened.canRetry)
        XCTAssertTrue(reopened.message.contains("source device was unavailable"))
        try await connect(f)
        try await f.model.prepareScoringPreferences()
        f.policy.coupled = false
        reopened.resumePendingChange(model: f.model)
        await reopened.waitForRecoveryObservation()
        XCTAssertTrue(reopened.ticket === original)
        XCTAssertEqual(original.state, .held(.missingSource))
        XCTAssertEqual(f.model.scoringPreferences?.pendingCount, 1)
        XCTAssertEqual(f.model.profile.weightKg, 75)
        let beforeDiscard = try await projection(f)
        XCTAssertEqual(beforeDiscard.position, .initial)

        reopened.discard(model: f.model)
        XCTAssertEqual(original.state, .discarded)
        XCTAssertEqual(reopened.phase, .idle)
        XCTAssertNil(f.model.scoringPreferences?.pendingHeadTicket)
        let thirdView = ScoringPreferenceActions()
        thirdView.resumePendingChange(model: f.model)
        XCTAssertNil(thirdView.ticket)
        XCTAssertEqual(f.model.scoringPreferences?.pendingCount, 0)
        let afterDiscard = try await projection(f)
        XCTAssertEqual(afterDiscard.position, .initial)
    }

    func testReopenQueuedHeadDoesNotConsumeInitiatingAcceptanceWaiter() async throws {
        let f = try await fixture()
        f.actions.resumePendingChange(model: f.model)
        let barrier = expectation(description: "original journal admission is in flight")
        f.gate.arm(barrier)
        f.actions.stage(.weightKg, value: .number(89), model: f.model)
        var advances = 0
        f.actions.saveOnboarding(model: f.model) { advances += 1 }
        await fulfillment(of: [barrier], timeout: 3)
        let original = try XCTUnwrap(f.actions.ticket)
        f.actions.suspendPresentation()

        let reopened = ScoringPreferenceActions()
        reopened.resumePendingChange(model: f.model)
        XCTAssertTrue(reopened.ticket === original)
        XCTAssertEqual(reopened.phase, .saving)
        XCTAssertFalse(reopened.canRetry)
        XCTAssertEqual(f.model.profile.weightKg, 75)
        XCTAssertEqual(f.model.scoringPreferences?.pendingCount, 1)
        f.gate.release()
        await f.actions.waitForCompletion()
        await reopened.waitForRecoveryObservation()
        XCTAssertEqual(f.actions.phase, .saved, "the original waiter still receives actual acceptance")
        XCTAssertEqual(try receipt(f.actions).position.sequence, 1)
        XCTAssertEqual(advances, 0, "reopening must not resurrect the dismissed navigation callback")
        XCTAssertEqual(reopened.phase, .idle)
        XCTAssertEqual(reopened.message, String(localized: "Showing saved account preferences."))
        XCTAssertEqual(f.model.profile.weightKg, 89)
        XCTAssertNil(f.model.scoringPreferences?.pendingHeadTicket)
    }

    func testReopenExplicitRetryKeepsHeadAndLeavesAcceptanceWaiterAvailable() async throws {
        let f = try await fixture(coupled: true)
        try await connect(f)
        let firstBarrier = expectation(description: "first admission reaches real journal")
        f.gate.arm(firstBarrier)
        f.actions.change(.weightKg, value: .number(87), model: f.model)
        await fulfillment(of: [firstBarrier], timeout: 3)
        // A transient admission hold, not a new consent epoch or substituted capture context.
        f.admission.set(false)
        f.gate.release()
        await f.actions.waitForCompletion()
        let original = try XCTUnwrap(f.actions.ticket)
        XCTAssertEqual(original.state, .held(.held))
        f.actions.suspendPresentation()

        let reopened = ScoringPreferenceActions()
        reopened.resumePendingChange(model: f.model)
        XCTAssertTrue(reopened.ticket === original)
        XCTAssertEqual(reopened.phase, .held)
        XCTAssertTrue(reopened.canRetry)
        f.admission.set(true)
        await reopened.waitForRecoveryObservation()
        XCTAssertEqual(original.state, .held(.held), "availability alone is not an automatic retry")
        XCTAssertEqual(f.model.profile.weightKg, 75)

        let retryBarrier = expectation(description: "explicit retry reaches real journal with same head")
        f.gate.arm(retryBarrier)
        reopened.retry(model: f.model)
        // A separate consumer can still be the sole acceptance waiter. Reopened presentation must
        // use published state only, even after its explicit Retry button is pressed.
        let waiter = Task { try await original.acceptance() }
        await fulfillment(of: [retryBarrier], timeout: 3)
        XCTAssertTrue(reopened.ticket === original)
        XCTAssertTrue(f.model.scoringPreferences?.pendingHeadTicket === original)
        XCTAssertEqual(f.model.scoringPreferences?.pendingCount, 1)
        XCTAssertEqual(f.model.profile.weightKg, 75)
        f.gate.release()
        let accepted = try await waiter.value
        await reopened.waitForRecoveryObservation()
        XCTAssertEqual(accepted.position.id, original.id)
        XCTAssertEqual(accepted.position.sequence, 1)
        XCTAssertNotNil(accepted.profileMutationID)
        XCTAssertNotNil(accepted.configMutationID)
        XCTAssertEqual(f.model.profile.weightKg, 87)
        XCTAssertEqual(reopened.phase, .idle)
        XCTAssertNil(f.model.scoringPreferences?.pendingHeadTicket)
        let result = try await projection(f)
        XCTAssertEqual(result.position, accepted.position)
    }

    func testReopenCannotRecoverAnotherGenerationOrRetiredRuntimeHead() async throws {
        let f = try await fixture(coupled: true)
        f.actions.change(.heightCm, value: .number(186), model: f.model)
        await f.actions.waitForCompletion()
        let original = try XCTUnwrap(f.actions.ticket)
        XCTAssertEqual(original.state, .held(.missingSource))
        f.actions.suspendPresentation()
        f.identity.replace(.init(scope: f.context.scope, generation: UUID()))
        let reopened = ScoringPreferenceActions()
        reopened.resumePendingChange(model: f.model)
        XCTAssertNil(reopened.ticket)
        XCTAssertNil(f.model.scoringPreferences?.pendingHeadTicket)
        XCTAssertEqual(reopened.phase, .retired)
        XCTAssertFalse(reopened.canRetry)
        reopened.retry(model: f.model)
        XCTAssertEqual(original.state, .held(.missingSource), "stale presentation performs no operation")
        f.model.shutdownForAccountChange()
        reopened.resumePendingChange(model: f.model)
        XCTAssertNil(reopened.ticket)
        XCTAssertEqual(reopened.phase, .retired)
    }
}
