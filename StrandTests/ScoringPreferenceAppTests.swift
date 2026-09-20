import Foundation
import GRDB
import NoopPush
import WhoopStore
import XCTest
@testable import Strand

enum ScoringPreferenceAppTestSupport {
    @MainActor static func dependencies(context: AccountSessionContext,
        isCurrent: @escaping @Sendable (AccountSessionContext) -> Bool) -> ScoringInputCoordinator.Dependencies {
        .init(isCurrent: { isCurrent($0) }, canUpload: { false }, openJournal: { layout, fence in
            try ScoringInputJournal(layout: layout, fence: fence, preferenceContext: context,
                isPreferenceContextCurrent: isCurrent)
        }, head: { _, _ in throw ScoringInputJournal.Failure.held },
        send: { _, _ in throw ScoringInputJournal.Failure.held })
    }
}

@MainActor
final class ScoringPreferenceAppTests: XCTestCase {
    private final class Identity: @unchecked Sendable {
        private let lock = NSLock()
        private var value: AccountSessionContext
        init(_ value: AccountSessionContext) { self.value = value }
        func matches(_ context: AccountSessionContext) -> Bool {
            lock.lock(); defer { lock.unlock() }; return value == context
        }
        func replace(_ context: AccountSessionContext) { lock.lock(); value = context; lock.unlock() }
    }
    @MainActor private final class Policy { var enabled: Bool; init(_ enabled: Bool) { self.enabled = enabled } }
    @MainActor private final class Fixture {
        let root: URL
        let context: AccountSessionContext
        let layout: AccountStorageLayout
        let identity: Identity
        let policy: Policy
        let model: AppModel
        init(coupled: Bool = false, seed: [String: Any] = [:], registration: [String: Any] = [:]) throws {
            let temporary = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory
            root = temporary.appendingPathComponent("preference-app-" + UUID().uuidString)
            let scope = try AccountScope(projectURL: "https://" + UUID().uuidString + ".invalid", userID: UUID().uuidString)
            context = .init(scope: scope, generation: UUID())
            layout = .init(baseDirectory: root, scope: scope)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: layout.preferencesSuite))
            defaults.setPersistentDomain(seed, forName: layout.preferencesSuite)
            defaults.register(defaults: registration)
            let context = context, identity = Identity(context), policy = Policy(coupled)
            self.identity = identity; self.policy = policy
            model = AppModel(storageLayout: layout, context: context, captureAllowed: true,
                scoringInputDependencies: ScoringPreferenceAppTestSupport.dependencies(context: context,
                    isCurrent: { identity.matches($0) }),
                nativePreferenceCurrent: { identity.matches($0) }, preferenceScoringEnabled: { policy.enabled },
                isCurrent: { $0.map(identity.matches) == true })
        }
        func journal() throws -> ScoringInputJournal {
            let identity = identity
            return try ScoringInputJournal(layout: layout, preferenceContext: context,
                isPreferenceContextCurrent: { identity.matches($0) })
        }
        func close() async throws {
            let captured = model.shutdownForAccountChange()
            let bleDrained = await model.ble.drainCaptureAfterAccountChange()
            let genericDrained = await captured?.drain() ?? true
            XCTAssertTrue(bleDrained); XCTAssertTrue(genericDrained)
            await model.scoringPreferences?.waitForRetirement()
            try await model.scoringInputs?.waitForRetirement()
            UserDefaults(suiteName: layout.preferencesSuite)?.removePersistentDomain(forName: layout.preferencesSuite)
            if captured != nil {
                print("Retained preference fixture with capture-store handle: \(root.path)")
            } else if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
    }
    private func fixture(coupled: Bool = false, seed: [String: Any] = [:], registration: [String: Any] = [:]) throws -> Fixture {
        try XCTSkipUnless(AppRuntimeMode.isUnitTesting, "requires hermetic app construction")
        let f = try Fixture(coupled: coupled, seed: seed, registration: registration)
        addTeardownBlock { try await f.close() }
        return f
    }
    private func projection(_ f: Fixture) async throws -> ScoringPreferenceProjection {
        try await XCTUnwrap(f.model.scoringInputs).preferenceProjection()
    }
    private func connectRegistry(_ f: Fixture) async throws {
        await f.model.wireSourceCoordinator()
        XCTAssertNotNil(f.model.deviceRegistry)
        XCTAssertNotNil(f.model.resolvedScoringPreferenceSource)
    }

    func testHydrationUsesOnlyAccountDomainAndCreatesNoAction() async throws {
        let f = try fixture(seed: ["profile.weightKg": 91.5], registration: [
            "noopBanisterEffort": true, "noopExperimentalSleepV2": false,
            "noopMotionAwareWake": true, "profile.heightCm": 222.0])
        XCTAssertNil(f.model.acceptedScoringPreferences)
        try await f.model.prepareScoringPreferences()
        XCTAssertEqual(f.model.profile.weightKg, 91.5)
        XCTAssertEqual(f.model.profile.heightCm, 178)
        XCTAssertEqual(f.model.scoringAlgorithmChoices.effortMethod, "EDWARDS")
        XCTAssertTrue(f.model.scoringAlgorithmChoices.useSleepStagerV2)
        XCTAssertFalse(f.model.scoringAlgorithmChoices.useMotionAwareWake)
        let result = try await projection(f)
        XCTAssertEqual(result.position, .initial)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testActionBeforeHydrationDoesNotBecomeAnActionOnStartup() async throws {
        let f = try fixture()
        let ticket = try f.model.completePreferenceAction([.init(key: .weightKg, value: .number(88))])
        XCTAssertEqual(ticket.state, .held(.loading))
        try await f.model.prepareScoringPreferences()
        f.model.scheduleScoringProfileInputs()
        XCTAssertEqual(ticket.state, .held(.loading))
        XCTAssertEqual(f.model.profile.weightKg, 75)
        let result = try await projection(f)
        XCTAssertEqual(result.position, .initial)
    }

    func testResetPublishesExactPairOnlyAfterDurableAcceptance() async throws {
        let f = try fixture()
        try await f.model.prepareScoringPreferences()
        let epoch = 1_789_693_200.125
        let ticket = try XCTUnwrap(f.model.recalibrateChargeBaseline(now: epoch))
        XCTAssertEqual(f.model.acceptedScoringPreferences?.hrvBaselineEpoch, 0)
        XCTAssertEqual(f.model.acceptedScoringPreferences?.recoveryBaselineEpoch, 0)
        let receipt = try await ticket.acceptance()
        XCTAssertNil(receipt.profileMutationID); XCTAssertNil(receipt.configMutationID)
        XCTAssertEqual(f.model.acceptedScoringPreferences?.hrvBaselineEpoch, epoch)
        XCTAssertEqual(f.model.acceptedScoringPreferences?.recoveryBaselineEpoch, epoch)
        let result = try await projection(f)
        XCTAssertEqual(result.position.sequence, 1)
        XCTAssertEqual(Set(result.entries.map(\.key)), [.hrvBaselineEpoch, .recoveryBaselineEpoch])
    }

    func testMissingSourceRemainsHeldAfterRealRegistryDiscovery() async throws {
        let f = try fixture(coupled: true)
        try await f.model.prepareScoringPreferences()
        XCTAssertNil(f.model.resolvedScoringPreferenceSource, "bootstrap my-whoop is not a resolved source")
        let patch = [ScoringPreferenceIntent.Patch(key: .weightKg, value: .number(88))]
        let held = try f.model.completePreferenceAction(patch)
        XCTAssertEqual(held.state, .held(.missingSource))
        try await connectRegistry(f)
        f.model.scheduleScoringProfileInputs()
        try await f.model.prepareScoringPreferences()
        XCTAssertEqual(held.state, .held(.missingSource))
        XCTAssertEqual(f.model.profile.weightKg, 75)
        XCTAssertTrue(try XCTUnwrap(f.model.scoringPreferences).discardUnacceptedChain(from: held))
        let replacement = try f.model.completePreferenceAction(patch)
        let receipt = try await replacement.acceptance()
        XCTAssertNotEqual(held.id, replacement.id)
        XCTAssertNotNil(receipt.profileMutationID); XCTAssertNotNil(receipt.configMutationID)
        XCTAssertEqual(f.model.profile.weightKg, 88)
    }

    func testOfflineCoupledActionCapturesSourceAndDayWithoutSending() async throws {
        let f = try fixture(coupled: true)
        try await f.model.prepareScoringPreferences()
        try await connectRegistry(f)
        let date = Date(timeIntervalSince1970: 1_789_693_200)
        let zone = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))
        let ticket = try f.model.completePreferenceAction([.init(key: .hrvWindow, value: .text("deep"))], now: date, zone: zone)
        let receipt = try await ticket.acceptance()
        XCTAssertNotNil(receipt.profileMutationID); XCTAssertNotNil(receipt.configMutationID)
        XCTAssertEqual(f.model.hrvWindowRaw, "deep")
        let journal = try f.journal()
        let status = try await journal.status()
        XCTAssertEqual(status.pending, 2)
        let pending = try await journal.next()
        let first = try XCTUnwrap(pending)
        XCTAssertEqual(first.change.device, f.model.resolvedScoringPreferenceSource)
        XCTAssertEqual(first.change.effectiveDay, ServerScoreDate.day(date, timeZone: zone))
        try await journal.close()
    }

    func testRapidCompletedActionsKeepAllThreePositions() async throws {
        let f = try fixture()
        try await f.model.prepareScoringPreferences()
        let tickets = try [80.0, 90.0, 80.0].map {
            try f.model.completePreferenceAction([.init(key: .weightKg, value: .number($0))])
        }
        XCTAssertEqual(f.model.profile.weightKg, 75)
        var positions: [Int64] = []
        for ticket in tickets { positions.append(try await ticket.acceptance().position.sequence) }
        XCTAssertEqual(positions, [1, 2, 3])
        XCTAssertEqual(Set(tickets.map(\.id)).count, 3)
        XCTAssertEqual(f.model.profile.weightKg, 80)
        let result = try await projection(f)
        XCTAssertEqual(result.position.sequence, 3)
    }

    func testConsentPermitAbsenceIsNotFilledByLaterPreparation() async throws {
        let f = try fixture(coupled: true)
        try await f.model.prepareScoringPreferences()
        try await connectRegistry(f)
        try XCTUnwrap(f.model.scoringContextConsent).gate.holdAdmission()
        let ticket = try f.model.completePreferenceAction([.init(key: .heightCm, value: .number(181))])
        XCTAssertEqual(ticket.state, .held(.missingPermit))
        try await f.model.prepareScoringPreferences()
        XCTAssertEqual(ticket.state, .held(.missingPermit))
        XCTAssertEqual(f.model.profile.heightCm, 178)
        let result = try await projection(f)
        XCTAssertEqual(result.position, .initial)
    }

    func testLocalOnlyAcceptanceDoesNotBecomeServerDebtWhenModeChanges() async throws {
        let f = try fixture()
        try await f.model.prepareScoringPreferences()
        let ticket = try f.model.completePreferenceAction([.init(key: .effortMethod, value: .text("BANISTER"))])
        let receipt = try await ticket.acceptance()
        XCTAssertNil(receipt.configMutationID)
        f.policy.enabled = true
        f.model.scheduleScoringProfileInputs()
        try await f.model.prepareScoringPreferences()
        let journal = try f.journal()
        let status = try await journal.status()
        XCTAssertEqual(status.pending, 0)
        XCTAssertEqual(f.model.scoringAlgorithmChoices.effortMethod, "BANISTER")
        let result = try await projection(f)
        XCTAssertEqual(result.position, receipt.position)
        try await journal.close()
    }

    func testDirectSettersAndCalibrationOutputsCannotCreateOrdinaryActions() async throws {
        let f = try fixture()
        try await f.model.prepareScoringPreferences()
        f.model.profile.weightKg = 99
        f.model.profile.stepsCalibrationCoefficient = 6.5
        f.model.profile.avatarImageData = Data([1, 2, 3])
        f.model.accountDefaults.set(true, forKey: "noopBanisterEffort")
        f.model.scheduleScoringProfileInputs()
        XCTAssertEqual(f.model.profile.weightKg, 75)
        XCTAssertEqual(f.model.scoringAlgorithmChoices.effortMethod, "EDWARDS")
        let result = try await projection(f)
        XCTAssertEqual(result.position, .initial)
    }

    func testSameOwnerGenerationRetirementCannotPublishQueuedChange() async throws {
        let f = try fixture()
        try await f.model.prepareScoringPreferences()
        let ticket = try f.model.completePreferenceAction([.init(key: .weightKg, value: .number(88))])
        f.identity.replace(.init(scope: f.context.scope, generation: UUID()))
        f.model.shutdownForAccountChange()
        XCTAssertEqual(ticket.state, .held(.retired))
        XCTAssertNil(f.model.acceptedScoringPreferences)
        XCTAssertThrowsError(try f.model.completePreferenceAction([.init(key: .weightKg, value: .number(91))]))
        XCTAssertNil(f.model.accountDefaults.object(forKey: "profile.weightKg"))
    }
}
