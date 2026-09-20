import Foundation
import NoopPush
import StrandAnalytics
import WhoopProtocol
import XCTest
@testable import Strand

@MainActor
final class ScoringPreferenceViewLoadTests: XCTestCase {
    private enum SyntheticFailure: Error { case journalUnavailable }
    private final class Identity: @unchecked Sendable {
        private let lock = NSLock()
        private var value: AccountSessionContext
        init(_ value: AccountSessionContext) { self.value = value }
        func matches(_ context: AccountSessionContext) -> Bool {
            lock.lock(); defer { lock.unlock() }; return value == context
        }
        func replace(_ context: AccountSessionContext) { lock.lock(); value = context; lock.unlock() }
    }

    @MainActor private final class Gate {
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func wait() async {
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @MainActor private final class Fixture {
        let root: URL
        var context: AccountSessionContext
        let layout: AccountStorageLayout
        let identity: Identity
        var model: AppModel

        init(journalUnavailable: Bool = false) throws {
            let temporary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
            root = temporary.appendingPathComponent("preference-view-load-" + UUID().uuidString)
            let scope = try AccountScope(projectURL: "https://view-" + UUID().uuidString + ".invalid",
                                         userID: UUID().uuidString)
            context = .init(scope: scope, generation: UUID())
            layout = .init(baseDirectory: root, scope: scope)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: layout.preferencesSuite))
            defaults.setPersistentDomain(["profile.dateOfBirth": Date(timeIntervalSince1970: 473_385_600),
                                          "profile.sex": "male"], forName: layout.preferencesSuite)
            let context = context, identity = Identity(context)
            self.identity = identity
            var inputs = ScoringPreferenceAppTestSupport.dependencies(context: context,
                isCurrent: { identity.matches($0) })
            if journalUnavailable {
                inputs.openJournal = { _, _ in throw SyntheticFailure.journalUnavailable }
            }
            model = AppModel(storageLayout: layout, context: context, captureAllowed: false,
                scoringInputDependencies: inputs, nativePreferenceCurrent: { identity.matches($0) },
                preferenceScoringEnabled: { false }, isCurrent: { $0.map(identity.matches) == true })
        }

        func reopen() async throws {
            let captured = model.shutdownForAccountChange()
            let bleDrained = await model.ble.drainCaptureAfterAccountChange()
            let genericDrained = await captured?.drain() ?? true
            XCTAssertTrue(bleDrained); XCTAssertTrue(genericDrained)
            await model.scoringPreferences?.waitForRetirement()
            try await model.scoringInputs?.waitForRetirement()
            context = .init(scope: context.scope, generation: UUID())
            identity.replace(context)
            let context = context, identity = identity
            model = AppModel(storageLayout: layout, context: context, captureAllowed: false,
                scoringInputDependencies: ScoringPreferenceAppTestSupport.dependencies(context: context,
                    isCurrent: { identity.matches($0) }), nativePreferenceCurrent: { identity.matches($0) },
                preferenceScoringEnabled: { false }, isCurrent: { $0.map(identity.matches) == true })
        }

        func close() async throws {
            let captured = model.shutdownForAccountChange()
            let bleDrained = await model.ble.drainCaptureAfterAccountChange()
            let genericDrained = await captured?.drain() ?? true
            XCTAssertTrue(bleDrained); XCTAssertTrue(genericDrained)
            await model.scoringPreferences?.waitForRetirement()
            try await model.scoringInputs?.waitForRetirement()
            UserDefaults(suiteName: layout.preferencesSuite)?.removePersistentDomain(forName: layout.preferencesSuite)
            if captured == nil, FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
    }

    private func fixture(prepare: Bool = true, journalUnavailable: Bool = false) async throws -> Fixture {
        try XCTSkipUnless(AppRuntimeMode.isUnitTesting, "requires hermetic app-host construction")
        let fixture = try Fixture(journalUnavailable: journalUnavailable)
        addTeardownBlock { try await fixture.close() }
        if prepare { try await fixture.model.prepareScoringPreferences() }
        return fixture
    }

    /// Exercises the production fence and actual Today cache, not SwiftUI's private @State storage.
    @discardableResult private func publish(_ load: ScoringPreferenceViewLoad, into model: AppModel,
                                            value: inout Double?) -> Bool {
        guard load.isCurrent(app: model, repo: model.repo) else { return false }
        value = strain(load)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        model.repo.todayDayScopedCache = TodayDayScopedCache(restSpark: [], restScore: nil,
            provenanceByMetric: [:], providerByMetric: [:], hrPoints: [], stepActivityClassToday: nil,
            liveTodayStrain: value, hrAxis: start...start.addingTimeInterval(3_600), sleepToday: nil, bankedAt: start)
        model.repo.todayDayScopedLoadedSeq = load.revision
        return true
    }

    private func strain(_ load: ScoringPreferenceViewLoad) -> Double? {
        let samples = (0..<3_600).map { HRSample(ts: 1_700_000_000 + $0, bpm: 125) }
        let maxHR = load.profileAge > 0 ? StrainScorer.tanakaHRmax(age: Double(load.profileAge)) : nil
        return StrainScorer.strain(samples, maxHR: maxHR, restingHR: StrainScorer.defaultRestingHR,
                                   method: load.effortMethod, sex: load.profileSex)
    }

    func testAcceptedPublicationFinishesNewPassBeforeOldWithoutStaleStateOrCacheOverwrite() async throws {
        let f = try await fixture(), model = f.model
        let old = ScoringPreferenceViewLoad(app: model, repo: model.repo)
        let gate = Gate(expectation(description: "old presentation pass suspended"))
        var value: Double?
        let oldPass = Task { @MainActor in
            await gate.wait()
            return publish(old, into: model, value: &value)
        }
        defer { gate.release() }
        await fulfillment(of: [gate.entered], timeout: 5)
        let unchangedRows = model.repo.days
        let ticket = try model.completePreferenceAction([
            .init(key: .effortMethod, value: .text("BANISTER")),
            .init(key: .sex, value: .text("female")),
            .init(key: .dateOfBirth, value: .number(946_684_800))])
        XCTAssertEqual(model.repo.refreshSeq, old.revision, "pending intent is not accepted publication")
        XCTAssertTrue(old.isCurrent(app: model, repo: model.repo))
        _ = try await ticket.acceptance()
        let fresh = ScoringPreferenceViewLoad(app: model, repo: model.repo)
        XCTAssertEqual(model.repo.refreshSeq, old.revision + 1)
        XCTAssertEqual(model.repo.days, unchangedRows)
        XCTAssertNotEqual(old.profileAge, fresh.profileAge)
        XCTAssertEqual(old.profileSex, "male")
        XCTAssertEqual(fresh.profileSex, "female")
        let expected = try XCTUnwrap(strain(fresh))
        XCTAssertNotEqual(try XCTUnwrap(strain(old)), expected, "fixture must distinguish native recipes")
        let newPass = Task { @MainActor in publish(fresh, into: model, value: &value) }
        let newPublished = await newPass.value
        XCTAssertTrue(newPublished)
        gate.release()
        let oldPublished = await oldPass.value
        XCTAssertFalse(oldPublished)
        XCTAssertEqual(value, expected)
        XCTAssertEqual(model.repo.todayDayScopedCache?.liveTodayStrain, expected)
        XCTAssertEqual(model.repo.todayDayScopedLoadedSeq, fresh.revision)
    }

    func testPendingIntentDoesNotInvalidateCapturedAcceptedInputs() async throws {
        let f = try await fixture(), model = f.model
        let load = ScoringPreferenceViewLoad(app: model, repo: model.repo)
        let ticket = try model.completePreferenceAction([.init(key: .effortMethod, value: .text("BANISTER"))])
        XCTAssertEqual(model.repo.refreshSeq, load.revision)
        XCTAssertEqual(load.effortMethod, .edwards)
        XCTAssertTrue(load.isCurrent(app: model, repo: model.repo))
        var value: Double?
        XCTAssertTrue(publish(load, into: model, value: &value))
        XCTAssertEqual(value, strain(load))
        _ = try await ticket.acceptance()
        XCTAssertFalse(load.isCurrent(app: model, repo: model.repo))
    }

    func testHydrationInvalidatesAnUnhydratedPassEvenWhenDefaultsAreIdentical() async throws {
        let f = try await fixture(prepare: false), model = f.model
        let load = ScoringPreferenceViewLoad(app: model, repo: model.repo)
        XCTAssertEqual(load.context, f.context)
        XCTAssertFalse(load.isCurrent(app: model, repo: model.repo))
        XCTAssertNil(model.acceptedScoringPreferences)
        var value: Double?
        XCTAssertFalse(publish(load, into: model, value: &value))
        XCTAssertNil(value)
        XCTAssertNil(model.repo.todayDayScopedCache)
        try await model.prepareScoringPreferences()
        XCTAssertEqual(load.algorithms, model.scoringAlgorithmChoices)
        XCTAssertEqual(model.repo.refreshSeq, load.revision + 1)
        XCTAssertFalse(publish(load, into: model, value: &value))
        XCTAssertNil(value)
        XCTAssertNil(model.repo.todayDayScopedCache)
        let hydrated = ScoringPreferenceViewLoad(app: model, repo: model.repo)
        XCTAssertTrue(publish(hydrated, into: model, value: &value))
        XCTAssertEqual(model.repo.todayDayScopedLoadedSeq, hydrated.revision)
    }

    func testReopenedNonDefaultRecipeCannotPublishBeforeHydration() async throws {
        let f = try await fixture()
        let ticket = try f.model.completePreferenceAction([
            .init(key: .effortMethod, value: .text("BANISTER")),
            .init(key: .sex, value: .text("female")),
            .init(key: .dateOfBirth, value: .number(946_684_800))])
        _ = try await ticket.acceptance()
        let accepted = try XCTUnwrap(f.model.acceptedScoringPreferences)
        let expected = try XCTUnwrap(strain(ScoringPreferenceViewLoad(app: f.model, repo: f.model.repo)))
        try await f.reopen()
        let model = f.model
        let unhydrated = ScoringPreferenceViewLoad(app: model, repo: model.repo)
        XCTAssertNil(model.acceptedScoringPreferences)
        var value: Double?
        XCTAssertFalse(publish(unhydrated, into: model, value: &value))
        XCTAssertNil(value)
        XCTAssertNil(model.repo.todayDayScopedCache)
        try await model.prepareScoringPreferences()
        let hydrated = ScoringPreferenceViewLoad(app: model, repo: model.repo)
        XCTAssertEqual(model.acceptedScoringPreferences?.position, accepted.position)
        XCTAssertEqual(hydrated.effortMethod, .banister)
        XCTAssertEqual(hydrated.profileSex, "female")
        XCTAssertFalse(publish(unhydrated, into: model, value: &value))
        XCTAssertTrue(publish(hydrated, into: model, value: &value))
        XCTAssertEqual(value, expected)
        XCTAssertEqual(model.repo.todayDayScopedCache?.liveTodayStrain, expected)
        XCTAssertEqual(model.repo.todayDayScopedLoadedSeq, hydrated.revision)
    }

    func testFailedHydrationRemainsUnavailableWithoutPublishingFallbackRecipe() async throws {
        let f = try await fixture(prepare: false, journalUnavailable: true), model = f.model
        let before = ScoringPreferenceViewLoad(app: model, repo: model.repo)
        do {
            try await model.prepareScoringPreferences()
            XCTFail("unavailable journal must not hydrate")
        } catch {}
        XCTAssertNil(model.acceptedScoringPreferences)
        let after = ScoringPreferenceViewLoad(app: model, repo: model.repo)
        var value: Double?
        XCTAssertFalse(publish(before, into: model, value: &value))
        XCTAssertFalse(publish(after, into: model, value: &value))
        XCTAssertNil(value)
        XCTAssertNil(model.repo.todayDayScopedCache)
    }

    func testServerPresentationCanProceedWithoutLocalPreferencesButRetainsLifetimeFence() async throws {
        let f = try await fixture(prepare: false, journalUnavailable: true), model = f.model
        do {
            try await model.prepareScoringPreferences()
            XCTFail("unavailable journal must not hydrate")
        } catch {}
        let load = ScoringPreferenceViewLoad(app: model, repo: model.repo)
        XCTAssertNil(model.acceptedScoringPreferences)
        XCTAssertFalse(load.isCurrent(app: model, repo: model.repo))
        XCTAssertTrue(load.isCurrent(app: model, repo: model.repo, requiringAcceptedPreferences: false))
        f.identity.replace(.init(scope: f.context.scope, generation: UUID()))
        XCTAssertFalse(load.isCurrent(app: model, repo: model.repo, requiringAcceptedPreferences: false))
        f.identity.replace(f.context)
        XCTAssertTrue(load.isCurrent(app: model, repo: model.repo, requiringAcceptedPreferences: false))
        _ = model.shutdownForAccountChange()
        XCTAssertFalse(load.isCurrent(app: model, repo: model.repo, requiringAcceptedPreferences: false))
    }

    func testCancelledSuspendedPassCannotPublishAtUnchangedAcceptedRevision() async throws {
        let f = try await fixture(), model = f.model
        let load = ScoringPreferenceViewLoad(app: model, repo: model.repo)
        let gate = Gate(expectation(description: "cancelled pass suspended"))
        var value: Double?
        let pass = Task { @MainActor in
            await gate.wait()
            return publish(load, into: model, value: &value)
        }
        defer { gate.release() }
        await fulfillment(of: [gate.entered], timeout: 5)
        pass.cancel()
        gate.release()
        let published = await pass.value
        XCTAssertFalse(published)
        XCTAssertEqual(model.repo.refreshSeq, load.revision)
        XCTAssertNil(value)
        XCTAssertNil(model.repo.todayDayScopedCache)
    }

    func testRetirementFencesSuspendedPassWithoutNeedingSequenceChange() async throws {
        let f = try await fixture(), model = f.model
        let load = ScoringPreferenceViewLoad(app: model, repo: model.repo)
        let gate = Gate(expectation(description: "retiring pass suspended"))
        var value: Double?
        let pass = Task { @MainActor in
            await gate.wait()
            return publish(load, into: model, value: &value)
        }
        defer { gate.release() }
        await fulfillment(of: [gate.entered], timeout: 5)
        _ = model.shutdownForAccountChange()
        gate.release()
        let published = await pass.value
        XCTAssertFalse(published)
        XCTAssertEqual(model.repo.refreshSeq, load.revision)
        XCTAssertNil(value)
        XCTAssertNil(model.repo.todayDayScopedCache)
    }

    func testSameAccountNewGenerationRejectsOldPassAtUnchangedSequence() async throws {
        let f = try await fixture(), model = f.model
        let load = ScoringPreferenceViewLoad(app: model, repo: model.repo)
        let successor = AccountSessionContext(scope: f.context.scope, generation: UUID())
        f.identity.replace(successor)
        XCTAssertEqual(load.context, f.context)
        XCTAssertNotEqual(load.context?.generation, successor.generation)
        XCTAssertEqual(model.repo.refreshSeq, load.revision)
        var value: Double?
        XCTAssertFalse(publish(load, into: model, value: &value))
        XCTAssertNil(value)
        XCTAssertNil(model.repo.todayDayScopedCache)
    }

    func testDifferentAccountModelOrRepositoryCannotBorrowLoadAtSameSequence() async throws {
        let first = try await fixture(), second = try await fixture()
        let load = ScoringPreferenceViewLoad(app: first.model, repo: first.model.repo)
        XCTAssertEqual(first.model.repo.refreshSeq, second.model.repo.refreshSeq)
        XCTAssertFalse(load.isCurrent(app: second.model, repo: second.model.repo))
        XCTAssertFalse(load.isCurrent(app: first.model, repo: second.model.repo))
        XCTAssertTrue(load.isCurrent(app: first.model, repo: first.model.repo))
    }

    func testVitalsTaskKeyChangesForAcceptedRevisionWithSameFlagAndForFlagChange() async throws {
        let f = try await fixture(), model = f.model
        func key() -> ScoringPreferenceVitalsLoadKey {
            .init(revision: model.repo.refreshSeq,
                  candidateDisplayEnabled: model.scoringAlgorithmChoices.spo2CandidateDisplayEnabled)
        }
        let initial = key()
        let effort = try model.completePreferenceAction([.init(key: .effortMethod, value: .text("BANISTER"))])
        XCTAssertEqual(initial, key(), "pending actions must not restart accepted presentation")
        _ = try await effort.acceptance()
        let revised = key()
        XCTAssertEqual(initial.candidateDisplayEnabled, revised.candidateDisplayEnabled)
        XCTAssertNotEqual(initial, revised)
        let candidate = try model.completePreferenceAction([.init(key: .spo2CandidateDisplayEnabled, value: .boolean(false))])
        _ = try await candidate.acceptance()
        XCTAssertFalse(key().candidateDisplayEnabled)
        XCTAssertNotEqual(revised, key())
        XCTAssertNotEqual(revised, .init(revision: revised.revision, candidateDisplayEnabled: false))
    }
}
