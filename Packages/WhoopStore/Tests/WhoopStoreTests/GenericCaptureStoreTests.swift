import Foundation
import GRDB
import XCTest
import WhoopProtocol
@testable import WhoopStore

final class GenericCaptureStoreTests: XCTestCase {
    private let owner = try! StandardHRCaptureOwner(projectURL: "https://standard-hr.fixture.invalid",
        userID: "ABCDEF12-3456-4789-ABCD-0123456789AB")
    private let device = "standard-hr-fixture-00000000-0000-0000-0000-000000000001"
    private let timestamp: Int64 = 1_789_689_600

    private func fixture(path: String? = nil, bind: Bool = true) async throws -> WhoopStore {
        let store: WhoopStore
        if let path { store = try await WhoopStore(path: path) } else { store = try await .inMemory() }
        try await store.registryWriter.read { db in
            XCTAssertTrue(try db.tableExists("standardHRCaptureSession"), "root must register v53")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier='v53-standard-hr-capture-journal'"), 1)
        }
        if bind { try await store.bindAccountOwner(projectURL: owner.projectURL, userID: owner.userID) }
        try await store.upsertDevice(id: device, mac: nil, name: nil)
        addTeardownBlock { try store.registryWriter.close() }
        return store
    }

    private func temporaryPath() throws -> String {
        let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("standard-hr-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Teardown blocks run LIFO: fixture() adds each writer close AFTER this cleanup.
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("capture.sqlite").path
    }

    private func begin(_ store: WhoopStore, at: Int64 = 100) async throws -> StandardHRCaptureSession {
        try await store.beginStandardHRCapture(owner: owner, sessionID: UUID(), runtimeGeneration: UUID(), openedAtUnixSeconds: at)
    }

    private func batch(_ session: StandardHRCaptureSession, sequence: Int64 = 0, ts: Int64? = nil,
                       raw: [UInt8] = [0x16, 72, 0, 4, 0, 4], hr: Int = 72,
                       rr: [Int] = [1000, 1000], contact: StandardHRContact = .supportedDetected,
                       deviceID: String? = nil) throws -> StandardHRFrozenBatch {
        let time = ts ?? timestamp
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(StandardHRMapping.samples(fromHR: hr, rr: rr, contact: contact, at: Int(time)))
        return try StandardHRFrozenBatch(id: StandardHRCaptureID(sessionID: session.sessionID, sequence: sequence),
            scope: DurableIngestScope(environment: owner.projectURL, accountID: owner.userID, deviceID: deviceID ?? device),
            hostTimestampSeconds: time, rawBytes: Data(raw), projectionJSON: json)
    }

    private func expect(_ expected: StandardHRCaptureError, file: StaticString = #filePath, line: UInt = #line,
                        _ action: () async throws -> Void) async {
        do { try await action(); XCTFail("expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? StandardHRCaptureError, expected, file: file, line: line) }
    }

    private func count(_ store: WhoopStore, _ table: String) async throws -> Int {
        try await store.registryWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")! }
    }

    private func pending(_ store: WhoopStore) async throws -> Int {
        try await store.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM standardHRCaptureOccurrence WHERE projectionState=0")!
        }
    }

    func testSchemaIsEmptyAdditiveAndDoesNotAdoptGuest() async throws {
        let s = try await fixture(bind: false)
        let initial = try await count(s, "standardHRCaptureSession")
        XCTAssertEqual(initial, 0)
        await expect(.unassignedOwner) { _ = try await self.begin(s) }
        try await s.recordEvent(deviceId: device, ts: 10, kind: "LEGACY", payloadJSON: "{}")
        do {
            try await s.bindAccountOwner(projectURL: owner.projectURL, userID: owner.userID)
            XCTFail("populated unowned file adopted")
        } catch { XCTAssertEqual(error as? LocalAccountOwnershipError, .unassignedExistingData) }
        let retained = try await count(s, "event")
        XCTAssertEqual(retained, 1)
    }

    func testSwiftEncodingsMatchAllFourSizingFixtures() async throws {
        let s = try await fixture(); let session = try await begin(s)
        let cases: [([UInt8], [Int], Int, Int64, String)] = [
            ([6, 72], [], 276, 590, "c27b07b1d25a5419b0cd4f58ad91d480b7761ab482f71ae03bf1c01aca2bc276"),
            ([0x16, 72, 0, 4, 0, 4], [1000, 1000], 335, 653, "3f0b15395fe0f519a89febe13abe573c3a1b055082543c1c0a47a351d3792033"),
            ([0x1e, 72, 0x34, 0x12, 0, 4, 0, 4], [1000, 1000], 335, 655, "3f0b15395fe0f519a89febe13abe573c3a1b055082543c1c0a47a351d3792033"),
            ([0x16, 72] + Array(repeating: 255, count: 510), Array(repeating: 63999, count: 255), 8180, 9004,
             "11e28e4375266cab0fd59cdeb858ae36def59660569fb6fca7fb1251fc57cd72")
        ]
        for (index, c) in cases.enumerated() {
            let b = try batch(session, sequence: Int64(index), raw: c.0, rr: c.1)
            XCTAssertEqual(b.projectionJSON.count, c.2); XCTAssertEqual(b.chargeBytes, c.3)
            XCTAssertEqual(DurableIngestScope.sha256(b.projectionJSON), c.4)
            let receipt = try await s.appendStandardHRCapture(b, session: session)
            XCTAssertEqual(receipt.id, b.id); XCTAssertEqual(receipt.intentSHA256, b.intentSHA256)
            let exact = try await s.registryWriter.read { db in
                try Data.fetchOne(db, sql: "SELECT rawBytes FROM standardHRCaptureOccurrence WHERE sequence=?", arguments: [index])
            }
            XCTAssertEqual(exact, Data(c.0))
        }
        let plain = try batch(session)
        let energy = try batch(session, raw: cases[2].0)
        XCTAssertEqual(plain.projectionJSON, energy.projectionJSON)
        XCTAssertNotEqual(plain.rawSHA256, energy.rawSHA256); XCTAssertNotEqual(plain.intentSHA256, energy.intentSHA256)
        XCTAssertEqual(plain.rawSHA256, "19545aa76d38497fa5a258c9a8bff44c20916bace60ac2c173af2c5485ec5da3")
        XCTAssertEqual(energy.rawSHA256, "ab18b7fb34dce9aa6e19904e5cc99a98a06de0fe75fcd37734319b935a594682")
    }

    func testLengthPrefixedDigestAndOwnerStringsRemainExact() async throws {
        let s = try await fixture(); let session = try await begin(s); let b = try batch(session)
        var independent: [UInt8] = []
        let text = ["standard-hr-capture-v1", owner.projectURL, owner.userID, device,
                    session.sessionID.uuidString.lowercased(), "0", String(timestamp),
                    "standard-hr-current-v1", "standard-hr-one-notification-v1"]
        for part in text.map({ Array($0.utf8) }) + [Array(b.rawBytes), Array(b.projectionJSON)] {
            for shift in stride(from: 56, through: 0, by: -8) { independent.append(UInt8((UInt64(part.count) >> shift) & 255)) }
            independent += part
        }
        XCTAssertEqual(b.intentSHA256, DurableIngestScope.sha256(Data(independent)))
        XCTAssertEqual(session.owner.userID, owner.userID)
        let lowerOwner = try StandardHRCaptureOwner(projectURL: owner.projectURL, userID: owner.userID.lowercased())
        await expect(.ownerMismatch) { _ = try await s.recoverStandardHRCapture(owner: lowerOwner) }
    }

    func testFrozenProjectionRejectsUnknownMissingReorderedAndNonstandardStreams() async throws {
        let s = try await fixture(); let session = try await begin(s); let good = try batch(session)
        let source = String(decoding: good.projectionJSON, as: UTF8.self)
        let invalid = [source + "\n", source.replacingOccurrences(of: "\"battery\":[],", with: ""),
            source.replacingOccurrences(of: "\"battery\":[]", with: "\"battery\":[],\"future\":1"),
            source.replacingOccurrences(of: "\"bpm\":72", with: "\"bpm\":72,\"extra\":1"),
            source.replacingOccurrences(of: "\"rrMs\":1000", with: "\"rrMs\":1000,\"seq\":0"),
            source.replacingOccurrences(of: "\"rrMs\":1000", with: "\"rrMs\":1000,\"srcChannel\":5"),
            source.replacingOccurrences(of: "supported_detected", with: "unknown"),
            source.replacingOccurrences(of: "\"rrMs\":1000", with: "\"rrMs\":NaN"),
            source.replacingOccurrences(of: "\"bpm\":72", with: "\"bpm\":72.0")]
        for json in invalid {
            XCTAssertThrowsError(try StandardHRFrozenBatch(id: good.id, scope: good.scope,
                hostTimestampSeconds: good.hostTimestampSeconds, rawBytes: good.rawBytes, projectionJSON: Data(json.utf8)))
        }
        for raw in [Data(), Data(repeating: 1, count: 513)] {
            XCTAssertThrowsError(try StandardHRFrozenBatch(id: good.id, scope: good.scope,
                hostTimestampSeconds: timestamp, rawBytes: raw, projectionJSON: good.projectionJSON))
        }
        XCTAssertThrowsError(try StandardHRCaptureID(sessionID: UUID(), sequence: -1))
        XCTAssertThrowsError(try StandardHRCaptureOwner(projectURL: "missing-host", userID: owner.userID))
        XCTAssertThrowsError(try StandardHRCaptureOwner(projectURL: owner.projectURL, userID: String(repeating: "x", count: 36)))
    }

    func testDistinctOccurrencesExactReplayConflictsAndSealedRetry() async throws {
        let s = try await fixture(); let session = try await begin(s); let b = try batch(session)
        let first = try await s.appendStandardHRCapture(b, session: session)
        _ = try await s.appendStandardHRCapture(batch(session, sequence: 1), session: session)
        try await s.sealStandardHRCapture(session)
        let retry = try await s.appendStandardHRCapture(b, session: session)
        XCTAssertEqual(first, retry)
        for changed in [try batch(session, raw: [0x1e, 72, 1, 2, 0, 4, 0, 4]),
                        try batch(session, hr: 73), try batch(session, ts: timestamp + 1),
                        try batch(session, deviceID: "another-source")] {
            await expect(.identityConflict) { _ = try await s.appendStandardHRCapture(changed, session: session) }
        }
        await expect(.closedSession) { _ = try await s.appendStandardHRCapture(self.batch(session, sequence: 2), session: session) }
        let rows = try await count(s, "standardHRCaptureOccurrence"); XCTAssertEqual(rows, 2)
        let totals = try await s.registryWriter.read { db in
            let r = try Row.fetchOne(db, sql: "SELECT * FROM standardHRCaptureSession")!
            return [r["retainedCount"] as Int64, r["nextSequence"] as Int64, r["retainedBytes"] as Int64]
        }
        XCTAssertEqual(totals, [2, 2, b.chargeBytes * 2])
    }

    func testBeginReplayRecoveryBeforeNewSessionAndAbandonedSeal() async throws {
        let s = try await fixture(); let first = try await begin(s, at: 900)
        let replay = try await s.beginStandardHRCapture(owner: owner, sessionID: first.sessionID,
            runtimeGeneration: first.runtimeGeneration, openedAtUnixSeconds: 900)
        XCTAssertEqual(replay, first)
        await expect(.identityConflict) {
            _ = try await s.beginStandardHRCapture(owner: self.owner, sessionID: first.sessionID,
                runtimeGeneration: UUID(), openedAtUnixSeconds: 900)
        }
        _ = try await s.appendStandardHRCapture(batch(first), session: first)
        await expect(.concurrentCapture) { _ = try await self.begin(s, at: 1) }
        let recovered = try await s.recoverStandardHRCapture(owner: owner); XCTAssertEqual(recovered, 1)
        let second = try await begin(s, at: 1)
        let sealed = try await s.registryWriter.read { db in
            try Int.fetchAll(db, sql: "SELECT sealed FROM standardHRCaptureSession ORDER BY ordinal")
        }
        XCTAssertEqual(sealed, [1, 0])
        _ = try await s.appendStandardHRCapture(batch(first), session: first)
        await expect(.closedSession) { _ = try await s.appendStandardHRCapture(self.batch(first, sequence: 1), session: first) }
        XCTAssertNotEqual(first.sessionID, second.sessionID)
    }

    func testSequenceGapAndRollbackDoNotSpendCounters() async throws {
        let s = try await fixture(); let session = try await begin(s)
        await expect(.sequenceGap) { _ = try await s.appendStandardHRCapture(self.batch(session, sequence: 1), session: session) }
        try await s.registryWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER fixture_abort AFTER INSERT ON standardHRCaptureOccurrence BEGIN SELECT RAISE(ABORT,'fixture'); END")
        }
        await expect(.storageUnavailable) { _ = try await s.appendStandardHRCapture(self.batch(session), session: session) }
        let c = try await count(s, "standardHRCaptureOccurrence"); XCTAssertEqual(c, 0)
        let usage = try await s.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT nextSequence+retainedCount+retainedBytes FROM standardHRCaptureSession")
        }
        XCTAssertEqual(usage, 0)
        try await s.registryWriter.write { try $0.execute(sql: "DROP TRIGGER fixture_abort") }
        _ = try await s.appendStandardHRCapture(batch(session), session: session)
    }

    func testNativeCommitFailureCannotIssueReceipt() async throws {
        let s = try await fixture(); let session = try await begin(s)
        let observer = RejectCommit()
        s.registryWriter.add(transactionObserver: observer, extent: .observerLifetime)
        await expect(.storageUnavailable) { _ = try await s.appendStandardHRCapture(self.batch(session), session: session) }
        s.registryWriter.remove(transactionObserver: observer)
        let c = try await count(s, "standardHRCaptureOccurrence"); XCTAssertEqual(c, 0)
        _ = try await s.appendStandardHRCapture(batch(session), session: session)
    }

    func testT1ReopenRecoversExactRawEnergyAndTrailingByte() async throws {
        let path = try temporaryPath(); let s = try await fixture(path: path); let session = try await begin(s)
        let b = try batch(session, raw: [0x1e, 72, 0x34, 0x12, 0, 4, 0, 4, 0xab])
        _ = try await s.appendStandardHRCapture(b, session: session)
        let before = try await count(s, "hrSample"); XCTAssertEqual(before, 0)
        let reopened = try await fixture(path: path)
        let done = try await reopened.recoverStandardHRCapture(owner: owner); XCTAssertEqual(done, 1)
        let bytes = try await reopened.registryWriter.read { db in try Data.fetchOne(db, sql: "SELECT rawBytes FROM standardHRCaptureOccurrence") }
        XCTAssertEqual(bytes, b.rawBytes)
        let retry = try await reopened.appendStandardHRCapture(b, session: session)
        XCTAssertEqual(retry.intentSHA256, b.intentSHA256)
    }

    func testCanonicalFirstWinsAndRRBatchOrderMatchExistingOneNotificationMapping() async throws {
        let s = try await fixture(); let control = try await fixture(); let session = try await begin(s)
        let batches = [try batch(session, rr: [900, 1000, 900]),
                       try batch(session, sequence: 1, hr: 99, rr: [900, 900, 1100])]
        for b in batches {
            _ = try await s.appendStandardHRCapture(b, session: session)
            _ = try await control.insertAndMarkJobsOwed(JSONDecoder().decode(Streams.self, from: b.projectionJSON),
                deviceId: device, postOffloadJobKinds: [], note: nil, captureScope: b.scope)
        }
        let done = try await s.recoverStandardHRCapture(owner: owner); XCTAssertEqual(done, 2)
        func snapshot(_ store: WhoopStore) async throws -> [String] {
            try await store.registryWriter.read { db in
                try ["hrSample", "rrInterval", "event"].flatMap { table in
                    try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map(\.description)
                }
            }
        }
        let actual = try await snapshot(s); let expected = try await snapshot(control)
        XCTAssertEqual(actual, expected)
        let hr = try await s.registryWriter.read { db in try Int.fetchOne(db, sql: "SELECT bpm FROM hrSample") }
        XCTAssertEqual(hr, 72)
        let rr = try await count(s, "rrInterval"); XCTAssertEqual(rr, 4)
        let raw = try await count(s, "standardHRCaptureOccurrence"); XCTAssertEqual(raw, 2)
    }

    func testT2FailureRollsBackCanonicalAndUploadDebtButKeepsT1() async throws {
        let s = try await fixture(); let session = try await begin(s)
        _ = try await s.appendStandardHRCapture(batch(session), session: session)
        try await s.registryWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_debt BEFORE INSERT ON syncJob BEGIN SELECT RAISE(ABORT,'fixture'); END")
        }
        await expect(.storageUnavailable) { _ = try await s.projectNextStandardHRCapture(owner: self.owner) }
        let canonical = try await count(s, "hrSample"); let owed = try await count(s, "syncJob")
        XCTAssertEqual(canonical, 0); XCTAssertEqual(owed, 0)
        let retained = try await pending(s); XCTAssertEqual(retained, 1)
        let attempts = try await s.registryWriter.read { db in try Int.fetchOne(db, sql: "SELECT attempts FROM standardHRCaptureOccurrence") }
        XCTAssertEqual(attempts, 1)
        try await s.registryWriter.write { try $0.execute(sql: "DROP TRIGGER fail_debt") }
        let done = try await s.recoverStandardHRCapture(owner: owner); XCTAssertEqual(done, 1)
        let jobs = try await s.owedJobs(); XCTAssertEqual(jobs.map(\.kind), ["cloudPush"])
    }

    func testT3FailureReopenReplaysWithoutRefreshingSettledDebt() async throws {
        let path = try temporaryPath(); let s = try await fixture(path: path); let session = try await begin(s)
        let b = try batch(session); _ = try await s.appendStandardHRCapture(b, session: session)
        try await s.registryWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_marker BEFORE UPDATE OF projectionState ON standardHRCaptureOccurrence
                BEGIN SELECT RAISE(ABORT,'fixture'); END
                """)
        }
        await expect(.storageUnavailable) { _ = try await s.projectNextStandardHRCapture(owner: self.owner) }
        let canonical = try await count(s, "hrSample"); XCTAssertEqual(canonical, 1)
        let jobs = try await s.owedJobs(); XCTAssertEqual(jobs.count, 1)
        _ = try await s.settleJob(kind: jobs[0].kind, token: jobs[0].token)
        let reopened = try await fixture(path: path)
        try await reopened.registryWriter.write { try $0.execute(sql: "DROP TRIGGER fail_marker") }
        let done = try await reopened.projectNextStandardHRCapture(owner: owner)
        XCTAssertEqual(done, .completed(id: b.id, intentSHA256: b.intentSHA256))
        let after = try await reopened.owedJobs(); XCTAssertTrue(after.isEmpty)
        let rr = try await count(reopened, "rrInterval"); XCTAssertEqual(rr, 2)
        let again = try await reopened.recoverStandardHRCapture(owner: owner); XCTAssertEqual(again, 0)
    }

    func testFailedBookkeepingAndUnknownVersionNeverSkipPendingHead() async throws {
        let s = try await fixture(); let session = try await begin(s)
        for i in 0..<2 { _ = try await s.appendStandardHRCapture(batch(session, sequence: Int64(i), ts: timestamp + Int64(i)), session: session) }
        // Corrupt a disposable fixture to model a future/unsupported stored version.
        try await s.registryWriter.write { db in
            try db.execute(sql: "DROP TRIGGER standardHRCaptureOccurrence_identity; PRAGMA ignore_check_constraints=ON")
            try db.execute(sql: "UPDATE standardHRCaptureOccurrence SET schemaVersion=2 WHERE sequence=0")
            try db.execute(sql: "PRAGMA ignore_check_constraints=OFF")
            try db.execute(sql: "CREATE TRIGGER fail_attempt BEFORE UPDATE ON standardHRCaptureOccurrence BEGIN SELECT RAISE(ABORT,'fixture'); END")
        }
        await expect(.unsupportedVersion) { _ = try await s.recoverStandardHRCapture(owner: self.owner) }
        let retained = try await pending(s); let canonical = try await count(s, "hrSample")
        XCTAssertEqual(retained, 2); XCTAssertEqual(canonical, 0)
    }

    func testCorruptDigestBlocksLaterProjection() async throws {
        let s = try await fixture(); let session = try await begin(s)
        for i in 0..<2 { _ = try await s.appendStandardHRCapture(batch(session, sequence: Int64(i)), session: session) }
        try await s.registryWriter.write { db in
            try db.execute(sql: "DROP TRIGGER standardHRCaptureOccurrence_identity")
            try db.execute(sql: "UPDATE standardHRCaptureOccurrence SET rawSHA256=? WHERE sequence=0", arguments: [String(repeating: "0", count: 64)])
        }
        await expect(.integrityFailure) { _ = try await s.recoverStandardHRCapture(owner: self.owner) }
        let retained = try await pending(s); XCTAssertEqual(retained, 2)
        let canonical = try await count(s, "hrSample"); XCTAssertEqual(canonical, 0)
    }

    func testOwnerRecheckedForEveryOperationAndProjection() async throws {
        let s = try await fixture(); let session = try await begin(s); let b = try batch(session)
        _ = try await s.appendStandardHRCapture(b, session: session)
        try await s.registryWriter.write { db in
            try db.execute(sql: "UPDATE localAccountOwner SET userID=?", arguments: [UUID().uuidString])
        }
        await expect(.ownerMismatch) { _ = try await s.appendStandardHRCapture(b, session: session) }
        await expect(.ownerMismatch) { try await s.sealStandardHRCapture(session) }
        await expect(.ownerMismatch) { _ = try await s.recoverStandardHRCapture(owner: self.owner) }
        await expect(.ownerMismatch) { _ = try await s.projectNextStandardHRCapture(owner: self.owner) }
        await expect(.ownerMismatch) { _ = try await self.begin(s) }
        let raw = try await count(s, "standardHRCaptureOccurrence"); XCTAssertEqual(raw, 1)
        let canonical = try await count(s, "hrSample"); XCTAssertEqual(canonical, 0)
    }

    func testSQLIdentityDeletionCountersAndCompletedWitnessAreImmutable() async throws {
        let s = try await fixture(); let session = try await begin(s)
        _ = try await s.appendStandardHRCapture(batch(session), session: session)
        let forbidden = [
            "UPDATE standardHRCaptureSession SET sessionID=sessionID",
            "UPDATE standardHRCaptureSession SET ordinal=ordinal+1",
            "UPDATE standardHRCaptureSession SET openedAt=0",
            "UPDATE standardHRCaptureSession SET retainedCount=0",
            "UPDATE standardHRCaptureSession SET nextSequence=0",
            "UPDATE standardHRCaptureSession SET retainedBytes=0",
            "UPDATE standardHRCaptureSession SET nextSequence=nextSequence+1,retainedCount=retainedCount+1,retainedBytes=retainedBytes+1",
            "UPDATE standardHRCaptureOccurrence SET rawBytes=rawBytes",
            "UPDATE standardHRCaptureOccurrence SET deviceID='other'",
            "UPDATE standardHRCaptureOccurrence SET chargeBytes=0",
            "DELETE FROM standardHRCaptureOccurrence", "DELETE FROM standardHRCaptureSession"
        ]
        for sql in forbidden {
            do { try await s.registryWriter.write { try $0.execute(sql: sql) }; XCTFail(sql) } catch {}
        }
        _ = try await s.recoverStandardHRCapture(owner: owner)
        for sql in ["UPDATE standardHRCaptureOccurrence SET projectionState=0,projectedAt=NULL",
                    "UPDATE standardHRCaptureOccurrence SET attempts=attempts+1",
                    "UPDATE standardHRCaptureOccurrence SET projectedAt=projectedAt",
                    "UPDATE standardHRCaptureOccurrence SET lastFailureCode='changed'"] {
            do { try await s.registryWriter.write { try $0.execute(sql: sql) }; XCTFail(sql) } catch {}
        }
        try await s.sealStandardHRCapture(session)
        do { try await s.registryWriter.write { try $0.execute(sql: "UPDATE standardHRCaptureSession SET sealed=0") }; XCTFail("reopened") } catch {}
    }

    func testSQLNullTypesRangesAndInitialStateFailAtomically() async throws {
        let s = try await fixture(); let session = try await begin(s); let b = try batch(session)
        let columns = ["sessionID", "sequence", "deviceID", "hostTimestampSeconds", "schemaVersion", "decoderVersion", "mappingVersion",
            "rawBytes", "projectionJSON", "rawSHA256", "intentSHA256", "chargeBytes", "projectionState", "attempts", "lastFailureCode", "projectedAt"]
        let valid: [DatabaseValue] = [session.sessionID.uuidString.lowercased().databaseValue, 0.databaseValue, device.databaseValue,
            timestamp.databaseValue, 1.databaseValue, "standard-hr-current-v1".databaseValue, "standard-hr-one-notification-v1".databaseValue,
            b.rawBytes.databaseValue, b.projectionJSON.databaseValue, b.rawSHA256.databaseValue, b.intentSHA256.databaseValue,
            b.chargeBytes.databaseValue, 0.databaseValue, 0.databaseValue, .null, .null]
        var bad: [(Int, DatabaseValue)] = [(0, "not-a-uuid".databaseValue), (1, (-1).databaseValue), (1, 0.5.databaseValue),
            (1, Int64.max.databaseValue), (2, "".databaseValue), (2, String(repeating: "x", count: 257).databaseValue),
            (3, "invalid".databaseValue), (4, 2.databaseValue), (5, "future".databaseValue), (6, "future".databaseValue),
            (7, Data().databaseValue), (7, Data(repeating: 1, count: 513).databaseValue), (7, "text".databaseValue),
            (8, Data(repeating: 1, count: 12289).databaseValue), (9, String(repeating: "G", count: 64).databaseValue),
            (10, "abc".databaseValue), (11, Int64.max.databaseValue), (12, 1.databaseValue), (13, 1.databaseValue),
            (14, "failure".databaseValue), (15, 1.databaseValue)]
        for index in 0...13 { bad.append((index, DatabaseValue.null)) }
        let sql = "INSERT INTO standardHRCaptureOccurrence(\(columns.joined(separator: ","))) VALUES(\(Array(repeating: "?", count: columns.count).joined(separator: ",")))"
        for (index, value) in bad {
            var args = valid; args[index] = value
            let arguments = StatementArguments(args)
            do { try await s.registryWriter.write { try $0.execute(sql: sql, arguments: arguments) }; XCTFail("accepted invalid \(columns[index])") } catch {}
        }
        let c = try await count(s, "standardHRCaptureOccurrence"); XCTAssertEqual(c, 0)
        _ = try await s.appendStandardHRCapture(b, session: session)
    }

    func testRecoveryLimitAndConcurrentTwoHandleAppendAndProjection() async throws {
        let path = try temporaryPath(); let a = try await fixture(path: path); let b = try await fixture(path: path)
        let session = try await begin(a); let first = try batch(session)
        async let left = a.appendStandardHRCapture(first, session: session)
        async let right = b.appendStandardHRCapture(first, session: session)
        let receipts = try await (left, right); XCTAssertEqual(receipts.0, receipts.1)
        for i in 1..<65 { _ = try await a.appendStandardHRCapture(batch(session, sequence: Int64(i), ts: timestamp + Int64(i)), session: session) }
        await expect(.invalidIntent) { _ = try await a.recoverStandardHRCapture(owner: self.owner, limit: 0) }
        await expect(.invalidIntent) { _ = try await b.recoverStandardHRCapture(owner: self.owner, limit: 65) }
        async let recovery = a.recoverStandardHRCapture(owner: owner)
        async let one = b.projectNextStandardHRCapture(owner: owner)
        let result = try await (recovery, one)
        XCTAssertEqual(result.0, 64)
        if case .completed = result.1 {} else { XCTFail("other handle must project exactly one") }
        let remaining = try await pending(a); XCTAssertEqual(remaining, 0)
        let rows = try await count(a, "hrSample"); XCTAssertEqual(rows, 65)
    }

    func testProcessGateHoldsAcrossT2CommitAndT3ForBothHandles() async throws {
        let path = try temporaryPath(); let a = try await fixture(path: path); let b = try await fixture(path: path)
        let session = try await begin(a); let batch = try batch(session)
        _ = try await a.appendStandardHRCapture(batch, session: session)
        let t2Entered = expectation(description: "actual canonical T2 commit suspended")
        let t3Entered = expectation(description: "actual completion T3 commit suspended")
        let registered = expectation(description: "same-key contender registered at the actual gate")
        let barrier = CommitBarrier(t2Entered: t2Entered, t3Entered: t3Entered)
        let probe = ProjectionGateProbe(registered: registered, barrier: barrier)
        a.registryWriter.add(transactionObserver: barrier, extent: .observerLifetime)
        defer {
            barrier.releaseAll()
            a.registryWriter.remove(transactionObserver: barrier)
        }
        let first = Task { try await a.projectNextStandardHRCapture(owner: self.owner) }
        var second: Task<Int, Error>?
        do {
            try await requireFulfillment(t2Entered)
            second = Task {
                try await b.recoverStandardHRCapture(owner: self.owner, gateObserver: { probe.record($0) })
            }
            try await requireFulfillment(registered)
            XCTAssertEqual(probe.events, [.registered(waiting: true)], "contender must be queued throughout T2")
            barrier.releaseT2.signal()
            try await requireFulfillment(t3Entered)
            XCTAssertEqual(probe.events, [.registered(waiting: true)], "contender must remain ungranted throughout T3")
            barrier.releaseT3.signal()
            let step = try await first.value
            let recovered = try await XCTUnwrap(second).value
            XCTAssertEqual(step, .completed(id: batch.id, intentSHA256: batch.intentSHA256))
            XCTAssertEqual(recovered, 0)
            XCTAssertEqual(probe.events, [.registered(waiting: true), .acquired])
            XCTAssertEqual(probe.acquiredAfterT3Commit, [true], "grant must follow the actual T3 didCommit callback")
        } catch {
            // Release before joining: otherwise a failed assertion/timeout can strand a native writer.
            barrier.releaseAll()
            _ = await first.result
            if let second { _ = await second.result }
            throw error
        }
    }

    private func requireFulfillment(_ expectation: XCTestExpectation,
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        guard result == .completed else {
            XCTFail("required gate/commit boundary timed out: \(expectation.expectationDescription)", file: file, line: line)
            throw ProjectionBarrierFailure.timeout
        }
    }

    func testSessionCapRetainsProjectedUsageAndAllowsExactBeginRetry() async throws {
        let s = try await fixture(); let first = try await begin(s)
        for _ in 1..<1024 { _ = try await begin(s) }
        await expect(.capacity) { _ = try await self.begin(s) }
        let exact = try await s.beginStandardHRCapture(owner: owner, sessionID: first.sessionID,
            runtimeGeneration: first.runtimeGeneration, openedAtUnixSeconds: 100)
        XCTAssertEqual(exact, first)
        let count = try await count(s, "standardHRCaptureSession"); XCTAssertEqual(count, 1024)
        let open = try await s.registryWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM standardHRCaptureSession WHERE sealed=0") }
        XCTAssertEqual(open, 1, "capacity rejection must roll back abandonment of the last session")
    }

    func testRecoveryOrdersBySessionOrdinalThenSequenceNotClockOrUUID() async throws {
        let s = try await fixture(); let first = try await begin(s, at: 900)
        let secondID = UUID(), generation = UUID()
        // Two historical sessions, before a new runtime claims its exclusive intake slot.
        try await s.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO standardHRCaptureSession(sessionID,projectURL,userID,runtimeGeneration,openedAt,sessionChargeBytes)
                VALUES (?,?,?,?,1,?)
                """, arguments: [secondID.uuidString.lowercased(), self.owner.projectURL, self.owner.userID,
                    generation.uuidString.lowercased(), 512 + self.owner.projectURL.utf8.count + self.owner.userID.utf8.count])
        }
        let second = try await s.beginStandardHRCapture(owner: owner, sessionID: secondID,
            runtimeGeneration: generation, openedAtUnixSeconds: 1)
        let a = try batch(first, ts: 500), b = try batch(first, sequence: 1, ts: 2), c = try batch(second, ts: 1)
        for (session, value) in [(second, c), (first, a), (first, b)] {
            _ = try await s.appendStandardHRCapture(value, session: session)
        }
        try await s.sealStandardHRCapture(first); try await s.sealStandardHRCapture(second)
        for expected in [a, b, c] {
            let actual = try await s.projectNextStandardHRCapture(owner: owner)
            XCTAssertEqual(actual, .completed(id: expected.id, intentSHA256: expected.intentSHA256))
        }
    }

    func testLiveProjectionIgnoresBackfillFrontierAndPreservesExistingDebtTokenOnReplay() async throws {
        let s = try await fixture(); let session = try await begin(s); let b = try batch(session, ts: 10)
        try await s.registryWriter.write { db in
            for stream in ["hr", "rr", "event"] {
                try db.execute(sql: "INSERT INTO backfillFrontier(deviceId,stream,maxTs) VALUES(?,?,99999)", arguments: [self.device, stream])
            }
        }
        // StreamStore currently hard-disables range skip, even if the old global opt-in is set.
        // Do not mutate ambient defaults to assert a branch the production source no longer reads.
        _ = try await s.appendStandardHRCapture(b, session: session)
        _ = try await s.projectNextStandardHRCapture(owner: owner)
        let jobs = try await s.owedJobs(); XCTAssertEqual(jobs.count, 1)
        _ = try await s.appendStandardHRCapture(batch(session, sequence: 1, ts: 10), session: session)
        _ = try await s.projectNextStandardHRCapture(owner: owner)
        let after = try await s.owedJobs(); XCTAssertEqual(after.map(\.token), jobs.map(\.token))
        let rows = try await count(s, "hrSample"); XCTAssertEqual(rows, 1)
    }

    func testSQLSessionUUIDNullOwnerAndInitialCountersFailWithoutSeedingMetadata() async throws {
        let s = try await fixture()
        let columns = ["sessionID", "projectURL", "userID", "runtimeGeneration", "openedAt", "sealed",
                       "nextSequence", "retainedCount", "retainedBytes", "sessionChargeBytes"]
        let values: [DatabaseValue] = [UUID().uuidString.lowercased().databaseValue, owner.projectURL.databaseValue,
            owner.userID.databaseValue, UUID().uuidString.lowercased().databaseValue, 0.databaseValue, 0.databaseValue,
            0.databaseValue, 0.databaseValue, 0.databaseValue, (512 + owner.projectURL.utf8.count + owner.userID.utf8.count).databaseValue]
        var bad: [(Int, DatabaseValue)] = [(0, String(repeating: "x", count: 36).databaseValue),
            (1, "https://other.invalid".databaseValue), (2, UUID().uuidString.databaseValue),
            (3, String(repeating: "0", count: 36).databaseValue), (4, 0.5.databaseValue),
            (5, 1.databaseValue), (6, 1.databaseValue), (7, 1.databaseValue), (8, 1.databaseValue), (9, Int64.max.databaseValue)]
        for index in columns.indices { bad.append((index, .null)) }
        let sql = "INSERT INTO standardHRCaptureSession(\(columns.joined(separator: ","))) VALUES(\(Array(repeating: "?", count: columns.count).joined(separator: ",")))"
        for (index, value) in bad {
            var invalid = values; invalid[index] = value
            let arguments = StatementArguments(invalid)
            do { try await s.registryWriter.write { try $0.execute(sql: sql, arguments: arguments) }; XCTFail("invalid \(columns[index])") } catch {}
        }
        let rows = try await count(s, "standardHRCaptureSession"); XCTAssertEqual(rows, 0)
        _ = try await begin(s)
    }

    func testPreV53PopulatedRowsSurviveAdditiveMigrationExactly() throws {
        let writer = try DatabaseQueue()
        defer { try? writer.close() }
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(writer, upTo: "v52-scalar-provenance")
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO device(id) VALUES('legacy');
                INSERT INTO hrSample(deviceId,ts,bpm) VALUES('legacy',101,72);
                INSERT INTO rrInterval(deviceId,ts,rrMs,seq,ord,srcChannel) VALUES('legacy',101,1000,0,0,NULL),('legacy',101,1000,1,1,NULL);
                INSERT INTO event(deviceId,ts,kind,payloadJSON) VALUES('legacy',101,'OPAQUE','{"future":9007199254740993}');
                """)
        }
        let tables = ["device", "hrSample", "rrInterval", "event", "localAccountOwner"]
        let before = try writer.read { db in try tables.map { try Row.fetchAll(db, sql: "SELECT rowid,* FROM \($0) ORDER BY rowid").map(\.description) } }
        try migrator.migrate(writer)
        try writer.read { db in
            let after = try tables.map { try Row.fetchAll(db, sql: "SELECT rowid,* FROM \($0) ORDER BY rowid").map(\.description) }
            XCTAssertEqual(after, before)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM standardHRCaptureSession"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM standardHRCaptureOccurrence"), 0)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testCountCapAtReal300000SQLRowsAllowsExactRetry() async throws {
        let s = try await fixture(path: temporaryPath()); let session = try await begin(s)
        let first = try batch(session); _ = try await s.appendStandardHRCapture(first, session: session)
        // SQL capacity probe: intentionally tiny opaque fixtures, not claimed valid projections.
        // Every row traverses the production admission/count triggers; no counters are patched.
        try await s.registryWriter.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<299999)
                INSERT INTO standardHRCaptureOccurrence(sessionID,sequence,deviceID,hostTimestampSeconds,
                    schemaVersion,decoderVersion,mappingVersion,rawBytes,projectionJSON,rawSHA256,intentSHA256,chargeBytes)
                SELECT ?,x,'d',0,1,'standard-hr-current-v1','standard-hr-one-notification-v1',x'01',x'7b7d',?,?,260 FROM n
                """, arguments: [session.sessionID.uuidString.lowercased(), first.rawSHA256, first.intentSHA256])
            // Settled history remains retained and must not release count capacity.
            try db.execute(sql: "UPDATE standardHRCaptureOccurrence SET projectionState=1,projectedAt=100 WHERE sequence>0")
        }
        await expect(.capacity) { _ = try await s.appendStandardHRCapture(self.batch(session, sequence: 300000), session: session) }
        let retry = try await s.appendStandardHRCapture(first, session: session); XCTAssertEqual(retry.id, first.id)
        let c = try await count(s, "standardHRCaptureOccurrence"); XCTAssertEqual(c, 300000)
        let unprojected = try await pending(s); XCTAssertEqual(unprojected, 1)
    }

    func testByteCapCountsActualPayloadPlusSessionMetadata() async throws {
        let s = try await fixture(path: temporaryPath()); let session = try await begin(s)
        let first = try batch(session); _ = try await s.appendStandardHRCapture(first, session: session)
        let sessionCharge = 512 + owner.projectURL.utf8.count + owner.userID.utf8.count
        let largeCharge = 512 + 12288 + 1 + 256
        let fill = (268435456 - sessionCharge - Int(first.chargeBytes)) / largeCharge
        try await s.registryWriter.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<?)
                INSERT INTO standardHRCaptureOccurrence(sessionID,sequence,deviceID,hostTimestampSeconds,
                    schemaVersion,decoderVersion,mappingVersion,rawBytes,projectionJSON,rawSHA256,intentSHA256,chargeBytes)
                SELECT ?,x,'d',0,1,'standard-hr-current-v1','standard-hr-one-notification-v1',zeroblob(512),zeroblob(12288),?,?,? FROM n
                """, arguments: [fill, session.sessionID.uuidString.lowercased(), first.rawSHA256, first.intentSHA256, largeCharge])
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO standardHRCaptureOccurrence(sessionID,sequence,deviceID,hostTimestampSeconds,
                    schemaVersion,decoderVersion,mappingVersion,rawBytes,projectionJSON,rawSHA256,intentSHA256,chargeBytes)
                VALUES (?,?,'d',0,1,'standard-hr-current-v1','standard-hr-one-notification-v1',zeroblob(512),zeroblob(12288),?,?,?)
                """, arguments: [session.sessionID.uuidString.lowercased(), fill+1, first.rawSHA256, first.intentSHA256, largeCharge]))
        }
        let retry = try await s.appendStandardHRCapture(first, session: session); XCTAssertEqual(retry.id, first.id)
        let c = try await count(s, "standardHRCaptureOccurrence"); XCTAssertEqual(c, fill+1)
    }
}

private final class RejectCommit: TransactionObserver {
    struct Rejected: Error {}
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseWillCommit() throws { throw Rejected() }
    func databaseDidCommit(_ db: Database) {}
    func databaseDidRollback(_ db: Database) {}
}

private enum ProjectionBarrierFailure: Error { case timeout, unexpectedTransaction }

private final class CommitBarrier: TransactionObserver, @unchecked Sendable {
    let releaseT2 = DispatchSemaphore(value: 0)
    let releaseT3 = DispatchSemaphore(value: 0)
    private let t2Entered: XCTestExpectation
    private let t3Entered: XCTestExpectation
    private let lock = NSLock()
    private var commitsEntered = 0
    private var commitsCompleted = 0
    private var changedTables: Set<String> = []

    init(t2Entered: XCTestExpectation, t3Entered: XCTestExpectation) {
        self.t2Entered = t2Entered; self.t3Entered = t3Entered
    }

    var didCommitT3: Bool { lock.withLock { commitsCompleted >= 2 } }

    func releaseAll() { releaseT2.signal(); releaseT3.signal() }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
    func databaseDidChange(with event: DatabaseEvent) { lock.withLock { _ = changedTables.insert(event.tableName) } }
    func databaseWillCommit() throws {
        let (ordinal, tables) = lock.withLock { commitsEntered += 1; return (commitsEntered, changedTables) }
        if ordinal == 1 || ordinal == 2 {
            let expectedTable = ordinal == 1 ? "hrSample" : "standardHRCaptureOccurrence"
            guard tables.contains(expectedTable) else {
                XCTFail("T\(ordinal + 1) barrier did not observe its actual \(expectedTable) write")
                throw ProjectionBarrierFailure.unexpectedTransaction
            }
        }
        let release: DispatchSemaphore
        switch ordinal {
        case 1: release = releaseT2; t2Entered.fulfill()
        case 2: release = releaseT3; t3Entered.fulfill()
        default: return
        }
        guard release.wait(timeout: .now() + 20) == .success else {
            XCTFail("native T\(ordinal + 1) barrier timed out without an explicit release")
            throw ProjectionBarrierFailure.timeout
        }
    }
    func databaseDidCommit(_ db: Database) { lock.withLock { commitsCompleted += 1; changedTables.removeAll() } }
    func databaseDidRollback(_ db: Database) { lock.withLock { changedTables.removeAll() } }
}

private final class ProjectionGateProbe: @unchecked Sendable {
    private let registered: XCTestExpectation
    private let barrier: CommitBarrier
    private let lock = NSLock()
    private var recorded: [StandardHRProjectionGateEvent] = []
    private var committedAtAcquisition: [Bool] = []

    init(registered: XCTestExpectation, barrier: CommitBarrier) {
        self.registered = registered; self.barrier = barrier
    }

    var events: [StandardHRProjectionGateEvent] { lock.withLock { recorded } }
    var acquiredAfterT3Commit: [Bool] { lock.withLock { committedAtAcquisition } }

    func record(_ event: StandardHRProjectionGateEvent) {
        lock.withLock {
            recorded.append(event)
            if event == .acquired { committedAtAcquisition.append(barrier.didCommitT3) }
        }
        if case .registered = event { registered.fulfill() }
    }
}
