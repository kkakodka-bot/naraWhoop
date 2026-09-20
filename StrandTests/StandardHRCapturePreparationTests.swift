import XCTest
import Combine
import Foundation
import GRDB
import NoopPush
import WhoopProtocol
import WhoopStore
@testable import Strand

@MainActor
final class StandardHRCapturePreparationTests: XCTestCase {
    private enum Failure: Error { case unavailable }

    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        let entered: XCTestExpectation

        init(_ entered: XCTestExpectation) { self.entered = entered }

        func wait() async {
            entered.fulfill()
            guard !opened else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            let value = continuation
            continuation = nil
            value?.resume()
        }
    }

    @MainActor
    private final class Handles {
        var values: [WhoopStore] = []
    }

    @MainActor
    private final class WiringFixture {
        let current = PreferenceRuntimeFlag()
        let model: AppModel
        let layout: AccountStorageLayout
        let handles = Handles()

        init(hooks: StandardHRJournalHooks, beforeClose: @escaping @Sendable () async throws -> Void = {}) throws {
            let temporary = ProcessInfo.processInfo.environment["NARA_CAPTURE_TEST_ROOT"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
            let root = temporary.appendingPathComponent("capture-wiring-" + UUID().uuidString, isDirectory: true)
            let scope = try AccountScope(projectURL: "https://" + UUID().uuidString + ".invalid", userID: UUID().uuidString)
            let context = AccountSessionContext(scope: scope, generation: UUID())
            layout = AccountStorageLayout(baseDirectory: root, scope: scope)
            try FileManager.default.createDirectory(at: layout.directory, withIntermediateDirectories: true)
            let current = current, handles = handles
            model = AppModel(storageLayout: layout, context: context, presentationAllowed: true,
                captureAllowed: true, capturePreparationHooks: .init(journal: hooks,
                    didOpen: { handles.values.append($0) }, startCoordinator: false, beforeClose: beforeClose),
                postIllnessNotification: { _ in XCTFail("capture fixture must not notify") },
                scoringInputDependencies: ScoringPreferenceAppTestSupport.dependencies(
                    context: context, isCurrent: { $0 == context && current.get() }),
                nativePreferenceCurrent: { $0 == context && current.get() },
                preferenceScoringEnabled: { false }, isCurrent: { $0 == context && current.get() })
        }

        func close() async throws {
            if let retired = model.shutdownForAccountChange() {
                let drained = await retired.drain()
                XCTAssertTrue(drained)
            }
            await model.scoringPreferences?.waitForRetirement()
            try await model.scoringInputs?.waitForRetirement()
            UserDefaults(suiteName: layout.preferencesSuite)?.removePersistentDomain(forName: layout.preferencesSuite)
            // Retain this UUID-only SQLite root until process exit; other model readers can outlive us.
        }
    }

    private func withWiring(hooks: StandardHRJournalHooks = .init(),
                            beforeClose: @escaping @Sendable () async throws -> Void = {},
                            _ body: (WiringFixture) async throws -> Void) async throws {
        let fixture = try WiringFixture(hooks: hooks, beforeClose: beforeClose)
        do { try await body(fixture); try await fixture.close() }
        catch { try await fixture.close(); throw error }
    }

    private func assertClosed(_ store: WhoopStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT 1") }, file: file, line: line)
    }

    func testRetirementBeforePreparationReturnsRetainsAndSealsExactJournal() async throws {
        let entered = expectation(description: "captured preparation reached its boundary")
        let gate = Gate(entered)
        defer { gate.open() }
        let journal = GenericCaptureJournal { _, _ in XCTFail("there is no admitted source") }
        let owner = AppModel.GenericCaptureOwnership {
            await gate.wait()
            return journal
        }
        await fulfillment(of: [entered], timeout: 3)
        owner.retire()
        let retained = RetiredCaptureDrain(automaticRetry: false)
        retained.retain(id: UUID()) { await owner.drain() }
        var finished = false
        let retry = Task { await retained.retry(); finished = true }
        await Task.yield()
        XCTAssertFalse(finished)
        XCTAssertEqual(retained.pendingCount, 1)
        gate.open()
        await retry.value
        XCTAssertTrue(owner.isRetired)
        XCTAssertEqual(retained.pendingCount, 0)
        let returned = try await owner.prepared()
        XCTAssertTrue(returned === journal)
        XCTAssertFalse(returned.admit(Streams(hr: [.init(ts: 1_800_000_000, bpm: 72)]), deviceID: "late"))
    }

    func testConcurrentWaitersJoinOneCapturedPreparation() async throws {
        let entered = expectation(description: "one preparation")
        let gate = Gate(entered)
        defer { gate.open() }
        let journal = GenericCaptureJournal { _, _ in }
        var calls = 0
        let owner = AppModel.GenericCaptureOwnership {
            calls += 1
            await gate.wait()
            return journal
        }
        let first = Task { try await owner.prepared() }
        let second = Task { try await owner.prepared() }
        await fulfillment(of: [entered], timeout: 3)
        gate.open()
        let a = try await first.value, b = try await second.value
        XCTAssertTrue(a === journal)
        XCTAssertTrue(b === journal)
        XCTAssertEqual(calls, 1)
        let drained = await owner.drain()
        XCTAssertTrue(drained)
    }

    func testCancellingAWaiterDoesNotCancelCapturedPreparationOrRetirement() async throws {
        let entered = expectation(description: "preparation survives its caller")
        let gate = Gate(entered)
        defer { gate.open() }
        let journal = GenericCaptureJournal { _, _ in }
        var preparationWasCancelled = false
        let owner = AppModel.GenericCaptureOwnership {
            await gate.wait()
            preparationWasCancelled = Task.isCancelled
            return journal
        }
        let caller = Task { try await owner.prepared() }
        await fulfillment(of: [entered], timeout: 3)
        caller.cancel()
        owner.retire()
        gate.open()
        let returned = try await caller.value
        XCTAssertTrue(returned === journal)
        XCTAssertFalse(preparationWasCancelled)
        let drained = await owner.drain()
        XCTAssertTrue(drained)
        XCTAssertFalse(returned.admit(Streams(), deviceID: "late"))
    }

    func testFailedCapturedWriterStaysRetainedUntilSameWriterCommits() async throws {
        let store = try await WhoopStore.inMemory()
        defer { try? store.registryWriter.close() }
        var fail = true
        let journal = GenericCaptureJournal { [store] streams, id in
            if fail { throw Failure.unavailable }
            _ = try await store.insert(streams, deviceId: id)
        }
        let owner = AppModel.GenericCaptureOwnership(journal: journal)
        XCTAssertTrue(journal.admit(Streams(hr: [.init(ts: 1_800_000_000, bpm: 73)]), deviceID: "captured-a"))
        owner.retire()
        let retained = RetiredCaptureDrain(automaticRetry: false)
        retained.retain(id: UUID()) { await owner.drain() }
        await retained.retry()
        XCTAssertEqual(retained.pendingCount, 1)
        XCTAssertEqual(journal.pendingBatchCount, 1)
        let before = try await store.hrSamples(deviceId: "captured-a", from: 1_800_000_000,
                                               to: 1_800_000_001, limit: 10)
        XCTAssertTrue(before.isEmpty)
        fail = false
        await retained.retry()
        XCTAssertEqual(retained.pendingCount, 0)
        XCTAssertEqual(journal.pendingBatchCount, 0)
        let after = try await store.hrSamples(deviceId: "captured-a", from: 1_800_000_000,
                                              to: 1_800_000_001, limit: 10)
        XCTAssertEqual(after.map(\.bpm), [73])
        XCTAssertFalse(journal.admit(Streams(), deviceID: "replacement-b"))
    }

    func testPreparationFailureNeverCreatesSourceAdmissionOrEndlessRetirementDebt() async {
        var attempts = 0
        let owner = AppModel.GenericCaptureOwnership(prepare: {
            attempts += 1
            throw Failure.unavailable
        })
        do {
            _ = try await owner.prepared()
            XCTFail("failed preparation cannot return a source journal")
        } catch { XCTAssertTrue(error is Failure) }
        let first = await owner.drain(), second = await owner.drain()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(owner.isRetired)
    }

    func testActualWiringJoinsDuplicateCallersBeforeOpeningCaptureStore() async throws {
        let gate = Gate(expectation(description: "real prepared journal recovery"))
        defer { gate.open() }
        try await withWiring(hooks: .init(beforeRecovery: { await gate.wait() })) { fixture in
            let first = Task { await fixture.model.wireSourceCoordinator() }
            await fulfillment(of: [gate.entered], timeout: 5)
            await fixture.model.wireSourceCoordinator()
            XCTAssertEqual(fixture.handles.values.count, 1)
            XCTAssertNil(fixture.model.sourceCoordinator)
            gate.open()
            await first.value
            XCTAssertNotNil(fixture.model.sourceCoordinator)
            let captured = try XCTUnwrap(fixture.handles.values.first)
            let owner = try await captured.registryWriter.read { try String.fetchOne($0, sql: "SELECT userID FROM localAccountOwner") }
            XCTAssertEqual(owner, fixture.layout.scope?.userID)
            let retirement = try XCTUnwrap(fixture.model.shutdownForAccountChange())
            let drained = await retirement.drain()
            XCTAssertTrue(drained)
            assertClosed(captured)
        }
    }

    func testActualWiringRetirementDuringPreparationNeverPublishesCoordinator() async throws {
        let gate = Gate(expectation(description: "retiring real journal preparation"))
        defer { gate.open() }
        try await withWiring(hooks: .init(beforeRecovery: { await gate.wait() })) { fixture in
            let first = Task { await fixture.model.wireSourceCoordinator() }
            await fulfillment(of: [gate.entered], timeout: 5)
            let captured = try XCTUnwrap(fixture.handles.values.first)
            fixture.current.set(false)
            let retirement = try XCTUnwrap(fixture.model.shutdownForAccountChange())
            let drain = Task { await retirement.drain() }
            gate.open()
            await first.value
            let drained = await drain.value
            XCTAssertTrue(drained)
            XCTAssertNil(fixture.model.sourceCoordinator)
            XCTAssertEqual(fixture.handles.values.count, 1)
            assertClosed(captured)
        }
    }

    func testActualWiringCancelledCallerClosesCapturedHandle() async throws {
        let gate = Gate(expectation(description: "cancelled wiring recovery"))
        defer { gate.open() }
        try await withWiring(hooks: .init(beforeRecovery: { await gate.wait() })) { fixture in
            let first = Task { await fixture.model.wireSourceCoordinator() }
            await fulfillment(of: [gate.entered], timeout: 5)
            let captured = try XCTUnwrap(fixture.handles.values.first)
            first.cancel()
            gate.open()
            await first.value
            XCTAssertNil(fixture.model.sourceCoordinator)
            assertClosed(captured)
        }
    }

    func testActualWiringFailureRetriesOnForegroundWithoutReplacingRuntime() async throws {
        let storageAvailable = PreferenceRuntimeFlag(false)
        try await withWiring(hooks: .init(beforeRecovery: {
            if !storageAvailable.get() { throw Failure.unavailable }
        })) { fixture in
            await fixture.model.wireSourceCoordinator()
            XCTAssertNil(fixture.model.sourceCoordinator)
            XCTAssertEqual(fixture.handles.values.count, 1)
            assertClosed(try XCTUnwrap(fixture.handles.values.first))
            let published = expectation(description: "foreground publishes recovered registry")
            let observer = fixture.model.$deviceRegistry.dropFirst().sink { registry in
                if registry != nil { published.fulfill() }
            }
            storageAvailable.set(true)
            fixture.model.setForeground(true)
            await fulfillment(of: [published], timeout: 5)
            XCTAssertNotNil(fixture.model.sourceCoordinator)
            XCTAssertEqual(fixture.handles.values.count, 2)
            withExtendedLifetime(observer) {}
        }
    }

    func testFinalCloseFailureRetainsOwnershipForLaterRetry() async throws {
        actor CloseState {
            var calls = 0
            func close() throws {
                calls += 1
                if calls == 1 { throw Failure.unavailable }
            }
        }
        let state = CloseState()
        let journal = GenericCaptureJournal { _, _ in }
        let owner = AppModel.GenericCaptureOwnership(prepareResource: {
            .init(journal: journal, close: { try await state.close() })
        })
        let retained = RetiredCaptureDrain(automaticRetry: false)
        retained.retain(id: UUID()) { await owner.drain() }
        await retained.retry()
        XCTAssertEqual(retained.pendingCount, 1)
        await retained.retry()
        XCTAssertEqual(retained.pendingCount, 0)
        let again = await owner.drain()
        XCTAssertTrue(again)
        let calls = await state.calls
        XCTAssertEqual(calls, 2)
    }

    func testActualPreparationFailureRetainsFailedCloseBeforeAnyReplacementOpen() async throws {
        let preparationAvailable = PreferenceRuntimeFlag(false)
        let closeAvailable = PreferenceRuntimeFlag(false)
        try await withWiring(hooks: .init(beforeRecovery: {
            if !preparationAvailable.get() { throw Failure.unavailable }
        }), beforeClose: {
            if !closeAvailable.get() { throw Failure.unavailable }
        }) { fixture in
            // Cleanup must also succeed if an assertion or unwrap throws below.
            defer { closeAvailable.set(true) }
            await fixture.model.wireSourceCoordinator()
            let captured = try XCTUnwrap(fixture.handles.values.first)
            XCTAssertNil(fixture.model.sourceCoordinator)
            let stillOpen = try await captured.registryWriter.read { try Int.fetchOne($0, sql: "SELECT 1") }
            XCTAssertEqual(stillOpen, 1)
            preparationAvailable.set(true)
            await fixture.model.wireSourceCoordinator()
            XCTAssertEqual(fixture.handles.values.count, 1, "failed close blocks a replacement writer")
            XCTAssertNil(fixture.model.sourceCoordinator)
            closeAvailable.set(true)
            await fixture.model.wireSourceCoordinator()
            assertClosed(captured)
            XCTAssertEqual(fixture.handles.values.count, 2)
            XCTAssertNotNil(fixture.model.sourceCoordinator)
        }
    }

    func testFailedPreparationCleanupSurvivesAccountRetirement() async throws {
        let closeAvailable = PreferenceRuntimeFlag(false)
        try await withWiring(hooks: .init(beforeRecovery: { throw Failure.unavailable }),
            beforeClose: { if !closeAvailable.get() { throw Failure.unavailable } }) { fixture in
            defer { closeAvailable.set(true) }
            await fixture.model.wireSourceCoordinator()
            let captured = try XCTUnwrap(fixture.handles.values.first)
            let ownership = try XCTUnwrap(fixture.model.shutdownForAccountChange())
            let retained = RetiredCaptureDrain(automaticRetry: false)
            retained.retain(id: UUID()) { await ownership.drain() }
            await retained.retry()
            XCTAssertEqual(retained.pendingCount, 1)
            let stillOpen = try await captured.registryWriter.read { try Int.fetchOne($0, sql: "SELECT 1") }
            XCTAssertEqual(stillOpen, 1)
            closeAvailable.set(true)
            await retained.retry()
            XCTAssertEqual(retained.pendingCount, 0)
            assertClosed(captured)
            XCTAssertEqual(fixture.handles.values.count, 1)
            XCTAssertNil(fixture.model.sourceCoordinator)
        }
    }
}
