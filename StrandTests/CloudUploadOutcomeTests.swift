import Foundation
import XCTest
import NoopPush
#if canImport(CloudUploadHarness)
@testable import CloudUploadHarness
#else
@testable import Strand
#endif

final class CloudUploadOutcomeTests: XCTestCase {
    private let endpoint = "https://project.example/functions/v1/push"
    private let receiver = "synthetic-receiver"

    private struct Fixture {
        let root: URL
        let context: AccountSessionContext
        let layout: AccountStorageLayout
        let journal: CloudUploadJournal
        let batch: PushBatch
        let job: CloudUploadJob
    }

    private func fixture() throws -> Fixture {
        let base: URL
        if let path = ProcessInfo.processInfo.environment["NARA_TEST_FIXTURE_ROOT"] {
            var isDirectory: ObjCBool = false
            guard path.hasPrefix("/"), !path.utf8.contains(0),
                  FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw NSError(domain: "NARATestFixtureRoot", code: 1)
            }
            base = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            base = FileManager.default.temporaryDirectory
        }
        let root = base.appendingPathComponent("cloud-outcome-" + UUID().uuidString, isDirectory: true)
        let scope = try AccountScope(projectURL: "https://project.example",
            userID: "11111111-1111-4111-8111-111111111111")
        let context = AccountSessionContext(scope: scope, generation: UUID())
        let layout = AccountStorageLayout(baseDirectory: root, scope: scope)
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory)
        let batch = try PushProtocol.appendBatch(table: .battery,
            sourceId: "22222222-2222-4222-8222-222222222222", deviceId: "synthetic-device",
            startCursor: nil, records: [.init(rowId: 1, key: ["ts": .int(1_800_000_000)],
                data: ["soc": .int(50), "mv": .null, "charging": .null])])
        var job = CloudUploadJob(id: AccountScope.digest("outcome-test-" + batch.batchId),
            owner: scope, generation: context.generation, endpoint: endpoint, deviceID: batch.deviceId,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), operation: .request,
            method: "POST", headers: ["Content-Type": "application/x-ndjson"])
        job.batchID = batch.batchId
        job.receiverStateID = receiver
        try journal.persistBody(batch.body, job: &job)
        try journal.save(job)
        return .init(root: root, context: context, layout: layout, journal: journal, batch: batch, job: job)
    }

    private func queue(_ f: Fixture, adapter: OutcomeSessionAdapter, clock: OutcomeClock,
                       context: AccountSessionContext? = nil, randomUnit: Double = 0.25,
                       current: @escaping CloudUploadQueue.Current = { _ in true },
                       control: @escaping @Sendable (URLRequest) async throws -> PushTransportResponse = { _ in throw CloudUploadError.unavailable },
                       journalWriteObserver: (@Sendable (URL) throws -> Void)? = nil,
                       refresh: (@Sendable (AccountSessionContext) async throws -> Void)? = nil) throws -> CloudUploadQueue {
        try CloudUploadQueue(context: context ?? f.context, layout: f.layout, adapter: adapter,
            authorize: { _ in "synthetic-token" }, isCurrent: current,
            policy: { .init(concurrency: 1, allowsCellular: false, allowsConstrained: false) },
            control: control, now: { clock.value }, journalWriteObserver: journalWriteObserver,
            randomUnit: { randomUnit }, refreshCredentials: refresh)
    }

    private func errorBody(_ code: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "error", "protocolVersion": "1.0", "code": code])
    }

    private func legacyAck(_ batch: PushBatch) throws -> Data {
        let cursor: Any = batch.endCursor.map {
            ["rowId": $0.rowId, "keySha256": $0.naturalKeyFingerprint] as [String: Any]
        } ?? NSNull()
        return try JSONSerialization.data(withJSONObject: [
            "protocolVersion": batch.protocolVersion,
            "batchId": batch.batchId,
            "stream": batch.table.wireName,
            "deviceId": batch.deviceId,
            "endCursor": cursor,
            "acceptedRows": batch.recordCount,
            "status": "accepted",
        ])
    }

    private func durableAck(_ batch: PushBatch, owner: AccountScope) throws -> Data {
        let cursor: Any = batch.endCursor.map {
            ["rowId": $0.rowId, "keySha256": $0.naturalKeyFingerprint] as [String: Any]
        } ?? NSNull()
        let canonicalDevice = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let receipt: [String: Any] = [
            "version": 1, "state": "verified_indexed",
            "receiptId": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "ownerUserId": owner.userID, "deviceId": canonicalDevice,
            "objectId": batch.batchId, "batchId": batch.batchId, "sourceId": batch.sourceId,
            "stream": batch.table.wireName,
            "schemaVersion": PushProtocol.schemaVersion(stream: batch.table.wireName,
                protocolVersion: batch.protocolVersion),
            "objectKey": "v3/core/users/\(owner.userID)/devices/\(canonicalDevice)/\(batch.table.wireName)/fixture/verified",
            "contentSha256": PushDurabilityReceipt.sha256(batch.body),
            "wireSha256": String(repeating: "a", count: 64),
            "compressedBytes": 128, "uncompressedBytes": batch.body.count,
            "verifiedAt": "2026-09-18T00:00:00Z", "indexedAt": "2026-09-18T00:00:01Z",
        ]
        return try JSONSerialization.data(withJSONObject: [
            "protocolVersion": batch.protocolVersion, "batchId": batch.batchId,
            "stream": batch.table.wireName, "deviceId": batch.deviceId,
            "endCursor": cursor, "acceptedRows": batch.recordCount, "status": "accepted",
            "durabilityReceipt": receipt,
        ])
    }

    private func persisted(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) throws -> CloudUploadJob {
        try XCTUnwrap(f.journal.load()[f.job.id], file: file, line: line)
    }

    private func assertSourceRetained(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let saved = try persisted(f, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: f.journal.bodyURL(saved)), f.batch.body, file: file, line: line)
        XCTAssertEqual(saved.payloadSHA256, f.job.payloadSHA256, file: file, line: line)
        XCTAssertFalse(saved.acknowledged, file: file, line: line)
        XCTAssertNil(saved.validatedReceipt, file: file, line: line)
    }

    func testTerminalHTTPOutcomesRemainPausedAfterRelaunch() async throws {
        for status in [400, 404, 409, 413, 422] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let clock = OutcomeClock()
            let adapter = OutcomeSessionAdapter()
            let q = try queue(f, adapter: adapter, clock: clock)
            try await q.reconcile()
            let task = try XCTUnwrap(adapter.last).task
            adapter.finish(task.identifier)
            let body = try errorBody("invalid_object_manifest")
            await q.receive(task, status: status, body: body, error: false)
            let saved = try persisted(f)
            XCTAssertEqual(saved.phase, .pausedTerminal, "status=\(status)")
            XCTAssertEqual(saved.responseStatus, status)
            XCTAssertEqual(saved.responseCode, "invalid_object_manifest")
            XCTAssertEqual(saved.responseBody, body)
            XCTAssertEqual(saved.failures, 1)
            XCTAssertNil(saved.nextAttemptAt)
            try assertSourceRetained(f)

            await q.suspend()
            clock.advance(by: 86_400)
            let relaunchedContext = AccountSessionContext(scope: f.context.scope, generation: UUID())
            let relaunchedAdapter = OutcomeSessionAdapter()
            let reopened = try queue(f, adapter: relaunchedAdapter, clock: clock, context: relaunchedContext)
            try await reopened.reconcile()
            try await reopened.reconcile()
            XCTAssertEqual(relaunchedAdapter.count, 0, "terminal job resumed without resolution")
            XCTAssertEqual(try persisted(f).phase, .pausedTerminal)
            XCTAssertEqual(try persisted(f).failures, 1)
            try assertSourceRetained(f)
        }
    }

    func testRetryAfterAndFailureCountSurviveDuplicateCallbackAndRelaunch() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let clock = OutcomeClock()
        let initialDate = clock.value
        let adapter = OutcomeSessionAdapter()
        let q = try queue(f, adapter: adapter, clock: clock)
        try await q.reconcile()
        let task = try XCTUnwrap(adapter.last).task
        adapter.finish(task.identifier)
        let body = try errorBody("rate_limited")
        await q.receive(task, status: 429, body: body, error: false, retryAfter: "120")
        let first = try persisted(f)
        let next = try XCTUnwrap(first.nextAttemptAt)
        XCTAssertEqual(first.phase, .retryPending)
        XCTAssertEqual(first.responseRetryAfter, "120")
        XCTAssertEqual(first.responseCode, "rate_limited")
        XCTAssertEqual(first.failures, 1)
        XCTAssertGreaterThanOrEqual(next.timeIntervalSince(initialDate), 120)

        clock.advance(by: 3)
        await q.receive(task, status: 429, body: body, error: false, retryAfter: "120")
        XCTAssertEqual(try persisted(f).failures, 1)
        XCTAssertEqual(try persisted(f).nextAttemptAt, next)
        try await q.reconcile()
        XCTAssertEqual(adapter.count, 1)
        await q.suspend()

        let reopenedAdapter = OutcomeSessionAdapter()
        let context = AccountSessionContext(scope: f.context.scope, generation: UUID())
        let reopened = try queue(f, adapter: reopenedAdapter, clock: clock, context: context)
        try await reopened.reconcile()
        XCTAssertEqual(reopenedAdapter.count, 0)
        XCTAssertEqual(try persisted(f).nextAttemptAt, next)
        XCTAssertEqual(try persisted(f).failures, 1)
        clock.set(next.addingTimeInterval(1))
        try await reopened.reconcile()
        XCTAssertEqual(reopenedAdapter.count, 1)
        try assertSourceRetained(f)
    }

    func testHTTPDateRetryAfterIsHonored() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let clock = OutcomeClock()
        let notBefore = clock.value.addingTimeInterval(300)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let header = formatter.string(from: notBefore)
        let adapter = OutcomeSessionAdapter()
        let q = try queue(f, adapter: adapter, clock: clock)
        try await q.reconcile()
        let task = try XCTUnwrap(adapter.last).task
        adapter.finish(task.identifier)
        await q.receive(task, status: 503, body: try errorBody("temporarily_unavailable"),
            error: false, retryAfter: header)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(persisted(f).nextAttemptAt), notBefore)
        XCTAssertEqual(try persisted(f).responseRetryAfter, header)
        XCTAssertEqual(try persisted(f).failures, 1)
    }

    func testTransientHTTPOutcomesRetryWithPersistedJitter() async throws {
        for status in [408, 500, 502, 503, 504] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let clock = OutcomeClock()
            let adapter = OutcomeSessionAdapter()
            let q = try queue(f, adapter: adapter, clock: clock, randomUnit: 0.25)
            try await q.reconcile()
            let task = try XCTUnwrap(adapter.last).task
            adapter.finish(task.identifier)
            await q.receive(task, status: status, body: try errorBody("temporarily_unavailable"), error: false)
            let saved = try persisted(f)
            XCTAssertEqual(saved.phase, .retryPending)
            XCTAssertEqual(saved.failures, 1)
            XCTAssertEqual(saved.responseStatus, status)
            let delay = try XCTUnwrap(saved.nextAttemptAt).timeIntervalSince(clock.value)
            XCTAssertGreaterThan(delay, 0)
            XCTAssertLessThan(delay, 10, "full jitter must not retain the old deterministic ten-second floor")
            try assertSourceRetained(f)
        }
    }

    func testScoringGateRetryAfterDoesNotGrowIntoExponentialDelay() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var retained = try persisted(f)
        retained.failures = 9
        try f.journal.save(retained)
        let clock = OutcomeClock()
        let adapter = OutcomeSessionAdapter()
        let q = try queue(f, adapter: adapter, clock: clock, randomUnit: 0.5)
        try await q.reconcile()
        let task = try XCTUnwrap(adapter.last).task
        adapter.finish(task.identifier)
        await q.receive(task, status: 503, body: try errorBody("scoring_input_gate_busy"),
            error: false, retryAfter: "2")
        let saved = try persisted(f)
        XCTAssertEqual(saved.failures, 10)
        XCTAssertEqual(saved.responseCode, "scoring_input_gate_busy")
        XCTAssertEqual(try XCTUnwrap(saved.nextAttemptAt).timeIntervalSince(clock.value), 2.5, accuracy: 0.001)
        try assertSourceRetained(f)
    }

    func testRelaunchReplaysRetainedRetryableServerFailureOnceWithoutStaleDelay() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let clock = OutcomeClock()
        var retained = try persisted(f)
        retained.phase = .retryPending
        retained.responseStatus = 500
        retained.responseCode = "push_failed"
        retained.responseDisposition = .retryable
        retained.nextAttemptAt = clock.value.addingTimeInterval(3_600)
        try f.journal.save(retained)

        let firstAdapter = OutcomeSessionAdapter()
        let first = try queue(f, adapter: firstAdapter, clock: clock,
            context: .init(scope: f.context.scope, generation: UUID()))
        try await first.reconcile()
        XCTAssertEqual(firstAdapter.count, 1)
        XCTAssertEqual(try persisted(f).serverRetryRecoveryCount, 1)
        XCTAssertNil(try persisted(f).nextAttemptAt)
        await first.suspend()

        retained = try persisted(f)
        retained.phase = .retryPending
        retained.taskIdentifier = nil
        retained.attempt = nil
        retained.nextAttemptAt = clock.value.addingTimeInterval(3_600)
        try f.journal.save(retained)
        let secondAdapter = OutcomeSessionAdapter()
        let second = try queue(f, adapter: secondAdapter, clock: clock,
            context: .init(scope: f.context.scope, generation: UUID()))
        try await second.reconcile()
        XCTAssertEqual(secondAdapter.count, 0, "persisted recovery allowance must not reset on every relaunch")
        XCTAssertEqual(try persisted(f).serverRetryRecoveryCount, 1)
        try assertSourceRetained(f)
    }

    func testHTTPFailureIsNotRecountedAsReceiptMismatch() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let adapter = OutcomeSessionAdapter()
        let q = try queue(f, adapter: adapter, clock: OutcomeClock())
        try await q.reconcile()
        let task = try XCTUnwrap(adapter.last).task
        adapter.finish(task.identifier)
        let body = try errorBody("invalid_object_manifest")
        await q.receive(task, status: 422, body: body, error: false)
        for _ in 0..<2 {
            do {
                try await q.validateResponse(batch: f.batch, response: .init(statusCode: 422, body: body),
                    captured: f.context, receiverStateID: receiver)
                XCTFail("non-2xx response passed receipt validation")
            } catch let error as PushTransportException {
                XCTAssertEqual(error.failure.httpStatus, 422)
                XCTAssertEqual(error.failure.receiverCode, "invalid_object_manifest")
                XCTAssertFalse(error.failure.retryable)
            } catch {
                XCTFail("HTTP outcome was erased: \(type(of: error))")
            }
        }
        XCTAssertEqual(try persisted(f).failures, 1)
        XCTAssertEqual(try persisted(f).phase, .pausedTerminal)
        XCTAssertEqual(try persisted(f).responseStatus, 422)
        try assertSourceRetained(f)
    }

    func testInvalidReceiptPausesOnceAndNeverAuthorizesSourceCleanup() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let adapter = OutcomeSessionAdapter()
        let q = try queue(f, adapter: adapter, clock: OutcomeClock())
        try await q.reconcile()
        let task = try XCTUnwrap(adapter.last).task
        adapter.finish(task.identifier)
        let body = Data("{\"type\":\"ack\",\"truncated\":".utf8)
        await q.receive(task, status: 200, body: body, error: false)
        for _ in 0..<2 {
            do {
                try await q.validateResponse(batch: f.batch, response: .init(statusCode: 200, body: body),
                    captured: f.context, receiverStateID: receiver)
                XCTFail("invalid receipt was accepted")
            } catch let error as PushTransportException {
                XCTAssertEqual(error.failure.code, .ackInvalid)
                XCTAssertFalse(error.failure.retryable)
            } catch {
                XCTFail("invalid receipt was not returned as a typed terminal outcome")
            }
        }
        XCTAssertEqual(try persisted(f).phase, .pausedTerminal)
        XCTAssertEqual(try persisted(f).failures, 1)
        XCTAssertNil(try persisted(f).nextAttemptAt)
        do {
            try await q.sourceCommitted(batchID: f.batch.batchId, receiverStateID: receiver, captured: f.context)
            XCTFail("invalid receipt authorized source cleanup")
        } catch {
            XCTAssertEqual(error as? CloudUploadError, .invalidReceipt)
        }
        try assertSourceRetained(f)
        await q.suspend()
        let reopenedAdapter = OutcomeSessionAdapter()
        let reopened = try queue(f, adapter: reopenedAdapter, clock: OutcomeClock())
        try await reopened.reconcile()
        XCTAssertEqual(reopenedAdapter.count, 0)
        XCTAssertEqual(try persisted(f).phase, .pausedTerminal)
        XCTAssertEqual(try persisted(f).failures, 1)
    }

    func testLegacySuccessAckReplaysExactBytesOnceAfterReceiverUpgrade() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let clock = OutcomeClock()
        let firstAdapter = OutcomeSessionAdapter()
        let firstQueue = try queue(f, adapter: firstAdapter, clock: clock)
        try await firstQueue.reconcile()
        let firstTask = try XCTUnwrap(firstAdapter.last).task
        firstAdapter.finish(firstTask.identifier)
        let legacy = try legacyAck(f.batch)
        await firstQueue.receive(firstTask, status: 200, body: legacy, error: false)
        do {
            try await firstQueue.validateResponse(batch: f.batch,
                response: .init(statusCode: 200, body: legacy), captured: f.context,
                receiverStateID: receiver)
            XCTFail("receipt-less ACK passed validation")
        } catch let error as PushTransportException {
            XCTAssertEqual(error.failure.code, .ackInvalid)
        }
        XCTAssertEqual(try persisted(f).phase, .pausedTerminal)
        XCTAssertNil(try persisted(f).receiptUpgradeRetryCount)
        await firstQueue.suspend()

        let upgradedContext = AccountSessionContext(scope: f.context.scope, generation: UUID())
        let upgradedAdapter = OutcomeSessionAdapter()
        let upgradedQueue = try queue(f, adapter: upgradedAdapter, clock: clock, context: upgradedContext)
        try await upgradedQueue.reconcile()
        let replay = try XCTUnwrap(upgradedAdapter.last)
        XCTAssertEqual(try Data(contentsOf: replay.file), f.batch.body)
        XCTAssertEqual(try persisted(f).receiptUpgradeRetryCount, 1)
        upgradedAdapter.finish(replay.task.identifier)
        await upgradedQueue.receive(replay.task, status: 200, body: legacy, error: false)
        do {
            try await upgradedQueue.validateResponse(batch: f.batch,
                response: .init(statusCode: 200, body: legacy), captured: upgradedContext,
                receiverStateID: receiver)
            XCTFail("second receipt-less ACK passed validation")
        } catch let error as PushTransportException {
            XCTAssertEqual(error.failure.code, .ackInvalid)
        }
        await upgradedQueue.suspend()

        let finalAdapter = OutcomeSessionAdapter()
        let finalQueue = try queue(f, adapter: finalAdapter, clock: clock,
            context: .init(scope: f.context.scope, generation: UUID()))
        try await finalQueue.reconcile()
        XCTAssertEqual(finalAdapter.count, 0, "legacy receipt recovery must run only once")
        XCTAssertEqual(try persisted(f).phase, .pausedTerminal)
        XCTAssertEqual(try persisted(f).receiptUpgradeRetryCount, 1)
        try assertSourceRetained(f)
    }

    func testBuild366ReceiptMismatchRevalidatesSavedReceiptWithoutReupload() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let ack = try durableAck(f.batch, owner: f.context.scope)
        var saved = try persisted(f)
        saved.phase = .pausedTerminal
        saved.responseStatus = 200
        saved.responseBody = ack
        saved.responseCode = "receipt_mismatch"
        saved.responseDisposition = .terminal
        saved.receiptUpgradeRetryCount = 1
        try f.journal.save(saved)

        let context = AccountSessionContext(scope: f.context.scope, generation: UUID())
        let adapter = OutcomeSessionAdapter()
        let q = try queue(f, adapter: adapter, clock: OutcomeClock(), context: context)
        try await q.reconcile()
        XCTAssertEqual(adapter.count, 0, "a durable saved response must not re-upload health bytes")
        XCTAssertEqual(try persisted(f).phase, .responseSaved)
        XCTAssertEqual(try persisted(f).receiptUpgradeRetryCount, 2)

        try await q.validateResponse(batch: f.batch,
            response: .init(statusCode: 200, body: ack), captured: context,
            receiverStateID: receiver)
        let verified = try persisted(f)
        XCTAssertEqual(verified.phase, .responseSaved)
        XCTAssertEqual(verified.responseDisposition, .verified)
        XCTAssertTrue(try XCTUnwrap(verified.validatedReceipt).isValid)
    }

    func testLegacyInvalidRecordRetriesOnceAfterBoundedReceiverUpgrade() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let rejection = try JSONSerialization.data(withJSONObject: [
            "type": "error", "protocolVersion": PushProtocol.binaryVersion, "code": "invalid_record",
        ])
        let firstAdapter = OutcomeSessionAdapter()
        let first = try queue(f, adapter: firstAdapter, clock: OutcomeClock())
        try await first.reconcile()
        let original = try XCTUnwrap(firstAdapter.last).task
        firstAdapter.finish(original.identifier)
        await first.receive(original, status: 422, body: rejection, error: false)
        XCTAssertEqual(try persisted(f).phase, .pausedTerminal)
        await first.suspend()

        let secondAdapter = OutcomeSessionAdapter()
        let second = try queue(f, adapter: secondAdapter, clock: OutcomeClock(),
            context: .init(scope: f.context.scope, generation: UUID()))
        try await second.reconcile()
        let replay = try XCTUnwrap(secondAdapter.last)
        XCTAssertEqual(try Data(contentsOf: replay.file), f.batch.body)
        XCTAssertEqual(try persisted(f).receiptUpgradeRetryCount, 1)
        secondAdapter.finish(replay.task.identifier)
        await second.receive(replay.task, status: 422, body: rejection, error: false)
        await second.suspend()

        let finalAdapter = OutcomeSessionAdapter()
        let final = try queue(f, adapter: finalAdapter, clock: OutcomeClock(),
            context: .init(scope: f.context.scope, generation: UUID()))
        try await final.reconcile()
        XCTAssertEqual(finalAdapter.count, 0)
        XCTAssertEqual(try persisted(f).phase, .pausedTerminal)
        XCTAssertEqual(try persisted(f).receiptUpgradeRetryCount, 1)
        try assertSourceRetained(f)
    }

    func testExplicitResolutionReusesExactBytesAndFencesPriorAttempt() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let adapter = OutcomeSessionAdapter()
        let q = try queue(f, adapter: adapter, clock: OutcomeClock())
        try await q.reconcile()
        let original = try XCTUnwrap(adapter.last)
        adapter.finish(original.task.identifier)
        await q.receive(original.task, status: 400, body: try errorBody("invalid_object_manifest"), error: false)
        XCTAssertEqual(try persisted(f).phase, .pausedTerminal)
        try await q.resumePaused(jobID: f.job.id, captured: f.context)
        XCTAssertEqual(adapter.count, 2)
        let resumed = try XCTUnwrap(adapter.last)
        XCTAssertNotEqual(resumed.task.description, original.task.description)
        XCTAssertEqual(resumed.file, original.file)
        XCTAssertEqual(try Data(contentsOf: resumed.file), f.batch.body)
        XCTAssertEqual(try persisted(f).phase, .transferring)
        let beforeStaleCallback = try persisted(f).failures
        await q.receive(original.task, status: 400, body: try errorBody("invalid_object_manifest"), error: false)
        XCTAssertEqual(try persisted(f).phase, .transferring)
        XCTAssertEqual(try persisted(f).failures, beforeStaleCallback)
        XCTAssertEqual(try persisted(f).taskIdentifier, resumed.task.identifier)
        try assertSourceRetained(f)
    }

    func testStaleAccountCannotResumeTerminalJob() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let adapter = OutcomeSessionAdapter()
        let q = try queue(f, adapter: adapter, clock: OutcomeClock())
        try await q.reconcile()
        let task = try XCTUnwrap(adapter.last).task
        adapter.finish(task.identifier)
        await q.receive(task, status: 413, body: try errorBody("payload_too_large"), error: false)
        let otherScope = try AccountScope(projectURL: f.context.scope.projectURL,
            userID: "33333333-3333-4333-8333-333333333333")
        do {
            try await q.resumePaused(jobID: f.job.id,
                captured: .init(scope: otherScope, generation: UUID()))
            XCTFail("another account resumed this job")
        } catch {
            XCTAssertEqual(error as? CloudUploadError, .staleOwner)
        }
        XCTAssertEqual(adapter.count, 1)
        XCTAssertEqual(try persisted(f).phase, .pausedTerminal)
        try assertSourceRetained(f)
    }

    func testAuthenticationRefreshRunsOnceThenPausesOnSecondRejection() async throws {
        for status in [401, 403] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let adapter = OutcomeSessionAdapter()
            let clock = OutcomeClock()
            let refreshes = OutcomeCounter()
            let q = try queue(f, adapter: adapter, clock: clock, refresh: { context in
                XCTAssertEqual(context, f.context)
                refreshes.increment()
            })
            try await q.reconcile()
            let first = try XCTUnwrap(adapter.last).task
            adapter.finish(first.identifier)
            let body = try errorBody("unauthorized")
            await q.receive(first, status: status, body: body, error: false)
            let rejected = try persisted(f)
            XCTAssertEqual(rejected.phase, .retryPending)
            XCTAssertEqual(rejected.authenticationRefreshCount, 1)
            XCTAssertEqual(rejected.authenticationRefreshPending, true)
            XCTAssertEqual(rejected.failures, 1)
            XCTAssertEqual(refreshes.value, 0)

            clock.set(try XCTUnwrap(rejected.nextAttemptAt).addingTimeInterval(1))
            try await q.reconcile()
            XCTAssertEqual(refreshes.value, 1)
            XCTAssertEqual(adapter.count, 2)
            XCTAssertEqual(try persisted(f).authenticationRefreshCount, 1)
            let second = try XCTUnwrap(adapter.last).task
            adapter.finish(second.identifier)
            await q.receive(second, status: status, body: body, error: false)
            XCTAssertEqual(try persisted(f).phase, .pausedTerminal)
            XCTAssertEqual(try persisted(f).authenticationRefreshCount, 1)
            XCTAssertEqual(try persisted(f).failures, 2)
            XCTAssertNil(try persisted(f).nextAttemptAt)
            clock.advance(by: 86_400)
            try await q.reconcile()
            XCTAssertEqual(refreshes.value, 1)
            XCTAssertEqual(adapter.count, 2)
            try assertSourceRetained(f)
        }
    }

    func testRelaunchCannotSpendAnAmbiguousRefreshAllowanceAgain() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let adapter = OutcomeSessionAdapter()
        let clock = OutcomeClock()
        let refreshes = OutcomeCounter()
        let q = try queue(f, adapter: adapter, clock: clock, refresh: { _ in refreshes.increment() })
        try await q.reconcile()
        let task = try XCTUnwrap(adapter.last).task
        adapter.finish(task.identifier)
        await q.receive(task, status: 401, body: try errorBody("unauthorized"), error: false)
        XCTAssertEqual(try persisted(f).authenticationRefreshPending, true)
        XCTAssertEqual(try persisted(f).authenticationRefreshCount, 1)
        await q.suspend()

        clock.advance(by: 86_400)
        let reopenedAdapter = OutcomeSessionAdapter()
        let newContext = AccountSessionContext(scope: f.context.scope, generation: UUID())
        let reopened = try queue(f, adapter: reopenedAdapter, clock: clock, context: newContext,
            refresh: { _ in refreshes.increment() })
        try await reopened.reconcile()
        try await reopened.reconcile()
        XCTAssertEqual(try persisted(f).phase, .pausedTerminal)
        XCTAssertEqual(try persisted(f).authenticationRefreshCount, 1)
        XCTAssertEqual(try persisted(f).failures, 1)
        XCTAssertEqual(refreshes.value, 0)
        XCTAssertEqual(reopenedAdapter.count, 0)
        try assertSourceRetained(f)
    }

    func testMissingRefreshCapabilityPausesAuthenticationImmediately() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let adapter = OutcomeSessionAdapter()
        let q = try queue(f, adapter: adapter, clock: OutcomeClock())
        try await q.reconcile()
        let task = try XCTUnwrap(adapter.last).task
        adapter.finish(task.identifier)
        await q.receive(task, status: 401, body: try errorBody("unauthorized"), error: false)
        XCTAssertEqual(try persisted(f).phase, .pausedTerminal)
        XCTAssertEqual(try persisted(f).authenticationRefreshCount, 1)
        XCTAssertEqual(try persisted(f).failures, 1)
        XCTAssertNil(try persisted(f).nextAttemptAt)
        try await q.reconcile()
        XCTAssertEqual(adapter.count, 1)
        try assertSourceRetained(f)
    }

    func testAccountSwitchDuringCredentialRefreshCannotSubmitAnotherTransfer() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let adapter = OutcomeSessionAdapter()
        let clock = OutcomeClock()
        let fence = OutcomeAccountFence()
        let gate = OutcomeRefreshGate()
        let started = expectation(description: "refresh began")
        let q = try queue(f, adapter: adapter, clock: clock, current: { _ in fence.isCurrent },
            refresh: { _ in
                started.fulfill()
                await gate.hold()
            })
        try await q.reconcile()
        let task = try XCTUnwrap(adapter.last).task
        adapter.finish(task.identifier)
        await q.receive(task, status: 401, body: try errorBody("unauthorized"), error: false)
        clock.set(try XCTUnwrap(persisted(f).nextAttemptAt).addingTimeInterval(1))
        let work = Task { try await q.reconcile() }
        await fulfillment(of: [started], timeout: 3)
        fence.revoke()
        await q.suspend()
        await gate.release()
        do { try await work.value }
        catch { XCTAssertEqual(error as? CloudUploadError, .staleOwner) }
        XCTAssertEqual(adapter.count, 1)
        XCTAssertEqual(try persisted(f).owner, f.context.scope)
        XCTAssertEqual(try persisted(f).authenticationRefreshCount, 1)
        try assertSourceRetained(f)
    }

    func testResponseWriteFailureCannotRecountDuplicateOrReconcileOutcome() async throws {
        for status in [429, 422] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let adapter = OutcomeSessionAdapter()
            let clock = OutcomeClock()
            let fault = OutcomeWriteFault()
            let q = try queue(f, adapter: adapter, clock: clock,
                journalWriteObserver: { try fault.afterWrite($0) })
            try await q.reconcile()
            let task = try XCTUnwrap(adapter.last).task
            adapter.finish(task.identifier)
            let body = try errorBody(status == 429 ? "rate_limited" : "invalid_object_manifest")
            let retryAfter = status == 429 ? "120" : nil
            fault.arm()
            await q.receive(task, status: status, body: body, error: false, retryAfter: retryAfter)
            XCTAssertEqual(fault.failureCount, 1)
            let durable = try persisted(f)
            XCTAssertEqual(durable.phase, status == 429 ? .retryPending : .pausedTerminal)
            XCTAssertEqual(durable.failures, 1)
            XCTAssertEqual(durable.responseStatus, status)
            XCTAssertEqual(durable.responseBody, body)
            XCTAssertEqual(durable.responseRetryAfter, retryAfter)
            if status == 429 { XCTAssertNotNil(durable.nextAttemptAt) }

            clock.advance(by: 5)
            await q.receive(task, status: status, body: body, error: false, retryAfter: retryAfter)
            try await q.reconcile()
            try await q.reconcile()
            let reconciled = try persisted(f)
            XCTAssertEqual(reconciled.phase, durable.phase)
            XCTAssertEqual(reconciled.failures, 1)
            XCTAssertEqual(reconciled.nextAttemptAt, durable.nextAttemptAt,
                "the durable response already selected its retry time before the write error")
            XCTAssertEqual(reconciled.responseBody, body)
            XCTAssertEqual(adapter.count, 1)
            try assertSourceRetained(f)
        }
    }

    func testTerminalIntentRenewalPausesWithoutUploadingAndSurvivesRelaunch() async throws {
        for status in [400, 404, 409, 413, 422] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            var unrelated = f.job
            unrelated.phase = .pausedTerminal
            try f.journal.save(unrelated)

            let objectID = "55555555-5555-4555-8555-555555555555"
            let decoded = Data([2, 4, 6])
            let payload = try PushBinaryCompression.compressObject(decoded, encoding: "zstd")
            var object = CloudUploadJob(id: CloudUploadQueue.objectJobID(endpoint: endpoint, objectID: objectID),
                owner: f.context.scope, generation: f.context.generation, endpoint: endpoint,
                deviceID: "synthetic-device", createdAt: f.job.createdAt, operation: .objectPut,
                method: "PUT", headers: [:])
            object.objectID = objectID
            object.objectKey = "scoped/synthetic-object"
            object.lanePath = "/functions/v1/push/objects"
            object.signedURL = "https://bucket.example/synthetic-expired"
            object.signedExpiry = Date(timeIntervalSince1970: 0)
            object.manifest = try JSONSerialization.data(withJSONObject: [
                "protocolVersion": "1.2", "objectId": objectID, "batchId": objectID,
                "sourceId": f.batch.sourceId, "deviceId": "synthetic-device", "stream": "rawBatch",
                "startTs": 1_800_000_000, "endTs": 1_800_000_001, "sampleCount": 1,
                "uncompressedBytes": decoded.count, "compressedBytes": payload.count,
                "contentSha256": PushDurabilityReceipt.sha256(decoded), "contentEncoding": "zstd"
            ])
            try f.journal.persistBody(payload, job: &object)
            try f.journal.save(object)
            let body = try JSONSerialization.data(withJSONObject: ["type": "error",
                "protocolVersion": "1.2", "code": "invalid_object_manifest"])
            let calls = OutcomeCounter()
            let adapter = OutcomeSessionAdapter()
            let clock = OutcomeClock()
            let q = try queue(f, adapter: adapter, clock: clock, control: { _ in
                calls.increment()
                return .init(statusCode: status, body: body)
            })
            try await q.reconcile()
            let saved = try XCTUnwrap(f.journal.load()[object.id])
            XCTAssertEqual(saved.phase, .pausedTerminal, "status=\(status)")
            XCTAssertEqual(saved.responseStatus, status)
            XCTAssertEqual(saved.responseCode, "invalid_object_manifest")
            XCTAssertEqual(saved.failures, 1)
            XCTAssertNil(saved.nextAttemptAt)
            XCTAssertNil(saved.validatedReceipt)
            XCTAssertFalse(saved.acknowledged)
            XCTAssertEqual(try Data(contentsOf: f.journal.bodyURL(saved)), payload)
            XCTAssertEqual(adapter.count, 0)
            XCTAssertEqual(calls.value, 1)
            await q.suspend()

            clock.advance(by: 86_400)
            let reopenedAdapter = OutcomeSessionAdapter()
            let context = AccountSessionContext(scope: f.context.scope, generation: UUID())
            let reopened = try queue(f, adapter: reopenedAdapter, clock: clock, context: context,
                control: { _ in
                    calls.increment()
                    return .init(statusCode: status, body: body)
                })
            try await reopened.reconcile()
            XCTAssertEqual(calls.value, 1)
            XCTAssertEqual(reopenedAdapter.count, 0)
            XCTAssertEqual(try f.journal.load()[object.id]?.phase, .pausedTerminal)
            XCTAssertEqual(try f.journal.load()[object.id]?.failures, 1)
        }
    }
}

private final class OutcomeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var value: Date { lock.lock(); defer { lock.unlock() }; return date }
    func set(_ value: Date) { lock.lock(); date = value; lock.unlock() }
    func advance(by interval: TimeInterval) { lock.lock(); date.addTimeInterval(interval); lock.unlock() }
}

private final class OutcomeSessionAdapter: CloudUploadSessionAdapter, @unchecked Sendable {
    struct Created {
        let task: CloudUploadTaskSnapshot
        let file: URL
    }
    private let lock = NSLock()
    private var active: [Int: CloudUploadTaskSnapshot] = [:]
    private var created: [Created] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return created.count }
    var last: Created? { lock.lock(); defer { lock.unlock() }; return created.last }
    private func snapshot() -> [CloudUploadTaskSnapshot] {
        lock.lock(); defer { lock.unlock() }; return Array(active.values)
    }
    func tasks() async -> [CloudUploadTaskSnapshot] { snapshot() }
    func create(request: URLRequest, file: URL, description: String) -> CloudUploadTaskSnapshot {
        lock.lock(); defer { lock.unlock() }
        let task = CloudUploadTaskSnapshot(identifier: 100 + created.count, description: description)
        active[task.identifier] = task
        created.append(.init(task: task, file: file))
        return task
    }
    func resume(_ identifier: Int) {}
    func cancel(_ identifier: Int) { finish(identifier) }
    func finish(_ identifier: Int) { lock.lock(); active[identifier] = nil; lock.unlock() }
}

private final class OutcomeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private final class OutcomeAccountFence: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return current }
    func revoke() { lock.lock(); current = false; lock.unlock() }
}

private actor OutcomeRefreshGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private final class OutcomeWriteFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var failures = 0
    var failureCount: Int { lock.lock(); defer { lock.unlock() }; return failures }
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func afterWrite(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard armed, url.pathExtension == "json" else { return }
        armed = false
        failures += 1
        throw POSIXError(.EIO)
    }
}
