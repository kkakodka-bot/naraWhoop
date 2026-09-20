import XCTest
import NoopPush
import WhoopStore
import WhoopProtocol
import GRDB
#if canImport(CloudUploadHarness)
@testable import CloudUploadHarness
#else
@testable import Strand
#endif

enum W5ReceiptFixture {
    static let owner = "11111111-1111-4111-8111-111111111111"
    static let source = "44444444-4444-4444-8444-444444444444"
    static func receipt(owner: String, device: String, object: String, batch: String, source: String,
                        stream: String, decoded: String, wire: String, decodedBytes: Int, wireBytes: Int,
                        key: String = "archive/verified-object", schema: Int = 1) -> [String: Any] {
        ["version": 1, "state": "verified_indexed", "receiptId": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
         "ownerUserId": owner, "deviceId": PushDurabilityReceipt.canonicalDevice(owner: owner, device: device),
         "objectId": object, "batchId": batch, "sourceId": source, "stream": stream, "schemaVersion": schema,
         "objectKey": key, "contentSha256": decoded, "wireSha256": wire, "compressedBytes": wireBytes,
         "uncompressedBytes": decodedBytes, "verifiedAt": "2026-09-18T00:00:00Z", "indexedAt": "2026-09-18T00:00:01Z"]
    }
    static func object(_ batch: PushBinaryBatch, owner: String, key: String = "archive/verified-object") -> [String: Any] {
        ["type": "objectAck", "protocolVersion": batch.protocolVersion, "objectId": batch.objectId,
         "objectKey": key, "status": "ready", "duplicate": false,
         "durabilityReceipt": receipt(owner: owner, device: batch.deviceId, object: batch.objectId,
            batch: batch.batchId, source: batch.sourceId, stream: batch.wireName, decoded: batch.contentSha256,
            wire: PushDurabilityReceipt.sha256(batch.payload), decodedBytes: batch.uncompressedBytes,
            wireBytes: batch.payload.count, key: key, schema: batch.protocolVersion == "1.3" && batch.table == .ppgWaveformSample ? 2 : 1)]
    }
    static func inline(_ batch: PushBatch, owner: String) -> [String: Any] {
        var cursor: Any = NSNull()
        if let end = batch.endCursor { cursor = ["rowId": end.rowId, "keySha256": end.naturalKeyFingerprint] }
        return ["protocolVersion": batch.protocolVersion, "batchId": batch.batchId, "stream": batch.table.wireName,
                "deviceId": batch.deviceId, "endCursor": cursor, "acceptedRows": batch.recordCount, "status": "accepted",
                "durabilityReceipt": receipt(owner: owner, device: batch.deviceId, object: batch.batchId,
                    batch: batch.batchId, source: batch.sourceId, stream: batch.table.wireName,
                    decoded: PushDurabilityReceipt.sha256(batch.body), wire: String(repeating: "a", count: 64),
                    decodedBytes: batch.body.count, wireBytes: 100)]
    }
    static func bytes(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
}

final class CloudPushReceiptIntegrationTests: XCTestCase {
    private let device = "opaque-fixture-strap"
    private let endpoint = "https://project.example/functions/v1/push"
    private let lane = PushObjectLane(endpoint: "/functions/v1/push/objects", maxObjectBytes: 8_000_000,
                                      urlTtlSec: 300, streams: [.rawBatch, .ppgWaveformSample, .rawImuSession])

    private struct Fixture {
        let root: URL
        let context: AccountSessionContext
        let layout: AccountStorageLayout
        let store: WhoopStore
        let snapshot: CloudPushSnapshot
        let progress: CloudPushProgressStore
        let runtime: CloudPushBackgroundRuntime
        let transport: CloudAccountPushTransport
        let session: URLSession
    }
    private func fixture(imuSource: (any ImuSessionPushSource)? = nil,
                         progressVersion: String? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("w5-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = AccountSessionContext(scope: try .init(projectURL: "https://project.example", userID: W5ReceiptFixture.owner), generation: UUID())
        let layout = AccountStorageLayout(baseDirectory: root, scope: context.scope)
        let store = try await WhoopStore(path: root.appendingPathComponent("source.sqlite").path)
        try await store.bindAccountOwner(projectURL: context.scope.projectURL, userID: context.scope.userID)
        try await store.upsertDevice(id: device, mac: nil, name: nil)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [W5IntakeProtocol.self]
        let session = URLSession(configuration: config)
        let runtime = try CloudPushBackgroundRuntime(context: context, layout: layout, authorize: { _ in "synthetic" },
            isCurrent: { _ in true }, policy: { .init(concurrency: 2, allowsCellular: false, allowsConstrained: false) },
            sessionConfiguration: config)
        CloudPushBackgroundRuntime.install(runtime)
        let transport = try CloudAccountPushTransport(endpoint: .init(url: endpoint, host: "project.example"),
            context: context, accessToken: "synthetic", session: session, isCurrent: { _ in true })
        let admission = try AccountPushAdmission(context: context, captureScope: context.scope,
            sourceID: W5ReceiptFixture.source, isCurrent: { _ in true })
        let namespace = progressVersion.map { admission.namespace(endpoint: endpoint, protocolVersion: $0,
            receiverStateID: "99999999-9999-4999-8999-999999999999") } ?? "test-receiver"
        return Fixture(root: root, context: context, layout: layout, store: store,
            snapshot: CloudPushSnapshot(db: store.registryWriter, imuPushSource: imuSource),
            progress: try CloudPushProgressStore(namespace: namespace, directory: runtime.progressDirectory,
                auxiliaryIdentityV2: progressVersion == PushProtocol.auxiliaryIdentityVersion),
            runtime: runtime, transport: transport, session: session)
    }
    private func close(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) async {
        CloudPushBackgroundRuntime.install(nil); await f.runtime.retire(); f.session.invalidateAndCancel()
        W5IntakeProtocol.set { _ in throw CloudUploadError.unavailable }
        do {
            try f.store.registryWriter.close()
            if FileManager.default.fileExists(atPath: f.root.path) { try FileManager.default.removeItem(at: f.root) }
        } catch { XCTFail("Receipt fixture cleanup failed; retained directory: \(error)", file: file, line: line) }
    }
    func testReopenAndCleanupCloseRetainedOriginalAndReplacementStoreHandles() async throws {
        func assertClosed(_ store: WhoopStore) async {
            do {
                _ = try await store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT 1") }
                XCTFail("retained fixture writer remains open")
            } catch { XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_MISUSE) }
        }
        let original = try await fixture()
        var replacement: Fixture?
        do {
            let reopened = try await reopen(original); replacement = reopened
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.root.path))
            await assertClosed(original.store)
            let value = try await reopened.store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT 1") }
            XCTAssertEqual(value, 1)
            await close(reopened)
            XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.root.path))
            await assertClosed(reopened.store)
        } catch { await close(replacement ?? original); throw error }
    }
    private func raw(_ f: Fixture, version: String = PushProtocol.objectVersion) async throws -> PushBinaryBatch {
        let meta = RawBatchMeta(batchId: "raw-fixture", deviceId: device, clockRef: ClockRef(device: 1, wall: 1),
            capturedAt: 1, startTs: 1, endTs: 1, frameCount: 1, byteSize: 3,
            captureScope: .init(environment: f.context.scope.projectURL, accountID: f.context.scope.userID, deviceID: device))
        try await f.store.enqueueRawBatch(meta, frames: [[1, 2, 3]])
        let rows = try await f.snapshot.binaryRows(table: .rawBatch, deviceId: device, afterRowId: 0, limit: 1)
        return try PushProtocol.binaryObjectBatch(table: .rawBatch, sourceId: W5ReceiptFixture.source,
            deviceId: device, startCursor: nil, rows: rows, protocolVersion: version)
    }
    private func serve(batch: PushBinaryBatch? = nil, inline: PushBatch? = nil,
                       mutation: [String: Any]? = nil, duplicate: Bool = false,
                       rejectGzip: Bool = false, loseCompletion: Bool = false,
                       receiver: String = "99999999-9999-4999-8999-999999999999",
                       onCapabilities: (() -> Void)? = nil) throws {
        let objectResponse = try batch.map { try W5ReceiptFixture.bytes(mutation ?? W5ReceiptFixture.object($0, owner: W5ReceiptFixture.owner)) }
        let inlineResponse = try inline.map { try W5ReceiptFixture.bytes(mutation ?? W5ReceiptFixture.inline($0, owner: W5ReceiptFixture.owner)) }
        W5IntakeProtocol.set { request in
            if request.httpMethod == "GET" {
                onCapabilities?()
                return (200, try W5ReceiptFixture.bytes(["type": "capabilities", "protocolVersion": batch?.protocolVersion ?? "1.2",
                    "receiverStateId": receiver, "userId": W5ReceiptFixture.owner,
                    "streams": ["hrSample", "rawBatch", "rawImuSession"], "maxRecords": 1000, "maxBodyBytes": 1_048_576,
                    "objectLane": ["endpoint": "/functions/v1/push/objects", "maxObjectBytes": 8_000_000,
                                   "streams": ["rawBatch", "rawImuSession"], "urlTtlSec": 300]]))
            }
            if request.httpMethod == "PUT" { return (200, Data()) }
            if request.url!.path.hasSuffix("/complete"), let objectResponse {
                if loseCompletion { throw URLError(.networkConnectionLost) }
                return (200, objectResponse)
            }
            if request.url!.path.hasSuffix("/objects"), let batch {
                return (200, try W5ReceiptFixture.bytes(["type": "objectIntent", "protocolVersion": batch.protocolVersion,
                    "objectId": batch.objectId, "objectKey": duplicate ? "archive/verified-object" : "staging/write-only",
                    "duplicate": duplicate, "uploadUrl": duplicate ? NSNull() : "https://bucket.example/upload",
                    "requiredHeaders": ["Content-Type": "application/octet-stream"], "expiresAt": "2030-01-01T00:00:00Z"]))
            }
            if let inlineResponse {
                if rejectGzip && request.value(forHTTPHeaderField: "Content-Encoding") == "gzip" { return (415, Data()) }
                return (200, inlineResponse)
            }
            throw CloudUploadError.unavailable
        }
    }
    private func committer(_ f: Fixture, cleanup: (@Sendable (String) async throws -> Void)? = nil) -> CloudPushSourceCommitter {
        CloudPushSourceCommitter(progress: f.progress, check: {},
            acknowledge: { try await f.snapshot.acknowledgeCommitted($0, scope: f.context.scope) },
            cleanup: cleanup ?? { try await f.transport.base.sourceCommitted(batchID: $0) },
            didApply: { try f.snapshot.sourceProgressApplied($0, scope: f.context.scope) },
            didCleanup: { try f.snapshot.sourceCleanupCompleted($0, scope: f.context.scope) })
    }
    private func coordinator(_ f: Fixture, cleanup: (@Sendable (String) async throws -> Void)? = nil,
                             version: String = PushProtocol.objectVersion,
                             sourceCommitter: CloudPushSourceCommitter? = nil,
                             afterAssociation: (@Sendable () throws -> Void)? = nil) -> PushCoordinator {
        let committer = sourceCommitter ?? committer(f, cleanup: cleanup)
        return PushCoordinator(source: f.snapshot, transport: f.transport, progress: f.progress,
            sourceId: W5ReceiptFixture.source, receiptOwner: f.context.scope, objectProtocolVersion: version,
            associateReceipt: { batch, rows, receipt in
                try await f.snapshot.associateReceipt(batch: batch, rows: rows, receipt: receipt, scope: f.context.scope)
                try await f.progress.associate(batch: batch, rows: rows, receipt: receipt)
                try afterAssociation?()
            }, associateInlineReceipt: { try await f.progress.associateInline(batch: $0, receipt: $1) },
            commitSource: { try await committer.commit($0) })
    }
    func testAccountWrapperBindsReceiverAndObjectCoordinatorAssociatesThenCleansActualQueue() async throws {
        let f = try await fixture()
        do {
            let batch = try await raw(f); try serve(batch: batch)
            guard case .available = try await f.transport.capabilities() else { return XCTFail("capabilities") }
            let result = await coordinator(f).pushObjects(.rawBatch, deviceId: device, lane: lane)
            guard case .accepted = result else { throw TestFailure.rejected(String(describing: result)) }
            let remaining = try CloudUploadJournal(directory: f.layout.uploadDirectory).load()
            XCTAssertTrue(remaining.isEmpty, "no manual sourceCommitted call in this test")
            let row = try await f.store.registryWriter.read { try Row.fetchOne($0, sql: "SELECT * FROM rawDurabilityReceipt") }
            XCTAssertEqual(row?["objectKey"] as String?, "archive/verified-object")
            let synced = try await f.store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT syncedAt FROM rawBatch") }
            XCTAssertNotNil(synced)
            let debt = await f.progress.pendingCommits(); XCTAssertTrue(debt.isEmpty)
            let pruned = try await f.store.pruneRaw(now: Int(Date().timeIntervalSince1970), keepWindowSeconds: 0, maxUnsyncedBytes: 0)
            XCTAssertEqual(pruned, 1)
        } catch { await close(f); throw error }
        await close(f)
    }
    func testDuplicateIntentStillRequiresFullReceiptAndPersistsPayloadIdentity() async throws {
        let f = try await fixture()
        do {
            let batch = try await raw(f); try serve(batch: batch, duplicate: true)
            _ = try await f.transport.capabilities()
            let result = await coordinator(f).pushObjects(.rawBatch, deviceId: device, lane: lane)
            guard case .accepted = result else { throw TestFailure.rejected(String(describing: result)) }
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
        } catch { await close(f); throw error }
        await close(f)
    }
    func testLegacyReadyAndEveryReceiptIdentityMismatchRetainRawRowsCursorAndUploadBody() async throws {
        let mutations: [(String, Any)] = [("ownerUserId", "22222222-2222-4222-8222-222222222222"),
            ("deviceId", "22222222-2222-4222-8222-222222222222"), ("objectId", "22222222-2222-4222-8222-222222222222"),
            ("batchId", "22222222-2222-4222-8222-222222222222"), ("sourceId", "22222222-2222-4222-8222-222222222222"),
            ("stream", "v18AuxSample"), ("schemaVersion", 2), ("contentSha256", String(repeating: "0", count: 64)),
            ("wireSha256", String(repeating: "0", count: 64)), ("compressedBytes", 1), ("uncompressedBytes", 1),
            ("state", "pending"), ("version", 2), ("objectKey", "unrelated/archive"), ("legacy", true)]
        for (field, value) in mutations {
            let f = try await fixture()
            do {
                let batch = try await raw(f)
                var response = W5ReceiptFixture.object(batch, owner: f.context.scope.userID)
                var receipt = response["durabilityReceipt"] as! [String: Any]; receipt[field] = value
                response["durabilityReceipt"] = field == "legacy" ? nil : receipt
                try serve(batch: batch, mutation: response); _ = try await f.transport.capabilities()
                let result = await coordinator(f).pushObjects(.rawBatch, deviceId: device, lane: lane)
                if case .accepted = result { XCTFail("accepted invalid \(field)") }
                let cursor = try await f.progress.binaryCursor(table: .rawBatch, deviceId: device); XCTAssertNil(cursor, field)
                let state = try await f.store.registryWriter.read { db in
                    (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawDurabilityReceipt"),
                     try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawBatch WHERE syncedAt IS NULL"))
                }
                XCTAssertEqual(state.0, 0, field); XCTAssertEqual(state.1, 1, field)
                let job = try XCTUnwrap(CloudUploadJournal(directory: f.layout.uploadDirectory).load().values.first)
                XCTAssertEqual(try Data(contentsOf: CloudUploadJournal(directory: f.layout.uploadDirectory).bodyURL(job)), batch.payload)
            } catch { await close(f); throw error }
            await close(f)
        }
    }
    func testCrashAfterCursorBeforeCleanupReopensDebtAndAutomaticallyReclaimsBody() async throws {
        let f = try await fixture()
        do {
            let batch = try await raw(f); try serve(batch: batch); _ = try await f.transport.capabilities()
            let result = await coordinator(f, cleanup: { _ in throw TestFailure.crash }).pushObjects(.rawBatch, deviceId: device, lane: lane)
            if case .accepted = result { XCTFail("injected crash") }
            let debt = await f.progress.pendingCommits(); XCTAssertEqual(debt.count, 1)
            XCTAssertEqual(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().count, 1)
            let reopened = try CloudPushProgressStore(namespace: "test-receiver", directory: f.runtime.progressDirectory)
            let resumed = CloudPushSourceCommitter(progress: reopened, check: {},
                acknowledge: { try await f.snapshot.acknowledgeCommitted($0, scope: f.context.scope) },
                cleanup: { try await f.transport.base.sourceCommitted(batchID: $0) })
            try await resumed.recover(); try await resumed.recover()
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
            let remainingDebt = await reopened.pendingCommits(); XCTAssertTrue(remainingDebt.isEmpty)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testProtocolUpgradeRecoversActualSourceAndQueueAtEveryCommitBarrierWithoutRetransmission() async throws {
        for barrier in 0..<3 {
            let f = try await fixture(progressVersion: PushProtocol.identityObjectVersion)
            do {
                let batch = try await raw(f, version: PushProtocol.identityObjectVersion)
                let sourceRows = try await f.snapshot.binaryRows(table: .rawBatch, deviceId: device,
                    afterRowId: 0, limit: 1)
                let oldAuxCursor = PushCursor(rowId: 42, naturalKeyFingerprint: String(repeating: "a", count: 64))
                try await f.progress.saveBinaryCursor(table: .v18AuxSample, deviceId: device, cursor: oldAuxCursor)
                try serve(batch: batch); _ = try await f.transport.capabilities()
                let interrupted = CloudPushSourceCommitter(progress: f.progress, check: {},
                    acknowledge: {
                        try await f.snapshot.acknowledgeCommitted($0, scope: f.context.scope)
                        if barrier == 0 { throw TestFailure.crash }
                    }, cleanup: {
                        if barrier == 1 { throw TestFailure.crash }
                        try await f.transport.base.sourceCommitted(batchID: $0)
                    }, didCleanup: { _ in if barrier == 2 { throw TestFailure.crash } })
                let result = await coordinator(f, version: PushProtocol.identityObjectVersion,
                    sourceCommitter: interrupted).pushObjects(.rawBatch, deviceId: device, lane: lane)
                if case .accepted = result { XCTFail("injected commit barrier \(barrier)") }
                let originalDebt = await f.progress.pendingCommits()
                XCTAssertEqual(originalDebt.count, 1)
                let admission = try AccountPushAdmission(context: f.context, captureScope: f.context.scope,
                    sourceID: W5ReceiptFixture.source, isCurrent: { _ in true })
                let foreignNamespace = admission.namespace(endpoint: endpoint,
                    protocolVersion: PushProtocol.identityObjectVersion, receiverStateID: "another-receiver")
                let foreign = try CloudPushProgressStore(namespace: foreignNamespace, directory: f.runtime.progressDirectory)
                let receipt = try PushObjectAck.parse(W5ReceiptFixture.bytes(W5ReceiptFixture.object(batch,
                    owner: f.context.scope.userID)), expectedObjectId: batch.objectId,
                    expectedVersion: batch.protocolVersion).durabilityReceipt
                try await foreign.associate(batch: batch, rows: sourceRows, receipt: try XCTUnwrap(receipt))
                try await foreign.stage(try XCTUnwrap(originalDebt.first))
                W5IntakeProtocol.set { _ in XCTFail("recovery must not contact the network"); throw TestFailure.crash }
                let makeCommitter: (CloudPushProgressStore) -> CloudPushSourceCommitter = { progress in
                    CloudPushSourceCommitter(progress: progress, check: { try admission.check() },
                        acknowledge: { try await f.snapshot.acknowledgeCommitted($0, scope: f.context.scope) },
                        cleanup: { try await f.transport.base.sourceCommitted(batchID: $0) })
                }
                for version in [PushProtocol.auxiliaryIdentityVersion, PushProtocol.identityObjectVersion,
                                PushProtocol.auxiliaryIdentityVersion] {
                    let current = try await CloudPushProgressRecovery.recover(admission: admission,
                        endpoint: endpoint, receiverStateID: "99999999-9999-4999-8999-999999999999",
                        currentVersion: version, directory: f.runtime.progressDirectory, committer: makeCommitter)
                    if version == PushProtocol.auxiliaryIdentityVersion {
                        let cursor = try await current.binaryCursor(table: .rawBatch, deviceId: device)
                        XCTAssertNil(cursor, "historical cursors must not be copied to the new identity namespace")
                        let aux = try await current.binaryCursor(table: .v18AuxSample, deviceId: device)
                        XCTAssertNil(aux)
                    }
                }
                let namespace = admission.namespace(endpoint: endpoint, protocolVersion: PushProtocol.identityObjectVersion,
                    receiverStateID: "99999999-9999-4999-8999-999999999999")
                let reopened = try CloudPushProgressStore(namespace: namespace, directory: f.runtime.progressDirectory)
                let remaining = await reopened.pendingCommits()
                XCTAssertTrue(remaining.isEmpty)
                let preservedAux = try await reopened.binaryCursor(table: .v18AuxSample, deviceId: device)
                XCTAssertEqual(preservedAux, oldAuxCursor)
                XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
                let foreignDebt = await foreign.pendingCommits()
                XCTAssertEqual(foreignDebt.count, 1)
                let associations = try FileManager.default.contentsOfDirectory(at: f.runtime.progressDirectory,
                    includingPropertiesForKeys: nil).filter { $0.pathExtension == "receipt" }
                XCTAssertEqual(associations.count, 1, "only the unrelated receiver association remains")
                let count = try await f.store.registryWriter.read { try Int.fetchOne($0,
                    sql: "SELECT COUNT(*) FROM rawDurabilityReceipt") }
                XCTAssertEqual(count, 1)
            } catch { await close(f); throw error }
            await close(f)
        }
    }

    private func associatedInline(_ f: Fixture, rowID: Int64) async throws -> PushBatch {
        let batch = try PushProtocol.appendBatch(table: .hrSample, sourceId: W5ReceiptFixture.source,
            deviceId: device, startCursor: nil,
            records: [.init(rowId: rowID, key: ["ts": .int(rowID)], data: ["bpm": .int(60)])])
        let ack = try PushAck.parse(W5ReceiptFixture.bytes(W5ReceiptFixture.inline(batch, owner: f.context.scope.userID)))
        try await f.progress.associateInline(batch: batch, receipt: try XCTUnwrap(ack.durabilityReceipt))
        return batch
    }

    func testSettledAssociationsAreReclaimedWithoutRemovingUnstagedReceipt() async throws {
        let f = try await fixture()
        do {
            let unstaged = try await associatedInline(f, rowID: 1000)
            let commit = CloudPushSourceCommitter(progress: f.progress, check: {}, acknowledge: { _ in }, cleanup: { _ in })
            for rowID in 1...200 {
                let batch = try await associatedInline(f, rowID: Int64(rowID))
                try await commit.commit(.init(kind: .append, table: "hrSample", deviceID: device,
                    batchIDs: [batch.batchId], cursor: batch.endCursor))
            }
            let files = try FileManager.default.contentsOfDirectory(at: f.runtime.progressDirectory,
                includingPropertiesForKeys: nil).filter { $0.pathExtension == "receipt" }
            XCTAssertEqual(files.count, 1)
            XCTAssertTrue(files[0].lastPathComponent.contains(AccountScope.digest(unstaged.batchId)))
            let pending = await f.progress.pendingCommits()
            XCTAssertTrue(pending.isEmpty)
            let reopened = try CloudPushProgressStore(namespace: "test-receiver", directory: f.runtime.progressDirectory)
            let cursor = try await reopened.cursor(table: .hrSample, deviceId: device)
            XCTAssertEqual(cursor?.rowId, 200)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testPartialReceiptUnlinkFailureKeepsDebtAndReopensWithoutRestagingMissingReceipt() async throws {
        let f = try await fixture()
        do {
            let first = try await associatedInline(f, rowID: 1)
            let second = try await associatedInline(f, rowID: 2)
            let value = PushSourceCommit(kind: .append, table: "hrSample", deviceID: device,
                batchIDs: [first.batchId, second.batchId], cursor: second.endCursor)
            try await f.progress.stage(value)
            let prefix = CloudPushProgressStore.stateFile(namespace: "test-receiver", directory: f.runtime.progressDirectory).lastPathComponent
            let firstURL = f.runtime.progressDirectory.appendingPathComponent(prefix + "." + AccountScope.digest(first.batchId) + ".receipt")
            let secondURL = f.runtime.progressDirectory.appendingPathComponent(prefix + "." + AccountScope.digest(second.batchId) + ".receipt")
            let saved = f.root.appendingPathComponent("saved-association")
            try FileManager.default.moveItem(at: secondURL, to: saved)
            try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: false)
            let commit = CloudPushSourceCommitter(progress: f.progress, check: {}, acknowledge: { _ in }, cleanup: { _ in })
            do { try await commit.recover(); XCTFail("unlink of a directory must fail") }
            catch { XCTAssertTrue(error is POSIXError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
            let debt = await f.progress.pendingCommits()
            XCTAssertEqual(debt.count, 1)
            try FileManager.default.removeItem(at: secondURL)
            try FileManager.default.moveItem(at: saved, to: secondURL)
            let reopened = try CloudPushProgressStore(namespace: "test-receiver", directory: f.runtime.progressDirectory)
            let resumed = CloudPushSourceCommitter(progress: reopened, check: {}, acknowledge: { _ in }, cleanup: { _ in })
            try await resumed.recover()
            try await resumed.recover()
            let remaining = await reopened.pendingCommits()
            XCTAssertTrue(remaining.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
        } catch { await close(f); throw error }
        await close(f)
    }

    func testHistoricalProgressRecoveryRetainsDebtIfOwnerRetiresDuringSourceAcknowledgement() async throws {
        let f = try await fixture(progressVersion: PushProtocol.identityObjectVersion)
        do {
            let batch = try await raw(f, version: PushProtocol.identityObjectVersion)
            try serve(batch: batch); _ = try await f.transport.capabilities()
            _ = await coordinator(f, cleanup: { _ in throw TestFailure.crash }, version: PushProtocol.identityObjectVersion)
                .pushObjects(.rawBatch, deviceId: device, lane: lane)
            let owner = W5CurrentOwner()
            let admission = try AccountPushAdmission(context: f.context, captureScope: f.context.scope,
                sourceID: W5ReceiptFixture.source, isCurrent: { _ in owner.current })
            do {
                _ = try await CloudPushProgressRecovery.recover(admission: admission, endpoint: endpoint,
                    receiverStateID: "99999999-9999-4999-8999-999999999999",
                    currentVersion: PushProtocol.auxiliaryIdentityVersion, directory: f.runtime.progressDirectory) { progress in
                    CloudPushSourceCommitter(progress: progress, check: { try admission.check() },
                        acknowledge: { _ in owner.retire() }, cleanup: { _ in XCTFail("retired owner reached cleanup") })
                }
                XCTFail("retired owner recovered progress")
            } catch { XCTAssertEqual(error as? AccountAuthError, .staleOperation) }
            let namespace = admission.namespace(endpoint: endpoint, protocolVersion: PushProtocol.identityObjectVersion,
                receiverStateID: "99999999-9999-4999-8999-999999999999")
            let reopened = try CloudPushProgressStore(namespace: namespace, directory: f.runtime.progressDirectory)
            let debt = await reopened.pendingCommits()
            XCTAssertEqual(debt.count, 1)
            XCTAssertEqual(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().count, 1)
        } catch { await close(f); throw error }
        await close(f)
    }
    func testPreStageBinaryAssociationRecoversOriginalVersionWithoutRetransmission() async throws {
        for version in [PushProtocol.objectVersion, PushProtocol.identityObjectVersion] {
            let f = try await fixture(progressVersion: version)
            do {
                let batch = try await raw(f, version: version)
                try serve(batch: batch); _ = try await f.transport.capabilities()
                let interrupted = await coordinator(f, version: version,
                    afterAssociation: { throw TestFailure.crash }).pushObjects(.rawBatch, deviceId: device, lane: lane)
                if case .accepted = interrupted { XCTFail("injected pre-stage fault") }
                let unstaged = await f.progress.pendingCommits()
                XCTAssertTrue(unstaged.isEmpty, "fault precedes the coordinator's explicit stage")
                let journal = try CloudUploadJournal(directory: f.layout.uploadDirectory)
                let old = try XCTUnwrap(journal.load().values.first)
                XCTAssertEqual(old.phase, .receiptSaved)
                XCTAssertFalse(old.acknowledged)
                XCTAssertEqual(try Data(contentsOf: journal.bodyURL(old)), batch.payload)
                let before = try await f.store.registryWriter.read { try Int.fetchOne($0,
                    sql: "SELECT COUNT(*) FROM rawBatch WHERE syncedAt IS NOT NULL") }
                XCTAssertEqual(before, 0)
                let admission = try AccountPushAdmission(context: f.context, captureScope: f.context.scope,
                    sourceID: W5ReceiptFixture.source, isCurrent: { _ in true })
                let makeCommitter: (CloudPushProgressStore) -> CloudPushSourceCommitter = { progress in
                    CloudPushSourceCommitter(progress: progress, check: { try admission.check() },
                        acknowledge: { try await f.snapshot.acknowledgeCommitted($0, scope: f.context.scope) },
                        cleanup: { try await f.transport.base.sourceCommitted(batchID: $0) })
                }
                // A new store is opened from disk for each historical version. No GET, PUT or
                // completion response is available: only the original typed receipt may settle it.
                W5IntakeProtocol.set { _ in XCTFail("pre-stage recovery retransmitted"); throw TestFailure.crash }
                let current = try await CloudPushProgressRecovery.recover(admission: admission, endpoint: endpoint,
                    receiverStateID: "99999999-9999-4999-8999-999999999999",
                    currentVersion: PushProtocol.auxiliaryIdentityVersion, directory: f.runtime.progressDirectory,
                    committer: makeCommitter)
                _ = try await CloudPushProgressRecovery.recover(admission: admission, endpoint: endpoint,
                    receiverStateID: "99999999-9999-4999-8999-999999999999",
                    currentVersion: PushProtocol.auxiliaryIdentityVersion, directory: f.runtime.progressDirectory,
                    committer: makeCommitter)
                XCTAssertTrue(try journal.load().isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: try journal.bodyURL(old).path))
                let synced = try await f.store.registryWriter.read { try Int.fetchOne($0,
                    sql: "SELECT COUNT(*) FROM rawBatch WHERE syncedAt IS NOT NULL") }
                XCTAssertEqual(synced, 1)
                let newPending = await current.pendingCommits()
                XCTAssertTrue(newPending.isEmpty)
                let rows = try await f.snapshot.binaryRows(table: .rawBatch, deviceId: device, afterRowId: 0, limit: 1)
                XCTAssertTrue(rows.isEmpty, "a version change must not upload the same source under a new batch ID")
                let associations = try FileManager.default.contentsOfDirectory(at: f.runtime.progressDirectory,
                    includingPropertiesForKeys: nil).filter { $0.pathExtension == "receipt" }
                XCTAssertTrue(associations.isEmpty)
            } catch { await close(f); throw error }
            await close(f)
        }
    }

    func testIndependentPreStageFullRestartAndPromotionCrashKeepExactCursor() async throws {
        let receiver = "99999999-9999-4999-8999-999999999999"
        for version in [PushProtocol.objectVersion, PushProtocol.identityObjectVersion] {
            for promoteBeforeRestart in [false, true] {
                var f = try await fixture(progressVersion: version)
                do {
                    let batch = try await raw(f, version: version)
                    let sibling = PushCursor(rowId: 42, naturalKeyFingerprint: String(repeating: "b", count: 64))
                    try await f.progress.saveBinaryCursor(table: .v18AuxSample, deviceId: device, cursor: sibling)
                    try serve(batch: batch); _ = try await f.transport.capabilities()
                    let result = await coordinator(f, version: version, afterAssociation: { throw TestFailure.crash })
                        .pushObjects(.rawBatch, deviceId: device, lane: lane)
                    if case .accepted = result { XCTFail("pre-stage barrier not reached") }
                    let journal = try CloudUploadJournal(directory: f.layout.uploadDirectory)
                    let old = try XCTUnwrap(journal.load().values.first)
                    XCTAssertEqual(old.phase, .receiptSaved)
                    XCTAssertEqual(try Data(contentsOf: journal.bodyURL(old)), batch.payload)
                    if promoteBeforeRestart {
                        try await f.progress.recoverAssociatedCommits()
                        let pending = await f.progress.pendingCommits()
                        XCTAssertEqual(pending.count, 1)
                    }
                    W5IntakeProtocol.set { _ in XCTFail("restart/recovery must be offline"); throw TestFailure.crash }
                    // Close the original SQLite handle, retire the stable session, and instantiate
                    // the actual queue, snapshot and transport under a new login generation.
                    f = try await reopen(f)
                    let reopened = f
                    try reopened.transport.base.bindReceiverState(receiver)
                    let admission = try AccountPushAdmission(context: reopened.context, captureScope: reopened.context.scope,
                        sourceID: W5ReceiptFixture.source, isCurrent: { _ in true })
                    let make: (CloudPushProgressStore) -> CloudPushSourceCommitter = { progress in
                        CloudPushSourceCommitter(progress: progress, check: { try admission.check() },
                            acknowledge: { try await reopened.snapshot.acknowledgeCommitted($0, scope: reopened.context.scope) },
                            cleanup: { try await reopened.transport.base.sourceCommitted(batchID: $0) })
                    }
                    for currentVersion in [PushProtocol.auxiliaryIdentityVersion, version, PushProtocol.auxiliaryIdentityVersion] {
                        let current = try await CloudPushProgressRecovery.recover(admission: admission, endpoint: endpoint,
                            receiverStateID: receiver, currentVersion: currentVersion,
                            directory: reopened.runtime.progressDirectory, committer: make)
                        let cursor = try await current.binaryCursor(table: .rawBatch, deviceId: device)
                        XCTAssertEqual(cursor, currentVersion == version ? batch.endCursor : nil)
                    }
                    let original = try CloudPushProgressStore(namespace: admission.namespace(endpoint: endpoint,
                        protocolVersion: version, receiverStateID: receiver), directory: reopened.runtime.progressDirectory)
                    let cursor = try await original.binaryCursor(table: .rawBatch, deviceId: device)
                    let preserved = try await original.binaryCursor(table: .v18AuxSample, deviceId: device)
                    let pending = await original.pendingCommits()
                    XCTAssertEqual(cursor, batch.endCursor)
                    XCTAssertEqual(preserved, sibling)
                    XCTAssertTrue(pending.isEmpty)
                    XCTAssertTrue(try journal.load().isEmpty)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: try journal.bodyURL(old).path))
                    let proof = try await reopened.store.registryWriter.read { db in
                        (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawBatch WHERE syncedAt IS NOT NULL"),
                         try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawDurabilityReceipt"))
                    }
                    XCTAssertEqual(proof.0, 1); XCTAssertEqual(proof.1, 1)
                } catch { await close(f); throw error }
                await close(f)
            }
        }
    }

    func testIndependentDiscoveryPreservesOtherNamespacesLegacyAndInline() async throws {
        let f = try await fixture(progressVersion: PushProtocol.identityObjectVersion)
        do {
            let version = PushProtocol.identityObjectVersion
            let receiver = "99999999-9999-4999-8999-999999999999"
            let batch = try await raw(f, version: version)
            let rows = try await f.snapshot.binaryRows(table: .rawBatch, deviceId: device, afterRowId: 0, limit: 1)
            let admission = try AccountPushAdmission(context: f.context, captureScope: f.context.scope,
                sourceID: W5ReceiptFixture.source, isCurrent: { _ in true })
            let otherOwner = AccountSessionContext(scope: try .init(projectURL: f.context.scope.projectURL,
                userID: "22222222-2222-4222-8222-222222222222"), generation: UUID())
            let otherSource = "55555555-5555-4555-8555-555555555555"
            let variants: [(AccountSessionContext, String, String, String)] = [
                (otherOwner, W5ReceiptFixture.source, endpoint, receiver),
                (f.context, otherSource, endpoint, receiver),
                (f.context, W5ReceiptFixture.source, endpoint, "88888888-8888-4888-8888-888888888888"),
                (f.context, W5ReceiptFixture.source, "https://other.example/functions/v1/push", receiver)
            ]
            var preserved: [URL: Data] = [:]
            for (context, source, foreignEndpoint, foreignReceiver) in variants {
                let foreignAdmission = try AccountPushAdmission(context: context, captureScope: context.scope,
                    sourceID: source, isCurrent: { _ in true })
                let namespace = foreignAdmission.namespace(endpoint: foreignEndpoint, protocolVersion: version,
                    receiverStateID: foreignReceiver)
                let progress = try CloudPushProgressStore(namespace: namespace, directory: f.runtime.progressDirectory)
                let foreignBatch = try PushProtocol.binaryObjectBatch(table: .rawBatch, sourceId: source,
                    deviceId: device, startCursor: nil, rows: rows, protocolVersion: version)
                let ack = try PushObjectAck.parse(W5ReceiptFixture.bytes(W5ReceiptFixture.object(foreignBatch,
                    owner: context.scope.userID)), expectedObjectId: foreignBatch.objectId, expectedVersion: version)
                try await progress.associate(batch: foreignBatch, rows: rows, receipt: try XCTUnwrap(ack.durabilityReceipt))
                let state = CloudPushProgressStore.stateFile(namespace: namespace, directory: f.runtime.progressDirectory)
                let association = f.runtime.progressDirectory.appendingPathComponent(state.lastPathComponent + "." +
                    AccountScope.digest(foreignBatch.batchId) + ".receipt")
                preserved[state] = try Data(contentsOf: state)
                preserved[association] = try Data(contentsOf: association)
            }
            // An association produced by the old Codable shape has no sourceCommit. Preserve
            // that ordinary on-disk upgrade fixture, as well as a valid uncommitted inline part.
            let ack = try PushObjectAck.parse(W5ReceiptFixture.bytes(W5ReceiptFixture.object(batch,
                owner: f.context.scope.userID)), expectedObjectId: batch.objectId, expectedVersion: version)
            try await f.progress.associate(batch: batch, rows: rows, receipt: try XCTUnwrap(ack.durabilityReceipt))
            _ = try await associatedInline(f, rowID: 99)
            let state = CloudPushProgressStore.stateFile(namespace: admission.namespace(endpoint: endpoint,
                protocolVersion: version, receiverStateID: receiver), directory: f.runtime.progressDirectory)
            let legacy = f.runtime.progressDirectory.appendingPathComponent(state.lastPathComponent + "." +
                AccountScope.digest(batch.batchId) + ".receipt")
            var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: legacy)) as? [String: Any])
            legacyObject.removeValue(forKey: "sourceCommit")
            try CloudUploadJournal(directory: f.runtime.progressDirectory).durableWrite(
                JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys]), to: legacy)
            for path in try FileManager.default.contentsOfDirectory(at: f.runtime.progressDirectory,
                includingPropertiesForKeys: nil) where path.lastPathComponent.hasPrefix(state.lastPathComponent) {
                preserved[path] = try Data(contentsOf: path)
            }
            W5IntakeProtocol.set { _ in XCTFail("namespace discovery must be offline"); throw TestFailure.crash }
            for _ in 0..<2 {
                _ = try await CloudPushProgressRecovery.recover(admission: admission, endpoint: endpoint,
                    receiverStateID: receiver, currentVersion: PushProtocol.auxiliaryIdentityVersion,
                    directory: f.runtime.progressDirectory) { progress in
                    CloudPushSourceCommitter(progress: progress, check: { try admission.check() },
                        acknowledge: { _ in XCTFail("unrelated or incomplete association was promoted") },
                        cleanup: { _ in XCTFail("unrelated or incomplete association was cleaned") })
                }
            }
            for (path, bytes) in preserved { XCTAssertEqual(try Data(contentsOf: path), bytes, path.lastPathComponent) }
            let pending = await f.progress.pendingCommits()
            let cursor = try await f.progress.binaryCursor(table: .rawBatch, deviceId: device)
            XCTAssertTrue(pending.isEmpty); XCTAssertNil(cursor)
            let synced = try await f.store.registryWriter.read { try Int.fetchOne($0,
                sql: "SELECT COUNT(*) FROM rawBatch WHERE syncedAt IS NOT NULL") }
            XCTAssertEqual(synced, 0)
        } catch { await close(f); throw error }
        await close(f)
    }

    private enum TestFailure: Error { case crash, rejected(String) }

    @discardableResult
    private func uploadImuRows(_ f: Fixture) async throws -> PushBinaryBatch {
        let cursor = try await f.progress.binaryCursor(table: .rawImuSession, deviceId: device)
        let rows = try await f.snapshot.binaryRows(table: .rawImuSession, deviceId: device, afterRowId: cursor?.rowId ?? 0, limit: 1000)
        let batch = try PushProtocol.binaryObjectBatch(table: .rawImuSession, sourceId: W5ReceiptFixture.source,
            deviceId: device, startCursor: cursor, rows: rows, protocolVersion: PushProtocol.objectVersion)
        try serve(batch: batch); _ = try await f.transport.capabilities()
        let result = await coordinator(f).pushObjects(.rawImuSession, deviceId: device, lane: lane)
        guard case .accepted = result else { throw TestFailure.rejected(String(describing: result)) }
        return batch
    }

    private func nextArchive(_ f: Fixture) async throws -> (PushRawBatchRecord, PushBinaryBatch) {
        let rows = try await f.snapshot.binaryRows(table: .rawBatch, deviceId: device, afterRowId: 0, limit: 1)
        guard case .rawBatch(let row) = try XCTUnwrap(rows.first) else { throw TestFailure.crash }
        return (row, try PushProtocol.binaryObjectBatch(table: .rawBatch, sourceId: W5ReceiptFixture.source,
            deviceId: device, startCursor: nil, rows: [rows[0]], protocolVersion: PushProtocol.objectVersion))
    }

    func testExactImusArchivesRoundTripBothStoresThenReceiptsEnablePruneAndBoundedCompaction() async throws {
        let imu = try W5ImuFixture(); defer { imu.close() }; imu.populateSameSecond()
        let f = try await fixture(imuSource: imu.source)
        do {
            var expected: [String: Data] = [:]
            for (origin, store) in [("session", imu.sessions), ("continuous", imu.continuous)] {
                for segment in try store.pushSegmentInventory(deviceID: device) {
                    expected[origin + "/" + segment.windowID] = try store.pushSegmentSnapshot(segment).archiveBytes
                }
            }
            // First archive before row receipts: neither raw-file success nor HTTP alone permits deletion.
            for ordinal in 0..<3 {
                let (row, batch) = try await nextArchive(f)
                let (descriptor, bytes) = try ImuArchiveDescriptor.decode(row)
                XCTAssertEqual(bytes, expected[descriptor.origin + "/" + descriptor.window])
                XCTAssertEqual(descriptor.members.count, 1)
                XCTAssertEqual(descriptor.recordCount, 1)
                XCTAssertEqual(descriptor.ownerNamespace, f.context.scope.namespace)
                try serve(batch: batch); _ = try await f.transport.capabilities()
                let result = await coordinator(f).pushObjects(.rawBatch, deviceId: device, lane: lane)
                guard case .accepted(_, _, let more, _) = result else { throw TestFailure.rejected(String(describing: result)) }
                XCTAssertEqual(more, ordinal < 2, "raw lookahead must retain work for the unsent archive")
                if ordinal == 0 {
                    XCTAssertFalse(imu.continuous.deleteSegment(id: "window-live", bucket: imu.ts))
                    XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM member") }, 3)
                    try await uploadImuRows(f)
                }
            }
            XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM member") }, 0)
            XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rowReceipt") }, 0)
            XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM archive") }, 0)
            XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM segmentCheckpoint") }, 3)
            let cursor = try await f.progress.binaryCursor(table: .rawImuSession, deviceId: device)
            XCTAssertNotNil(try imu.source.indexedPushRecord(deviceId: device, rowId: try XCTUnwrap(cursor?.rowId)))
            XCTAssertTrue(imu.continuous.deleteSegment(id: "window-live", bucket: imu.ts))
            XCTAssertTrue(imu.sessions.deleteSegment(id: "window-a", bucket: imu.ts))
            XCTAssertTrue(imu.sessions.deleteSegment(id: "window-b", bucket: imu.ts))
            XCTAssertTrue(try imu.source.archiveRows(deviceID: device, limit: 1).isEmpty)
            XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM segmentCheckpoint") }, 0,
                           "already-pruned file checkpoints are reclaimed in a bounded sweep")
            let noData = await coordinator(f).pushObjects(.rawImuSession, deviceId: device, lane: lane)
            guard case .noData = noData else { throw TestFailure.rejected(String(describing: noData)) }
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testExactArchiveCompactionAndSpoolCleanupRecoverAfterCursorSaveCrash() async throws {
        let imu = try W5ImuFixture(); defer { imu.close() }
        imu.register(imu.continuous, id: "window-live", at: imu.ts); imu.append(imu.continuous, ts: imu.ts, seed: 45)
        let f = try await fixture(imuSource: imu.source)
        var reopened: Fixture?
        do {
            try await uploadImuRows(f)
            let (_, batch) = try await nextArchive(f); try serve(batch: batch)
            let result = await coordinator(f, cleanup: { _ in throw TestFailure.crash }).pushObjects(.rawBatch, deviceId: device, lane: lane)
            if case .accepted = result { XCTFail("injected crash") }
            XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM member") }, 0)
            let pending = await f.progress.pendingCommits(); XCTAssertEqual(pending.count, 1)
            let mux = try CloudImuPushSource(scope: imu.scope, directory: imu.indexDirectory, sessionStore: imu.sessions, continuousStore: imu.continuous)
            defer { XCTAssertNoThrow(try mux.index.close()) }
            let r = try await reopen(f, imuSource: mux); reopened = r
            // Bind the new transport, then disable all remote I/O: saved receipts/debt suffice.
            _ = try await r.transport.capabilities()
            W5IntakeProtocol.set { _ in throw TestFailure.crash }
            try await committer(r).recover(); try await committer(r).recover()
            XCTAssertTrue(try CloudUploadJournal(directory: r.layout.uploadDirectory).load().isEmpty)
            let debt = await r.progress.pendingCommits(); XCTAssertTrue(debt.isEmpty)
            XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM archive") }, 0)
            XCTAssertTrue(imu.continuous.deleteSegment(id: "window-live", bucket: imu.ts))
        } catch { await close(reopened ?? f); throw error }
        await close(reopened ?? f)
    }

    func testAppendDuringExactArchiveUploadRequiresNewSnapshotAndPreservesPrefixAfterCompaction() async throws {
        let imu = try W5ImuFixture(); defer { imu.close() }
        imu.register(imu.continuous, id: "window-live", at: imu.ts); imu.append(imu.continuous, ts: imu.ts, seed: 1)
        let f = try await fixture(imuSource: imu.source)
        do {
            let (oldRow, oldBatch) = try await nextArchive(f)
            let (_, oldBytes) = try ImuArchiveDescriptor.decode(oldRow)
            imu.append(imu.continuous, ts: imu.ts + 1, seed: 2)
            try await uploadImuRows(f)
            try serve(batch: oldBatch)
            let oldResult = await coordinator(f).pushObjects(.rawBatch, deviceId: device, lane: lane)
            guard case .accepted = oldResult else { throw TestFailure.rejected(String(describing: oldResult)) }
            XCTAssertFalse(imu.continuous.deleteSegment(id: "window-live", bucket: imu.ts), "old prefix receipt is not a current-file receipt")
            let (newRow, newBatch) = try await nextArchive(f)
            XCTAssertNotEqual(oldRow.batchId, newRow.batchId)
            let (newDescriptor, newBytes) = try ImuArchiveDescriptor.decode(newRow)
            XCTAssertEqual(newBytes.prefix(oldBytes.count), oldBytes)
            XCTAssertEqual(newDescriptor.previousArchive, oldRow.batchId)
            XCTAssertEqual(newDescriptor.prefixRecords, 1); XCTAssertEqual(newDescriptor.members.count, 1)
            XCTAssertEqual(newDescriptor.members.first?.ts, imu.ts + 1)
            let delta = try await uploadImuRows(f)
            XCTAssertEqual(delta.sampleCount, 1, "the new second still needs its own committed row receipt")
            try serve(batch: newBatch)
            let newResult = await coordinator(f).pushObjects(.rawBatch, deviceId: device, lane: lane)
            guard case .accepted = newResult else { throw TestFailure.rejected(String(describing: newResult)) }
            XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM member") }, 0)
            XCTAssertTrue(imu.continuous.deleteSegment(id: "window-live", bucket: imu.ts))
        } catch { await close(f); throw error }
        await close(f)
    }

    func testExactArchiveWrongReceiptKeepsCanonicalAndIndexBytes() async throws {
        let imu = try W5ImuFixture(); defer { imu.close() }; imu.populateSameSecond()
        let f = try await fixture(imuSource: imu.source)
        do {
            let (_, batch) = try await nextArchive(f)
            var response = W5ReceiptFixture.object(batch, owner: f.context.scope.userID)
            var receipt = response["durabilityReceipt"] as! [String: Any]
            receipt["contentSha256"] = String(repeating: "0", count: 64); response["durabilityReceipt"] = receipt
            try serve(batch: batch, mutation: response); _ = try await f.transport.capabilities()
            let result = await coordinator(f).pushObjects(.rawBatch, deviceId: device, lane: lane)
            if case .accepted = result { XCTFail("wrong content receipt") }
            XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM archive WHERE receipt IS NOT NULL") }, 0)
            XCTAssertGreaterThan(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT SUM(length(bytes)) FROM archive") } ?? 0, 0)
            XCTAssertFalse(imu.continuous.deleteSegment(id: "window-live", bucket: imu.ts))
            let debt = await f.progress.pendingCommits(); XCTAssertTrue(debt.isEmpty)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testExactArchiveSidecarFailureReplaysCompactedMembershipWithoutLosingBytes() async throws {
        let imu = try W5ImuFixture(); defer { imu.close() }
        imu.register(imu.continuous, id: "window-live", at: imu.ts); imu.append(imu.continuous, ts: imu.ts, seed: 45)
        let f = try await fixture(imuSource: imu.source)
        do {
            try await uploadImuRows(f)
            let (_, batch) = try await nextArchive(f); try serve(batch: batch)
            imu.continuous.testFailReceiptPersistence = true
            let result = await coordinator(f).pushObjects(.rawBatch, deviceId: device, lane: lane)
            if case .accepted = result { XCTFail("injected sidecar failure") }
            let debt = await f.progress.pendingCommits(); XCTAssertEqual(debt.count, 1)
            XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT sidecarPending FROM segmentCheckpoint") }, 1)
            XCTAssertFalse(imu.continuous.deleteSegment(id: "window-live", bucket: imu.ts))
            XCTAssertEqual(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().count, 1)
            imu.continuous.testFailReceiptPersistence = false
            W5IntakeProtocol.set { _ in throw TestFailure.crash }
            try await committer(f).recover(); try await committer(f).recover()
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
            XCTAssertTrue(imu.continuous.deleteSegment(id: "window-live", bucket: imu.ts))
        } catch { await close(f); throw error }
        await close(f)
    }

    func testRepeatedReceiptCompactionReclaimsRowsAndPreservesMonotonicCursor() async throws {
        let imu = try W5ImuFixture(); defer { imu.close() }
        let f = try await fixture(imuSource: imu.source)
        do {
            var priorCursor: Int64 = 0
            for generation in 0..<4 {
                let ts = imu.ts + Int64(generation) * ImuSessionFileStore.segmentSeconds
                let name = "closed-\(generation)"
                imu.continuous.register(id: name, deviceId: device, fromMs: ts * 1000, toMs: (ts + 239) * 1000)
                for second in 0..<240 { imu.append(imu.continuous, ts: ts + Int64(second), seed: Int16(second)) }
                let rowBatch = try await uploadImuRows(f)
                XCTAssertEqual(rowBatch.sampleCount, 240)
                let cursor = try XCTUnwrap(rowBatch.endCursor?.rowId)
                XCTAssertGreaterThan(cursor, priorCursor); priorCursor = cursor
                let (_, archive) = try await nextArchive(f); try serve(batch: archive)
                let result = await coordinator(f).pushObjects(.rawBatch, deviceId: device, lane: lane)
                guard case .accepted = result else { throw TestFailure.rejected(String(describing: result)) }
                XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM member") }, 0)
                XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rowReceipt") }, 0)
                XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM archive") }, 0)
                XCTAssertTrue(imu.continuous.deleteSegment(id: name, bucket: ts))
                // Keyset maintenance wraps on a following bounded call.
                _ = try imu.source.archiveRows(deviceID: device, limit: 1)
                _ = try imu.source.archiveRows(deviceID: device, limit: 1)
                XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM segmentCheckpoint") }, 0)
                let size = try FileManager.default.attributesOfItem(atPath: imu.indexDirectory.appendingPathComponent("membership.sqlite").path)[.size] as! NSNumber
                XCTAssertLessThan(size.intValue, 2 * 1_048_576, "compacted index must reuse/reclaim storage across generations")
            }
            XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM progressAnchor") }, 1)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testActualImuMuxObjectLanePreservesSameSecondRowsAndCommitsMembershipWithoutPruningFiles() async throws {
        let imu = try W5ImuFixture(); defer { imu.close() }; imu.populateSameSecond()
        let f = try await fixture(imuSource: imu.source)
        do {
            let rows = try await f.snapshot.binaryRows(table: .rawImuSession, deviceId: device, afterRowId: 0, limit: 100)
            XCTAssertEqual(rows.count, 3)
            let batch = try PushProtocol.binaryObjectBatch(table: .rawImuSession, sourceId: W5ReceiptFixture.source,
                deviceId: device, startCursor: nil, rows: rows, protocolVersion: PushProtocol.objectVersion)
            try serve(batch: batch); _ = try await f.transport.capabilities()
            let result = await coordinator(f).pushObjects(.rawImuSession, deviceId: device, lane: lane)
            guard case .accepted = result else { throw TestFailure.rejected(String(describing: result)) }
            let cursor = try await f.progress.binaryCursor(table: .rawImuSession, deviceId: device)
            XCTAssertEqual(cursor?.rowId, 3)
            XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rowReceipt") }, 3)
            let proofCount = try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(DISTINCT hex(receipt)) FROM rowReceipt") }
            XCTAssertEqual(proofCount, 1, "one exact object receipt binds all three distinct members")
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
            XCTAssertFalse(imu.continuous.deleteSegment(id: "window-live", bucket: imu.ts))
            XCTAssertFalse(imu.sessions.deleteSegment(id: "window-a", bucket: imu.ts))
            XCTAssertFalse(imu.sessions.deleteSegment(id: "window-b", bucket: imu.ts))
            let repeated = await coordinator(f).pushObjects(.rawImuSession, deviceId: device, lane: lane)
            guard case .noData = repeated else { throw TestFailure.rejected(String(describing: repeated)) }
            XCTAssertEqual(try imu.source.indexedPushRows(deviceId: device, afterRowId: 0, limit: 100).count, 3)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testMissingImuBindingIsDeferredNotSuccessfulEmptyLane() async throws {
        let f = try await fixture()
        do {
            try serve(); _ = try await f.transport.capabilities()
            let result = await coordinator(f).pushObjects(.rawImuSession, deviceId: device, lane: lane)
            guard case .rejected(_, let retryable, _) = result else { throw TestFailure.rejected(String(describing: result)) }
            XCTAssertTrue(retryable)
            let cursor = try await f.progress.binaryCursor(table: .rawImuSession, deviceId: device)
            XCTAssertNil(cursor)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testQuarantineExactRepeatedOccurrencesReachRawLaneReceiptAndOnlyThenPrune() async throws {
        let f = try await fixture()
        do {
            let scope = DurableIngestScope(environment: f.context.scope.projectURL, accountID: f.context.scope.userID, deviceID: device)
            let frames: [[UInt8]] = [[0, 255, 0, 47, 22], [0, 255, 0, 47, 22]]
            let inserted = try await f.store.persistSensorQuarantine(frames, scope: scope, family: "unsupported-fixture", trim: 42,
                clockRef: .init(device: 100, wall: 200), preserveOccurrences: true)
            XCTAssertEqual(inserted, 2)
            let before = try await f.store.pruneSensorQuarantine(now: Int(Date().timeIntervalSince1970))
            XCTAssertEqual(before, 0)
            let children = try await f.store.pendingSensorQuarantine(scope: scope)
            XCTAssertEqual(children.count, 2); XCTAssertNotEqual(children[0].id, children[1].id)
            for ordinal in 0..<2 {
                let rows = try await f.snapshot.binaryRows(table: .rawBatch, deviceId: device, afterRowId: 0, limit: 1)
                guard case .rawBatch(let row) = try XCTUnwrap(rows.first) else { throw TestFailure.crash }
                let member = try XCTUnwrap(QuarantineArchiveIdentity(batchID: row.batchId))
                XCTAssertEqual(member.family, "unsupported-fixture"); XCTAssertEqual(member.trim, 42)
                XCTAssertTrue(children.contains { $0.id == member.recordID })
                let recoveredBytes = try await f.store.rawFrames(batchId: row.batchId)
                XCTAssertEqual(recoveredBytes, [frames[ordinal]])
                let batch = try PushProtocol.binaryObjectBatch(table: .rawBatch, sourceId: W5ReceiptFixture.source,
                    deviceId: device, startCursor: nil, rows: rows, protocolVersion: PushProtocol.objectVersion)
                try serve(batch: batch); _ = try await f.transport.capabilities()
                let result = await coordinator(f).pushObjects(.rawBatch, deviceId: device, lane: lane)
                guard case .accepted = result else { throw TestFailure.rejected(String(describing: result)) }
                let prunedChild = try await f.store.pruneSensorQuarantine(now: Int(Date().timeIntervalSince1970))
                XCTAssertEqual(prunedChild, 1, "the unsent sibling must remain")
            }
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
            let remaining = try await f.store.pendingSensorQuarantine(scope: scope); XCTAssertTrue(remaining.isEmpty)
            let rawPruned = try await f.store.pruneRaw(now: Int(Date().timeIntervalSince1970) + 10, keepWindowSeconds: 0, maxUnsyncedBytes: 0)
            XCTAssertEqual(rawPruned, 2)
            let receiptCount = try await f.store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rawDurabilityReceipt") }
            XCTAssertEqual(receiptCount, 2, "immutable membership evidence survives both cleanups")
        } catch { await close(f); throw error }
        await close(f)
    }

    private func inlineBatch(_ f: Fixture) async throws -> PushBatch {
        try await f.store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO hrSample(deviceId, ts, bpm) VALUES (?, 100, 60)", arguments: [self.device])
        }
        let rows = try await f.snapshot.appendRows(table: .hrSample, deviceId: device, afterRowId: 0, limit: 10)
        return try PushProtocol.appendBatch(table: .hrSample, sourceId: W5ReceiptFixture.source,
                                             deviceId: device, startCursor: nil, records: rows)
    }
    private func reopen(_ f: Fixture, imuSource: (any ImuSessionPushSource)? = nil) async throws -> Fixture {
        CloudPushBackgroundRuntime.install(nil); await f.runtime.retire(); f.session.invalidateAndCancel()
        try f.store.registryWriter.close()
        let context = AccountSessionContext(scope: f.context.scope, generation: UUID())
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [W5IntakeProtocol.self]
        let session = URLSession(configuration: config)
        let runtime = try CloudPushBackgroundRuntime(context: context, layout: f.layout,
            authorize: { _ in "synthetic-new-generation" }, isCurrent: { _ in true },
            policy: { .init(concurrency: 2, allowsCellular: false, allowsConstrained: false) },
            sessionConfiguration: config, now: { Date().addingTimeInterval(60) })
        CloudPushBackgroundRuntime.install(runtime)
        let store = try await WhoopStore(path: f.root.appendingPathComponent("source.sqlite").path)
        return Fixture(root: f.root, context: context, layout: f.layout, store: store,
            snapshot: CloudPushSnapshot(db: store.registryWriter, imuPushSource: imuSource),
            progress: try CloudPushProgressStore(namespace: "test-receiver", directory: runtime.progressDirectory),
            runtime: runtime, transport: try .init(endpoint: .init(url: endpoint, host: "project.example"),
                context: context, accessToken: "synthetic", session: session, isCurrent: { _ in true }), session: session)
    }
    func testInlineWrapperGzipFallbackCommitsCursorAndCleansBothRepresentations() async throws {
        let f = try await fixture()
        do {
            let batch = try await inlineBatch(f); try serve(inline: batch, rejectGzip: true)
            _ = try await f.transport.capabilities()
            let result = await coordinator(f).pushAppend(.hrSample, deviceId: device)
            guard case .accepted = result else { throw TestFailure.rejected(String(describing: result)) }
            let cursor = try await f.progress.cursor(table: .hrSample, deviceId: device)
            XCTAssertEqual(cursor, batch.endCursor)
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
            let reopened = try CloudPushProgressStore(namespace: "test-receiver", directory: f.runtime.progressDirectory)
            let diskCursor = try await reopened.cursor(table: .hrSample, deviceId: device)
            XCTAssertEqual(diskCursor, batch.endCursor)
        } catch { await close(f); throw error }
        await close(f)
    }
    func testInvalidCachedHTTP2xxIsRetriedAfterRelaunchRatherThanReplayedForever() async throws {
        var f = try await fixture()
        do {
            let batch = try await inlineBatch(f)
            var legacy = W5ReceiptFixture.inline(batch, owner: f.context.scope.userID); legacy["durabilityReceipt"] = nil
            try serve(inline: batch, mutation: legacy); _ = try await f.transport.capabilities()
            let rejected = await coordinator(f).pushAppend(.hrSample, deviceId: device)
            if case .accepted = rejected { XCTFail("legacy ACK accepted") }
            let cursor = try await f.progress.cursor(table: .hrSample, deviceId: device); XCTAssertNil(cursor)
            XCTAssertEqual(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().values.first?.phase, .retryPending)
            f = try await reopen(f)
            try serve(inline: batch); _ = try await f.transport.capabilities()
            let result = await coordinator(f).pushAppend(.hrSample, deviceId: device)
            guard case .accepted = result else { throw TestFailure.rejected(String(describing: result)) }
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
        } catch { await close(f); throw error }
        await close(f)
    }
    func testLostCompleteThenDuplicateIntentAndNewGenerationReusesSameImmutableObject() async throws {
        var f = try await fixture()
        do {
            let batch = try await raw(f); try serve(batch: batch, loseCompletion: true)
            _ = try await f.transport.capabilities()
            let result = await coordinator(f).pushObjects(.rawBatch, deviceId: device, lane: lane)
            if case .accepted = result { XCTFail("lost response") }
            let before = try XCTUnwrap(CloudUploadJournal(directory: f.layout.uploadDirectory).load().values.first)
            XCTAssertEqual(before.objectKey, "staging/write-only"); XCTAssertEqual(before.objectID, batch.objectId)
            f = try await reopen(f); try serve(batch: batch, duplicate: true)
            _ = try await f.transport.capabilities()
            let intent = try await f.transport.createObjectIntent(.init(batch: batch), lane: lane)
            XCTAssertTrue(intent.duplicate); XCTAssertEqual(intent.objectKey, "archive/verified-object")
            let after = try XCTUnwrap(CloudUploadJournal(directory: f.layout.uploadDirectory).load()[before.id])
            XCTAssertEqual(after.payloadSHA256, before.payloadSHA256); XCTAssertEqual(after.objectKey, before.objectKey)
            let accepted = await coordinator(f).pushObjects(.rawBatch, deviceId: device, lane: lane)
            guard case .accepted = accepted else { throw TestFailure.rejected(String(describing: accepted)) }
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testCrashAfterSourceAssociationBeforeCursorReplaysReceiptWithoutUploadingAgain() async throws {
        var f = try await fixture()
        do {
            let batch = try await raw(f); try serve(batch: batch); _ = try await f.transport.capabilities()
            let result = await coordinator(f, afterAssociation: { throw TestFailure.crash })
                .pushObjects(.rawBatch, deviceId: device, lane: lane)
            if case .accepted = result { XCTFail("injected crash") }
            let before = try CloudUploadJournal(directory: f.layout.uploadDirectory).load()
            XCTAssertEqual(before.values.first?.phase, .receiptSaved)
            let cursor = try await f.progress.binaryCursor(table: .rawBatch, deviceId: device); XCTAssertNil(cursor)
            f = try await reopen(f)
            // Capability GET is allowed; any unexpected retransmission fails the resumed run.
            try serve(); _ = try await f.transport.capabilities()
            let accepted = await coordinator(f).pushObjects(.rawBatch, deviceId: device, lane: lane)
            guard case .accepted = accepted else { throw TestFailure.rejected(String(describing: accepted)) }
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testPpgV2ReceiptAssociatesOnlyActuallyUploadedPrefixNotLookaheadRow() async throws {
        let f = try await fixture()
        do {
            let samples = [PpgWaveformSample(ts: 100, samples: [1, -2], recordIndex: 1),
                           PpgWaveformSample(ts: 100 + 48 * 3600 - 1, samples: [3, 4], recordIndex: 2),
                           PpgWaveformSample(ts: 100 + 48 * 3600, samples: [5, 6], recordIndex: 3)]
            _ = try await f.store.insertAndMarkJobsOwed(Streams(ppgWaveform: samples), deviceId: device,
                postOffloadJobKinds: ["cloudPush"], note: nil)
            let rows = try await f.snapshot.binaryRows(table: .ppgWaveformSample, deviceId: device, afterRowId: 0, limit: 10)
            let batch = try PushProtocol.binaryObjectBatch(table: .ppgWaveformSample, sourceId: W5ReceiptFixture.source,
                deviceId: device, startCursor: nil, rows: rows, protocolVersion: "1.3")
            try serve(batch: batch); _ = try await f.transport.capabilities()
            let result = await coordinator(f, version: "1.3").pushObjects(.ppgWaveformSample, deviceId: device, lane: lane)
            guard case .accepted = result else { throw TestFailure.rejected(String(describing: result)) }
            let keys = try await f.store.registryWriter.read { try String.fetchAll($0, sql: "SELECT resourceKey FROM rawDurabilityReceipt ORDER BY resourceKey") }
            XCTAssertEqual(Set(keys), ["100:1", "\(100 + 48 * 3600 - 1):2"])
            let cursor = try await f.progress.binaryCursor(table: .ppgWaveformSample, deviceId: device)
            XCTAssertEqual(cursor, batch.endCursor)
            let remaining = try await f.snapshot.binaryRows(table: .ppgWaveformSample, deviceId: device, afterRowId: cursor!.rowId, limit: 10)
            XCTAssertEqual(remaining.count, 1)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testCapabilityOwnerRetirementDuringAwaitDoesNotBindOrCreatePayloadJob() async throws {
        let f = try await fixture()
        do {
            let owner = W5CurrentOwner()
            try serve(onCapabilities: { owner.retire() })
            let transport = try CloudAccountPushTransport(endpoint: .init(url: endpoint, host: "project.example"),
                context: f.context, accessToken: "synthetic", session: f.session, isCurrent: { _ in owner.current })
            do { _ = try await transport.capabilities(); XCTFail("retired capability accepted") }
            catch { XCTAssertEqual(error as? AccountAuthError, .staleOperation) }
            let batch = try await inlineBatch(f)
            do { _ = try await transport.base.post(batch); XCTFail("unbound receiver scheduled payload") }
            catch { XCTAssertEqual(error as? CloudUploadError, .invalidRequest) }
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testSameTransportCannotRebindReceiverAfterReset() async throws {
        let f = try await fixture()
        do {
            try serve(); _ = try await f.transport.capabilities()
            try serve(receiver: "88888888-8888-4888-8888-888888888888")
            do { _ = try await f.transport.capabilities(); XCTFail("receiver changed in place") }
            catch { XCTAssertEqual(error as? CloudUploadError, .invalidReceipt) }
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
        } catch { await close(f); throw error }
        await close(f)
    }
}

private final class W5CurrentOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var current: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func retire() { lock.lock(); value = false; lock.unlock() }
}

private final class W5IntakeProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: (URLRequest) throws -> (Int, Data) = { _ in throw CloudUploadError.unavailable }
    static func set(_ value: @escaping (URLRequest) throws -> (Int, Data)) { lock.lock(); defer { lock.unlock() }; handler = value }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let callback = Self.handler; Self.lock.unlock()
        do {
            let (status, data) = try callback(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
