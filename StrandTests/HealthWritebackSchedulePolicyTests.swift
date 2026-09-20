import XCTest
@testable import Strand

final class HealthWritebackSchedulePolicyTests: XCTestCase {
    func testSchedulesOnlyAfterAppleHealthAuthorization() {
        XCTAssertTrue(HealthWritebackSchedulePolicy.shouldSchedule(isAuthorized: true))
        XCTAssertFalse(HealthWritebackSchedulePolicy.shouldSchedule(isAuthorized: false))
    }

    func testRequestsNextRefreshOneHourAfterScheduling() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            HealthWritebackSchedulePolicy.earliestBeginDate(after: now),
            now.addingTimeInterval(3_600)
        )
    }
}

/// Tests the orchestration used by HealthKitBridge with memory-only operation callbacks.
/// It does not construct an HKHealthStore or certify the iOS adapter's payload/call wiring.
@MainActor
final class HealthWritebackBoundaryTests: XCTestCase {
    private enum Rejected: Error, Equatable {
        case revoked
        case operation(String)
        case read
    }

    @MainActor private final class State {
        var current = true
        var validations = 0
        var checks = 0
        var operations: [String] = []
        var discards = 0
    }

    @MainActor private final class Gate {
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        init(_ entered: XCTestExpectation) { self.entered = entered }

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func makeBoundary(_ state: State, guarded: Bool = true) -> HealthWritebackBoundary {
        HealthWritebackBoundary(guarded: guarded, validate: {
            state.validations += 1
            return state.current
        }, checkBoundary: {
            state.checks += 1
            guard state.current else { throw Rejected.revoked }
        })
    }

    private func failure(_ operation: @MainActor () async throws -> Void) async -> Error? {
        do { try await operation(); return nil } catch { return error }
    }

    private func workout(_ boundary: HealthWritebackBoundary, state: State,
                         failAt: String? = nil, revokeAfter: String? = nil,
                         includeSamples: Bool = true) async throws {
        func operation(_ name: String) throws {
            state.operations.append(name)
            if name == revokeAfter { state.current = false }
            if name == failAt { throw Rejected.operation(name) }
        }
        let samples: HealthWritebackBoundary.Operation? = includeSamples ? { try operation("samples") } : nil
        try await boundary.workout(begin: { try operation("begin") },
            metadata: { try operation("metadata") }, samples: samples,
            end: { try operation("end") }, finish: { try operation("finish") },
            discard: { state.discards += 1 })
    }

    func testValidReplacementRevalidatesForBothOperations() async throws {
        let state = State(), boundary = makeBoundary(state)
        try await boundary.replace(delete: { state.operations.append("delete") },
                                   save: { state.operations.append("save") })
        XCTAssertEqual(state.operations, ["delete", "save"])
        XCTAssertEqual(state.validations, 2)
        XCTAssertEqual(state.checks, 4)
    }

    func testInvalidAdmissionDoesNotStartDeleteOrSave() async {
        let state = State(), boundary = makeBoundary(state)
        state.current = false
        let error = await failure {
            try await boundary.replace(delete: { state.operations.append("delete") },
                                       save: { state.operations.append("save") })
        }
        XCTAssertNotNil(error as? CancellationError)
        XCTAssertEqual(state.operations, [])
        XCTAssertEqual(state.validations, 1)
    }

    func testSynchronousCheckRejectsStaleTrueValidationAfterSuspension() async {
        let state = State()
        let gate = Gate(expectation(description: "Health boundary validation suspended"))
        let boundary = HealthWritebackBoundary(guarded: true, validate: {
            state.validations += 1
            let validBeforeSuspension = state.current
            await gate.wait()
            return validBeforeSuspension
        }, checkBoundary: {
            state.checks += 1
            guard state.current else { throw Rejected.revoked }
        })
        let work = Task {
            await failure { try await boundary.perform { state.operations.append("save") } }
        }
        addTeardownBlock { @MainActor in gate.release(); _ = await work.value }
        await fulfillment(of: [gate.entered], timeout: 5)
        state.current = false
        gate.release()
        let error = await work.value
        XCTAssertEqual(error as? Rejected, .revoked)
        XCTAssertEqual(state.checks, 1)
        XCTAssertEqual(state.operations, [])
    }

    func testRevocationDuringDeletePreventsReplacementSave() async {
        let state = State(), boundary = makeBoundary(state)
        let error = await failure {
            try await boundary.replace(delete: {
                state.operations.append("delete")
                state.current = false
            }, save: { state.operations.append("save") })
        }
        XCTAssertNotNil(error as? CancellationError)
        XCTAssertEqual(state.operations, ["delete"])
        XCTAssertEqual(state.validations, 2)
    }

    func testDeleteFailurePreservesErrorAndDoesNotStartSave() async {
        let state = State(), boundary = makeBoundary(state)
        let error = await failure {
            try await boundary.replace(delete: {
                state.operations.append("delete"); throw Rejected.operation("delete")
            }, save: { state.operations.append("save") })
        }
        XCTAssertEqual(error as? Rejected, .operation("delete"))
        XCTAssertEqual(state.operations, ["delete"])
        XCTAssertEqual(state.validations, 1)
    }

    func testSaveFailureIsNotReportedAsSuccessfulReplacement() async {
        let state = State(), boundary = makeBoundary(state)
        let error = await failure {
            try await boundary.replace(delete: { state.operations.append("delete") }, save: {
                state.operations.append("save"); throw Rejected.operation("save")
            })
        }
        XCTAssertEqual(error as? Rejected, .operation("save"))
        XCTAssertEqual(state.operations, ["delete", "save"])
        XCTAssertEqual(state.validations, 2)
    }

    func testEmptyAuthoritativeReplacementDeletesWithoutInventingSave() async throws {
        let state = State(), boundary = makeBoundary(state)
        try await boundary.replace(delete: { state.operations.append("delete") }, save: nil)
        XCTAssertEqual(state.operations, ["delete"])
        XCTAssertEqual(state.validations, 1)
    }

    func testWorkoutRevalidatesEveryBuilderOperationInOrder() async throws {
        let state = State(), boundary = makeBoundary(state)
        try await workout(boundary, state: state)
        XCTAssertEqual(state.operations, ["begin", "metadata", "samples", "end", "finish"])
        XCTAssertEqual(state.validations, 5)
        XCTAssertEqual(state.discards, 0)
    }

    func testRevocationAtEachUnfinishedBuilderStageStopsFollowingOperationsAndDiscards() async {
        let steps = ["begin", "metadata", "samples", "end", "finish"]
        for (index, step) in steps.dropLast().enumerated() {
            let state = State(), boundary = makeBoundary(state)
            let error = await failure { try await workout(boundary, state: state, revokeAfter: step) }
            XCTAssertNotNil(error as? CancellationError, step)
            XCTAssertEqual(state.operations, Array(steps.prefix(index + 1)), step)
            XCTAssertEqual(state.discards, 1, step)
            XCTAssertFalse(state.current, "Discard must still run after revocation: \(step)")
        }
    }

    func testFailureAtEachBuilderStagePreservesErrorAndDiscardsExactlyOnce() async {
        let steps = ["begin", "metadata", "samples", "end", "finish"]
        for (index, step) in steps.enumerated() {
            let state = State(), boundary = makeBoundary(state)
            let error = await failure { try await workout(boundary, state: state, failAt: step) }
            XCTAssertEqual(error as? Rejected, .operation(step), step)
            XCTAssertEqual(state.operations, Array(steps.prefix(index + 1)), step)
            XCTAssertEqual(state.discards, 1, step)
        }
    }

    func testWorkoutWithoutExtrasDoesNotInventSampleOperation() async throws {
        let state = State(), boundary = makeBoundary(state)
        try await workout(boundary, state: state, includeSamples: false)
        XCTAssertEqual(state.operations, ["begin", "metadata", "end", "finish"])
        XCTAssertEqual(state.validations, 4)
        XCTAssertEqual(state.discards, 0)
    }

    func testBusyGuardedPassDefersWithoutCreatingLegacyTail() {
        var tails = 0
        let admitted = HealthWritebackBoundary.admitPass(isBusy: true, guarded: true,
                                                       queueLegacyTail: { tails += 1 })
        XCTAssertFalse(admitted)
        XCTAssertEqual(tails, 0)
    }

    func testBusyLegacyPassStillQueuesItsExistingTail() {
        var tails = 0
        let admitted = HealthWritebackBoundary.admitPass(isBusy: true, guarded: false,
                                                       queueLegacyTail: { tails += 1 })
        XCTAssertFalse(admitted)
        XCTAssertEqual(tails, 1)
    }

    func testIdlePassDoesNotQueueTailInEitherMode() {
        for guarded in [true, false] {
            var tails = 0
            XCTAssertTrue(HealthWritebackBoundary.admitPass(isBusy: false, guarded: guarded,
                                                          queueLegacyTail: { tails += 1 }))
            XCTAssertEqual(tails, 0)
        }
    }

    func testPresentationRequirementIsRecheckedAfterAsyncValidation() async {
        let state = State()
        let capturedRevision = 10
        var revision = capturedRevision
        let boundary = HealthWritebackBoundary(guarded: true, validate: {
            revision += 1; return true
        }, checkBoundary: {
            guard state.current else { throw Rejected.revoked }
        }).requiring { revision == capturedRevision }
        let error = await failure { try await boundary.perform { state.operations.append("save") } }
        XCTAssertNotNil(error as? CancellationError)
        XCTAssertEqual(state.operations, [])
    }

    func testGuardedReadFailureCannotBecomeSuccessfulEmptyPayload() async {
        let state = State(), boundary = makeBoundary(state)
        let error = await failure {
            let _: [Int] = try await boundary.read(or: []) { throw Rejected.read }
            XCTFail("A failed guarded read must not reach payload preparation")
        }
        XCTAssertEqual(error as? Rejected, .read)
        XCTAssertEqual(state.operations, [])
    }

    func testLegacyReadFailureKeepsExistingBestEffortFallback() async throws {
        let boundary = makeBoundary(State(), guarded: false)
        let result: [Int] = try await boundary.read(or: [7]) { throw Rejected.read }
        XCTAssertEqual(result, [7])
    }

    func testSuccessfulReadsPreserveExactValuesInBothModes() async throws {
        for guarded in [true, false] {
            let boundary = makeBoundary(State(), guarded: guarded)
            let expected = [5, 3, 3, 1]
            let result = try await boundary.read(or: [0]) { expected }
            XCTAssertEqual(result, expected)
        }
    }

    func testLegacyBoundarySkipsPreferenceValidationButStillRejectsRetiredOwner() async {
        let state = State(), boundary = makeBoundary(state, guarded: false)
        state.current = false
        let error = await failure { try await boundary.perform { state.operations.append("save") } }
        XCTAssertEqual(error as? Rejected, .revoked)
        XCTAssertEqual(state.validations, 0)
        XCTAssertEqual(state.operations, [])
    }

    func testCancellationDuringValidationPreventsStartingExternalOperation() async {
        let state = State()
        let gate = Gate(expectation(description: "validation suspended before cancellation"))
        let boundary = HealthWritebackBoundary(guarded: true, validate: {
            await gate.wait(); return true
        }, checkBoundary: { state.checks += 1 })
        let work = Task {
            await failure { try await boundary.perform { state.operations.append("delete") } }
        }
        addTeardownBlock { @MainActor in gate.release(); _ = await work.value }
        await fulfillment(of: [gate.entered], timeout: 5)
        work.cancel()
        gate.release()
        let error = await work.value
        XCTAssertNotNil(error as? CancellationError)
        XCTAssertEqual(state.operations, [])
        XCTAssertEqual(state.checks, 0)
    }

    func testCancellationDuringDeletePreventsStartingReplacementSave() async {
        let state = State(), boundary = makeBoundary(state)
        let work = Task {
            await failure {
                try await boundary.replace(delete: {
                    state.operations.append("delete")
                    withUnsafeCurrentTask { $0?.cancel() }
                }, save: { state.operations.append("save") })
            }
        }
        let error = await work.value
        XCTAssertNotNil(error as? CancellationError)
        XCTAssertEqual(state.operations, ["delete"])
    }
}

import WhoopStore

/// Exercises the no-authorization decision used by the bridge, not HealthKit authorization itself.
@MainActor
final class HealthUnauthorizedBoundaryTests: XCTestCase {
    private enum Rejected: Error { case revoked }

    @MainActor private final class Gate {
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    func testStillUnauthorizedCurrentPassIsAValidatedNoOp() async {
        var order: [String] = []
        let boundary = HealthWritebackBoundary(guarded: true,
            validate: { order.append("validate"); return true }, checkBoundary: { order.append("boundary") })
        let result = await boundary.completeUnauthorizedNoOp(isActive: { order.append("active"); return true },
            isAuthorized: { order.append("authorization"); return false })
        XCTAssertTrue(result)
        XCTAssertEqual(order, ["validate", "boundary", "active", "authorization"])
    }

    func testGrantDuringSuspendedValidationIsNotCompletedNoOp() async {
        let gate = Gate(expectation(description: "no-op validation suspended"))
        var authorized = false, checks = 0
        let boundary = HealthWritebackBoundary(guarded: true, validate: {
            await gate.wait(); return true
        }, checkBoundary: { checks += 1 })
        let work = Task {
            await boundary.completeUnauthorizedNoOp(isActive: { true }, isAuthorized: { authorized })
        }
        addTeardownBlock { @MainActor in gate.release(); _ = await work.value }
        await fulfillment(of: [gate.entered], timeout: 5)
        authorized = true
        gate.release()
        let result = await work.value
        XCTAssertFalse(result)
        XCTAssertEqual(checks, 1)
    }

    func testInvalidAdmissionDoesNotInspectOrCompleteNoOp() async {
        let boundary = HealthWritebackBoundary(guarded: true, validate: { false },
            checkBoundary: { XCTFail("invalid validation must stop before boundary") })
        let result = await boundary.completeUnauthorizedNoOp(isActive: { XCTFail("not admitted"); return true },
            isAuthorized: { XCTFail("not admitted"); return false })
        XCTAssertFalse(result)
    }

    func testRevokedBoundaryRejectsStaleSuccessfulNoOpValidation() async {
        let gate = Gate(expectation(description: "validation captured before revocation"))
        var current = true, checks = 0
        let boundary = HealthWritebackBoundary(guarded: true, validate: { await gate.wait(); return true },
            checkBoundary: { checks += 1; if !current { throw Rejected.revoked } })
        let work = Task { await boundary.completeUnauthorizedNoOp(isActive: { true }, isAuthorized: { false }) }
        addTeardownBlock { @MainActor in gate.release(); _ = await work.value }
        await fulfillment(of: [gate.entered], timeout: 5)
        current = false; gate.release()
        let result = await work.value
        XCTAssertFalse(result)
        XCTAssertEqual(checks, 1)
    }

    func testRetirementDuringValidationRejectsUnauthorizedNoOp() async {
        let gate = Gate(expectation(description: "validation before runtime retirement"))
        var active = true
        let boundary = HealthWritebackBoundary(guarded: true, validate: { await gate.wait(); return true }, checkBoundary: {})
        let work = Task { await boundary.completeUnauthorizedNoOp(isActive: { active }, isAuthorized: { false }) }
        addTeardownBlock { @MainActor in gate.release(); _ = await work.value }
        await fulfillment(of: [gate.entered], timeout: 5)
        active = false; gate.release()
        let result = await work.value
        XCTAssertFalse(result)
    }

    func testCancellationDuringValidationRejectsUnauthorizedNoOp() async {
        let gate = Gate(expectation(description: "validation before cancellation"))
        var checks = 0
        let boundary = HealthWritebackBoundary(guarded: true, validate: { await gate.wait(); return true },
            checkBoundary: { checks += 1 })
        let work = Task { await boundary.completeUnauthorizedNoOp(isActive: { true }, isAuthorized: { false }) }
        addTeardownBlock { @MainActor in gate.release(); _ = await work.value }
        await fulfillment(of: [gate.entered], timeout: 5)
        work.cancel(); gate.release()
        let result = await work.value
        XCTAssertFalse(result)
        XCTAssertEqual(checks, 0)
    }

    func testLegacyNoOpDoesNotValidateOrRecheckAuthorization() async {
        let boundary = HealthWritebackBoundary(guarded: false,
            validate: { XCTFail("nil policy never awaits validation"); return false },
            checkBoundary: { XCTFail("nil no-op remains synchronous") })
        let result = await boundary.completeUnauthorizedNoOp(isActive: { XCTFail("entry already checked active"); return true },
            isAuthorized: { XCTFail("nil branch does not suspend then recheck"); return false })
        XCTAssertTrue(result)
    }

    func testGrantDuringActualAdmissionValidationRetainsExactHealthJobUntilGuardedRetry() async throws {
        let f = try await ExportBoundaryStoreFixture()
        addTeardownBlock { @MainActor in try await f.close() }
        let model = try f.openModel()
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        let token = try await f.store.markJobOwed(kind: "healthWriteback")
        let gate = Gate(expectation(description: "actual captured health admission before auth recheck"))
        var authorized = false, operations = 0, results: [Bool] = [], metadata: [Bool] = []
        model.syncEngine.dependentStageDriver = .init(perform: { stage, admission in
            XCTAssertEqual(stage, .healthWriteback)
            let enteredUnauthorized = !authorized
            let boundary = HealthWritebackBoundary(guarded: true, validate: {
                guard await admission.validate() else { return false }
                if enteredUnauthorized { await gate.wait() }
                return await admission.validate()
            }, checkBoundary: { try admission.checkBoundary() })
            if enteredUnauthorized {
                let result = await boundary.completeUnauthorizedNoOp(isActive: { model.isAccountRuntimeActive },
                    isAuthorized: { authorized })
                results.append(result)
                metadata.append(await admission.validate())
                return result
            }
            do { try await boundary.perform { operations += 1 }; return true }
            catch { XCTFail("same valid admission must permit the synthetic retry: \(error)"); return false }
        })
        let drain = Task { await model.syncEngine.drain(reason: .foreground) }
        addTeardownBlock { @MainActor in gate.release(); await drain.value }
        await fulfillment(of: [gate.entered], timeout: 15)
        authorized = true
        gate.release(); await drain.value
        XCTAssertEqual(results, [false])
        XCTAssertEqual(metadata, [true], "the same real head/token remains valid after authorization changes")
        XCTAssertEqual(operations, 0)
        let retained = try await f.store.owedJobs()
        XCTAssertEqual(retained.first { $0.kind == "healthWriteback" }?.token, token)
        XCTAssertEqual(retained.first { $0.kind == "healthWriteback" }?.attempts, 1)
        await model.syncEngine.drain(reason: .foreground)
        XCTAssertEqual(operations, 1)
        let completed = try await f.store.owedJobs()
        XCTAssertFalse(completed.contains { $0.kind == "healthWriteback" })
    }

    func testActualStillUnauthorizedAdmissionSettlesOnlyCapturedHealthJob() async throws {
        let f = try await ExportBoundaryStoreFixture()
        addTeardownBlock { @MainActor in try await f.close() }
        let model = try f.openModel()
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        let token = try await f.store.markJobOwed(kind: "healthWriteback")
        var completions = 0
        model.syncEngine.dependentStageDriver = .init(perform: { stage, admission in
            XCTAssertEqual(stage, .healthWriteback)
            let rows = try? await f.store.owedJobs()
            XCTAssertEqual(rows?.first { $0.kind == "healthWriteback" }?.token, token)
            let boundary = HealthWritebackBoundary(guarded: true,
                validate: { await admission.validate() }, checkBoundary: { try admission.checkBoundary() })
            let result = await boundary.completeUnauthorizedNoOp(isActive: { model.isAccountRuntimeActive }, isAuthorized: { false })
            if result { completions += 1 }
            return result
        })
        await model.syncEngine.drain(reason: .foreground)
        XCTAssertEqual(completions, 1)
        let completed = try await f.store.owedJobs()
        XCTAssertFalse(completed.contains { $0.kind == "healthWriteback" })
    }
}
