import Combine
import Foundation
import XCTest
@testable import NoopPush
@testable import Strand

@MainActor
final class AccountRuntimeReplacementTests: XCTestCase {
    @MainActor private final class IdentitySource {
        var value: AccountIdentitySnapshot
        let changes = PassthroughSubject<Void, Never>()
        init(_ value: AccountIdentitySnapshot) { self.value = value }
        func publish(_ value: AccountIdentitySnapshot) { self.value = value; changes.send() }
    }

    @MainActor private final class CapturedWriter {
        let context: AccountSessionContext?
        init(_ context: AccountSessionContext?) { self.context = context }
    }

    @MainActor private final class DrainBarrier {
        var calls: [AccountSessionContext?] = []
        var entered: (() -> Void)?
        private var release: CheckedContinuation<Bool, Never>?
        private var completed = false

        func drain(_ writer: CapturedWriter) async -> Bool {
            calls.append(writer.context)
            guard !completed else { return true }
            return await withCheckedContinuation { continuation in
                precondition(release == nil, "the actual retired drain must join overlapping retries")
                release = continuation
                entered?()
            }
        }

        func finish(_ succeeded: Bool) {
            if succeeded { completed = true }
            let continuation = release
            release = nil
            continuation?.resume(returning: succeeded)
        }
    }

    @MainActor private final class Fixture {
        enum Failure: Error { case captureNotDrained }
        let directory: URL
        let identity: IdentitySource
        let retired: RetiredCaptureDrain
        let barrier = DrainBarrier()
        var runtime: AccountAppRuntime!
        var builds: [AccountAppRuntime.ModelRequest] = []
        var models: [AppModel] = []
        var retiredModels: [ObjectIdentifier] = []
        var retainedContexts: [AccountSessionContext?] = []
        weak var capturedWriter: CapturedWriter?
        var afterBuild: ((AccountAppRuntime.ModelRequest, AppModel) -> Void)?
        var observations: Set<AnyCancellable> = []

        init(initial: AccountIdentitySnapshot, automaticRetry: Bool,
             initialSuccessor: AccountIdentitySnapshot? = nil, profileWeights: [String: Double] = [:]) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            identity = IdentitySource(initial)
            retired = RetiredCaptureDrain(automaticRetry: automaticRetry, retryNanoseconds: 0)
            let identity = self.identity, directory = self.directory
            var dependencies = AccountAppRuntime.Dependencies(snapshot: { identity.value }, observeIdentity: { changed in
                identity.changes.sink { changed() }
            }, layout: { AccountStorageLayout(baseDirectory: directory, scope: $0) }, makeModel: { [weak self] request in
                if let layout = request.layout, let namespace = layout.scope?.namespace,
                   let weight = profileWeights[namespace] {
                    UserDefaults(suiteName: layout.preferencesSuite)?.set(weight, forKey: "profile.weightKg")
                }
                let model = AccountAppRuntime.buildModel(context: request.context, layout: request.layout,
                    captureAllowed: request.captureAllowed, isCurrent: request.isCurrent)
                self?.builds.append(request)
                self?.models.append(model)
                if let initialSuccessor, request.context == initial.context, self?.builds.count == 1 {
                    model.accountDefaults.set("old-private-context", forKey: "initial-construction-marker")
                    identity.value = initialSuccessor
                }
                self?.afterBuild?(request, model)
                return model
            }, externalEffects: .inert)
            let captureRetirement = dependencies.retireModel
            dependencies.retireModel = { [weak self] model in
                let capturedDrain = captureRetirement(model)
                guard let self else { return { false } }
                self.retiredModels.append(ObjectIdentifier(model))
                guard model.captureAdmissionEnabled else {
                    return { XCTFail("presentation-only model must never be retained for capture"); return false }
                }
                let context = self.builds[self.models.firstIndex(where: { $0 === model })!].context
                let writer = CapturedWriter(context)
                self.capturedWriter = writer
                self.retainedContexts.append(context)
                let barrier = self.barrier
                return {
                    let capturedDrained = await capturedDrain()
                    let storageAvailable = await barrier.drain(writer)
                    return capturedDrained && storageAvailable
                }
            }
            runtime = AccountAppRuntime(dependencies: dependencies, retiredCapture: retired)
        }

        func close() async throws {
            observations.removeAll()
            afterBuild = nil
            barrier.entered = nil
            barrier.finish(true)
            await retired.retry()
            guard retired.pendingCount == 0 else { throw Failure.captureNotDrained }
            // Drop the real runtime callback before final fixture-only shutdown.
            runtime = nil
            for model in models {
                let generic = model.shutdownForAccountChange()
                let bleDrained = await model.ble.drainCaptureAfterAccountChange()
                let genericDrained = await generic?.drain() ?? true
                guard bleDrained && genericDrained else { throw Failure.captureNotDrained }
                try await model.scoringInputs?.waitForRetirement()
            }
            for suite in Set(builds.compactMap { $0.layout?.preferencesSuite }) {
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            }
            models.removeAll()
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func identity(scope: AccountScope? = nil) throws -> AccountIdentitySnapshot {
        let scope = try scope ?? AccountScope(projectURL: "https://" + UUID().uuidString + ".invalid",
                                               userID: UUID().uuidString)
        return AccountIdentitySnapshot(projectURL: scope.projectURL, scope: scope, generation: UUID())
    }

    private func fixture(initial: AccountIdentitySnapshot, automaticRetry: Bool = false,
                         initialSuccessor: AccountIdentitySnapshot? = nil,
                         profileWeights: [String: Double] = [:]) throws -> Fixture {
        // AppModel's existing hermetic constructor suppresses central/bootstrap work before it starts.
        try XCTSkipUnless(AppRuntimeMode.isUnitTesting, "requires NOOP_HERMETIC_TESTING=1")
        let fixture = try Fixture(initial: initial, automaticRetry: automaticRetry,
                                  initialSuccessor: initialSuccessor, profileWeights: profileWeights)
        addTeardownBlock { try await fixture.close() }
        return fixture
    }

    func testRepeatedOwnersAndSameOwnerGenerationsStayPresentationOnlyUntilCapturedDrainSucceeds() async throws {
        let a = try identity(), b1 = try identity()
        let b2 = try identity(scope: b1.scope), c = try identity()
        let fixture = try fixture(initial: a)
        let original = fixture.runtime.model
        XCTAssertTrue(original.captureAdmissionEnabled)
        fixture.identity.publish(b1)
        XCTAssertEqual(fixture.retired.pendingCount, 1)
        XCTAssertFalse(original.isAccountRuntimeActive)

        let entered = expectation(description: "original writer drain entered")
        fixture.barrier.entered = { entered.fulfill() }
        let attempt = Task { await fixture.retired.retry() }
        await fulfillment(of: [entered], timeout: 2)
        fixture.barrier.entered = nil
        fixture.barrier.finish(false)
        await attempt.value
        XCTAssertNotNil(fixture.capturedWriter)

        for next in [b1, b2, c] {
            fixture.identity.publish(next)
            XCTAssertEqual(fixture.runtime.generation, next.generation)
            XCTAssertEqual(fixture.runtime.model.accountStorage?.scope, next.scope)
            XCTAssertTrue(fixture.runtime.model.isAccountRuntimeActive)
            XCTAssertFalse(fixture.runtime.model.captureAdmissionEnabled)
            XCTAssertNil(fixture.runtime.model.sourceCoordinator)
            XCTAssertNotNil(fixture.runtime.model.scoringInputs)
            XCTAssertNotNil(fixture.runtime.storageError)
            XCTAssertEqual(fixture.retired.pendingCount, 1)
        }
        XCTAssertEqual(fixture.builds.map(\.context), [a.context, b1.context, b2.context, c.context])
        XCTAssertEqual(fixture.retainedContexts, [a.context])
        XCTAssertEqual(fixture.barrier.calls, [a.context])
        XCTAssertFalse(fixture.builds[1].isCurrent(b1.context), "same owner with an old generation is stale")

        let resumed = expectation(description: "real count-zero callback publishes latest enabled owner")
        fixture.runtime.$model.dropFirst().sink { model in
            if model.captureAdmissionEnabled { resumed.fulfill() }
        }.store(in: &fixture.observations)
        fixture.barrier.finish(true)
        await fixture.retired.retry()
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertEqual(fixture.runtime.generation, c.generation)
        XCTAssertEqual(fixture.retired.pendingCount, 0)
        XCTAssertNil(fixture.capturedWriter)
        XCTAssertNil(fixture.runtime.storageError)
    }

    func testAutomaticRetryCountZeroEnablesExactlyOneSuccessorAndReleasesOldWriter() async throws {
        let a = try identity(), b = try identity()
        let fixture = try fixture(initial: a, automaticRetry: true)
        let first = expectation(description: "first automatic pass")
        fixture.barrier.entered = { first.fulfill() }
        fixture.identity.publish(b)
        await fulfillment(of: [first], timeout: 2)
        XCTAssertNotNil(fixture.capturedWriter)
        let retry = expectation(description: "zero-delay automatic retry after failure")
        fixture.barrier.entered = { retry.fulfill() }
        fixture.barrier.finish(false)
        await fulfillment(of: [retry], timeout: 2)
        fixture.barrier.entered = nil
        XCTAssertEqual(fixture.barrier.calls, [a.context, a.context])
        XCTAssertEqual(fixture.retired.pendingCount, 1)
        XCTAssertFalse(fixture.runtime.model.captureAdmissionEnabled)

        let resumed = expectation(description: "single latest successor")
        var publications = 0
        fixture.runtime.$model.dropFirst().sink { model in
            publications += 1
            XCTAssertTrue(model.captureAdmissionEnabled)
            resumed.fulfill()
        }.store(in: &fixture.observations)
        fixture.barrier.finish(true)
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertEqual(fixture.runtime.generation, b.generation)
        XCTAssertEqual(fixture.retired.pendingCount, 0)
        XCTAssertNil(fixture.capturedWriter)
        for _ in 0..<3 {
            fixture.identity.publish(b)
            fixture.runtime.setForeground(true)
        }
        await fixture.retired.retry()
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(fixture.builds.map(\.captureAllowed), [true, false, true])
        XCTAssertEqual(fixture.retainedContexts, [a.context])
    }

    func testOtherOwnerChangeDuringConstructionNeverPublishesObsoleteCandidate() async throws {
        try await constructionRace(sameOwner: false)
    }

    func testSameOwnerGenerationChangeDuringConstructionNeverPublishesObsoleteCandidate() async throws {
        try await constructionRace(sameOwner: true)
    }

    func testReplacementRaceReturningToCapturedIdentityStillReplacesNeutralPresentation() async throws {
        try await constructionRace(sameOwner: false, restoreCapturedIdentity: true)
    }

    func testInitialOtherOwnerRacePublishesOnlyInertPresentationBeforeQueuedReplacement() async throws {
        try await initialConstructionRace(sameOwner: false)
    }

    func testInitialSameOwnerGenerationRacePublishesOnlyInertPresentationBeforeQueuedReplacement() async throws {
        try await initialConstructionRace(sameOwner: true)
    }

    func testInitialRaceReturningToCapturedIdentityStillReplacesNeutralPresentation() async throws {
        try await initialConstructionRace(sameOwner: false, restoreCapturedIdentity: true)
    }

    private func initialConstructionRace(sameOwner: Bool, restoreCapturedIdentity: Bool = false) async throws {
        let a = try identity()
        let next = try identity(scope: sameOwner ? a.scope : nil)
        let fixture = try fixture(initial: a, initialSuccessor: next)
        let rejected = try XCTUnwrap(fixture.models.first)
        // All of these assertions are synchronous: the queued repair task has not had an actor turn.
        XCTAssertFalse(fixture.runtime.model === rejected)
        XCTAssertNil(fixture.runtime.model.accountStorage?.scope)
        XCTAssertFalse(fixture.runtime.model.captureAdmissionEnabled)
        XCTAssertFalse(fixture.runtime.model.isAccountRuntimeActive)
        XCTAssertNil(fixture.runtime.model.scoringInputs)
        XCTAssertNil(fixture.runtime.model.accountDefaults.string(forKey: "initial-construction-marker"))
        XCTAssertTrue(rejected.ble.accountShutdown)
        XCTAssertEqual(fixture.retired.pendingCount, 1)
        XCTAssertNotNil(fixture.capturedWriter, "the rejected initial writer must already be retained")
        var initialScopes: [AccountScope?] = []
        let initialObservation = fixture.runtime.$model.sink { initialScopes.append($0.accountStorage?.scope) }
        XCTAssertEqual(initialScopes.count, 1)
        XCTAssertNil(initialScopes[0], "the publisher's immediate value must also be neutral")
        initialObservation.cancel()

        let expected = restoreCapturedIdentity ? a : next
        if restoreCapturedIdentity { fixture.identity.value = a }
        let latest = expectation(description: "existing queued identity check constructs latest owner without notification")
        fixture.runtime.$model.dropFirst().sink { model in
            XCTAssertEqual(model.accountStorage?.scope, expected.scope)
            latest.fulfill()
        }.store(in: &fixture.observations)
        await fulfillment(of: [latest], timeout: 2)
        XCTAssertEqual(fixture.runtime.generation, expected.generation)
        XCTAssertTrue(fixture.runtime.model.isAccountRuntimeActive)
        XCTAssertFalse(fixture.runtime.model.captureAdmissionEnabled)
        XCTAssertEqual(fixture.retired.pendingCount, 1)
        XCTAssertEqual(fixture.retainedContexts, [a.context])
        fixture.observations.removeAll()
    }

    private func constructionRace(sameOwner: Bool, restoreCapturedIdentity: Bool = false) async throws {
        let a = try identity(), b = try identity()
        let next = try identity(scope: sameOwner ? b.scope : nil)
        let aScope = try XCTUnwrap(a.scope), bScope = try XCTUnwrap(b.scope)
        let fixture = try fixture(initial: a, profileWeights: [aScope.namespace: 137.25, bScope.namespace: 148.5])
        let original = fixture.runtime.model
        original.accountDefaults.set("private-a", forKey: "replacement-construction-marker")
        XCTAssertEqual(original.accountDefaults.double(forKey: "profile.weightKg"), 137.25)
        var obsolete: AppModel?
        fixture.afterBuild = { request, model in
            if request.context == b.context {
                obsolete = model
                model.accountDefaults.set("private-b", forKey: "replacement-construction-marker")
                XCTAssertEqual(model.accountDefaults.double(forKey: "profile.weightKg"), 148.5)
                // No notification: the runtime's post-construction check must schedule recovery itself.
                fixture.identity.value = next
            }
        }
        let expected = restoreCapturedIdentity ? b : next
        let published = expectation(description: "post-construction identity guard schedules latest replacement")
        var publications: [ObjectIdentifier] = []
        fixture.runtime.$model.dropFirst().sink { model in
            publications.append(ObjectIdentifier(model))
            if model.accountStorage?.scope == nil {
                XCTAssertFalse(model.captureAdmissionEnabled)
                XCTAssertFalse(model.isAccountRuntimeActive)
                XCTAssertNil(model.scoringInputs)
                XCTAssertNil(model.accountDefaults.string(forKey: "replacement-construction-marker"))
                XCTAssertNotEqual(model.profile.weightKg, 137.25)
                XCTAssertNotEqual(model.profile.weightKg, 148.5)
            } else {
                XCTAssertEqual(model.accountStorage?.scope, expected.scope)
                published.fulfill()
            }
        }.store(in: &fixture.observations)
        fixture.identity.publish(b)
        let rejected = try XCTUnwrap(obsolete)
        // No suspension has occurred since publish: neither queued identity recovery nor a UI
        // refresh can hide an old account's still-published preferences/profile here.
        let neutral = fixture.runtime.model
        XCTAssertFalse(neutral === original)
        XCTAssertNotEqual(fixture.runtime.generation, a.generation, "retained screen state must also be replaced")
        XCTAssertFalse(fixture.runtime.model === rejected)
        XCTAssertNil(neutral.accountStorage?.scope)
        XCTAssertFalse(neutral.captureAdmissionEnabled)
        XCTAssertFalse(neutral.isAccountRuntimeActive)
        XCTAssertNil(neutral.scoringInputs)
        XCTAssertNil(neutral.accountDefaults.string(forKey: "replacement-construction-marker"))
        XCTAssertNotEqual(neutral.profile.weightKg, 137.25)
        XCTAssertNotEqual(neutral.profile.weightKg, 148.5)
        var immediateScopes: [AccountScope?] = []
        let immediate = fixture.runtime.$model.sink { immediateScopes.append($0.accountStorage?.scope) }
        XCTAssertEqual(immediateScopes.count, 1)
        XCTAssertNil(immediateScopes[0])
        immediate.cancel()
        XCTAssertEqual(publications, [ObjectIdentifier(neutral)])
        XCTAssertTrue(original.ble.accountShutdown)
        XCTAssertFalse(rejected.isAccountRuntimeActive)
        XCTAssertTrue(fixture.retiredModels.contains(ObjectIdentifier(rejected)))
        XCTAssertEqual(fixture.retired.pendingCount, 1)
        XCTAssertEqual(fixture.retainedContexts, [a.context])
        XCTAssertNotNil(fixture.capturedWriter)
        fixture.afterBuild = nil
        if restoreCapturedIdentity { fixture.identity.value = b }
        await fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(fixture.runtime.generation, expected.generation)
        XCTAssertTrue(fixture.runtime.model.isAccountRuntimeActive)
        XCTAssertFalse(fixture.runtime.model.captureAdmissionEnabled)
        XCTAssertEqual(publications, [ObjectIdentifier(neutral), ObjectIdentifier(fixture.runtime.model)])
        XCTAssertEqual(fixture.retired.pendingCount, 1)
        XCTAssertEqual(fixture.builds.map(\.context), [a.context, b.context, nil, expected.context])
        if !restoreCapturedIdentity { XCTAssertFalse(fixture.builds[1].isCurrent(b.context)) }
        fixture.observations.removeAll()
    }
}
