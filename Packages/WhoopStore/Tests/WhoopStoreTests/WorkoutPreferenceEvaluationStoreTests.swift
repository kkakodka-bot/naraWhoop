import Foundation
import CryptoKit
import GRDB
import XCTest
@testable import WhoopStore

final class WorkoutPreferenceEvaluationStoreTests: XCTestCase {
    private typealias E = WorkoutPreferenceEvaluation
    private struct Fixture {
        let store: WhoopStore
        let session: WorkoutEvaluationSession
        let runtime: StoreWriteFence
        let permit: WorkoutEvaluationPermit
        let request: E.Request
        let target: E.Target
    }
    private func directory(_ prefix: String) throws -> URL {
        let parent = ProcessInfo.processInfo.environment["WPE_TEST_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let result = parent.appendingPathComponent("\(prefix)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        return result
    }
    private func seedNulCursor(_ f: Fixture, sportKey: Bool) async throws {
        try await f.store.registryWriter.write { db in
            var keys = (1...127).map {
                (device: "a", sport: sportKey ? String(format: "0s%03d", $0) : String(format: "s%03d", $0))
            }
            keys.append(sportKey ? (device: "a", sport: "a\0b") : (device: "a\0b", sport: "z"))
            keys.append(sportKey ? (device: "a", sport: "b") : (device: "b", sport: "z"))
            for key in keys {
                try db.execute(sql: """
                    INSERT INTO workout(deviceId,startTs,endTs,sport,source,durationS,energyKcal,avgHr,maxHr,strain)
                    VALUES(CAST(? AS TEXT),100,160,CAST(? AS TEXT),'whoop',60,100,140,150,4)
                    """, arguments: [Data(key.device.utf8), Data(key.sport.utf8)])
            }
        }
    }

    func testNulDeviceAndSportContinuationCountExactly129Not130() async throws {
        for sportKey in [false, true] {
            let f = try await fixture()
            try await seedNulCursor(f, sportKey: sportKey)
            let first = try await f.store.advanceWorkoutPreferenceEvaluation(session: f.session, lease: scanLease(f), permit: f.permit)
            XCTAssertEqual(first.rowsProcessed, 128); XCTAssertEqual(first.view.counts.totalRows, 128)
            XCTAssertEqual(first.view.disposition, .continuation)
            let last = try await f.store.advanceWorkoutPreferenceEvaluation(session: f.session, lease: XCTUnwrap(first.view.lease), permit: f.permit)
            XCTAssertEqual(last.rowsProcessed, 1, "sportKey=\(sportKey)")
            XCTAssertEqual(last.view.counts.totalRows, 129, "sportKey=\(sportKey)")
            XCTAssertEqual(last.view.disposition, .complete)
            let stored = try await f.store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM workout") }
            XCTAssertEqual(stored, 129)
        }
    }

    func testColdNulDeviceAndSportPrefixProvesAll128WithoutNewCore() async throws {
        for sportKey in [false, true] {
            let directory = try directory("workout-nul-prefix")
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("account.sqlite").path, req = try request()
            let f = try await fixture(path: path, request: req)
            try await seedNulCursor(f, sportKey: sportKey)
            let first = try await f.store.advanceWorkoutPreferenceEvaluation(session: f.session, lease: scanLease(f), permit: f.permit)
            XCTAssertEqual(first.rowsProcessed, 128); XCTAssertEqual(first.view.counts.totalRows, 128)
            try f.store.registryWriter.close()
            let cold = try await fixture(path: path, request: req)
            defer { try? cold.store.registryWriter.close() }
            let view = try await cold.store.inspectWorkoutPreferenceEvaluation(session: cold.session, request: req, now: 0)
            XCTAssertEqual(view.disposition, .needsValidation)
            let prefix = try await cold.store.advanceWorkoutPreferenceEvaluation(session: cold.session, lease: XCTUnwrap(view.lease), permit: cold.permit)
            XCTAssertEqual(prefix.rowsProcessed, 128, "sportKey=\(sportKey)")
            XCTAssertEqual(prefix.view.counts.totalRows, 128, "sportKey=\(sportKey)")
            XCTAssertEqual(prefix.view.disposition, .continuation, "sportKey=\(sportKey)")
            XCTAssertNil(prefix.view.validatedReceipt)
            if prefix.view.disposition == .continuation {
                let last = try await cold.store.advanceWorkoutPreferenceEvaluation(session: cold.session, lease: XCTUnwrap(prefix.view.lease), permit: cold.permit)
                XCTAssertEqual(last.rowsProcessed, 1); XCTAssertEqual(last.view.counts.totalRows, 129)
                XCTAssertEqual(last.view.disposition, .complete)
            }
        }
    }

    private func request(sequence: Int64 = 1, id: UUID = UUID(), days: Int = 21) throws -> E.Request {
        try .init(owner: .init(projectURL: "https://workout-evaluation.invalid", userID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
                  preference: .init(sequence: sequence, id: id, identity: .init(bytes: Data(repeating: UInt8(sequence), count: 32))),
                  canonicalWriter: "canonical", requestedDays: days, localDayAnchor: "2026-09-18",
                  timezoneID: "America/Los_Angeles", offsetSeconds: -25200,
                  dependencyDigest: .init(bytes: Data(repeating: 7, count: 32)))
    }
    private func fixture(path: String? = nil, request supplied: E.Request? = nil) async throws -> Fixture {
        let req = try supplied ?? request()
        let store: WhoopStore
        if let path { store = try await WhoopStore(path: path) } else { store = try await WhoopStore.inMemory() }
        try await store.bindAccountOwner(projectURL: req.owner.projectURL, userID: req.owner.userID)
        let runtime = StoreWriteFence()
        let session = try await store.openWorkoutPreferenceEvaluation(owner: req.owner, runtimeFence: runtime)
        return Fixture(store: store, session: session, runtime: runtime, permit: .init(), request: req,
                       target: try .init(request: req, lowerTs: 0, upperTs: Int64(req.requestedDays) * 86400))
    }
    private func insert(_ f: Fixture, start: Int64, device: String = "strap", sport: String = "run",
                        source: String = "whoop", strain: Double? = 4, notes: String? = nil,
                        energy: Double? = 100) async throws {
        try await f.store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO workout(deviceId,startTs,endTs,sport,source,durationS,energyKcal,avgHr,maxHr,strain,distanceM,zonesJSON,notes,steps)
                VALUES(?,?,?,?,?,60,?,140,150,?,100,'{}',CAST(? AS TEXT),10)
                """, arguments: [device, start, start + 60, sport, source, energy, strain, notes.map { Data($0.utf8) }])
        }
    }
    private func many(_ f: Fixture, count: Int, notes: String? = nil) async throws {
        try await f.store.registryWriter.write { db in
            for index in 1...count {
                try db.execute(sql: """
                    INSERT INTO workout(deviceId,startTs,endTs,sport,source,durationS,energyKcal,avgHr,maxHr,strain,notes)
                    VALUES('strap',?,?,'run','whoop',60,100,140,150,4,?)
                    """, arguments: [index, index + 60, notes])
            }
        }
    }
    private func admitted(_ f: Fixture, markJob: Bool = true) async throws -> E.Lease {
        if markJob { _ = try await f.store.markJobOwed(kind: "rescore") }
        let view = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 0)
        return try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: view.head,
                                                                 target: f.target, permit: f.permit)
    }
    private func scanLease(_ f: Fixture, markJob: Bool = true) async throws -> E.Lease {
        let lease = try await admitted(f, markJob: markJob)
        return try await f.store.recordWorkoutPreferenceCorePass(session: f.session, lease: lease,
            witness: .init(targetDigest: lease.target.digest, dependencyDigest: f.request.dependencyDigest,
                           capturedRescoreJobToken: lease.rescoreJobToken, legacyAttemptToken: "original-attempt"), permit: f.permit)
    }
    private func finish(_ f: Fixture, lease initial: E.Lease) async throws -> E.View {
        var lease = initial
        for _ in 0..<24 {
            let step = try await f.store.advanceWorkoutPreferenceEvaluation(session: f.session, lease: lease, permit: f.permit)
            switch step.view.disposition {
            case .continuation, .needsValidation:
                lease = try XCTUnwrap(step.view.lease)
            default: return step.view
            }
        }
        XCTFail("bounded fixture unexpectedly needs more than 24 pages")
        throw E.Failure.invalidState
    }
    private func revision(_ f: Fixture) async throws -> Int64 {
        try await f.store.registryWriter.read { db in
            try Int64.fetchOne(db, sql: "SELECT workoutRevision FROM workoutPreferenceEvaluation") ?? -1
        }
    }
    private func generated(start: Int, source: String = "canonical-noop", sport: String = "detected",
                           notes: String? = nil) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + 60, sport: sport, source: source,
                   durationS: 60, energyKcal: 20, avgHr: 130, maxHr: 145, strain: 3,
                   distanceM: 10, zonesJSON: "[1,2]", notes: notes, steps: 12)
    }
    private func workoutBytes(_ f: Fixture) async throws -> [Row] {
        try await f.store.registryWriter.read {
            try Row.fetchAll($0, sql: "SELECT *,CAST(notes AS BLOB) AS exactNotes FROM workout ORDER BY deviceId,startTs,sport")
        }
    }
    private func recordCore(_ f: Fixture, lease: E.Lease) async throws -> E.Lease {
        try await f.store.recordWorkoutPreferenceCorePass(session: f.session, lease: lease,
            witness: .init(targetDigest: lease.target.digest, dependencyDigest: f.request.dependencyDigest,
                           capturedRescoreJobToken: lease.rescoreJobToken, legacyAttemptToken: "original-attempt"), permit: f.permit)
    }
    private func failed(_ expected: E.Failure? = nil, file: StaticString = #filePath, line: UInt = #line,
                        _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("operation unexpectedly succeeded", file: file, line: line) }
        catch { if let expected { XCTAssertEqual(error as? E.Failure, expected, file: file, line: line) } }
    }

    func testMigrationDoesNotSeedBeforeBindingOrClaimPopulatedUnboundStore() async throws {
        let store = try await WhoopStore.inMemory()
        let owner = try request().owner
        let before = try await store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM workoutPreferenceEvaluation") }
        XCTAssertEqual(before, 0)
        await failed(.unboundOwner) { _ = try await store.openWorkoutPreferenceEvaluation(owner: owner, runtimeFence: .init()) }
        try await store.registryWriter.write { try $0.execute(sql: "INSERT INTO workout(deviceId,startTs,endTs,sport,source) VALUES('legacy',1,2,'run','manual')") }
        do { try await store.bindAccountOwner(projectURL: owner.projectURL, userID: owner.userID); XCTFail("claimed legacy") }
        catch { XCTAssertEqual(error as? LocalAccountOwnershipError, .unassignedExistingData) }
        let values = try await store.registryWriter.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workoutPreferenceEvaluation"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout"))
        }
        XCTAssertEqual(values.0, 0); XCTAssertEqual(values.1, 1)
    }

    func testFreshBindingThenSeedAndWrongOwnerIsRejected() async throws {
        let f = try await fixture()
        let view = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 0)
        XCTAssertEqual(view.disposition, .needsCorePass)
        let other = try E.Owner(projectURL: f.request.owner.projectURL, userID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        await failed(.wrongOwner) { _ = try await f.store.openWorkoutPreferenceEvaluation(owner: other, runtimeFence: .init()) }
        let count = try await f.store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM workoutPreferenceEvaluation") }
        XCTAssertEqual(count, 1)
    }

    func testMissingOrReplacedTriggerRefusesProofWithoutMutatingWorkouts() async throws {
        let f = try await fixture()
        try await insert(f, start: 1)
        try await f.store.registryWriter.write { db in
            try db.execute(sql: "DROP TRIGGER workout_preference_update_v1")
            try db.execute(sql: "CREATE TRIGGER workout_preference_update_v1 AFTER UPDATE ON workout BEGIN SELECT 1; END")
        }
        await failed(.unsupportedSchema) { _ = try await f.store.openWorkoutPreferenceEvaluation(owner: f.request.owner, runtimeFence: .init()) }
        let count = try await f.store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM workout") }
        XCTAssertEqual(count, 1)
    }

    func testInsertUpdateReplaceDeleteAndRollbackRevision() async throws {
        let f = try await fixture()
        try await insert(f, start: 1)
        let one = try await revision(f)
        XCTAssertEqual(one, 1)
        try await f.store.registryWriter.write { db in
            try db.execute(sql: "UPDATE workout SET deviceId='adopted',sport='ride' WHERE startTs=1")
            try db.execute(sql: "INSERT OR REPLACE INTO workout(deviceId,startTs,endTs,sport,source) VALUES('adopted',1,2,'ride','manual')")
            try db.execute(sql: "DELETE FROM workout WHERE startTs=1")
        }
        let changed = try await revision(f)
        XCTAssertGreaterThanOrEqual(changed, 4)
        do {
            try await f.store.registryWriter.write { db in
                try db.execute(sql: "INSERT INTO workout(deviceId,startTs,endTs,sport,source) VALUES('rollback',1,2,'run','manual')")
                throw E.Failure.cancelled
            }
        } catch { XCTAssertEqual(error as? E.Failure, .cancelled) }
        let after = try await revision(f)
        XCTAssertEqual(after, changed)
    }

    func testOverflowRetainsHealthWriteButHoldsEvaluation() async throws {
        let f = try await fixture()
        try await f.store.registryWriter.write { try $0.execute(sql: "UPDATE workoutPreferenceEvaluation SET workoutRevision=9223372036854775807") }
        try await insert(f, start: 1)
        let view = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 0)
        XCTAssertEqual(view.disposition, .held(.revisionExhausted))
        XCTAssertFalse(view.hasRunnableWork(at: Int64.max))
        let count = try await f.store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM workout") }
        XCTAssertEqual(count, 1)
    }

    func testManualPositiveZeroLowCaloriesNilAndUnknownAreNeverRewritten() async throws {
        let f = try await fixture()
        try await insert(f, start: 1, source: "manual", strain: 8, notes: "import-copy\0unchanged", energy: 0)
        try await insert(f, start: 2, source: "manual", strain: 0, energy: 1)
        try await insert(f, start: 3, source: "manual", strain: nil)
        try await insert(f, start: 4, source: "unrecognized-provider", strain: 7)
        let before = try await f.store.registryWriter.read { try Row.fetchAll($0, sql: "SELECT *,CAST(notes AS BLOB) AS notesBytes FROM workout ORDER BY startTs") }
        XCTAssertEqual(before.first?["notesBytes"] as Data?, Data("import-copy\0unchanged".utf8))
        let view = try await finish(f, lease: scanLease(f))
        XCTAssertEqual(view.disposition, .evaluatedPartial)
        XCTAssertTrue(view.membershipComplete); XCTAssertFalse(view.hasRunnableWork(at: Int64.max))
        XCTAssertEqual(view.counts.manualPopulatedUnknown, 2); XCTAssertEqual(view.counts.manualNilDeferred, 1)
        XCTAssertEqual(view.counts.unknownSource, 1)
        let after = try await f.store.registryWriter.read { try Row.fetchAll($0, sql: "SELECT *,CAST(notes AS BLOB) AS notesBytes FROM workout ORDER BY startTs") }
        XCTAssertEqual(before, after)
        let receipt = try XCTUnwrap(view.validatedReceipt)
        let settled = try await f.store.settleWorkoutPreferenceRescoreJob(session: f.session, receipt: receipt,
            request: f.request, capturedToken: try XCTUnwrap(receipt.receipt.coreWitness.capturedRescoreJobToken), permit: f.permit)
        XCTAssertFalse(settled)
    }

    func testInclusiveBoundaryAllOwnersAndExactDetectedTuple() async throws {
        let f = try await fixture()
        try await insert(f, start: 0, device: "other-owner")
        try await insert(f, start: f.target.upperTs, device: "canonical-noop", sport: "detected", source: "canonical-noop")
        try await insert(f, start: f.target.upperTs + 1, source: "manual")
        try await insert(f, start: -1, source: "manual")
        let view = try await finish(f, lease: scanLease(f))
        XCTAssertEqual(view.disposition, .complete); XCTAssertEqual(view.counts.totalRows, 2)
        XCTAssertEqual(view.counts.managedDetected, 1)
    }

    func testSixHundredMembersRequireMoreThanFourPagesWithoutFalseCompletion() async throws {
        let f = try await fixture()
        try await many(f, count: 600)
        var lease = try await scanLease(f)
        for page in 1...4 {
            let result = try await f.store.advanceWorkoutPreferenceEvaluation(session: f.session, lease: lease, permit: f.permit)
            XCTAssertEqual(result.rowsProcessed, 128)
            XCTAssertEqual(result.view.counts.totalRows, Int64(page * 128))
            XCTAssertEqual(result.view.disposition, .continuation); XCTAssertNil(result.view.validatedReceipt)
            lease = try XCTUnwrap(result.view.lease)
        }
        let done = try await finish(f, lease: lease)
        XCTAssertEqual(done.disposition, .complete); XCTAssertEqual(done.counts.totalRows, 600)
    }

    func testByteBudgetYieldsWithoutCountLimitOrDataLoss() async throws {
        let f = try await fixture()
        try await many(f, count: 6, notes: String(repeating: "n", count: 60000))
        let lease = try await scanLease(f)
        let first = try await f.store.advanceWorkoutPreferenceEvaluation(session: f.session, lease: lease, permit: f.permit)
        XCTAssertEqual(first.rowsProcessed, 4); XCTAssertLessThanOrEqual(first.bytesProcessed, 262144)
        XCTAssertEqual(first.view.disposition, .continuation)
        let done = try await finish(f, lease: XCTUnwrap(first.view.lease))
        XCTAssertEqual(done.counts.totalRows, 6); XCTAssertEqual(done.disposition, .complete)
    }

    func testOversizedRowAndKeyHoldIncompleteMembership() async throws {
        for keyCase in [false, true] {
            let f = try await fixture()
            try await insert(f, start: 1, device: keyCase ? String(repeating: "d", count: 1025) : "strap",
                             notes: keyCase ? nil : String(repeating: "n", count: 65536))
            let view = try await finish(f, lease: scanLease(f))
            XCTAssertEqual(view.disposition, .held(keyCase ? .oversizedKey : .oversizedRow))
            XCTAssertFalse(view.membershipComplete); XCTAssertNil(view.validatedReceipt)
            XCTAssertFalse(view.hasRunnableWork(at: Int64.max))
            let unchanged = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: Int64.max)
            XCTAssertEqual(unchanged.head, view.head)
        }
    }

    func testExactRowCapAcceptsBoundaryThenRejectsOneExtraByte() async throws {
        let measure = try await fixture()
        try await insert(measure, start: 1, notes: "")
        let initial = try await scanLease(measure)
        let base = try await measure.store.advanceWorkoutPreferenceEvaluation(session: measure.session, lease: initial, permit: measure.permit)
        for extra in [0, 1] {
            let f = try await fixture()
            try await insert(f, start: 1, notes: String(repeating: "x", count: 65536 - base.bytesProcessed + extra))
            let view = try await finish(f, lease: scanLease(f))
            XCTAssertEqual(view.disposition, extra == 0 ? .complete : .held(.oversizedRow))
        }
    }

    func testInsertBehindCursorAndABAInvalidatesRatherThanSkippingMembers() async throws {
        let f = try await fixture()
        try await many(f, count: 200)
        let first = try await f.store.advanceWorkoutPreferenceEvaluation(session: f.session, lease: scanLease(f), permit: f.permit)
        let old = try XCTUnwrap(first.view.lease)
        try await f.store.registryWriter.write { db in
            try db.execute(sql: "UPDATE workout SET strain=8 WHERE startTs=1")
            try db.execute(sql: "UPDATE workout SET strain=4 WHERE startTs=1")
        }
        try await insert(f, start: 0)
        await failed(.staleHead) { _ = try await f.store.advanceWorkoutPreferenceEvaluation(session: f.session, lease: old, permit: f.permit) }
        let view = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 0)
        XCTAssertEqual(view.disposition, .needsCorePass)
    }

    func testP2CannotBeOverwrittenByAnyDelayedP1Ticket() async throws {
        let f = try await fixture()
        let old = try await scanLease(f)
        let secondRequest = try request(sequence: 2)
        let next = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: secondRequest, now: 0)
        let p2 = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: next.head,
            target: .init(request: secondRequest, lowerTs: 0, upperTs: f.target.upperTs), permit: .init())
        await failed(.staleHead) { _ = try await f.store.advanceWorkoutPreferenceEvaluation(session: f.session, lease: old, permit: f.permit) }
        await failed(.staleHead) { _ = try await f.store.deferWorkoutPreferenceEvaluation(session: f.session, lease: old, failure: .interruption, now: 0, permit: f.permit) }
        await failed(.stalePreference) { _ = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 0) }
        let after = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: secondRequest, now: 0)
        XCTAssertEqual(after.head, p2.head)
    }

    func testWrongCoreTokenAndNewerJobCannotSettle() async throws {
        let f = try await fixture()
        let lease = try await admitted(f)
        await failed(.staleHead) {
            _ = try await f.store.recordWorkoutPreferenceCorePass(session: f.session, lease: lease,
                witness: .init(targetDigest: lease.target.digest, dependencyDigest: f.request.dependencyDigest,
                               capturedRescoreJobToken: "wrong", legacyAttemptToken: nil), permit: f.permit)
        }
        let scan = try await f.store.recordWorkoutPreferenceCorePass(session: f.session, lease: lease,
            witness: .init(targetDigest: lease.target.digest, dependencyDigest: f.request.dependencyDigest,
                           capturedRescoreJobToken: lease.rescoreJobToken, legacyAttemptToken: nil), permit: f.permit)
        let view = try await finish(f, lease: scan)
        let receipt = try XCTUnwrap(view.validatedReceipt)
        let newToken = try await f.store.markJobOwed(kind: "rescore")
        let settled = try await f.store.settleWorkoutPreferenceRescoreJob(session: f.session, receipt: receipt,
            request: f.request, capturedToken: XCTUnwrap(lease.rescoreJobToken), permit: f.permit)
        XCTAssertFalse(settled)
        let owed = try await f.store.owedJobs()
        XCTAssertEqual(owed.first?.token, newToken)
    }

    func testSuccessfulAtomicSettlementDoesNotRequestAnotherPassOnTokenAbsence() async throws {
        let f = try await fixture()
        let view = try await finish(f, lease: scanLease(f))
        let receipt = try XCTUnwrap(view.validatedReceipt)
        let settled = try await f.store.settleWorkoutPreferenceRescoreJob(session: f.session, receipt: receipt,
            request: f.request, capturedToken: XCTUnwrap(receipt.receipt.coreWitness.capturedRescoreJobToken), permit: f.permit)
        XCTAssertTrue(settled)
        let after = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: Int64.max)
        XCTAssertEqual(after.disposition, .complete); XCTAssertFalse(after.hasRunnableWork(at: Int64.max))
        let owed = try await f.store.owedJobs()
        XCTAssertTrue(owed.isEmpty)
    }

    func testMutationAfterValidationPreventsExactJobDeletion() async throws {
        let f = try await fixture()
        let view = try await finish(f, lease: scanLease(f))
        let receipt = try XCTUnwrap(view.validatedReceipt)
        try await insert(f, start: 1, source: "manual")
        let settled = try await f.store.settleWorkoutPreferenceRescoreJob(session: f.session, receipt: receipt,
            request: f.request, capturedToken: XCTUnwrap(receipt.receipt.coreWitness.capturedRescoreJobToken), permit: f.permit)
        XCTAssertFalse(settled)
        let jobs = try await f.store.owedJobs(); XCTAssertEqual(jobs.count, 1)
    }

    func testPermitRevokedDuringRealTransactionRollsBackAndDoesNotPoisonOtherWrites() async throws {
        let f = try await fixture()
        let lease = try await admitted(f)
        try await f.store.registryWriter.write { db in
            db.add(function: DatabaseFunction("revokeWorkoutPermit", argumentCount: 0, pure: false) { _ in
                f.permit.invalidate(); return nil
            })
            try db.execute(sql: "CREATE TEMP TRIGGER revokeEvaluation BEFORE UPDATE ON workoutPreferenceEvaluation BEGIN SELECT revokeWorkoutPermit(); END")
        }
        await failed {
            _ = try await f.store.recordWorkoutPreferenceCorePass(session: f.session, lease: lease,
                witness: .init(targetDigest: lease.target.digest, dependencyDigest: f.request.dependencyDigest,
                               capturedRescoreJobToken: lease.rescoreJobToken, legacyAttemptToken: nil), permit: f.permit)
        }
        try await f.store.registryWriter.write { try $0.execute(sql: "DROP TRIGGER revokeEvaluation") }
        let after = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 0)
        XCTAssertEqual(after.head, lease.head)
        try await insert(f, start: 1)
        let count = try await f.store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM workout") }
        XCTAssertEqual(count, 1)
    }

    func testSessionRetirementAndPrecancelledTaskRetainDebt() async throws {
        let f = try await fixture()
        let lease = try await scanLease(f)
        f.session.invalidate()
        await failed(.retired) { _ = try await f.store.advanceWorkoutPreferenceEvaluation(session: f.session, lease: lease, permit: f.permit) }
        let fresh = try await f.store.openWorkoutPreferenceEvaluation(owner: f.request.owner, runtimeFence: .init())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.store.inspectWorkoutPreferenceEvaluation(session: fresh, request: f.request, now: 0)
        }
        do { _ = try await task.value; XCTFail("cancelled task returned a view") } catch { XCTAssertTrue(error is CancellationError) }
        let jobs = try await f.store.owedJobs(); XCTAssertEqual(jobs.count, 1)
    }

    func testRetryAfterIsNotRunnableUntilDeadlineEvenBeforeCorePass() async throws {
        let f = try await fixture()
        let lease = try await admitted(f)
        let view = try await f.store.deferWorkoutPreferenceEvaluation(session: f.session, lease: lease,
            failure: .transientBusy, now: 100, permit: f.permit)
        XCTAssertEqual(view.disposition, .retryAfter(160))
        XCTAssertFalse(view.hasRunnableWork(at: 159)); XCTAssertTrue(view.hasRunnableWork(at: 160))
    }

    func testUnknownCanonicalFieldsAndFutureVersionRemainUnmodified() async throws {
        let f = try await fixture()
        _ = try await scanLease(f)
        try await f.store.registryWriter.write { db in
            var object = try JSONSerialization.jsonObject(with: Data.fetchOne(db, sql: "SELECT stateBytes FROM workoutPreferenceEvaluation")!) as! [String: Any]
            object["unknownFutureField"] = true
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try db.execute(sql: "UPDATE workoutPreferenceEvaluation SET stateBytes=?,stateSHA256=?",
                           arguments: [bytes, Data(SHA256.hash(data: bytes))])
        }
        await failed(.invalidState) { _ = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 0) }
        try await f.store.registryWriter.write { try $0.execute(sql: "UPDATE workoutPreferenceEvaluation SET formatVersion=2") }
        await failed(.unsupportedFormat) { _ = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 0) }
        let version = try await f.store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT formatVersion FROM workoutPreferenceEvaluation") }
        XCTAssertEqual(version, 2)
    }

    func testRealReopenValidatesCompletedRowsWithoutRequiringScoring() async throws {
        let directory = try directory("workout-evaluation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("account.sqlite").path
        let req = try request()
        let f = try await fixture(path: path, request: req)
        try await many(f, count: 300)
        let original = try await finish(f, lease: scanLease(f))
        let digest = try XCTUnwrap(original.validatedReceipt).receipt.digest
        try f.store.registryWriter.close()
        let reopened = try await fixture(path: path, request: req)
        defer { try? reopened.store.registryWriter.close() }
        let view = try await reopened.store.inspectWorkoutPreferenceEvaluation(session: reopened.session, request: req, now: 0)
        XCTAssertEqual(view.disposition, .needsValidation)
        let validated = try await finish(reopened, lease: XCTUnwrap(view.lease))
        XCTAssertEqual(validated.disposition, .complete)
        XCTAssertEqual(validated.validatedReceipt?.receipt.digest, digest)
    }

    func testCopiedMatchingUUIDAndRevisionWithChangedRowDoesNotRenewReceipt() async throws {
        let directory = try directory("workout-copy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let req = try request(), originalPath = directory.appendingPathComponent("original.sqlite").path
        let f = try await fixture(path: originalPath, request: req)
        try await insert(f, start: 1, notes: "a\0original")
        let original = try await finish(f, lease: scanLease(f))
        let oldRevision = original.head.workoutRevision
        try await f.store.checkpointWAL(); try f.store.registryWriter.close()
        let copiedPath = directory.appendingPathComponent("copied.sqlite").path
        // Copy a closed, checkpointed SQLite file set. On this host the existing
        // read-only origin probe cannot open a WAL-mode main file lacking sidecars.
        // This is content/receipt recovery coverage, not a backup installer test.
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: originalPath + suffix) {
            try FileManager.default.copyItem(atPath: originalPath + suffix, toPath: copiedPath + suffix)
        }
        let copied = try await fixture(path: copiedPath, request: req)
        defer { try? copied.store.registryWriter.close() }
        try await copied.store.registryWriter.write { db in
            // Bind bytes then cast to TEXT: GRDB's String binding itself stops at NUL.
            try db.execute(sql: "UPDATE workout SET notes=CAST(? AS TEXT) WHERE startTs=1", arguments: [Data("a\0different".utf8)])
            try db.execute(sql: "UPDATE workoutPreferenceEvaluation SET workoutRevision=?", arguments: [oldRevision])
        }
        let view = try await copied.store.inspectWorkoutPreferenceEvaluation(session: copied.session, request: req, now: 0)
        XCTAssertEqual(view.head.storeID, original.head.storeID); XCTAssertEqual(view.head.workoutRevision, oldRevision)
        XCTAssertEqual(view.disposition, .needsValidation)
        let rejected = try await finish(copied, lease: XCTUnwrap(view.lease))
        XCTAssertEqual(rejected.disposition, .needsCorePass); XCTAssertNil(rejected.validatedReceipt)
        let bytes = try await copied.store.registryWriter.read { try Data.fetchOne($0, sql: "SELECT CAST(notes AS BLOB) FROM workout") }
        XCTAssertEqual(bytes, Data("a\0different".utf8))
    }

    func testColdPartialPrefixRevalidatesThenContinues() async throws {
        let directory = try directory("workout-prefix")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("account.sqlite").path, req = try request()
        let f = try await fixture(path: path, request: req)
        try await many(f, count: 260)
        let step = try await f.store.advanceWorkoutPreferenceEvaluation(session: f.session, lease: scanLease(f), permit: f.permit)
        XCTAssertEqual(step.view.counts.totalRows, 128)
        try f.store.registryWriter.close()
        let reopened = try await fixture(path: path, request: req)
        defer { try? reopened.store.registryWriter.close() }
        let view = try await reopened.store.inspectWorkoutPreferenceEvaluation(session: reopened.session, request: req, now: 0)
        XCTAssertEqual(view.disposition, .needsValidation)
        let final = try await finish(reopened, lease: XCTUnwrap(view.lease))
        XCTAssertEqual(final.disposition, .complete); XCTAssertEqual(final.counts.totalRows, 260)
    }

    func testInvalidTargetsRejectUnicodeHexOverflowAndTooShortWindow() throws {
        XCTAssertThrowsError(try E.Digest(hex: String(repeating: "é", count: 32)))
        let req = try request()
        XCTAssertThrowsError(try E.Target(request: req, lowerTs: Int64.min, upperTs: Int64.max))
        XCTAssertThrowsError(try E.Target(request: req, lowerTs: 0, upperTs: 20 * 86400))
        let maxString = String(repeating: "x", count: 1025)
        XCTAssertThrowsError(try E.Request(owner: req.owner, preference: req.preference, canonicalWriter: maxString,
                                           requestedDays: 21, localDayAnchor: req.localDayAnchor, timezoneID: req.timezoneID,
                                           offsetSeconds: req.offsetSeconds, dependencyDigest: req.dependencyDigest))
    }

    func testDecodedRequestCannotBypassCheckedTargetArithmetic() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request())) as? [String: Any])
        object["requestedDays"] = Int64.max
        let unchecked = try JSONDecoder().decode(E.Request.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try E.Target(request: unchecked, lowerTs: Int64.min, upperTs: Int64.max))
    }

    func testClockTicksKeepAdmittedBoundsAndIdentity() async throws {
        let f = try await fixture()
        let lease = try await admitted(f)
        let view = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 100)
        let later = try E.Target(request: f.request, lowerTs: 100, upperTs: f.target.upperTs + 100)
        let same = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: view.head,
                                                                     target: later, permit: f.permit)
        XCTAssertEqual(same.head, lease.head); XCTAssertEqual(same.evaluationID, lease.evaluationID)
        XCTAssertEqual(same.target, lease.target)
    }

    func testPartialRetainsEveryJobAndFreshRescoreDebtIsNotHidden() async throws {
        let f = try await fixture()
        try await insert(f, start: 1, source: "manual", strain: 7)
        _ = try await f.store.markJobOwed(kind: "cloudPush")
        _ = try await f.store.markJobOwed(kind: "autoExport")
        let lease = try await scanLease(f)
        let before = try await f.store.registryWriter.read { try Row.fetchAll($0, sql: "SELECT * FROM syncJob ORDER BY kind") }
        let partial = try await finish(f, lease: lease)
        let after = try await f.store.registryWriter.read { try Row.fetchAll($0, sql: "SELECT * FROM syncJob ORDER BY kind") }
        XCTAssertEqual(partial.disposition, .evaluatedPartial); XCTAssertEqual(before, after)
        for now: Int64 in [1, 60, 86400] {
            let held = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: now)
            XCTAssertEqual(held.head, partial.head); XCTAssertFalse(held.hasRunnableWork(at: now))
        }
        _ = try await f.store.markJobOwed(kind: "rescore")
        let fresh = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 86401)
        XCTAssertEqual(fresh.disposition, .needsCorePass)
        XCTAssertTrue(fresh.hasRunnableWork(at: 86401))
    }

    func testColdReopenAfterSettlementValidatesWithoutNewCoreOrJob() async throws {
        let directory = try directory("workout-settled")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("account.sqlite").path, req = try request()
        let f = try await fixture(path: path, request: req)
        try await many(f, count: 260)
        let original = try await finish(f, lease: scanLease(f))
        let receipt = try XCTUnwrap(original.validatedReceipt)
        let settled = try await f.store.settleWorkoutPreferenceRescoreJob(session: f.session, receipt: receipt,
            request: req, capturedToken: XCTUnwrap(receipt.receipt.coreWitness.capturedRescoreJobToken), permit: f.permit)
        XCTAssertTrue(settled)
        try f.store.registryWriter.close()
        let reopened = try await fixture(path: path, request: req)
        defer { try? reopened.store.registryWriter.close() }
        let view = try await reopened.store.inspectWorkoutPreferenceEvaluation(session: reopened.session, request: req, now: 0)
        XCTAssertEqual(view.disposition, .needsValidation)
        let renewed = try await finish(reopened, lease: XCTUnwrap(view.lease))
        XCTAssertEqual(renewed.disposition, .complete)
        XCTAssertEqual(renewed.validatedReceipt?.receipt.digest, receipt.receipt.digest)
        let jobs = try await reopened.store.owedJobs(); XCTAssertTrue(jobs.isEmpty)
    }

    func testEveryOneOfFourteenRowFieldsParticipatesInColdProof() async throws {
        let mutations = ["deviceId='other'", "startTs=2", "endTs=100", "sport='ride'", "source='manual'",
                         "durationS=61", "energyKcal=101", "avgHr=141", "maxHr=151", "strain=5",
                         "distanceM=101", "zonesJSON='[]'", "notes='changed'", "steps=11"]
        for mutation in mutations {
            let f = try await fixture()
            try await insert(f, start: 1)
            let original = try await finish(f, lease: scanLease(f))
            try await f.store.registryWriter.write { db in
                try db.execute(sql: "UPDATE workout SET \(mutation)")
                try db.execute(sql: "UPDATE workoutPreferenceEvaluation SET workoutRevision=?", arguments: [original.head.workoutRevision])
            }
            // A new session has no authority from the matching stored UUID/revision.
            let cold = try await f.store.openWorkoutPreferenceEvaluation(owner: f.request.owner, runtimeFence: f.runtime)
            let view = try await f.store.inspectWorkoutPreferenceEvaluation(session: cold, request: f.request, now: 0)
            XCTAssertEqual(view.disposition, .needsValidation, mutation)
            let step = try await f.store.advanceWorkoutPreferenceEvaluation(session: cold, lease: XCTUnwrap(view.lease), permit: f.permit)
            XCTAssertEqual(step.view.disposition, .needsCorePass, mutation)
            XCTAssertNil(step.view.validatedReceipt, mutation)
        }
    }

    func testNonfiniteStoredRealHoldsWithoutDeletingDebt() async throws {
        let f = try await fixture()
        try await insert(f, start: 1)
        try await f.store.registryWriter.write { try $0.execute(sql: "UPDATE workout SET strain=9e999") }
        let view = try await finish(f, lease: scanLease(f))
        XCTAssertEqual(view.disposition, .held(.malformedRow)); XCTAssertFalse(view.membershipComplete)
        let values = try await f.store.registryWriter.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM syncJob"),
             try Double.fetchOne(db, sql: "SELECT strain FROM workout"))
        }
        XCTAssertEqual(values.0, 1); XCTAssertEqual(values.1, Double.infinity)
    }

    func testCanonicalControlRejectsWhitespaceWrongTypeAndVersionWithoutRewrite() async throws {
        let f = try await fixture()
        _ = try await scanLease(f)
        let original = try await f.store.registryWriter.read { try XCTUnwrap(Data.fetchOne($0, sql: "SELECT stateBytes FROM workoutPreferenceEvaluation")) }
        var wrongType = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        wrongType["version"] = "1"
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        future["version"] = 2
        for bytes in [Data(" ".utf8) + original,
                      try JSONSerialization.data(withJSONObject: wrongType, options: [.sortedKeys]),
                      try JSONSerialization.data(withJSONObject: future, options: [.sortedKeys])] {
            try await f.store.registryWriter.write { db in
                try db.execute(sql: "UPDATE workoutPreferenceEvaluation SET stateBytes=?,stateSHA256=?",
                               arguments: [bytes, Data(SHA256.hash(data: bytes))])
            }
            await failed(.invalidState) { _ = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 0) }
            let retained = try await f.store.registryWriter.read { try Data.fetchOne($0, sql: "SELECT stateBytes FROM workoutPreferenceEvaluation") }
            XCTAssertEqual(retained, bytes)
        }
    }

    func testWindowQueryUsesOrderedIndexWithoutTemporarySort() async throws {
        let f = try await fixture()
        try await many(f, count: 300)
        let details = try await f.store.registryWriter.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT rowid,typeof(notes),length(CAST(notes AS BLOB)) FROM workout
                WHERE startTs>=0 AND startTs<=1814400
                AND (startTs,deviceId COLLATE BINARY,sport COLLATE BINARY)>(100,'strap','run')
                ORDER BY startTs,deviceId COLLATE BINARY,sport COLLATE BINARY LIMIT 129
                """).map { $0["detail"] as String }
        }
        XCTAssertTrue(details.contains { $0.contains("workout_preference_window_v1") }, details.joined(separator: "; "))
        XCTAssertFalse(details.contains { $0.contains("TEMP B-TREE") }, details.joined(separator: "; "))
    }

    func testAutomaticAdmissionKeepsRetryButExplicitRetryClearsOnlyMatchingStop() async throws {
        let f = try await fixture()
        let original = try await admitted(f)
        let held = try await f.store.deferWorkoutPreferenceEvaluation(session: f.session, lease: original,
            failure: .requiredWrite, now: 100, permit: f.permit)
        let automatic = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: held.head,
            target: f.target, permit: f.permit)
        XCTAssertEqual(automatic.head, held.head)
        let before = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 100)
        XCTAssertEqual(before.disposition, .retryAfter(160))
        let retried = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: held.head,
            target: original.target, permit: f.permit, mode: .explicitRetry)
        XCTAssertEqual(retried.evaluationID, original.evaluationID)
        XCTAssertEqual(retried.target, original.target); XCTAssertEqual(retried.rescoreJobToken, original.rescoreJobToken)
        XCTAssertEqual(retried.head.stateSerial, held.head.stateSerial + 1)
        let after = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 100)
        XCTAssertEqual(after.disposition, .needsCorePass)
    }

    func testExplicitRetryCannotMoveBoundsAndKeepsPartialUnchanged() async throws {
        let f = try await fixture()
        try await insert(f, start: 1, source: "manual")
        let partial = try await finish(f, lease: scanLease(f))
        let lease = try XCTUnwrap(partial.lease)
        let same = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: partial.head,
            target: lease.target, permit: f.permit, mode: .explicitRetry)
        XCTAssertEqual(same.head, partial.head); XCTAssertEqual(same.evaluationID, lease.evaluationID)
        let later = try E.Target(request: f.request, lowerTs: 100, upperTs: f.target.upperTs + 100)
        await failed(.invalidTarget) {
            _ = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: partial.head,
                target: later, permit: f.permit, mode: .explicitRetry)
        }
        let after = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: Int64.max)
        XCTAssertEqual(after.disposition, .evaluatedPartial); XCTAssertEqual(after.head, partial.head)
        let jobs = try await f.store.owedJobs(); XCTAssertEqual(jobs.count, 1)
    }

    func testExplicitResourceRetryPreservesPrefixAndDoesNotCertifyOversizeRow() async throws {
        let f = try await fixture()
        try await insert(f, start: 1)
        try await insert(f, start: 2, notes: String(repeating: "x", count: 65536))
        let held = try await finish(f, lease: scanLease(f))
        XCTAssertEqual(held.disposition, .held(.oversizedRow)); XCTAssertEqual(held.counts.totalRows, 1)
        let before = try await workoutBytes(f)
        let retry = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: held.head,
            target: f.target, permit: f.permit, mode: .explicitRetry)
        XCTAssertEqual(retry.evaluationID, held.lease?.evaluationID)
        let reopened = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 0)
        XCTAssertEqual(reopened.disposition, .continuation); XCTAssertEqual(reopened.counts.totalRows, 1)
        let stillHeld = try await finish(f, lease: retry)
        XCTAssertEqual(stillHeld.disposition, .held(.oversizedRow)); XCTAssertNil(stillHeld.validatedReceipt)
        XCTAssertEqual(stillHeld.counts.totalRows, 1)
        let after = try await workoutBytes(f); XCTAssertEqual(before, after)
    }

    func testColdExplicitResourceRetryStillValidatesSavedPrefix() async throws {
        let directory = try directory("workout-resource-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("account.sqlite").path, req = try request()
        let f = try await fixture(path: path, request: req)
        try await insert(f, start: 1)
        try await insert(f, start: 2, notes: String(repeating: "x", count: 65536))
        _ = try await finish(f, lease: scanLease(f))
        try f.store.registryWriter.close()
        let cold = try await fixture(path: path, request: req)
        defer { try? cold.store.registryWriter.close() }
        let view = try await cold.store.inspectWorkoutPreferenceEvaluation(session: cold.session, request: req, now: 0)
        XCTAssertEqual(view.disposition, .held(.oversizedRow))
        let retry = try await cold.store.admitWorkoutPreferenceEvaluation(session: cold.session, expected: view.head,
            target: XCTUnwrap(view.lease).target, permit: cold.permit, mode: .explicitRetry)
        let unvalidated = try await cold.store.inspectWorkoutPreferenceEvaluation(session: cold.session, request: req, now: 0)
        XCTAssertEqual(unvalidated.disposition, .needsValidation)
        let prefix = try await cold.store.advanceWorkoutPreferenceEvaluation(session: cold.session, lease: retry, permit: cold.permit)
        XCTAssertEqual(prefix.rowsProcessed, 1); XCTAssertEqual(prefix.view.disposition, .continuation)
        XCTAssertNil(prefix.view.validatedReceipt)
    }

    func testRefreshCoreInvalidatesReceiptBeforeCorrectionAndRetainsBounds() async throws {
        let f = try await fixture()
        let complete = try await finish(f, lease: scanLease(f))
        let receipt = try XCTUnwrap(complete.validatedReceipt)
        let shifted = try E.Target(request: f.request, lowerTs: 100, upperTs: f.target.upperTs + 100)
        let fresh = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: complete.head,
            target: shifted, permit: f.permit, mode: .refreshCore)
        XCTAssertNotEqual(fresh.evaluationID, complete.lease?.evaluationID)
        XCTAssertEqual(fresh.target, receipt.receipt.target)
        XCTAssertEqual(fresh.target.request.preference, receipt.receipt.target.request.preference)
        let pending = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 0)
        XCTAssertEqual(pending.disposition, .needsCorePass); XCTAssertNil(pending.validatedReceipt)
        let settled = try await f.store.settleWorkoutPreferenceRescoreJob(session: f.session, receipt: receipt,
            request: f.request, capturedToken: XCTUnwrap(fresh.rescoreJobToken), permit: f.permit)
        XCTAssertFalse(settled)
        let done = try await finish(f, lease: recordCore(f, lease: fresh))
        XCTAssertEqual(done.disposition, .complete)
    }

    func testExplicitModesCannotBypassCorruptMetadataOrStaleHead() async throws {
        let f = try await fixture()
        let original = try await admitted(f)
        let refreshed = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: original.head,
            target: f.target, permit: f.permit, mode: .refreshCore)
        for mode: E.AdmissionMode in [.explicitRetry, .refreshCore] {
            await failed(.staleHead) {
                _ = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: original.head,
                    target: f.target, permit: f.permit, mode: mode)
            }
        }
        try await f.store.registryWriter.write { try $0.execute(sql: "UPDATE workoutPreferenceEvaluation SET formatVersion=2") }
        for mode: E.AdmissionMode in [.explicitRetry, .refreshCore] {
            await failed(.unsupportedFormat) {
                _ = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: refreshed.head,
                    target: f.target, permit: f.permit, mode: mode)
            }
        }
    }

    func testCoreWriteRevisionDriftCanPersistFailureAcrossReopen() async throws {
        let directory = try directory("workout-core-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("account.sqlite").path, req = try request()
        let f = try await fixture(path: path, request: req)
        let lease = try await admitted(f)
        _ = try await f.store.replaceManagedDetectedWorkouts(session: f.session, lease: lease,
            rows: [generated(start: 1)], permit: f.permit)
        let held = try await f.store.deferWorkoutPreferenceEvaluation(session: f.session, lease: lease,
            failure: .requiredWrite, now: 100, permit: f.permit)
        XCTAssertEqual(held.disposition, .retryAfter(160)); XCTAssertEqual(held.lease?.evaluationID, lease.evaluationID)
        XCTAssertGreaterThan(held.head.workoutRevision, lease.head.workoutRevision)
        try f.store.registryWriter.close()
        let cold = try await fixture(path: path, request: req)
        defer { try? cold.store.registryWriter.close() }
        let persisted = try await cold.store.inspectWorkoutPreferenceEvaluation(session: cold.session, request: req, now: 101)
        XCTAssertEqual(persisted.disposition, .retryAfter(160)); XCTAssertEqual(persisted.head, held.head)
        let retried = try await cold.store.admitWorkoutPreferenceEvaluation(session: cold.session, expected: persisted.head,
            target: XCTUnwrap(persisted.lease).target, permit: cold.permit, mode: .explicitRetry)
        XCTAssertEqual(retried.evaluationID, lease.evaluationID)
        _ = try await cold.store.replaceManagedDetectedWorkouts(session: cold.session, lease: retried,
            rows: [generated(start: 2)], permit: cold.permit)
        let done = try await finish(cold, lease: recordCore(cold, lease: retried))
        XCTAssertEqual(done.disposition, .complete)
    }

    func testRevisionDriftDeferralRejectsScanningPhaseAndChangedToken() async throws {
        let f = try await fixture()
        let scanning = try await scanLease(f)
        try await insert(f, start: 1)
        await failed(.staleHead) {
            _ = try await f.store.deferWorkoutPreferenceEvaluation(session: f.session, lease: scanning,
                failure: .interruption, now: 0, permit: f.permit)
        }
        let current = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 0)
        let core = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: current.head,
            target: f.target, permit: f.permit)
        _ = try await f.store.markJobOwed(kind: "rescore")
        await failed(.staleHead) {
            _ = try await f.store.deferWorkoutPreferenceEvaluation(session: f.session, lease: core,
                failure: .interruption, now: 0, permit: f.permit)
        }
    }

    func testManagedReplacementPreservesSourceConflictsAllOwnersAndRange() async throws {
        let f = try await fixture()
        try await insert(f, start: 1, device: "canonical-noop", sport: "detected", source: "manual", notes: "unknown\0retain")
        try await insert(f, start: 2, device: "canonical-noop", sport: "detected", source: "canonical-noop")
        try await insert(f, start: 3, device: "other", sport: "detected", source: "canonical-noop")
        try await insert(f, start: 4, device: "canonical-noop", sport: "run", source: "canonical-noop")
        try await insert(f, start: f.target.upperTs + 1, device: "canonical-noop", sport: "detected", source: "canonical-noop")
        let before = try await workoutBytes(f)
        let lease = try await admitted(f)
        let changed = try await f.store.replaceManagedDetectedWorkouts(session: f.session, lease: lease,
            rows: [generated(start: 1), generated(start: 5, notes: "managed\0bytes")], permit: f.permit)
        XCTAssertEqual(changed, 2) // One exact old row deleted; one new row inserted; conflict untouched.
        let after = try await workoutBytes(f)
        for old in before where old["startTs"] as Int64 != 2 { XCTAssertTrue(after.contains(old)) }
        XCTAssertFalse(after.contains { $0["startTs"] as Int64 == 2 })
        let inserted = try XCTUnwrap(after.first { $0["startTs"] as Int64 == 5 })
        XCTAssertEqual(inserted["exactNotes"] as Data, Data("managed\0bytes".utf8))
        let view = try await finish(f, lease: recordCore(f, lease: lease))
        XCTAssertEqual(view.disposition, .evaluatedPartial)
        XCTAssertEqual(view.counts.manualPopulatedUnknown, 1)
    }

    func testEmptyManagedReplacementDeletesOnlyExactTuple() async throws {
        let f = try await fixture()
        try await insert(f, start: 1, device: "canonical-noop", sport: "detected", source: "canonical-noop")
        try await insert(f, start: 2, device: "canonical-noop", sport: "detected", source: "detected")
        let lease = try await admitted(f)
        let changes = try await f.store.replaceManagedDetectedWorkouts(session: f.session, lease: lease, rows: [], permit: f.permit)
        XCTAssertEqual(changes, 1)
        let kept = try await workoutBytes(f); XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?["source"] as String?, "detected")
    }

    func testInvalidGeneratedGroupCannotPartiallyDeleteOrInsert() async throws {
        let f = try await fixture()
        try await insert(f, start: 1, device: "canonical-noop", sport: "detected", source: "canonical-noop")
        let lease = try await admitted(f), before = try await workoutBytes(f), oldRevision = try await revision(f)
        let invalid = [generated(start: 2, source: "manual"), generated(start: 2, sport: "run"),
                       generated(start: -1), generated(start: Int(f.target.upperTs) + 1)]
        for bad in invalid {
            await failed(.invalidTarget) {
                _ = try await f.store.replaceManagedDetectedWorkouts(session: f.session, lease: lease,
                    rows: [self.generated(start: 3), bad], permit: f.permit)
            }
            let rows = try await workoutBytes(f), currentRevision = try await revision(f)
            XCTAssertEqual(rows, before); XCTAssertEqual(currentRevision, oldRevision)
        }
    }

    func testManagedWriterSqlFailureRollsBackDeleteInsertAndRevisionTogether() async throws {
        let f = try await fixture()
        try await insert(f, start: 1, device: "canonical-noop", sport: "detected", source: "canonical-noop")
        let lease = try await admitted(f), before = try await workoutBytes(f), oldRevision = try await revision(f)
        try await f.store.registryWriter.write { try $0.execute(sql: "CREATE TEMP TRIGGER failManaged BEFORE INSERT ON workout WHEN NEW.startTs=3 BEGIN SELECT RAISE(ABORT,'synthetic writer fault'); END") }
        await failed {
            _ = try await f.store.replaceManagedDetectedWorkouts(session: f.session, lease: lease,
                rows: [self.generated(start: 2), self.generated(start: 3)], permit: f.permit)
        }
        let after = try await workoutBytes(f), afterRevision = try await revision(f)
        XCTAssertEqual(after, before); XCTAssertEqual(afterRevision, oldRevision)
    }

    func testManagedWriterPermitRevocationBeforeCommitRollsBackWithoutPoisoningStore() async throws {
        let f = try await fixture()
        try await insert(f, start: 1, device: "canonical-noop", sport: "detected", source: "canonical-noop")
        let lease = try await admitted(f), before = try await workoutBytes(f), oldRevision = try await revision(f)
        try await f.store.registryWriter.write { db in
            db.add(function: DatabaseFunction("revokeManagedPermit", argumentCount: 0, pure: false) { _ in f.permit.invalidate(); return nil })
            try db.execute(sql: "CREATE TEMP TRIGGER revokeManaged AFTER DELETE ON workout BEGIN SELECT revokeManagedPermit(); END")
        }
        await failed {
            _ = try await f.store.replaceManagedDetectedWorkouts(session: f.session, lease: lease,
                rows: [self.generated(start: 2)], permit: f.permit)
        }
        let after = try await workoutBytes(f), afterRevision = try await revision(f)
        XCTAssertEqual(after, before); XCTAssertEqual(afterRevision, oldRevision)
        try await f.store.registryWriter.write { try $0.execute(sql: "DROP TRIGGER revokeManaged") }
        try await insert(f, start: 10)
        let rows = try await workoutBytes(f); XCTAssertEqual(rows.count, 2)
    }

    func testManagedWriterCannotUseOldEvaluationOrPostCoreLease() async throws {
        let f = try await fixture()
        let original = try await admitted(f)
        let newCore = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: original.head,
            target: f.target, permit: f.permit, mode: .refreshCore)
        await failed(.staleHead) {
            _ = try await f.store.replaceManagedDetectedWorkouts(session: f.session, lease: original,
                rows: [self.generated(start: 1)], permit: f.permit)
        }
        let scanning = try await recordCore(f, lease: newCore)
        await failed(.staleHead) {
            _ = try await f.store.replaceManagedDetectedWorkouts(session: f.session, lease: scanning,
                rows: [self.generated(start: 1)], permit: f.permit)
        }
        let rows = try await workoutBytes(f); XCTAssertTrue(rows.isEmpty)
    }

    private struct DependentSnapshot: Equatable {
        let control: [Row]
        let jobs: [Row]
        let workouts: [Row]
    }

    private func dependentSnapshot(_ f: Fixture) async throws -> DependentSnapshot {
        try await f.store.registryWriter.read { db in
            .init(control: try Row.fetchAll(db, sql: "SELECT * FROM workoutPreferenceEvaluation"),
                  jobs: try Row.fetchAll(db, sql: "SELECT * FROM syncJob ORDER BY kind"),
                  workouts: try Row.fetchAll(db, sql: "SELECT * FROM workout ORDER BY deviceId,startTs,sport"))
        }
    }

    private func dependentReceipt(_ f: Fixture, rescore: Bool = true) async throws -> E.ValidatedReceipt {
        let done = try await finish(f, lease: scanLease(f, markJob: rescore))
        XCTAssertEqual(done.disposition, .complete)
        let receipt = try XCTUnwrap(done.validatedReceipt)
        if rescore {
            let paid = try await f.store.settleWorkoutPreferenceRescoreJob(session: f.session, receipt: receipt,
                request: f.request, capturedToken: XCTUnwrap(receipt.receipt.coreWitness.capturedRescoreJobToken), permit: f.permit)
            XCTAssertTrue(paid)
        }
        let current = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 0)
        XCTAssertEqual(current.disposition, .complete)
        return try XCTUnwrap(current.validatedReceipt)
    }

    func testDependentSettlementDeletesOnlyEachExactAllowedJobWithoutStateOrRowWrites() async throws {
        let f = try await fixture()
        try await insert(f, start: 1)
        try await insert(f, start: f.target.upperTs + 1, source: "manual", strain: 7)
        let receipt = try await dependentReceipt(f)
        let kinds: [SyncJobKind] = [.cloudPush, .healthWriteback, .widgetPublish]
        let tokens = try await f.store.markJobsOwed(kinds: kinds.map(\.rawValue) + ["unknownExport"])
        let original = try await dependentSnapshot(f)
        for kind in kinds {
            let before = try await dependentSnapshot(f)
            let deleted = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
                request: f.request, kind: kind, capturedToken: XCTUnwrap(tokens[kind.rawValue]), permit: f.permit)
            XCTAssertTrue(deleted)
            let after = try await dependentSnapshot(f)
            XCTAssertEqual(after.control, original.control); XCTAssertEqual(after.workouts, original.workouts)
            XCTAssertEqual(after.jobs, before.jobs.filter { $0["kind"] as String != kind.rawValue })
            let repeated = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
                request: f.request, kind: kind, capturedToken: XCTUnwrap(tokens[kind.rawValue]), permit: f.permit)
            XCTAssertFalse(repeated)
        }
        let jobs = try await f.store.owedJobs()
        XCTAssertEqual(jobs.count, 1); XCTAssertEqual(jobs.first?.kind, "unknownExport")
        XCTAssertEqual(jobs.first?.token, tokens["unknownExport"])
    }

    func testDependentSettlementRejectsRescoreAndCannotRepresentUnknownKind() async throws {
        let f = try await fixture(), receipt = try await dependentReceipt(f, rescore: false)
        let tokens = try await f.store.markJobsOwed(kinds: ["rescore", "unknownExport", "cloudPush"])
        let before = try await dependentSnapshot(f)
        let deleted = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
            request: f.request, kind: .rescore, capturedToken: XCTUnwrap(tokens["rescore"]), permit: f.permit)
        XCTAssertFalse(deleted); XCTAssertNil(SyncJobKind(rawValue: "unknownExport"))
        let after = try await dependentSnapshot(f); XCTAssertEqual(after, before)
    }

    func testDependentSettlementAcceptsCompleteEvaluationThatNeverHadRescoreDebt() async throws {
        let f = try await fixture(), receipt = try await dependentReceipt(f, rescore: false)
        XCTAssertNil(receipt.receipt.coreWitness.capturedRescoreJobToken)
        let token = try await f.store.markJobOwed(kind: "widgetPublish")
        let before = try await dependentSnapshot(f)
        let deleted = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
            request: f.request, kind: .widgetPublish, capturedToken: token, permit: f.permit)
        XCTAssertTrue(deleted)
        let after = try await dependentSnapshot(f)
        XCTAssertEqual(after.control, before.control); XCTAssertEqual(after.workouts, before.workouts)
        XCTAssertTrue(after.jobs.isEmpty)
    }

    func testDependentSettlementRefusesOwedRescoreAndItsUnverifiedGenericDisappearance() async throws {
        let f = try await fixture()
        let complete = try await finish(f, lease: scanLease(f))
        let receipt = try XCTUnwrap(complete.validatedReceipt)
        let token = try await f.store.markJobOwed(kind: "cloudPush")
        let before = try await dependentSnapshot(f)
        let owed = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
            request: f.request, kind: .cloudPush, capturedToken: token, permit: f.permit)
        XCTAssertFalse(owed)
        let unchanged = try await dependentSnapshot(f); XCTAssertEqual(unchanged, before)
        let generic = try await f.store.settleJob(kind: "rescore", token: XCTUnwrap(receipt.receipt.coreWitness.capturedRescoreJobToken))
        XCTAssertTrue(generic)
        let missing = try await dependentSnapshot(f)
        let unproved = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
            request: f.request, kind: .cloudPush, capturedToken: token, permit: f.permit)
        XCTAssertFalse(unproved)
        let after = try await dependentSnapshot(f); XCTAssertEqual(after, missing)
    }

    func testDependentSettlementRefusesNewRescoreDebtAfterPriorExactSettlement() async throws {
        let f = try await fixture(), receipt = try await dependentReceipt(f)
        let token = try await f.store.markJobOwed(kind: "healthWriteback")
        _ = try await f.store.markJobOwed(kind: "rescore")
        let before = try await dependentSnapshot(f)
        let deleted = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
            request: f.request, kind: .healthWriteback, capturedToken: token, permit: f.permit)
        XCTAssertFalse(deleted)
        let after = try await dependentSnapshot(f); XCTAssertEqual(after, before)
    }

    func testDependentSettlementRequiresCurrentExactExportTokenIncludingEmbeddedNul() async throws {
        let f = try await fixture(), receipt = try await dependentReceipt(f)
        let old = try await f.store.markJobOwed(kind: "cloudPush")
        let current = try await f.store.markJobOwed(kind: "cloudPush")
        let other = try await f.store.markJobOwed(kind: "widgetPublish")
        let before = try await dependentSnapshot(f)
        for token in [old, current + "\0suffix", other, ""] {
            let deleted = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
                request: f.request, kind: .cloudPush, capturedToken: token, permit: f.permit)
            XCTAssertFalse(deleted)
            let after = try await dependentSnapshot(f); XCTAssertEqual(after, before)
        }
        let deleted = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
            request: f.request, kind: .cloudPush, capturedToken: current, permit: f.permit)
        XCTAssertTrue(deleted)
    }

    func testDependentSettlementRejectsWrongRequestOwnerPreferenceAndWriter() async throws {
        let f = try await fixture(), receipt = try await dependentReceipt(f)
        let token = try await f.store.markJobOwed(kind: "cloudPush")
        let otherOwner = try E.Owner(projectURL: f.request.owner.projectURL, userID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        let wrongOwner = try E.Request(owner: otherOwner, preference: f.request.preference,
            canonicalWriter: f.request.canonicalWriter, requestedDays: f.request.requestedDays,
            localDayAnchor: f.request.localDayAnchor, timezoneID: f.request.timezoneID,
            offsetSeconds: f.request.offsetSeconds, dependencyDigest: f.request.dependencyDigest)
        let requests = [wrongOwner, try request(sequence: 2), try withWriter("other-writer", request: f.request)]
        let before = try await dependentSnapshot(f)
        for request in requests {
            let deleted = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
                request: request, kind: .cloudPush, capturedToken: token, permit: f.permit)
            XCTAssertFalse(deleted)
        }
        let after = try await dependentSnapshot(f); XCTAssertEqual(after, before)
    }

    func testDependentSettlementRejectsWorkoutRevisionDriftAndOverflow() async throws {
        for overflow in [false, true] {
            let f = try await fixture(), receipt = try await dependentReceipt(f)
            let token = try await f.store.markJobOwed(kind: "cloudPush")
            if overflow {
                try await f.store.registryWriter.write { try $0.execute(sql: "UPDATE workoutPreferenceEvaluation SET revisionOverflow=1") }
            } else {
                try await insert(f, start: 1, source: "manual", strain: 7)
            }
            let before = try await dependentSnapshot(f)
            let deleted = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
                request: f.request, kind: .cloudPush, capturedToken: token, permit: f.permit)
            XCTAssertFalse(deleted)
            let after = try await dependentSnapshot(f); XCTAssertEqual(after, before)
        }
    }

    func testDependentSettlementRejectsPartialReceiptAndResourceHeldOldReceipt() async throws {
        let partial = try await fixture()
        try await insert(partial, start: 1, source: "manual", strain: 7)
        let view = try await finish(partial, lease: scanLease(partial, markJob: false))
        XCTAssertEqual(view.disposition, .evaluatedPartial)
        let token = try await partial.store.markJobOwed(kind: "cloudPush")
        let before = try await dependentSnapshot(partial)
        let deleted = try await partial.store.settleWorkoutPreferenceDependentJob(session: partial.session,
            receipt: XCTUnwrap(view.validatedReceipt), request: partial.request, kind: .cloudPush,
            capturedToken: token, permit: partial.permit)
        XCTAssertFalse(deleted)
        let after = try await dependentSnapshot(partial); XCTAssertEqual(after, before)

        let held = try await fixture(), oldReceipt = try await dependentReceipt(held, rescore: false)
        let heldToken = try await held.store.markJobOwed(kind: "healthWriteback")
        try await insert(held, start: 1, notes: String(repeating: "x", count: 65536))
        let hold = try await finish(held, lease: scanLease(held, markJob: false))
        XCTAssertEqual(hold.disposition, .held(.oversizedRow)); XCTAssertNil(hold.validatedReceipt)
        let heldBefore = try await dependentSnapshot(held)
        let paid = try await held.store.settleWorkoutPreferenceDependentJob(session: held.session, receipt: oldReceipt,
            request: held.request, kind: .healthWriteback, capturedToken: heldToken, permit: held.permit)
        XCTAssertFalse(paid)
        let heldAfter = try await dependentSnapshot(held); XCTAssertEqual(heldAfter, heldBefore)
    }

    func testDependentSettlementNeedsCurrentReceiptAfterRescoreSettlementAdvancedHead() async throws {
        let f = try await fixture()
        let complete = try await finish(f, lease: scanLease(f))
        let old = try XCTUnwrap(complete.validatedReceipt)
        let paid = try await f.store.settleWorkoutPreferenceRescoreJob(session: f.session, receipt: old,
            request: f.request, capturedToken: XCTUnwrap(old.receipt.coreWitness.capturedRescoreJobToken), permit: f.permit)
        XCTAssertTrue(paid)
        let token = try await f.store.markJobOwed(kind: "cloudPush")
        let before = try await dependentSnapshot(f)
        let stale = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: old,
            request: f.request, kind: .cloudPush, capturedToken: token, permit: f.permit)
        XCTAssertFalse(stale)
        let unchanged = try await dependentSnapshot(f); XCTAssertEqual(unchanged, before)
        let current = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 0)
        let fresh = try XCTUnwrap(current.validatedReceipt)
        XCTAssertNotEqual(fresh.head, old.head)
        let settled = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: fresh,
            request: f.request, kind: .cloudPush, capturedToken: token, permit: f.permit)
        XCTAssertTrue(settled)
    }

    func testDependentSettlementCannotBorrowWarmReceiptIntoUnvalidatedSameStoreSession() async throws {
        let f = try await fixture()
        try await many(f, count: 129)
        let receipt = try await dependentReceipt(f)
        let token = try await f.store.markJobOwed(kind: "cloudPush")
        let session = try await f.store.openWorkoutPreferenceEvaluation(owner: f.request.owner, runtimeFence: f.runtime)
        let cold = Fixture(store: f.store, session: session, runtime: f.runtime, permit: f.permit,
                           request: f.request, target: f.target)
        let before = try await dependentSnapshot(cold)
        let denied = try await cold.store.settleWorkoutPreferenceDependentJob(session: session, receipt: receipt,
            request: f.request, kind: .cloudPush, capturedToken: token, permit: f.permit)
        XCTAssertFalse(denied)
        let unchanged = try await dependentSnapshot(cold); XCTAssertEqual(unchanged, before)
        let view = try await cold.store.inspectWorkoutPreferenceEvaluation(session: session, request: f.request, now: 0)
        XCTAssertEqual(view.disposition, .needsValidation)
        let proved = try await finish(cold, lease: XCTUnwrap(view.lease))
        XCTAssertEqual(proved.disposition, .complete)
        let settled = try await cold.store.settleWorkoutPreferenceDependentJob(session: session,
            receipt: XCTUnwrap(proved.validatedReceipt), request: f.request,
            kind: .cloudPush, capturedToken: token, permit: f.permit)
        XCTAssertTrue(settled)
    }

    func testDependentSettlementAfterRealReopenRequiresNewInstanceValidatedReceipt() async throws {
        let directory = try directory("workout-export-reopen")
        defer { try? FileManager.default.removeItem(at: directory) }
        let req = try request(), path = directory.appendingPathComponent("account.sqlite").path
        let original = try await fixture(path: path, request: req)
        defer { try? original.store.registryWriter.close() }
        try await many(original, count: 129)
        let receipt = try await dependentReceipt(original)
        let token = try await original.store.markJobOwed(kind: "healthWriteback")
        try await original.store.checkpointWAL(); try original.store.registryWriter.close()
        let cold = try await fixture(path: path, request: req)
        defer { try? cold.store.registryWriter.close() }
        let before = try await dependentSnapshot(cold)
        let denied = try await cold.store.settleWorkoutPreferenceDependentJob(session: cold.session, receipt: receipt,
            request: req, kind: .healthWriteback, capturedToken: token, permit: cold.permit)
        XCTAssertFalse(denied)
        let unchanged = try await dependentSnapshot(cold); XCTAssertEqual(unchanged, before)
        let view = try await cold.store.inspectWorkoutPreferenceEvaluation(session: cold.session, request: req, now: 0)
        XCTAssertEqual(view.head, receipt.head); XCTAssertEqual(view.disposition, .needsValidation)
        let proved = try await finish(cold, lease: XCTUnwrap(view.lease))
        XCTAssertEqual(proved.disposition, .complete)
        let stillForeign = try await cold.store.settleWorkoutPreferenceDependentJob(session: cold.session, receipt: receipt,
            request: req, kind: .healthWriteback, capturedToken: token, permit: cold.permit)
        XCTAssertFalse(stillForeign)
        let settled = try await cold.store.settleWorkoutPreferenceDependentJob(session: cold.session,
            receipt: XCTUnwrap(proved.validatedReceipt), request: req,
            kind: .healthWriteback, capturedToken: token, permit: cold.permit)
        XCTAssertTrue(settled)
    }

    func testDependentSettlementRefusesCopiedMatchingHeadWithChangedMembership() async throws {
        let directory = try directory("workout-export-copy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let req = try request(), path = directory.appendingPathComponent("original.sqlite").path
        let original = try await fixture(path: path, request: req)
        defer { try? original.store.registryWriter.close() }
        try await insert(original, start: 1, notes: "original\0bytes")
        let receipt = try await dependentReceipt(original)
        let token = try await original.store.markJobOwed(kind: "widgetPublish")
        try await original.store.checkpointWAL(); try original.store.registryWriter.close()
        let copiedPath = directory.appendingPathComponent("copied.sqlite").path
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            try FileManager.default.copyItem(atPath: path + suffix, toPath: copiedPath + suffix)
        }
        let copied = try await fixture(path: copiedPath, request: req)
        defer { try? copied.store.registryWriter.close() }
        try await copied.store.registryWriter.write { db in
            try db.execute(sql: "UPDATE workout SET notes=CAST(? AS TEXT)", arguments: [Data("changed\0bytes".utf8)])
            try db.execute(sql: "UPDATE workoutPreferenceEvaluation SET workoutRevision=?", arguments: [receipt.head.workoutRevision])
        }
        let before = try await dependentSnapshot(copied)
        let denied = try await copied.store.settleWorkoutPreferenceDependentJob(session: copied.session, receipt: receipt,
            request: req, kind: .widgetPublish, capturedToken: token, permit: copied.permit)
        XCTAssertFalse(denied)
        let unchanged = try await dependentSnapshot(copied); XCTAssertEqual(unchanged, before)
        let view = try await copied.store.inspectWorkoutPreferenceEvaluation(session: copied.session, request: req, now: 0)
        XCTAssertEqual(view.head, receipt.head); XCTAssertEqual(view.disposition, .needsValidation)
        let rejected = try await finish(copied, lease: XCTUnwrap(view.lease))
        XCTAssertEqual(rejected.disposition, .needsCorePass); XCTAssertNil(rejected.validatedReceipt)
        let afterProof = try await dependentSnapshot(copied)
        let again = try await copied.store.settleWorkoutPreferenceDependentJob(session: copied.session, receipt: receipt,
            request: req, kind: .widgetPublish, capturedToken: token, permit: copied.permit)
        XCTAssertFalse(again)
        let final = try await dependentSnapshot(copied); XCTAssertEqual(final, afterProof)
        XCTAssertEqual(final.jobs, before.jobs); XCTAssertEqual(final.workouts, before.workouts)
    }

    func testDependentSettlementPermitRevocationAfterDeleteBeforeCommitRollsBackExactJob() async throws {
        let f = try await fixture(), receipt = try await dependentReceipt(f)
        let token = try await f.store.markJobOwed(kind: "cloudPush")
        let before = try await dependentSnapshot(f)
        try await f.store.registryWriter.write { db in
            db.add(function: DatabaseFunction("revokeDependentPermit", argumentCount: 0, pure: false) { _ in
                f.permit.invalidate(); return nil
            })
            try db.execute(sql: "CREATE TEMP TRIGGER revokeDependent AFTER DELETE ON syncJob WHEN OLD.kind='cloudPush' BEGIN SELECT revokeDependentPermit(); END")
        }
        await failed(.retired) {
            _ = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
                request: f.request, kind: .cloudPush, capturedToken: token, permit: f.permit)
        }
        let after = try await dependentSnapshot(f); XCTAssertEqual(after, before)
        XCTAssertTrue(f.runtime.isValid)
        try await f.store.registryWriter.write { try $0.execute(sql: "DROP TRIGGER revokeDependent") }
        _ = try await f.store.markJobOwed(kind: "widgetPublish") // No account-wide fence poisoning.
        let jobs = try await f.store.owedJobs()
        XCTAssertEqual(jobs.first { $0.kind == "cloudPush" }?.token, token)
        XCTAssertTrue(jobs.contains { $0.kind == "widgetPublish" })
    }

    func testDependentSettlementSqlFailureAfterDeleteRollsBackAndOriginalReceiptCanRetry() async throws {
        let f = try await fixture(), receipt = try await dependentReceipt(f)
        let token = try await f.store.markJobOwed(kind: "cloudPush")
        let before = try await dependentSnapshot(f)
        try await f.store.registryWriter.write {
            try $0.execute(sql: "CREATE TEMP TRIGGER failDependent AFTER DELETE ON syncJob WHEN OLD.kind='cloudPush' BEGIN SELECT RAISE(ABORT,'synthetic export settlement failure'); END")
        }
        do {
            _ = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
                request: f.request, kind: .cloudPush, capturedToken: token, permit: f.permit)
            XCTFail("SQL fault was swallowed")
        } catch { XCTAssertTrue(error is DatabaseError, "\(error)") }
        let after = try await dependentSnapshot(f); XCTAssertEqual(after, before)
        try await f.store.registryWriter.write { try $0.execute(sql: "DROP TRIGGER failDependent") }
        let retried = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
            request: f.request, kind: .cloudPush, capturedToken: token, permit: f.permit)
        XCTAssertTrue(retried)
    }

    func testDependentSettlementPrecancelledTaskRetainsExactJob() async throws {
        let f = try await fixture(), receipt = try await dependentReceipt(f)
        let token = try await f.store.markJobOwed(kind: "cloudPush"), before = try await dependentSnapshot(f)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
                request: f.request, kind: .cloudPush, capturedToken: token, permit: f.permit)
        }
        do { _ = try await task.value; XCTFail("cancelled export settled") }
        catch { XCTAssertTrue(error is CancellationError) }
        let after = try await dependentSnapshot(f); XCTAssertEqual(after, before)
    }

    private final class DependentCancellationHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Bool, Error>?
        func install(_ task: Task<Bool, Error>?) { lock.lock(); self.task = task; lock.unlock() }
        func cancel() { lock.lock(); let captured = task; lock.unlock(); captured?.cancel() }
    }

    func testDependentSettlementTaskCancellationAfterDeleteIsCaughtAtCommit() async throws {
        let f = try await fixture(), receipt = try await dependentReceipt(f)
        let token = try await f.store.markJobOwed(kind: "cloudPush"), before = try await dependentSnapshot(f)
        let handle = DependentCancellationHandle()
        try await f.store.registryWriter.write { db in
            db.add(function: DatabaseFunction("cancelDependentTask", argumentCount: 0, pure: false) { _ in
                handle.cancel(); return nil
            })
            try db.execute(sql: "CREATE TEMP TRIGGER cancelDependent AFTER DELETE ON syncJob WHEN OLD.kind='cloudPush' BEGIN SELECT cancelDependentTask(); END")
        }
        let start = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in start.stream { break }
            return try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
                request: f.request, kind: .cloudPush, capturedToken: token, permit: f.permit)
        }
        handle.install(task)
        defer { handle.install(nil) }
        start.continuation.yield(()); start.continuation.finish()
        do { _ = try await task.value; XCTFail("mid-transaction cancellation settled export") }
        catch { XCTAssertEqual(error as? E.Failure, .cancelled) }
        let after = try await dependentSnapshot(f); XCTAssertEqual(after, before)
        try await f.store.registryWriter.write { try $0.execute(sql: "DROP TRIGGER cancelDependent") }
        XCTAssertTrue(f.runtime.isValid)
    }

    func testDependentSettlementRetiredSessionOrRuntimeCannotDeleteDebt() async throws {
        for retireSession in [true, false] {
            let f = try await fixture(), receipt = try await dependentReceipt(f)
            let token = try await f.store.markJobOwed(kind: "cloudPush"), before = try await dependentSnapshot(f)
            if retireSession { f.session.invalidate() } else { f.runtime.invalidate() }
            await failed(.retired) {
                _ = try await f.store.settleWorkoutPreferenceDependentJob(session: f.session, receipt: receipt,
                    request: f.request, kind: .cloudPush, capturedToken: token, permit: f.permit)
            }
            let after = try await dependentSnapshot(f); XCTAssertEqual(after, before)
        }
    }

    private func persistedProgress(_ f: Fixture) async throws -> Data {
        try await f.store.registryWriter.read { db in
            let bytes = try XCTUnwrap(Data.fetchOne(db, sql: "SELECT stateBytes FROM workoutPreferenceEvaluation"))
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            return try JSONSerialization.data(withJSONObject: XCTUnwrap(state["progress"]), options: [.sortedKeys])
        }
    }

    private func assertFailedColdValidationRemainsUntrusted(partialPrefix: Bool) async throws {
        let directory = try directory("workout-failed-cold-proof")
        defer { try? FileManager.default.removeItem(at: directory) }
        let req = try request(), originalPath = directory.appendingPathComponent("original.sqlite").path
        let original = try await fixture(path: originalPath, request: req)
        defer { try? original.store.registryWriter.close() }
        try await many(original, count: partialPrefix ? 300 : 1)
        let scan = try await scanLease(original)
        let saved: E.View
        if partialPrefix {
            let first = try await original.store.advanceWorkoutPreferenceEvaluation(session: original.session,
                lease: scan, permit: original.permit)
            XCTAssertEqual(first.rowsProcessed, 128)
            let second = try await original.store.advanceWorkoutPreferenceEvaluation(session: original.session,
                lease: XCTUnwrap(first.view.lease), permit: original.permit)
            XCTAssertEqual(second.rowsProcessed, 128)
            saved = second.view
            XCTAssertEqual(saved.disposition, .continuation)
            XCTAssertNil(saved.validatedReceipt)
        } else {
            saved = try await finish(original, lease: scan)
            XCTAssertEqual(saved.disposition, .complete)
            XCTAssertNotNil(saved.validatedReceipt)
        }
        let savedCount: Int64 = partialPrefix ? 256 : 1
        XCTAssertEqual(saved.counts.totalRows, savedCount)
        let progress = try await persistedProgress(original)
        let token = try XCTUnwrap(saved.lease?.rescoreJobToken)
        try await original.store.checkpointWAL()
        try original.store.registryWriter.close()
        let copiedPath = directory.appendingPathComponent("copied.sqlite").path
        // Closed SQLite file-set copy, not a main-file-only backup installer claim.
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: originalPath + suffix) {
            try FileManager.default.copyItem(atPath: originalPath + suffix, toPath: copiedPath + suffix)
        }
        let modified = try await fixture(path: copiedPath, request: req)
        defer { try? modified.store.registryWriter.close() }
        let oversizedNotes = Data(repeating: 0x78, count: 65536)
        try await modified.store.registryWriter.write { db in
            // A disposable restored-content mismatch with the same UUID/revision. Ordinary
            // trigger-covered application writes do not preserve this revision.
            try db.execute(sql: "UPDATE workout SET notes=CAST(? AS TEXT) WHERE startTs=?",
                           arguments: [oversizedNotes, partialPrefix ? 129 : 1])
            try db.execute(sql: "UPDATE workoutPreferenceEvaluation SET workoutRevision=?",
                           arguments: [saved.head.workoutRevision])
        }
        let changedRows = try await workoutBytes(modified)
        try await modified.store.checkpointWAL()
        try modified.store.registryWriter.close()

        func proveHeld(_ cold: Fixture, lease: E.Lease) async throws -> E.View {
            var step = try await cold.store.advanceWorkoutPreferenceEvaluation(session: cold.session,
                lease: lease, permit: cold.permit)
            if partialPrefix {
                // A new attempt must re-read the first valid page, not reuse incomplete
                // session proof or skip directly past the persisted 256-row cursor.
                XCTAssertEqual(step.rowsProcessed, 128)
                XCTAssertEqual(step.view.disposition, .needsValidation)
                XCTAssertNil(step.view.validatedReceipt)
                if step.view.disposition == .needsValidation {
                    step = try await cold.store.advanceWorkoutPreferenceEvaluation(session: cold.session,
                        lease: XCTUnwrap(step.view.lease), permit: cold.permit)
                }
            }
            XCTAssertEqual(step.rowsProcessed, 0)
            XCTAssertEqual(step.view.disposition, .held(.oversizedRow))
            XCTAssertEqual(step.view.counts.totalRows, savedCount)
            XCTAssertNil(step.view.validatedReceipt)
            XCTAssertFalse(step.view.membershipComplete)
            XCTAssertFalse(step.view.hasRunnableWork(at: Int64.max))
            // On the unrepaired source, try the falsely issued receipt rather than merely
            // rejecting a receipt from the original, different Store instance.
            if let receipt = step.view.validatedReceipt {
                let settled = try await cold.store.settleWorkoutPreferenceRescoreJob(session: cold.session,
                    receipt: receipt, request: req, capturedToken: token, permit: cold.permit)
                XCTAssertFalse(settled, "failed cold proof must never authorize job deletion")
            }
            let jobs = try await cold.store.owedJobs()
            XCTAssertEqual(jobs.count, 1); XCTAssertEqual(jobs.first?.token, token)
            let currentProgress = try await persistedProgress(cold)
            XCTAssertEqual(currentProgress, progress, "a failed proof must retain the original durable prefix")
            let currentRows = try await workoutBytes(cold)
            XCTAssertEqual(currentRows, changedRows)
            let bytes = try await cold.store.registryWriter.read {
                try Data.fetchOne($0, sql: "SELECT CAST(notes AS BLOB) FROM workout WHERE startTs=?",
                                  arguments: [partialPrefix ? 129 : 1])
            }
            XCTAssertEqual(bytes, oversizedNotes)
            return step.view
        }

        let cold = try await fixture(path: copiedPath, request: req)
        defer { try? cold.store.registryWriter.close() }
        let initial = try await cold.store.inspectWorkoutPreferenceEvaluation(session: cold.session, request: req, now: 0)
        XCTAssertEqual(initial.head, saved.head)
        XCTAssertEqual(initial.disposition, .needsValidation)
        var held = try await proveHeld(cold, lease: XCTUnwrap(initial.lease))
        for _ in 0..<2 {
            let retry = try await cold.store.admitWorkoutPreferenceEvaluation(session: cold.session, expected: held.head,
                target: XCTUnwrap(held.lease).target, permit: cold.permit, mode: .explicitRetry)
            XCTAssertEqual(retry.evaluationID, saved.lease?.evaluationID)
            XCTAssertEqual(retry.rescoreJobToken, token)
            let untrusted = try await cold.store.inspectWorkoutPreferenceEvaluation(session: cold.session, request: req, now: 0)
            XCTAssertEqual(untrusted.disposition, .needsValidation)
            XCTAssertNil(untrusted.validatedReceipt)
            held = try await proveHeld(cold, lease: retry)
        }
        try await cold.store.checkpointWAL()
        try cold.store.registryWriter.close()
        let reopened = try await fixture(path: copiedPath, request: req)
        defer { try? reopened.store.registryWriter.close() }
        let persisted = try await reopened.store.inspectWorkoutPreferenceEvaluation(session: reopened.session, request: req, now: 0)
        XCTAssertEqual(persisted.head, held.head)
        XCTAssertEqual(persisted.disposition, .held(.oversizedRow))
        XCTAssertNil(persisted.validatedReceipt)
        let retry = try await reopened.store.admitWorkoutPreferenceEvaluation(session: reopened.session, expected: persisted.head,
            target: XCTUnwrap(persisted.lease).target, permit: reopened.permit, mode: .explicitRetry)
        let untrusted = try await reopened.store.inspectWorkoutPreferenceEvaluation(session: reopened.session, request: req, now: 0)
        XCTAssertEqual(untrusted.disposition, .needsValidation)
        _ = try await proveHeld(reopened, lease: retry)
    }

    func testColdCopiedSealedOversizedRowCannotBecomeTrustedAfterExplicitRetry() async throws {
        try await assertFailedColdValidationRemainsUntrusted(partialPrefix: false)
    }

    func testColdCopiedPartialPrefixOversizedRowCannotSkipProofAfterExplicitRetry() async throws {
        try await assertFailedColdValidationRemainsUntrusted(partialPrefix: true)
    }

    private func withWriter(_ writer: String, request: E.Request) throws -> E.Request {
        try .init(owner: request.owner, preference: request.preference, canonicalWriter: writer,
                  requestedDays: request.requestedDays, localDayAnchor: request.localDayAnchor,
                  timezoneID: request.timezoneID, offsetSeconds: request.offsetSeconds,
                  dependencyDigest: request.dependencyDigest)
    }

    private func unicodeRowIdentityControl(ownerAlias: Bool) async throws {
        let canonical = "caf\u{00E9}", alias = "cafe\u{0301}"
        let computed = canonical + "-noop", aliasComputed = alias + "-noop"
        XCTAssertEqual(canonical, alias) // Swift equivalence is deliberately NOT SQL identity.
        XCTAssertNotEqual(Data(canonical.utf8), Data(alias.utf8))
        for differentBytes in [true, false] {
            let req = try withWriter(canonical, request: request())
            let f = try await fixture(request: req)
            let device = differentBytes && ownerAlias ? aliasComputed : computed
            let source = differentBytes && !ownerAlias ? aliasComputed : computed
            try await insert(f, start: 1, device: device, sport: "detected", source: source,
                             notes: "original\0payload")
            let before = try await workoutBytes(f)
            let lease = try await admitted(f)
            // The source-alias case is a protected natural-key conflict. For the owner-alias
            // case, deletion-only must leave that other BINARY owner untouched.
            let rows = differentBytes && ownerAlias ? [] : [generated(start: 1, source: computed)]
            let changes = try await f.store.replaceManagedDetectedWorkouts(session: f.session, lease: lease,
                rows: rows, permit: f.permit)
            XCTAssertEqual(changes, differentBytes ? 0 : 2)
            let after = try await workoutBytes(f)
            if differentBytes { XCTAssertEqual(after, before) }
            let identities = try await f.store.registryWriter.read { db in
                try Row.fetchAll(db, sql: "SELECT CAST(deviceId AS BLOB) AS ownerBytes,CAST(source AS BLOB) AS sourceBytes FROM workout")
            }
            XCTAssertEqual(identities.count, 1)
            let identity = try XCTUnwrap(identities.first)
            XCTAssertEqual(identity["ownerBytes"] as Data, Data(device.utf8))
            XCTAssertEqual(identity["sourceBytes"] as Data, Data(source.utf8))
            let done = try await finish(f, lease: recordCore(f, lease: lease))
            XCTAssertEqual(done.counts.totalRows, 1)
            XCTAssertEqual(done.counts.managedDetected, differentBytes ? 0 : 1)
            XCTAssertEqual(done.counts.unknownSource, differentBytes ? 1 : 0)
            XCTAssertEqual(done.disposition, differentBytes ? .evaluatedPartial : .complete)
            let settled = try await f.store.settleWorkoutPreferenceRescoreJob(session: f.session,
                receipt: XCTUnwrap(done.validatedReceipt), request: req,
                capturedToken: XCTUnwrap(lease.rescoreJobToken), permit: f.permit)
            XCTAssertEqual(settled, !differentBytes)
            let jobs = try await f.store.owedJobs()
            XCTAssertEqual(jobs.count, differentBytes ? 1 : 0)
        }
    }

    func testUnicodeSourceAliasConflictRetainedAndExactSourceManaged() async throws {
        try await unicodeRowIdentityControl(ownerAlias: false)
    }

    func testUnicodeOwnerAliasRetainedAndExactOwnerManaged() async throws {
        try await unicodeRowIdentityControl(ownerAlias: true)
    }

    func testUnicodeWriterCompatibilityRequiresExactBytesNotCanonicalEquivalence() async throws {
        let req = try withWriter("caf\u{00E9}", request: request())
        let f = try await fixture(request: req)
        let complete = try await finish(f, lease: scanLease(f))
        let oldLease = try XCTUnwrap(complete.lease), receipt = try XCTUnwrap(complete.validatedReceipt)
        let identical = try withWriter("caf\u{00E9}", request: req)
        let reusable = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: identical, now: 0)
        XCTAssertEqual(reusable.disposition, .complete)
        XCTAssertEqual(reusable.validatedReceipt?.receipt.digest, receipt.receipt.digest)
        let reused = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: complete.head,
            target: f.target, permit: f.permit)
        XCTAssertEqual(reused.evaluationID, oldLease.evaluationID); XCTAssertEqual(reused.head, oldLease.head)

        let distinct = try withWriter("cafe\u{0301}", request: req)
        let target = try E.Target(request: distinct, lowerTs: f.target.lowerTs, upperTs: f.target.upperTs)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertNotEqual(try encoder.encode(target), try encoder.encode(f.target))
        XCTAssertNotEqual(try target.digest, try f.target.digest)
        let invalidated = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: distinct, now: 0)
        XCTAssertEqual(invalidated.disposition, .needsCorePass)
        XCTAssertNil(invalidated.lease); XCTAssertNil(invalidated.validatedReceipt)
        let borrowed = try await f.store.settleWorkoutPreferenceRescoreJob(session: f.session, receipt: receipt,
            request: distinct, capturedToken: XCTUnwrap(oldLease.rescoreJobToken), permit: f.permit)
        XCTAssertFalse(borrowed)
        let fresh = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: invalidated.head,
            target: target, permit: f.permit)
        XCTAssertNotEqual(fresh.evaluationID, oldLease.evaluationID)
        XCTAssertEqual(Data(fresh.target.request.canonicalWriter.utf8), Data(distinct.canonicalWriter.utf8))
        XCTAssertEqual(try fresh.target.digest, try target.digest)
        let pending = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: distinct, now: 0)
        XCTAssertEqual(pending.disposition, .needsCorePass); XCTAssertNil(pending.validatedReceipt)
        await failed(.staleHead) { _ = try await self.recordCore(f, lease: oldLease) }
        let jobs = try await f.store.owedJobs(); XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.token, oldLease.rescoreJobToken)
    }

    func testExplicitRetryAfterNewJobAndTimeAdvanceCreatesCoreLeaseWithOriginalBounds() async throws {
        let f = try await fixture()
        try await insert(f, start: 1)
        let complete = try await finish(f, lease: scanLease(f))
        let oldLease = try XCTUnwrap(complete.lease), oldReceipt = try XCTUnwrap(complete.validatedReceipt)
        let originalRows = try await workoutBytes(f)
        let newToken = try await f.store.markJobOwed(kind: "rescore")
        XCTAssertNotEqual(newToken, oldLease.rescoreJobToken)
        let nowTarget = try E.Target(request: f.request, lowerTs: 100, upperTs: f.target.upperTs + 100)
        let current = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 100)
        XCTAssertEqual(current.disposition, .needsCorePass); XCTAssertNil(current.validatedReceipt)
        let fresh = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: current.head,
            target: nowTarget, permit: f.permit, mode: .explicitRetry)
        XCTAssertNotEqual(fresh.evaluationID, oldLease.evaluationID)
        XCTAssertGreaterThan(fresh.head.stateSerial, oldLease.head.stateSerial)
        XCTAssertEqual(fresh.target, oldLease.target); XCTAssertNotEqual(fresh.target, nowTarget)
        XCTAssertEqual(try fresh.target.digest, try oldLease.target.digest)
        XCTAssertEqual(fresh.rescoreJobToken, newToken)
        let pending = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 100)
        XCTAssertEqual(pending.disposition, .needsCorePass); XCTAssertNil(pending.validatedReceipt)
        XCTAssertEqual(pending.counts.totalRows, 0)
        await failed(.staleHead) { _ = try await self.recordCore(f, lease: oldLease) }
        await failed(.staleHead) {
            _ = try await f.store.advanceWorkoutPreferenceEvaluation(session: f.session, lease: oldLease, permit: f.permit)
        }
        await failed(.staleHead) {
            _ = try await f.store.replaceManagedDetectedWorkouts(session: f.session, lease: oldLease,
                rows: [self.generated(start: 2)], permit: f.permit)
        }
        for token in [try XCTUnwrap(oldLease.rescoreJobToken), newToken] {
            let settled = try await f.store.settleWorkoutPreferenceRescoreJob(session: f.session, receipt: oldReceipt,
                request: f.request, capturedToken: token, permit: f.permit)
            XCTAssertFalse(settled)
        }
        let unchanged = try await workoutBytes(f); XCTAssertEqual(unchanged, originalRows)
        let jobs = try await f.store.owedJobs(); XCTAssertEqual(jobs.count, 1); XCTAssertEqual(jobs.first?.token, newToken)
        let finished = try await finish(f, lease: recordCore(f, lease: fresh))
        XCTAssertEqual(finished.disposition, .complete); XCTAssertEqual(finished.counts.totalRows, 1)
        let settled = try await f.store.settleWorkoutPreferenceRescoreJob(session: f.session,
            receipt: XCTUnwrap(finished.validatedReceipt), request: f.request, capturedToken: newToken, permit: f.permit)
        XCTAssertTrue(settled)
        let remaining = try await f.store.owedJobs(); XCTAssertTrue(remaining.isEmpty)
    }

    func testExplicitRetryAfterRevisionInvalidationRetainsBoundsAndRejectsOldCapabilities() async throws {
        let f = try await fixture()
        let complete = try await finish(f, lease: scanLease(f))
        let oldLease = try XCTUnwrap(complete.lease), oldReceipt = try XCTUnwrap(complete.validatedReceipt)
        try await insert(f, start: 1)
        let originalRows = try await workoutBytes(f)
        let nowTarget = try E.Target(request: f.request, lowerTs: 100, upperTs: f.target.upperTs + 100)
        let current = try await f.store.inspectWorkoutPreferenceEvaluation(session: f.session, request: f.request, now: 100)
        XCTAssertEqual(current.disposition, .needsCorePass)
        let fresh = try await f.store.admitWorkoutPreferenceEvaluation(session: f.session, expected: current.head,
            target: nowTarget, permit: f.permit, mode: .explicitRetry)
        XCTAssertNotEqual(fresh.evaluationID, oldLease.evaluationID)
        XCTAssertGreaterThan(fresh.head.workoutRevision, oldLease.head.workoutRevision)
        XCTAssertEqual(fresh.target, oldLease.target); XCTAssertNotEqual(fresh.target, nowTarget)
        XCTAssertEqual(fresh.rescoreJobToken, oldLease.rescoreJobToken)
        await failed(.staleHead) { _ = try await self.recordCore(f, lease: oldLease) }
        let settled = try await f.store.settleWorkoutPreferenceRescoreJob(session: f.session, receipt: oldReceipt,
            request: f.request, capturedToken: XCTUnwrap(fresh.rescoreJobToken), permit: f.permit)
        XCTAssertFalse(settled)
        let unchanged = try await workoutBytes(f); XCTAssertEqual(unchanged, originalRows)
        let done = try await finish(f, lease: recordCore(f, lease: fresh))
        XCTAssertEqual(done.disposition, .complete); XCTAssertEqual(done.counts.totalRows, 1)
        let jobs = try await f.store.owedJobs(); XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.token, fresh.rescoreJobToken)
    }

    func testLosslessCursorCastPredicatesKeepIndexedOrder() async throws {
        let f = try await fixture()
        try await seedNulCursor(f, sportKey: false)
        let details = try await f.store.registryWriter.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT rowid,typeof(notes),length(CAST(notes AS BLOB)) FROM workout
                WHERE startTs>=0 AND startTs<=1814400
                AND (startTs,deviceId COLLATE BINARY,sport COLLATE BINARY)>(?,CAST(? AS TEXT),CAST(? AS TEXT))
                AND (startTs,deviceId COLLATE BINARY,sport COLLATE BINARY)<=(?,CAST(? AS TEXT),CAST(? AS TEXT))
                ORDER BY startTs,deviceId COLLATE BINARY,sport COLLATE BINARY LIMIT 129
                """, arguments: [100, Data("a\0b".utf8), Data("z".utf8), 100, Data("b".utf8), Data("z".utf8)])
                .map { $0["detail"] as String }
        }
        XCTAssertTrue(details.contains { $0.contains("workout_preference_window_v1") }, details.joined(separator: "; "))
        XCTAssertFalse(details.contains { $0.contains("TEMP B-TREE") }, details.joined(separator: "; "))
    }
}
