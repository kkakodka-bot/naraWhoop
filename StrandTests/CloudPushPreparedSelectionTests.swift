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

private func preparedSelectionFixtureBaseDirectory() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["NARA_TEST_FIXTURE_ROOT"] else {
        return FileManager.default.temporaryDirectory
    }
    var isDirectory: ObjCBool = false
    guard path.hasPrefix("/"), !path.utf8.contains(0),
          FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw NSError(domain: "NARATestFixtureRoot", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "NARA_TEST_FIXTURE_ROOT must name an existing absolute directory"
        ])
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}

final class CloudPushPreparedSelectionTests: XCTestCase {
    private let endpoint = "https://project.example/functions/v1/push"
    private let receiver = "99999999-9999-4999-8999-999999999999"
    private let source = W5ReceiptFixture.source
    private let device = "prepared-synthetic"
    private let lane = PushObjectLane(endpoint: "/functions/v1/push/objects", maxObjectBytes: 8_000_000, urlTtlSec: 300,
        streams: [.rawBatch, .ppgWaveformSample, .v18AuxSample, .rawImuSession])
    private struct Fixture {
        let root: URL
        let context: AccountSessionContext
        let layout: AccountStorageLayout
        let store: WhoopStore
        let runtime: CloudPushBackgroundRuntime
        let session: URLSession
        let transport: CloudPushTransport
        let imuSource: (any ImuSessionPushSource)?
        var snapshot: CloudPushSnapshot { .init(db: store.registryWriter, imuPushSource: imuSource) }
    }
    private func fixture(root: URL? = nil, imuSource: (any ImuSessionPushSource)? = nil,
                         dependentAdmission: SyncEngine.DependentStageAdmission? = nil) async throws -> Fixture {
        let temporary = try preparedSelectionFixtureBaseDirectory()
        let root = root ?? temporary.appendingPathComponent("prepared-selection-" + UUID().uuidString)
        let scope = try AccountScope(projectURL: "https://project.example", userID: W5ReceiptFixture.owner)
        let context = AccountSessionContext(scope: scope, generation: UUID())
        let layout = AccountStorageLayout(baseDirectory: root, scope: scope)
        try layout.prepare()
        let store = try await WhoopStore(path: root.appendingPathComponent("source.sqlite").path)
        try await store.bindAccountOwner(projectURL: scope.projectURL, userID: scope.userID)
        try await store.upsertDevice(id: device, mac: nil, name: nil)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PreparedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let runtime = try CloudPushBackgroundRuntime(context: context, layout: layout, authorize: { _ in "synthetic" },
            isCurrent: { _ in true }, policy: { .init(concurrency: 2, allowsCellular: false, allowsConstrained: false) },
            sessionConfiguration: configuration)
        CloudPushBackgroundRuntime.install(runtime)
        let transport = CloudPushTransport(endpoint: .init(url: endpoint, host: "project.example"), bearerToken: "synthetic",
            context: context, session: session, dependentAdmission: dependentAdmission)
        try transport.bindReceiverState(receiver); transport.requirePreparedSelections()
        return .init(root: root, context: context, layout: layout, store: store, runtime: runtime, session: session, transport: transport, imuSource: imuSource)
    }
    private func stop(_ f: Fixture) async throws {
        CloudPushBackgroundRuntime.install(nil); await f.runtime.retire(); f.session.invalidateAndCancel()
        try f.store.registryWriter.close()
    }
    private func close(_ f: Fixture) async {
        do { try await stop(f); try FileManager.default.removeItem(at: f.root) }
        catch { XCTFail("fixture retained: \(error)") }
        PreparedURLProtocol.set { _ in throw CloudUploadError.unavailable }
    }
    private func namespace(_ f: Fixture, version: String) throws -> String {
        try AccountPushAdmission(context: f.context, captureScope: f.context.scope, sourceID: source, isCurrent: { _ in true })
            .namespace(endpoint: endpoint, protocolVersion: version, receiverStateID: receiver)
    }
    private func progress(_ f: Fixture, version: String) throws -> CloudPushProgressStore {
        try .init(namespace: namespace(f, version: version), directory: f.runtime.progressDirectory,
            auxiliaryIdentityV2: version == "1.4")
    }
    private func committer(_ f: Fixture, _ p: CloudPushProgressStore,
                           afterApply: (@Sendable () throws -> Void)? = nil,
                           afterCleanup: (@Sendable () throws -> Void)? = nil) -> CloudPushSourceCommitter {
        .init(progress: p, check: {}, acknowledge: { try await f.snapshot.acknowledgeCommitted($0, scope: f.context.scope) },
            cleanup: { _ in XCTFail("prepared cleanup must not use batch-wide legacy deletion") },
            didApply: { value in try f.snapshot.sourceProgressApplied(value, scope: f.context.scope); try afterApply?() },
            didCleanup: { value in try f.snapshot.sourceCleanupCompleted(value, scope: f.context.scope); try afterCleanup?() },
            cleanupPrepared: { try await f.transport.preparedSourceCommitted($0) },
            retirePrepared: { try await f.transport.retireSelection($0) })
    }
    private func coordinator(_ f: Fixture, _ p: CloudPushProgressStore, version: String,
                             beforeAssociation: (@Sendable () throws -> Void)? = nil,
                             beforeStage: (@Sendable () throws -> Void)? = nil,
                             freshSource: Bool = false) -> PushCoordinator {
        let c = committer(f, p)
        let sourceSnapshot: any PushSnapshotSource = freshSource ? f.snapshot : PreparedNoSelectionSource()
        return PushCoordinator(source: sourceSnapshot, transport: f.transport, progress: p,
            sourceId: source, today: { Date(timeIntervalSince1970: 4_000_000_000) }, receiptOwner: f.context.scope,
            objectProtocolVersion: version,
            associateReceipt: { batch, rows, receipt in
                try beforeAssociation?()
                let id = try await f.transport.preparedSelectionID(batchID: batch.batchId, sourceID: batch.sourceId)
                let selection = try await f.runtime.queue.preparedSelection(id, captured: f.context)
                try await f.snapshot.associateReceipt(batch: batch, rows: rows, receipt: receipt, scope: f.context.scope)
                try await p.associate(batch: batch, rows: rows, receipt: receipt, prepared: selection)
            }, associateInlineReceipt: { batch, receipt in
                try beforeAssociation?()
                let id = try await f.transport.preparedSelectionID(batchID: batch.batchId, sourceID: batch.sourceId)
                let selection = try await f.runtime.queue.preparedSelection(id, captured: f.context)
                try await p.associateInline(batch: batch, receipt: receipt, prepared: selection)
            }, commitSource: { value in
                try beforeStage?()
                let id = try await f.transport.preparedSelectionID(batchID: value.batchIDs[0], sourceID: W5ReceiptFixture.source)
                try await c.commit(value, preparedSelectionID: id)
            }, prepareSelection: { try await f.transport.prepareSelection($0, progressVersion: version) })
    }
    private func raw(_ f: Fixture, key: String = "raw-prepared", ts: Int = 100) async throws -> (PushBinaryBatch, [PushBinaryRow]) {
        let meta = RawBatchMeta(batchId: key, deviceId: device, clockRef: .init(device: ts, wall: ts), capturedAt: ts,
            startTs: ts, endTs: ts, frameCount: 1, byteSize: 3,
            captureScope: .init(environment: f.context.scope.projectURL, accountID: f.context.scope.userID, deviceID: device))
        try await f.store.enqueueRawBatch(meta, frames: [[1, 2, 3]])
        let rows = try await f.snapshot.binaryRows(table: .rawBatch, deviceId: device, afterRowId: 0, limit: 1)
        return (try PushProtocol.binaryObjectBatch(table: .rawBatch, sourceId: source, deviceId: device,
            startCursor: nil, rows: rows, protocolVersion: "1.2"), rows)
    }
    private func binarySelection(_ f: Fixture, batch: PushBinaryBatch, rows: [PushBinaryRow]) throws -> CloudPushPreparedSelection {
        let commit = PushSourceCommit(kind: .binary, table: batch.wireName, deviceID: batch.deviceId,
            batchIDs: [batch.batchId], cursor: batch.endCursor, rawBatchIDs: rows.compactMap { if case .rawBatch(let r) = $0 { return r.batchId }; return nil })
        return try .init(context: f.context, endpoint: endpoint, receiverStateID: receiver, progressVersion: batch.protocolVersion,
            selection: .init(binary: batch, rows: rows, manifest: .init(batch: batch), lane: lane, commit: commit), inlineGzip: [])
    }
    private func serveObject(_ batch: PushBinaryBatch) throws {
        var ack = W5ReceiptFixture.object(batch, owner: W5ReceiptFixture.owner)
        var receipt = ack["durabilityReceipt"] as! [String: Any]
        receipt["schemaVersion"] = PushProtocol.schemaVersion(stream: batch.wireName, protocolVersion: batch.protocolVersion)
        ack["durabilityReceipt"] = receipt
        let response = try W5ReceiptFixture.bytes(ack)
        PreparedURLProtocol.set { request in
            if request.httpMethod == "PUT" { return (200, Data()) }
            if request.url!.path.hasSuffix("/complete") { return (200, response) }
            return (200, try W5ReceiptFixture.bytes(["type": "objectIntent", "protocolVersion": batch.protocolVersion,
                "objectId": batch.objectId, "objectKey": "staging/exact", "duplicate": false,
                "uploadUrl": "https://bucket.example/synthetic", "requiredHeaders": [:], "expiresAt": "2030-01-01T00:00:00Z"]))
        }
    }
    private func append(_ f: Fixture, row: Int64 = 1, device: String? = nil, version: String = "1.2") throws -> CloudPushPreparedSelection {
        let batch = try PushProtocol.appendBatch(table: .hrSample, sourceId: source, deviceId: device ?? self.device,
            startCursor: nil, records: [.init(rowId: row, key: ["ts": .int(row)], data: ["bpm": .int(60)])])
        return try .init(context: f.context, endpoint: endpoint, receiverStateID: receiver, progressVersion: version,
            selection: .init(inline: [batch], commit: .init(kind: .append, table: "hrSample", deviceID: batch.deviceId,
                batchIDs: [batch.batchId], cursor: batch.endCursor)), inlineGzip: [CloudPushTransport.gzip(batch.body)])
    }

    func testReceiptSavedBeforeAssociationReopensOldVersionWithoutNetworkOrFreshSelection() async throws {
        var f = try await fixture()
        do {
            let (batch, rows) = try await raw(f), selection = try binarySelection(f, batch: batch, rows: rows)
            try serveObject(batch)
            try await f.runtime.queue.prepareSelection(selection, captured: f.context)
            let result = await coordinator(f, try progress(f, version: "1.2"), version: "1.2",
                beforeAssociation: { throw PreparedStop.crash }).resumePrepared(selection.selection)
            guard case .rejected = result else { throw PreparedStop.rejected("expected injected pre-association crash") }
            XCTAssertEqual(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().values.first?.phase, .receiptSaved)
            let before = try await f.store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rawDurabilityReceipt") }
            XCTAssertEqual(before, 0)
            let originalGeneration = f.context.generation, root = f.root
            try await stop(f); f = try await fixture(root: root)
            PreparedURLProtocol.set { _ in XCTFail("saved receipt recovery must not send"); throw PreparedStop.crash }
            let admission = try AccountPushAdmission(context: f.context, captureScope: f.context.scope, sourceID: source, isCurrent: { _ in true })
            let current = try await CloudPushProgressRecovery.recover(admission: admission, endpoint: endpoint,
                receiverStateID: receiver, currentVersion: "1.4", directory: f.runtime.progressDirectory,
                committer: { self.committer(f, $0) })
            let pending = try await f.runtime.queue.preparedSelections(sourceID: source, endpoint: endpoint, receiverStateID: receiver, captured: f.context)
            XCTAssertEqual(pending.first?.capturedGeneration, originalGeneration)
            XCTAssertNotEqual(f.context.generation, originalGeneration)
            let blocked = try await CloudPushPreparedRecovery.recover(queue: f.runtime.queue, context: f.context, sourceID: source,
                endpoint: endpoint, receiverStateID: receiver, directory: f.runtime.progressDirectory,
                coordinator: { self.coordinator(f, $0, version: $1) })
            XCTAssertFalse(blocked)
            let rowsAfter = try await f.store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rawDurabilityReceipt") }
            let synced = try await f.store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rawBatch WHERE syncedAt IS NOT NULL") }
            XCTAssertEqual(rowsAfter, 1); XCTAssertEqual(synced, 1)
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
            let debt = await current.pendingCommits(); XCTAssertTrue(debt.isEmpty)
            let retained = try await f.runtime.queue.preparedSelections(sourceID: source, endpoint: endpoint, receiverStateID: receiver, captured: f.context)
            XCTAssertTrue(retained.isEmpty)
            let repeated = try await CloudPushPreparedRecovery.recover(queue: f.runtime.queue, context: f.context, sourceID: source,
                endpoint: endpoint, receiverStateID: receiver, directory: f.runtime.progressDirectory,
                coordinator: { self.coordinator(f, $0, version: $1) })
            XCTAssertFalse(repeated)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testPreparationPublishesBothRepresentationsAndDoesNotSendUntilAdmitted() async throws {
        let f = try await fixture()
        do {
            PreparedURLProtocol.set { _ in XCTFail("preparation is not delivery"); throw PreparedStop.crash }
            let saved = try append(f)
            try await f.runtime.queue.prepareSelection(saved, captured: f.context)
            try await f.runtime.queue.reconcile()
            let journal = try CloudUploadJournal(directory: f.layout.uploadDirectory)
            let jobs = try journal.load(); XCTAssertEqual(jobs.count, 2)
            XCTAssertTrue(jobs.values.allSatisfy { $0.taskIdentifier == nil && $0.deliveryAdmitted == false && $0.preparedSelectionID == saved.id })
            for job in jobs.values { try journal.verifyBody(job) }
            let identity = try XCTUnwrap(jobs[saved.jobID(batchID: saved.commit.batchIDs[0], representation: "identity")])
            XCTAssertEqual(try Data(contentsOf: journal.bodyURL(identity)), try saved.selection.restoredInlineBatches()[0].body)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testOldProtocolSameLaneBlockedButUnrelatedDeviceCanPrepare() async throws {
        let f = try await fixture()
        do {
            let old = try append(f), new = try append(f, row: 2, version: "1.4")
            XCTAssertEqual(old.laneID, new.laneID)
            try await f.runtime.queue.prepareSelection(old, captured: f.context)
            do { try await f.runtime.queue.prepareSelection(new, captured: f.context); XCTFail("old lane overtaken") }
            catch { XCTAssertEqual(error as? CloudUploadError, .retryScheduled) }
            try await f.runtime.queue.prepareSelection(try append(f, row: 2, device: "independent", version: "1.4"), captured: f.context)
            XCTAssertEqual(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().count, 4)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testGzipFallbackUsesSavedBytesAndLeavesCollidingLegacyJobUntouched() async throws {
        let f = try await fixture()
        do {
            let saved = try append(f), batch = try saved.selection.restoredInlineBatches()[0]
            let journal = try CloudUploadJournal(directory: f.layout.uploadDirectory)
            var legacy = CloudUploadJob(id: AccountScope.digest("legacy-overlap"), owner: f.context.scope, generation: f.context.generation,
                endpoint: endpoint, deviceID: device, createdAt: Date(), operation: .request, method: "POST", headers: [:])
            legacy.batchID = batch.batchId; legacy.receiverStateID = receiver; legacy.phase = .responseSaved
            legacy.correlation = UUID()
            legacy.responseStatus = 200; legacy.responseBody = Data("unproven".utf8)
            try journal.persistBody(Data("retained legacy".utf8), job: &legacy); try journal.save(legacy)
            let legacyBytes = try Data(contentsOf: f.layout.uploadDirectory.appendingPathComponent(legacy.id + ".json"))
            try await f.runtime.queue.prepareSelection(saved, captured: f.context)
            let reply = try W5ReceiptFixture.bytes(W5ReceiptFixture.inline(batch, owner: f.context.scope.userID))
            PreparedURLProtocol.set { request in
                (request.value(forHTTPHeaderField: "Content-Encoding") == "gzip" ? 415 : 200, reply)
            }
            let result = await coordinator(f, try progress(f, version: "1.2"), version: "1.2").resumePrepared(saved.selection)
            guard case .accepted = result else { throw PreparedStop.rejected(String(describing: result)) }
            let remaining = try journal.load(); XCTAssertEqual(remaining.count, 1)
            XCTAssertEqual(try Data(contentsOf: journal.bodyURL(legacy)), Data("retained legacy".utf8))
            XCTAssertEqual(try Data(contentsOf: f.layout.uploadDirectory.appendingPathComponent(legacy.id + ".json")), legacyBytes)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testCountByteAndCompletionReservationsAreBounded() async throws {
        let f = try await fixture()
        do {
            let saved = try append(f), quota = CloudPreparedQuota(), allocation = try quota.reservation(for: saved)
            XCTAssertEqual(allocation.jobSlots, 2)
            XCTAssertGreaterThanOrEqual(allocation.completionBytes, 1_048_576)
            var small = quota; small.maximumBytes = allocation.total
            XCTAssertNoThrow(try small.admit(allocation, occupiedBytes: 0, reservedBytes: 0, groups: 0, jobs: 0))
            XCTAssertThrowsError(try small.admit(allocation, occupiedBytes: 1, reservedBytes: 0, groups: 0, jobs: 0))
            XCTAssertThrowsError(try quota.admit(allocation, occupiedBytes: 0, reservedBytes: 0, groups: 64, jobs: 0))
            XCTAssertThrowsError(try quota.admit(allocation, occupiedBytes: 0, reservedBytes: 0, groups: 0, jobs: 255))
            XCTAssertThrowsError(try quota.admit(allocation, occupiedBytes: Int.max, reservedBytes: Int.max, groups: 0, jobs: 0))
            let path = f.root.appendingPathComponent("quota-only")
            let journal = try CloudUploadJournal(directory: path, maximumBytes: allocation.total)
            try journal.reserve(saved, legacyJobs: 0)
            var legacy = CloudUploadJob(id: AccountScope.digest("ordinary-overflow"), owner: f.context.scope,
                generation: f.context.generation, endpoint: endpoint, deviceID: device, createdAt: Date(), operation: .request,
                method: "POST", headers: [:])
            XCTAssertThrowsError(try journal.persistBody(Data([1]), job: &legacy), "ordinary bytes cannot spend completion reserve")
            XCTAssertTrue(journal.selections[saved.id] != nil)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testEveryPreparationWriteCrashReopensWithoutPrematureTaskAdmission() async throws {
        let f = try await fixture()
        do {
            let saved = try append(f)
            for position in 1...7 {
                let layout = AccountStorageLayout(baseDirectory: f.root.appendingPathComponent("write-\(position)"), scope: f.context.scope)
                let fault = PreparedWriteFault(position)
                let adapter = PreparedAdapter()
                let q = try CloudUploadQueue(context: f.context, layout: layout, adapter: adapter,
                    authorize: { _ in XCTFail("prepublication auth"); throw PreparedStop.crash }, isCurrent: { _ in true },
                    policy: { .init(concurrency: 2, allowsCellular: false, allowsConstrained: false) },
                    control: { _ in XCTFail("prepublication request"); throw PreparedStop.crash },
                    journalWriteObserver: { try fault.write($0) })
                do { try await q.prepareSelection(saved, captured: f.context); XCTFail("fault \(position) not reached") } catch {}
                await q.suspend()
                XCTAssertEqual(adapter.count, 0)
                let reopened = try CloudUploadQueue(context: f.context, layout: layout, adapter: adapter,
                    authorize: { _ in throw PreparedStop.crash }, isCurrent: { _ in true },
                    policy: { .init(concurrency: 2, allowsCellular: false, allowsConstrained: false) }, control: { _ in throw PreparedStop.crash })
                try await reopened.reconcile()
                XCTAssertEqual(adapter.count, 0, "partial selection cannot deliver")
                try await reopened.prepareSelection(saved, captured: f.context)
                let journal = try CloudUploadJournal(directory: layout.uploadDirectory)
                let jobs = try journal.load(); XCTAssertEqual(jobs.count, 2)
                for job in jobs.values { try journal.verifyBody(job); XCTAssertEqual(job.deliveryAdmitted, false) }
                let original = try await reopened.preparedSelection(saved.id, captured: f.context)
                XCTAssertEqual(try original.encoded(), try saved.encoded())
                await reopened.suspend()
            }
        } catch { await close(f); throw error }
        await close(f)
    }

    func testEveryPreparationWriteFailureKeepsLiveBarrierAndExactRetryCompletes() async throws {
        let f = try await fixture()
        do {
            let saved = try append(f), correction = try append(f, row: 2), independent = try append(f, device: "independent")
            for position in 1...7 {
                let layout = AccountStorageLayout(baseDirectory: f.root.appendingPathComponent("live-write-\(position)"), scope: f.context.scope)
                let fault = PreparedWriteFault(position), adapter = PreparedAdapter()
                let queue = try CloudUploadQueue(context: f.context, layout: layout, adapter: adapter,
                    authorize: { _ in XCTFail("no auth before delivery"); throw PreparedStop.crash }, isCurrent: { _ in true },
                    policy: { .init(concurrency: 2, allowsCellular: false, allowsConstrained: false) },
                    control: { _ in XCTFail("no request before delivery"); throw PreparedStop.crash },
                    journalWriteObserver: { try fault.write($0) })
                do { try await queue.prepareSelection(saved, captured: f.context); XCTFail("missing fault \(position)") } catch {}
                do { try await queue.prepareSelection(correction, captured: f.context); XCTFail("live lane was released") }
                catch { XCTAssertEqual(error as? CloudUploadError, .retryScheduled) }
                let pending = try await queue.preparedSelections(sourceID: source, endpoint: endpoint, receiverStateID: receiver, captured: f.context)
                XCTAssertEqual(pending.map(\.id), [saved.id])
                if position <= 2 {
                    do { try await queue.prepareSelection(independent, captured: f.context); XCTFail("ambiguous reservation allowed fresh admission") }
                    catch { XCTAssertEqual(error as? CloudUploadError, .retryScheduled) }
                }
                try await queue.prepareSelection(saved, captured: f.context)
                let journal = try CloudUploadJournal(directory: layout.uploadDirectory)
                try journal.loadSelections(owner: f.context.scope)
                XCTAssertEqual(journal.continuations[saved.id]?.published, true)
                XCTAssertEqual(try Data(contentsOf: layout.uploadDirectory.appendingPathComponent(saved.id + ".selection")), try saved.encoded())
                for job in try journal.load().values { try journal.verifyBody(job); XCTAssertEqual(job.deliveryAdmitted, false) }
                try await queue.prepareSelection(independent, captured: f.context)
                try await queue.reconcile()
                XCTAssertEqual(adapter.count, 0)
                await queue.suspend()
            }
        } catch { await close(f); throw error }
        await close(f)
    }

    func testAmbiguousReservationRetainsCompletionQuotaAndBlocksOrdinaryBodies() async throws {
        let f = try await fixture()
        do {
            let saved = try append(f), independent = try append(f, device: "independent")
            let allocation = try CloudPreparedQuota().reservation(for: saved)
            for position in 1...2 {
                let fault = PreparedWriteFault(position)
                let path = f.root.appendingPathComponent("live-quota-\(position)")
                let journal = try CloudUploadJournal(directory: path, maximumBytes: allocation.total, afterWrite: { try fault.write($0) })
                XCTAssertThrowsError(try journal.reserve(saved, legacyJobs: 0))
                XCTAssertEqual(journal.selections[saved.id]?.id, saved.id)
                let retained = try journal.storageAccounting()
                XCTAssertEqual(retained.used + retained.reserved, allocation.total)
                var ordinary = CloudUploadJob(id: AccountScope.digest("pending-ordinary"), owner: f.context.scope,
                    generation: f.context.generation, endpoint: endpoint, deviceID: device, createdAt: Date(), operation: .request,
                    method: "POST", headers: [:])
                XCTAssertThrowsError(try journal.persistBody(Data([1]), job: &ordinary))
                XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent(ordinary.id + ".body").path))
                XCTAssertThrowsError(try journal.reserve(independent, legacyJobs: 0))
                try journal.reserve(saved, legacyJobs: 0)
                let repaired = try journal.storageAccounting()
                XCTAssertEqual(repaired.used + repaired.reserved, allocation.total)
                XCTAssertThrowsError(try journal.reserve(independent, legacyJobs: 0)) { XCTAssertEqual($0 as? CloudUploadError, .storageFull) }
                XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent(saved.id + ".selection")), try saved.encoded())
            }
        } catch { await close(f); throw error }
        await close(f)
    }

    func testUnknownPendingReservationFilesRemainUntouchedDuringLiveRetry() async throws {
        let f = try await fixture()
        do {
            let saved = try append(f), independent = try append(f, device: "independent")
            for (position, suffix) in [(1, "selection"), (2, "continuation")] {
                let path = f.root.appendingPathComponent("unknown-live-\(position)"), fault = PreparedWriteFault(position)
                let journal = try CloudUploadJournal(directory: path, afterWrite: { try fault.write($0) })
                XCTAssertThrowsError(try journal.reserve(saved, legacyJobs: 0))
                let unknownPath = path.appendingPathComponent(saved.id + "." + suffix)
                var unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: unknownPath)) as? [String: Any])
                unknown["version"] = 3
                let bytes = try JSONSerialization.data(withJSONObject: unknown, options: [.sortedKeys])
                try bytes.write(to: unknownPath)
                for _ in 0..<2 {
                    XCTAssertThrowsError(try journal.reserve(saved, legacyJobs: 0))
                    XCTAssertThrowsError(try journal.reserve(independent, legacyJobs: 0))
                    XCTAssertEqual(try Data(contentsOf: unknownPath), bytes)
                    XCTAssertEqual(journal.selections.count, 1)
                    XCTAssertEqual(journal.continuations[saved.id]?.published, false)
                }
                let reopened = try CloudUploadJournal(directory: path)
                XCTAssertThrowsError(try reopened.loadSelections(owner: f.context.scope))
                XCTAssertThrowsError(try reopened.reserve(independent, legacyJobs: 0))
                XCTAssertEqual(try Data(contentsOf: unknownPath), bytes)
            }
        } catch { await close(f); throw error }
        await close(f)
    }

    func testDuplicatePersistedLanesFailClosedWithoutSelectingHashOrderOrDeletingDebt() async throws {
        let f = try await fixture()
        do {
            let original = try append(f), correction = try append(f, row: 2), independent = try append(f, device: "independent")
            let layout = AccountStorageLayout(baseDirectory: f.root.appendingPathComponent("duplicate-lanes"), scope: f.context.scope)
            let journal = try CloudUploadJournal(directory: layout.uploadDirectory)
            let snapshots = try [original, correction].map { ($0.id, try $0.encoded()) }
            for (id, bytes) in snapshots { try journal.durableWrite(bytes, to: layout.uploadDirectory.appendingPathComponent(id + ".selection")) }
            XCTAssertEqual(original.laneID, correction.laneID)
            for _ in 0..<2 {
                XCTAssertThrowsError(try journal.loadSelections(owner: f.context.scope)) { XCTAssertEqual($0 as? CloudUploadError, .corruptJournal) }
                XCTAssertThrowsError(try journal.reserve(independent, legacyJobs: 0))
                XCTAssertTrue(journal.selections.isEmpty, "failed load must not expose a hash-ordered partial queue")
                XCTAssertThrowsError(try CloudUploadQueue(context: f.context, layout: layout, adapter: PreparedAdapter(),
                    authorize: { _ in XCTFail("duplicate lane auth"); throw PreparedStop.crash }, isCurrent: { _ in true },
                    policy: { .init(concurrency: 0, allowsCellular: false, allowsConstrained: false) },
                    control: { _ in XCTFail("duplicate lane request"); throw PreparedStop.crash }))
                for (id, bytes) in snapshots {
                    XCTAssertEqual(try Data(contentsOf: layout.uploadDirectory.appendingPathComponent(id + ".selection")), bytes)
                }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: layout.uploadDirectory.path).count, 2)
            }
        } catch { await close(f); throw error }
        await close(f)
    }

    private func multipart(_ f: Fixture) throws -> CloudPushPreparedSelection {
        let window = PushWindow(fromDay: "2026-09-18", toDay: "2026-09-18", startTsInclusive: 100, endTsExclusive: 86_500)
        let rows = (0...5000).map { PushMutableRecord(key: ["day": .string("2026-09-18"), "question": .string("q\($0)")],
            data: ["answeredYes": .bool(true), "notes": .null, "numericValue": .null]) }
        let batches = try PushProtocol.mutableBatches(table: .journal, sourceId: source, deviceId: device, window: window, records: rows)
        let full = PushWindow(fromDay: "2026-09-17", toDay: "2026-09-18", startTsInclusive: -86_300, endTsExclusive: 86_500)
        let progress = PushWindowProgress(window: full, batchId: batches[0].replacementId!, dayHashes: [
            "2026-09-17": String(repeating: "a", count: 64), "2026-09-18": String(repeating: "b", count: 64)])
        return try .init(context: f.context, endpoint: endpoint, receiverStateID: receiver, progressVersion: "1.2",
            selection: .init(inline: batches, commit: .init(kind: .mutable, table: "journal", deviceID: device,
                batchIDs: batches.map(\.batchId), window: progress)), inlineGzip: batches.map { try CloudPushTransport.gzip($0.body) })
    }

    func testMultipartPartialReceiptAndAllReceiptsBeforeStagePreserveOriginalFullWindow() async throws {
        var f = try await fixture()
        do {
            let saved = try multipart(f), batches = try saved.selection.restoredInlineBatches()
            XCTAssertEqual(batches.count, 2)
            try await f.runtime.queue.prepareSelection(saved, captured: f.context)
            let first = try W5ReceiptFixture.bytes(W5ReceiptFixture.inline(batches[0], owner: f.context.scope.userID))
            PreparedURLProtocol.set { _ in (200, first) }
            // A direct attempt to send the second part cannot overtake the first.
            do { _ = try await f.transport.post(batches[1]); XCTFail("part overtook predecessor") }
            catch { XCTAssertEqual(error as? CloudUploadError, .retryScheduled) }
            _ = try await f.transport.post(batches[0]) // Receipt persisted, no association yet.
            let p = try progress(f, version: "1.2")
            do { try await p.stage(saved.commit, preparedSelectionID: saved.id); XCTFail("partial group staged") } catch {}
            let empty = try await p.window(table: .journal, deviceId: device); XCTAssertNil(empty)
            let root = f.root; try await stop(f); f = try await fixture(root: root)
            let second = try W5ReceiptFixture.bytes(W5ReceiptFixture.inline(batches[1], owner: f.context.scope.userID))
            let requests = PreparedRequestCount()
            PreparedURLProtocol.set { _ in requests.add(); return (200, second) }
            let interrupted = await coordinator(f, try progress(f, version: "1.2"), version: "1.2",
                beforeStage: { throw PreparedStop.crash }).resumePrepared(saved.selection)
            guard case .rejected = interrupted else { throw PreparedStop.rejected("expected pre-stage interruption") }
            XCTAssertEqual(requests.value, 1, "already receipted part must not be retransmitted")
            let before = try await progress(f, version: "1.2").window(table: .journal, deviceId: device); XCTAssertNil(before)
            try await stop(f); f = try await fixture(root: root)
            PreparedURLProtocol.set { _ in XCTFail("all-part receipt recovery must be offline"); throw PreparedStop.crash }
            let blocked = try await CloudPushPreparedRecovery.recover(queue: f.runtime.queue, context: f.context, sourceID: source,
                endpoint: endpoint, receiverStateID: receiver, directory: f.runtime.progressDirectory,
                coordinator: { self.coordinator(f, $0, version: $1) })
            XCTAssertFalse(blocked)
            let old = try await progress(f, version: "1.2").window(table: .journal, deviceId: device)
            XCTAssertEqual(old?.window.fromDay, "2026-09-17")
            XCTAssertEqual(old?.window.startTsInclusive, -86_300)
            XCTAssertEqual(old?.dayHashes, saved.commit.window?.dayHashes)
            let current = try await progress(f, version: "1.4").window(table: .journal, deviceId: device); XCTAssertNil(current)
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
            let remaining = try await f.runtime.queue.preparedSelections(sourceID: source, endpoint: endpoint, receiverStateID: receiver, captured: f.context)
            XCTAssertTrue(remaining.isEmpty)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testPreparedCleanupDebtSurvivesApplyBodyUnlinkAndSelectionRetirement() async throws {
        for boundary in 0..<3 {
            var f = try await fixture()
            do {
                let (batch, rows) = try await raw(f), saved = try binarySelection(f, batch: batch, rows: rows)
                try serveObject(batch); try await f.runtime.queue.prepareSelection(saved, captured: f.context)
                let p = try progress(f, version: "1.2")
                let result = await coordinator(f, p, version: "1.2", beforeStage: { throw PreparedStop.crash }).resumePrepared(saved.selection)
                guard case .rejected = result else { throw PreparedStop.rejected("expected interruption") }
                var c = committer(f, p, afterApply: { if boundary == 0 { throw PreparedStop.crash } },
                                  afterCleanup: { if boundary == 1 { throw PreparedStop.crash } })
                if boundary == 2 {
                    let transport = f.transport
                    c.retirePrepared = { id in try await transport.retireSelection(id); throw PreparedStop.crash }
                }
                do { try await c.commit(saved.commit, preparedSelectionID: saved.id); XCTFail("fault absent") } catch {}
                let debts = await p.pendingCommits(); XCTAssertEqual(debts.count, 1)
                let reference = await p.preparedReference(saved.commit); XCTAssertEqual(reference, saved.id)
                if boundary > 0 { XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty) }
                let root = f.root; try await stop(f); f = try await fixture(root: root)
                PreparedURLProtocol.set { _ in XCTFail("cleanup recovery sent a request"); throw PreparedStop.crash }
                let recovered = try progress(f, version: "1.2")
                try await committer(f, recovered).recover(); try await committer(f, recovered).recover()
                let remaining = await recovered.pendingCommits(); XCTAssertTrue(remaining.isEmpty)
                let selections = try await f.runtime.queue.preparedSelections(sourceID: source, endpoint: endpoint, receiverStateID: receiver, captured: f.context)
                XCTAssertTrue(selections.isEmpty)
                XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
            } catch { await close(f); throw error }
            await close(f)
        }
    }

    func testUnknownLocalVersionsAndChangedBodyStayRetained() async throws {
        let f = try await fixture()
        do {
            let saved = try append(f)
            for version in [1, 3] {
                let path = f.root.appendingPathComponent("unknown-\(version)")
                let journal = try CloudUploadJournal(directory: path)
                var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: saved.encoded()) as? [String: Any])
                encoded["version"] = version
                let bytes = try JSONSerialization.data(withJSONObject: encoded, options: [.sortedKeys])
                let file = path.appendingPathComponent(saved.id + ".selection")
                try journal.durableWrite(bytes, to: file)
                XCTAssertThrowsError(try journal.loadSelections(owner: f.context.scope))
                XCTAssertEqual(try Data(contentsOf: file), bytes)
            }
            try await f.runtime.queue.prepareSelection(saved, captured: f.context)
            let job = try XCTUnwrap(CloudUploadJournal(directory: f.layout.uploadDirectory).load().values.first)
            let url = try CloudUploadJournal(directory: f.layout.uploadDirectory).bodyURL(job)
            try Data("controlled corruption".utf8).write(to: url)
            do { try await f.runtime.queue.prepareSelection(saved, captured: f.context); XCTFail("corrupt body admitted") }
            catch { XCTAssertEqual(error as? CloudUploadError, .changedPayload) }
            XCTAssertEqual(try Data(contentsOf: url), Data("controlled corruption".utf8))
        } catch { await close(f); throw error }
        await close(f)
    }

    func testConflictSuccessorIsDurableBeforeRequestAndReusesExactPayloadAfterRelaunch() async throws {
        var f = try await fixture()
        do {
            let (batch, rows) = try await raw(f), saved = try binarySelection(f, batch: batch, rows: rows)
            try await f.runtime.queue.prepareSelection(saved, captured: f.context)
            let conflict = try W5ReceiptFixture.bytes(["type": "error", "protocolVersion": "1.2", "code": "object_id_conflict"])
            PreparedURLProtocol.set { _ in (409, conflict) }
            do { _ = try await f.transport.createObjectIntent(.init(batch: batch), lane: lane); XCTFail("expected conflict") }
            catch { XCTAssertEqual((error as? PushTransportException)?.failure.receiverCode, "object_id_conflict") }
            let root = f.root; try await stop(f); f = try await fixture(root: root)
            let resumedManifest = try await f.runtime.queue.resumeManifest(selectionID: saved.id, captured: f.context)
            let successor = try XCTUnwrap(resumedManifest)
            XCTAssertNotEqual(successor.objectId, batch.objectId)
            XCTAssertEqual(successor.contentSha256, batch.contentSha256)
            try await stop(f); f = try await fixture(root: root)
            let repeated = try await f.runtime.queue.resumeManifest(selectionID: saved.id, captured: f.context)
            XCTAssertEqual(repeated, successor)
            let jobs = try CloudUploadJournal(directory: f.layout.uploadDirectory).load()
            XCTAssertEqual(jobs.count, 2)
            for job in jobs.values {
                XCTAssertEqual(job.payloadSHA256, PushDurabilityReceipt.sha256(batch.payload))
                XCTAssertEqual(try Data(contentsOf: f.layout.uploadDirectory.appendingPathComponent(job.payloadName!)), batch.payload)
            }
            var ack = W5ReceiptFixture.object(batch, owner: f.context.scope.userID)
            ack["objectId"] = successor.objectId
            var receipt = ack["durabilityReceipt"] as! [String: Any]; receipt["objectId"] = successor.objectId; ack["durabilityReceipt"] = receipt
            let bytes = try W5ReceiptFixture.bytes(ack), intentBytes = try successor.encode()
            PreparedURLProtocol.set { request in
                if request.httpMethod == "PUT" { return (200, Data()) }
                if request.url!.path.hasSuffix("/complete") { return (200, bytes) }
                XCTAssertEqual(try PreparedURLProtocol.body(request), intentBytes)
                return (200, try W5ReceiptFixture.bytes(["type": "objectIntent", "protocolVersion": "1.2",
                    "objectId": successor.objectId, "objectKey": "staging/successor", "duplicate": false,
                    "uploadUrl": "https://bucket.example/synthetic", "requiredHeaders": [:], "expiresAt": "2030-01-01T00:00:00Z"]))
            }
            let result = await coordinator(f, try progress(f, version: "1.2"), version: "1.2").resumePrepared(saved.selection, manifestOverride: successor)
            guard case .accepted = result else { throw PreparedStop.rejected(String(describing: result)) }
            let receiptKey = try await f.store.registryWriter.read { try String.fetchOne($0, sql: "SELECT objectKey FROM rawDurabilityReceipt") }
            XCTAssertEqual(receiptKey, "archive/verified-object")
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testPreparedExpiryAnd403RenewSameManifestIDAndFileUnderBoundedPolicy() async throws {
        let f = try await fixture()
        do {
            let (batch, rows) = try await raw(f), saved = try binarySelection(f, batch: batch, rows: rows)
            let layout = AccountStorageLayout(baseDirectory: f.root.appendingPathComponent("expiry-queue"), scope: f.context.scope)
            let adapter = PreparedAdapter(), renewals = PreparedRequestCount()
            let intentData = try W5ReceiptFixture.bytes(["type": "objectIntent", "protocolVersion": "1.2", "objectId": batch.objectId,
                "objectKey": "staging/expiry", "duplicate": false, "uploadUrl": "https://bucket.example/renewed",
                "requiredHeaders": [:], "expiresAt": "2030-01-01T00:00:00Z"])
            let q = try CloudUploadQueue(context: f.context, layout: layout, adapter: adapter, authorize: { _ in "synthetic" },
                isCurrent: { _ in true }, policy: { .init(concurrency: 1, allowsCellular: false, allowsConstrained: false) },
                control: { request in
                    XCTAssertEqual(request.httpBody, saved.selection.objectIntentBytes); renewals.add()
                    return .init(statusCode: 200, body: intentData)
                })
            try await q.prepareSelection(saved, captured: f.context)
            try await q.admitPreparedIntent(.init(batch: batch), endpoint: endpoint, receiverStateID: receiver, captured: f.context)
            try await q.recordIntent(.init(batch: batch), lane: lane,
                intent: .init(objectId: batch.objectId, objectKey: "staging/expiry", uploadUrl: "https://bucket.example/expired",
                    requiredHeaders: [:], expiresAt: "2000-01-01T00:00:00Z", duplicate: false), endpoint: endpoint,
                captured: f.context, receiverStateID: receiver)
            try await q.reconcile()
            XCTAssertEqual(renewals.value, 1); XCTAssertEqual(adapter.count, 1)
            let task = try XCTUnwrap(adapter.last)
            XCTAssertEqual(task.request.url?.absoluteString, "https://bucket.example/renewed")
            XCTAssertFalse(task.request.allowsCellularAccess)
            XCTAssertEqual(try Data(contentsOf: task.file), batch.payload)
            await q.receive(task.task, status: 403, body: Data(), error: false)
            await q.suspend()
            let reopened = try CloudUploadQueue(context: .init(scope: f.context.scope, generation: UUID()), layout: layout, adapter: adapter,
                authorize: { _ in "synthetic" }, isCurrent: { _ in true },
                policy: { .init(concurrency: 1, allowsCellular: false, allowsConstrained: false) }, control: { request in
                    XCTAssertEqual(request.httpBody, saved.selection.objectIntentBytes); renewals.add()
                    return .init(statusCode: 200, body: intentData)
                }, now: { Date().addingTimeInterval(600) })
            try await reopened.reconcile()
            XCTAssertEqual(renewals.value, 2); XCTAssertEqual(adapter.count, 2)
            XCTAssertEqual(adapter.last?.file, task.file)
            let job = try XCTUnwrap(CloudUploadJournal(directory: layout.uploadDirectory).load().values.first)
            XCTAssertEqual(job.objectID, batch.objectId)
            XCTAssertEqual(job.objectKey, "staging/expiry")
            XCTAssertEqual(job.payloadSHA256, PushDurabilityReceipt.sha256(batch.payload))
            await reopened.suspend()
        } catch { await close(f); throw error }
        await close(f)
    }

    func testOtherSourceReceiverAndOwnerCannotRecoverOrAdoptSelection() async throws {
        let f = try await fixture()
        do {
            let saved = try append(f)
            try await f.runtime.queue.prepareSelection(saved, captured: f.context)
            let otherSource = try await f.runtime.queue.preparedSelections(sourceID: UUID().uuidString.lowercased(), endpoint: endpoint,
                receiverStateID: receiver, captured: f.context)
            let otherReceiver = try await f.runtime.queue.preparedSelections(sourceID: source, endpoint: endpoint,
                receiverStateID: "different", captured: f.context)
            XCTAssertTrue(otherSource.isEmpty); XCTAssertTrue(otherReceiver.isEmpty)
            let other = AccountSessionContext(scope: try .init(projectURL: f.context.scope.projectURL,
                userID: "22222222-2222-4222-8222-222222222222"), generation: UUID())
            do { _ = try await f.runtime.queue.preparedSelection(saved.id, captured: other); XCTFail("foreign owner") }
            catch { XCTAssertEqual(error as? CloudUploadError, .staleOwner) }
            let copied = try CloudPushPreparedSelection(context: other, endpoint: endpoint, receiverStateID: receiver,
                progressVersion: saved.progressVersion, selection: saved.selection, inlineGzip: saved.inlineGzip)
            do { try await f.runtime.queue.prepareSelection(copied, captured: f.context); XCTFail("owner reassigned") }
            catch { XCTAssertEqual(error as? CloudUploadError, .staleOwner) }
            XCTAssertNotEqual(copied.id, saved.id)
            XCTAssertEqual(try CloudPushPreparedSelection.decode(Data(contentsOf: f.layout.uploadDirectory.appendingPathComponent(saved.id + ".selection"))).capturedGeneration, f.context.generation)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testPpgPrefixAndAuxiliaryResourceMembershipSurviveReceiptGap() async throws {
        for table in [PushBinaryTable.ppgWaveformSample, .v18AuxSample] {
            var f = try await fixture()
            do {
                let version = table == .ppgWaveformSample ? "1.3" : "1.4"
                if table == .ppgWaveformSample {
                    _ = try await f.store.insert(Streams(ppgWaveform: [
                        .init(ts: 100, samples: [1, 2], recordIndex: 1),
                        .init(ts: 100 + 48 * 3600 - 1, samples: [3, 4], recordIndex: 2),
                        .init(ts: 100 + 48 * 3600, samples: [5, 6], recordIndex: 3)]), deviceId: device)
                } else {
                    _ = try await f.store.insert(Streams(v18Aux: [.init(ts: 100, recordIndex: 0), .init(ts: 100, recordIndex: 1)]), deviceId: device)
                    try await f.store.registryWriter.write { db in
                        try db.execute(sql: "UPDATE v18AuxSample SET resourceKey='100' WHERE recordIndex=0; UPDATE ingestRawResource SET resourceKey='100' WHERE lane='v18AuxSample' AND resourceKey='100:0'")
                    }
                }
                let rows = try await f.snapshot.binaryRows(table: table, deviceId: device, afterRowId: 0, limit: 10)
                let batch = try PushProtocol.binaryObjectBatch(table: table, sourceId: source, deviceId: device, startCursor: nil,
                    rows: table == .v18AuxSample ? Array(rows.prefix(1)) : rows, protocolVersion: version)
                let selected = Array(rows.prefix(batch.sampleCount))
                let saved = try binarySelection(f, batch: batch, rows: selected)
                try serveObject(batch); try await f.runtime.queue.prepareSelection(saved, captured: f.context)
                let result = await coordinator(f, try progress(f, version: version), version: version,
                    beforeAssociation: { throw PreparedStop.crash }).resumePrepared(saved.selection)
                guard case .rejected = result else { throw PreparedStop.rejected("expected interruption") }
                let root = f.root; try await stop(f); f = try await fixture(root: root)
                PreparedURLProtocol.set { _ in XCTFail("membership replay sent"); throw PreparedStop.crash }
                let blocked = try await CloudPushPreparedRecovery.recover(queue: f.runtime.queue, context: f.context, sourceID: source,
                    endpoint: endpoint, receiverStateID: receiver, directory: f.runtime.progressDirectory,
                    coordinator: { self.coordinator(f, $0, version: $1) })
                XCTAssertFalse(blocked)
                let keys = try await f.store.registryWriter.read { try String.fetchAll($0, sql: "SELECT resourceKey FROM rawDurabilityReceipt ORDER BY resourceKey") }
                XCTAssertEqual(Set(keys), table == .v18AuxSample ? ["100"] : ["100:1", "\(100 + 48 * 3600 - 1):2"])
                let cursor = try await progress(f, version: version).binaryCursor(table: table, deviceId: device)
                XCTAssertEqual(cursor, batch.endCursor)
                let remaining = try await f.snapshot.binaryRows(table: table, deviceId: device, afterRowId: cursor!.rowId, limit: 10)
                XCTAssertEqual(remaining.count, 1, "lookahead/same-second sibling remains unassociated")
            } catch { await close(f); throw error }
            await close(f)
        }
    }

    func testSameSecondImuAndBothExactArchiveOriginsRecoverMembershipThenCompact() async throws {
        let imu = try W5ImuFixture(); defer { imu.close() }
        imu.populateSameSecond()
        var currentSource = imu.source
        defer { XCTAssertNoThrow(try currentSource.index.close()) }
        var f = try await fixture(imuSource: currentSource)
        do {
            var archiveOrigins: Set<String> = []
            for ordinal in 0..<4 {
                let table: PushBinaryTable = ordinal == 0 ? .rawImuSession : .rawBatch
                let rows = try await f.snapshot.binaryRows(table: table, deviceId: imu.device, afterRowId: 0, limit: ordinal == 0 ? 100 : 1)
                XCTAssertEqual(rows.count, ordinal == 0 ? 3 : 1)
                let batch = try PushProtocol.binaryObjectBatch(table: table, sourceId: source, deviceId: imu.device, startCursor: nil,
                    rows: rows, protocolVersion: "1.2", decodedLimit: PushProtocolLimits.maxObjectDecodedBytes)
                let saved = try binarySelection(f, batch: batch, rows: rows)
                var exactArchive: Data?
                if case .rawBatch(let row) = rows[0] {
                    let (descriptor, bytes) = try ImuArchiveDescriptor.decode(row)
                    archiveOrigins.insert(descriptor.origin); exactArchive = bytes
                    let store = descriptor.origin == "session" ? imu.sessions : imu.continuous
                    XCTAssertEqual(bytes, try store.pushSegmentSnapshot(.init(windowID: descriptor.window,
                        deviceID: descriptor.device, bucket: descriptor.bucket)).archiveBytes)
                }
                try serveObject(batch); try await f.runtime.queue.prepareSelection(saved, captured: f.context)
                let result = await coordinator(f, try progress(f, version: "1.2"), version: "1.2",
                    beforeAssociation: { throw PreparedStop.crash }).resumePrepared(saved.selection)
                guard case .rejected = result else { throw PreparedStop.rejected("expected receipt gap") }
                let root = f.root; try await stop(f)
                try currentSource.index.close()
                currentSource = try CloudImuPushSource(scope: imu.scope, directory: imu.indexDirectory,
                    sessionStore: imu.sessions, continuousStore: imu.continuous)
                f = try await fixture(root: root, imuSource: currentSource)
                let restored = try await f.runtime.queue.preparedSelection(saved.id, captured: f.context)
                if let exactArchive, case .rawBatch(let row) = try XCTUnwrap(restored.selection.restoredObject()).rows[0] {
                    XCTAssertEqual(try ImuArchiveDescriptor.decode(row).1, exactArchive)
                }
                PreparedURLProtocol.set { _ in XCTFail("IMU receipt replay sent"); throw PreparedStop.crash }
                let blocked = try await CloudPushPreparedRecovery.recover(queue: f.runtime.queue, context: f.context, sourceID: source,
                    endpoint: endpoint, receiverStateID: receiver, directory: f.runtime.progressDirectory,
                    coordinator: { self.coordinator(f, $0, version: $1) })
                XCTAssertFalse(blocked)
                if ordinal == 0 {
                    let cursor = try await progress(f, version: "1.2").binaryCursor(table: .rawImuSession, deviceId: imu.device)
                    XCTAssertEqual(cursor, batch.endCursor)
                    XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM member") }, 3,
                        "row receipts alone must retain exact-file archive membership")
                }
            }
            XCTAssertEqual(archiveOrigins, ["session", "continuous"])
            XCTAssertEqual(try imu.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM member") }, 0,
                "rows plus exact archives and completed source cleanup authorize bounded compaction")
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testConflictSuccessorPublicationCrashRepairsOnlyItsReservedExactJob() async throws {
        let f = try await fixture()
        do {
            let (batch, rows) = try await raw(f), saved = try binarySelection(f, batch: batch, rows: rows)
            let successor = PushObjectManifest(batch: batch).replacingObjectId("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
            for position in 1...3 {
                let layout = AccountStorageLayout(baseDirectory: f.root.appendingPathComponent("conflict-\(position)"), scope: f.context.scope)
                let adapter = PreparedAdapter()
                let q = try CloudUploadQueue(context: f.context, layout: layout, adapter: adapter, authorize: { _ in throw PreparedStop.crash },
                    isCurrent: { _ in true }, policy: { .init(concurrency: 0, allowsCellular: false, allowsConstrained: false) }, control: { _ in throw PreparedStop.crash })
                try await q.prepareSelection(saved, captured: f.context)
                try await q.recordPreparedConflict(.init(batch: batch), endpoint: endpoint, receiverStateID: receiver, captured: f.context)
                await q.suspend()
                let fault = PreparedWriteFault(position)
                let broken = try CloudUploadQueue(context: f.context, layout: layout, adapter: adapter, authorize: { _ in throw PreparedStop.crash },
                    isCurrent: { _ in true }, policy: { .init(concurrency: 0, allowsCellular: false, allowsConstrained: false) },
                    control: { _ in throw PreparedStop.crash }, journalWriteObserver: { try fault.write($0) })
                do { try await broken.admitPreparedIntent(successor, endpoint: endpoint, receiverStateID: receiver, captured: f.context); XCTFail("missing fault") } catch {}
                await broken.suspend()
                let recovered = try CloudUploadQueue(context: f.context, layout: layout, adapter: adapter, authorize: { _ in throw PreparedStop.crash },
                    isCurrent: { _ in true }, policy: { .init(concurrency: 0, allowsCellular: false, allowsConstrained: false) }, control: { _ in throw PreparedStop.crash })
                try await recovered.prepareSelection(saved, captured: f.context)
                let identity = try await recovered.resumeManifest(selectionID: saved.id, captured: f.context)
                XCTAssertEqual(identity, successor)
                let journal = try CloudUploadJournal(directory: layout.uploadDirectory)
                XCTAssertEqual(try journal.load().count, 2)
                for job in try journal.load().values { try journal.verifyBody(job); XCTAssertEqual(job.payloadSHA256, PushDurabilityReceipt.sha256(batch.payload)) }
                XCTAssertEqual(adapter.count, 0)
                await recovered.suspend()
            }
        } catch { await close(f); throw error }
        await close(f)
    }

    func testPreparedReceiptAssociationDoesNotOverwriteLegacyAssociationWithSameBatchID() async throws {
        let f = try await fixture()
        do {
            let saved = try append(f), batch = try saved.selection.restoredInlineBatches()[0]
            let p = try progress(f, version: "1.2")
            let bytes = try W5ReceiptFixture.bytes(W5ReceiptFixture.inline(batch, owner: f.context.scope.userID))
            let receipt = try XCTUnwrap(PushAck.parse(bytes).durabilityReceipt)
            try await p.associateInline(batch: batch, receipt: receipt)
            let legacy = try FileManager.default.contentsOfDirectory(at: f.runtime.progressDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "receipt" }
            XCTAssertEqual(legacy.count, 1)
            let original = try Data(contentsOf: legacy[0])
            try await f.runtime.queue.prepareSelection(saved, captured: f.context)
            PreparedURLProtocol.set { _ in (200, bytes) }
            let result = await coordinator(f, p, version: "1.2").resumePrepared(saved.selection)
            guard case .accepted = result else { throw PreparedStop.rejected(String(describing: result)) }
            XCTAssertEqual(try Data(contentsOf: legacy[0]), original)
            let after = try FileManager.default.contentsOfDirectory(at: f.runtime.progressDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "receipt" }
            XCTAssertEqual(after, legacy)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testOrphanPreparedCleanupMarkerIsRetainedInsteadOfLegacyGarbageCollection() async throws {
        let f = try await fixture()
        do {
            let saved = try append(f)
            try await f.runtime.queue.prepareSelection(saved, captured: f.context)
            let markerJournal = try CloudUploadJournal(directory: f.layout.uploadDirectory)
            try markerJournal.loadSelections(owner: f.context.scope)
            var marker = try XCTUnwrap(markerJournal.continuations[saved.id]); marker.sourceCommitted = true
            try markerJournal.saveContinuation(marker)
            for var job in try markerJournal.load().values { job.acknowledged = true; try markerJournal.save(job) }
            let path = f.layout.uploadDirectory.appendingPathComponent(saved.id + ".selection")
            let heldPath = f.root.appendingPathComponent("retained-selection")
            try FileManager.default.moveItem(at: path, to: heldPath) // Synthetic missing continuation proof.
            try FileManager.default.moveItem(at: f.layout.uploadDirectory.appendingPathComponent(saved.id + ".continuation"),
                to: f.root.appendingPathComponent("retained-continuation"))
            let jobsBefore = try CloudUploadJournal(directory: f.layout.uploadDirectory).load()
            let journal = try CloudUploadJournal(directory: f.layout.uploadDirectory)
            XCTAssertThrowsError(try CloudUploadQueue(context: f.context, layout: f.layout, adapter: PreparedAdapter(),
                authorize: { _ in throw PreparedStop.crash }, isCurrent: { _ in true },
                policy: { .init(concurrency: 0, allowsCellular: false, allowsConstrained: false) }, control: { _ in throw PreparedStop.crash }))
            XCTAssertEqual(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().count, jobsBefore.count)
            for job in jobsBefore.values { XCTAssertTrue(FileManager.default.fileExists(atPath: try journal.bodyURL(job).path)) }
            XCTAssertEqual(try CloudPushPreparedSelection.decode(Data(contentsOf: heldPath)).id, saved.id)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testFullByteReservationStillRecordsReceiptAndCompletesExactCleanup() async throws {
        let f = try await fixture()
        do {
            let saved = try append(f), batch = try saved.selection.restoredInlineBatches()[0]
            let capacity = try CloudPreparedQuota().reservation(for: saved).total
            let layout = AccountStorageLayout(baseDirectory: f.root.appendingPathComponent("full-queue"), scope: f.context.scope)
            let adapter = PreparedAdapter()
            let q = try CloudUploadQueue(context: f.context, layout: layout, adapter: adapter, authorize: { _ in "synthetic" },
                isCurrent: { _ in true }, policy: { .init(concurrency: 1, allowsCellular: false, allowsConstrained: false) },
                control: { _ in throw PreparedStop.crash }, maximumBytes: capacity)
            try await q.prepareSelection(saved, captured: f.context)
            do { _ = try await q.request(endpoint: endpoint, body: Data([1]), headers: [:], captured: f.context); XCTFail("ordinary admission spent reserve") }
            catch { XCTAssertEqual(error as? CloudUploadError, .storageFull) }
            let captured = f.context
            let pending = Task { try await q.request(endpoint: saved.endpoint, body: saved.inlineGzip[0],
                headers: ["Content-Type": "application/x-ndjson; charset=utf-8", "Content-Encoding": "gzip"],
                captured: captured, receiverStateID: saved.receiverStateID, batchID: batch.batchId, selectionID: saved.id) }
            for _ in 0..<200 { if adapter.count == 1 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            let created = try XCTUnwrap(adapter.last)
            let ack = try W5ReceiptFixture.bytes(W5ReceiptFixture.inline(batch, owner: f.context.scope.userID))
            await q.receive(created.task, status: 200, body: ack, error: false)
            let response = try await pending.value
            try await q.validateResponse(batch: batch, response: response, captured: f.context, receiverStateID: receiver, selectionID: saved.id)
            let p = try CloudPushProgressStore(namespace: saved.progressNamespace, directory: layout.uploadDirectory.appendingPathComponent("source-progress"))
            try await p.associateInline(batch: batch, receipt: try XCTUnwrap(PushAck.parse(ack).durabilityReceipt), prepared: saved)
            let c = CloudPushSourceCommitter(progress: p, check: {}, acknowledge: { _ in },
                cleanup: { _ in XCTFail("legacy cleanup") }, cleanupPrepared: { try await q.preparedSourceCommitted(selectionID: $0, captured: captured) },
                retirePrepared: { try await q.retireSelection($0, captured: captured) })
            try await c.commit(saved.commit, preparedSelectionID: saved.id)
            let cursor = try await p.cursor(table: .hrSample, deviceId: device); XCTAssertEqual(cursor, batch.endCursor)
            XCTAssertTrue(try CloudUploadJournal(directory: layout.uploadDirectory).load().isEmpty)
            let debt = await p.pendingCommits(); XCTAssertTrue(debt.isEmpty)
            await q.suspend()
        } catch { await close(f); throw error }
        await close(f)
    }

    func testActualGroupAndLegacyJobCountCapsAdmitNoPartialSelection() async throws {
        let f = try await fixture()
        do {
            for index in 0..<64 { try await f.runtime.queue.prepareSelection(try append(f, device: "group-\(index)"), captured: f.context) }
            do { try await f.runtime.queue.prepareSelection(try append(f, device: "group-65"), captured: f.context); XCTFail("group count overflow") }
            catch { XCTAssertEqual(error as? CloudUploadError, .storageFull) }
            XCTAssertEqual(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().count, 128)
            let groups = try await f.runtime.queue.preparedSelections(sourceID: source, endpoint: endpoint, receiverStateID: receiver, captured: f.context)
            XCTAssertEqual(groups.count, 64)
            let layout = AccountStorageLayout(baseDirectory: f.root.appendingPathComponent("job-cap"), scope: f.context.scope)
            let journal = try CloudUploadJournal(directory: layout.uploadDirectory)
            for index in 0..<254 {
                var job = CloudUploadJob(id: AccountScope.digest("legacy-\(index)"), owner: f.context.scope, generation: f.context.generation,
                    endpoint: endpoint, deviceID: device, createdAt: Date(), operation: .request, method: "POST", headers: [:])
                job.phase = .responseSaved; job.responseStatus = 200; job.responseBody = Data("unproven".utf8)
                try journal.persistBody(Data([1]), job: &job); try journal.save(job)
            }
            let q = try CloudUploadQueue(context: f.context, layout: layout, adapter: PreparedAdapter(), authorize: { _ in throw PreparedStop.crash },
                isCurrent: { _ in true }, policy: { .init(concurrency: 0, allowsCellular: false, allowsConstrained: false) }, control: { _ in throw PreparedStop.crash })
            try await q.prepareSelection(try append(f, device: "job-255-256"), captured: f.context)
            do { try await q.prepareSelection(try append(f, device: "over-job-cap"), captured: f.context); XCTFail("job count overflow") }
            catch { XCTAssertEqual(error as? CloudUploadError, .storageFull) }
            XCTAssertEqual(try journal.load().count, 256)
            XCTAssertEqual(try journal.load().values.filter { $0.preparedSelectionID == nil }.count, 254)
            await q.suspend()
        } catch { await close(f); throw error }
        await close(f)
    }

    func testDisabledTermsPreparedQueueCancelsRestoredTasksWithoutAuthOrNewTasks() async throws {
        let f = try await fixture()
        do {
            let saved = try append(f), batch = try saved.selection.restoredInlineBatches()[0]
            let layout = AccountStorageLayout(baseDirectory: f.root.appendingPathComponent("disabled"), scope: f.context.scope)
            let adapter = PreparedAdapter()
            func make() throws -> CloudUploadQueue {
                try CloudUploadQueue(context: f.context, layout: layout, adapter: adapter,
                    authorize: { _ in XCTFail("disabled authorization"); throw PreparedStop.crash }, isCurrent: { _ in true },
                    policy: { .current(wifiOnly: true, enabled: false) }, control: { _ in XCTFail("disabled renewal"); throw PreparedStop.crash })
            }
            let q = try make(); try await q.prepareSelection(saved, captured: f.context)
            do { try await q.checkIntentAdmission(captured: f.context); XCTFail("disabled intent") }
            catch { XCTAssertEqual(error as? CloudUploadError, .retryScheduled) }
            do { _ = try await q.request(endpoint: endpoint, body: saved.inlineGzip[0],
                headers: ["Content-Type": "application/x-ndjson; charset=utf-8", "Content-Encoding": "gzip"],
                captured: f.context, receiverStateID: receiver, batchID: batch.batchId, selectionID: saved.id); XCTFail("disabled request") }
            catch { XCTAssertEqual(error as? CloudUploadError, .retryScheduled) }
            await q.suspend()
            let journal = try CloudUploadJournal(directory: layout.uploadDirectory); try journal.loadSelections(owner: f.context.scope)
            let id = saved.jobID(batchID: batch.batchId, representation: "gzip")
            var job = try XCTUnwrap(journal.load()[id])
            job.phase = .transferring; job.taskIdentifier = 42; job.attempt = UUID(); try journal.save(job)
            adapter.seed(.init(identifier: 42, description: job.taskDescription))
            let reopened = try make(); try await reopened.reconcile()
            XCTAssertTrue(adapter.cancelled.contains(42)); XCTAssertEqual(adapter.count, 0)
            XCTAssertEqual(try journal.load().count, 2)
            for remaining in try journal.load().values { try journal.verifyBody(remaining) }
            await reopened.suspend()
        } catch { await close(f); throw error }
        await close(f)
    }

    func testFreshCoordinatorCallsPreparationHookOnActualCloudTransportLane() async throws {
        let f = try await fixture()
        do {
            let (batch, _) = try await raw(f)
            try serveObject(batch)
            let p = try progress(f, version: "1.2")
            // No manual preparation, association, stage or cleanup in this path.
            let result = await coordinator(f, p, version: "1.2", freshSource: true).pushObjects(.rawBatch, deviceId: device, lane: lane)
            guard case .accepted = result else { throw PreparedStop.rejected(String(describing: result)) }
            let synced = try await f.store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rawBatch WHERE syncedAt IS NOT NULL") }
            XCTAssertEqual(synced, 1)
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
            let remaining = try await f.runtime.queue.preparedSelections(sourceID: source, endpoint: endpoint, receiverStateID: receiver, captured: f.context)
            XCTAssertTrue(remaining.isEmpty)
            let debt = await p.pendingCommits(); XCTAssertTrue(debt.isEmpty)
        } catch { await close(f); throw error }
        await close(f)
    }
    @MainActor
    private func preferenceAdmission(_ fence: PreparedPreferenceFence, reportCurrent: Bool? = nil,
                                     revalidate: @escaping () async -> Bool = { true }) -> SyncEngine.DependentStageAdmission {
        .init(current: { reportCurrent ?? fence.current }, revalidate: revalidate,
              boundaryCheck: { try fence.check() },
              settleCaptured: { XCTFail("transport must not settle the current preference job"); return false })
    }

    private func assertNoPreparedPublication(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        let saved = try await f.runtime.queue.preparedSelections(sourceID: source, endpoint: endpoint,
            receiverStateID: receiver, captured: f.context)
        XCTAssertTrue(saved.isEmpty, file: file, line: line)
        XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty, file: file, line: line)
        let files = try FileManager.default.contentsOfDirectory(at: f.layout.uploadDirectory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.contains { ["selection", "continuation", "body", "json"].contains($0.pathExtension) }, file: file, line: line)
    }

    func testCapturedPreferenceRevokedDuringPostEncodingValidationCannotFallBackToNil() async throws {
        let fence = PreparedPreferenceFence(), gate = PreparedValidationGate()
        let entered = expectation(description: "encoded payload reached async preference validation")
        let admission = await preferenceAdmission(fence, revalidate: { entered.fulfill(); return await gate.value() })
        let f = try await fixture(dependentAdmission: admission)
        defer { Task { await gate.release() } }
        do {
            PreparedURLProtocol.set { _ in XCTFail("invalid admission issued network work"); throw PreparedStop.crash }
            let saved = try append(f)
            let pending = Task { try await f.transport.prepareSelection(saved.selection, progressVersion: saved.progressVersion) }
            defer { pending.cancel() }
            await fulfillment(of: [entered], timeout: 2)
            fence.revoke()
            await gate.release()
            do { try await pending.value; XCTFail("revoked validation became an unguarded selection") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(fence.boundaryChecks, 0, "failed metadata validation must deny fresh admission itself")
            try await assertNoPreparedPublication(f)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testSynchronousPreferenceBoundaryRejectsAfterEncodingBeforeQueueActorEntry() async throws {
        let fence = PreparedPreferenceFence()
        let validated = expectation(description: "encoded payload's metadata was validated")
        // Keep the async metadata answer true to isolate the independent synchronous fence.
        let admission = await preferenceAdmission(fence, reportCurrent: true, revalidate: { validated.fulfill(); return true })
        let f = try await fixture(dependentAdmission: admission)
        let entered = expectation(description: "queue actor held before reservation")
        let barrier = PreparedQueueEntryBarrier(entered: entered)
        defer { barrier.release() }
        do {
            PreparedURLProtocol.set { _ in XCTFail("stale actor entry issued network work"); throw PreparedStop.crash }
            let saved = try append(f)
            let holding = Task { await f.runtime.queue.holdPreparedPreferenceTestEntry(barrier) }
            await fulfillment(of: [entered], timeout: 2)
            let pending = Task { try await f.transport.prepareSelection(saved.selection, progressVersion: saved.progressVersion) }
            defer { pending.cancel() }
            await fulfillment(of: [validated], timeout: 2)
            fence.revoke()
            barrier.release()
            await holding.value
            do { try await pending.value; XCTFail("actor hop bypassed the captured boundary fence") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(fence.boundaryChecks, 1)
            try await assertNoPreparedPublication(f)
        } catch { barrier.release(); await close(f); throw error }
        await close(f)
    }

    func testCurrentPreferenceReservationReplaysExactBytesAfterRevokeButRefusesFreshDevice() async throws {
        let fence = PreparedPreferenceFence()
        let admission = await preferenceAdmission(fence)
        let f = try await fixture(dependentAdmission: admission)
        do {
            let saved = try append(f), batch = try saved.selection.restoredInlineBatches()[0]
            try await f.transport.prepareSelection(saved.selection, progressVersion: saved.progressVersion)
            XCTAssertEqual(fence.boundaryChecks, 1)
            let path = f.layout.uploadDirectory.appendingPathComponent(saved.id + ".selection")
            let original = try Data(contentsOf: path)
            fence.revoke()
            try await f.transport.prepareSelection(saved.selection, progressVersion: saved.progressVersion)
            XCTAssertEqual(fence.boundaryChecks, 1, "exact replay must not acquire a replacement admission")
            XCTAssertEqual(try Data(contentsOf: path), original)
            let fresh = try append(f, device: "not-admitted")
            do {
                try await f.transport.prepareSelection(fresh.selection, progressVersion: fresh.progressVersion)
                XCTFail("revoked preference selected new device bytes")
            } catch { XCTAssertTrue(error is CancellationError) }
            let requests = PreparedRequestCount()
            let response = try W5ReceiptFixture.bytes(W5ReceiptFixture.inline(batch, owner: f.context.scope.userID))
            PreparedURLProtocol.set { request in
                requests.add()
                XCTAssertEqual(try PreparedURLProtocol.body(request), saved.inlineGzip[0])
                return (200, response)
            }
            let received = try await f.transport.post(batch)
            XCTAssertEqual(received.body, response)
            XCTAssertEqual(requests.value, 1)
            let journal = try CloudUploadJournal(directory: f.layout.uploadDirectory)
            let jobs = try journal.load()
            XCTAssertEqual(jobs.count, 2)
            XCTAssertTrue(jobs.values.allSatisfy { $0.preparedSelectionID == saved.id && !$0.acknowledged })
            XCTAssertNotNil(jobs[saved.jobID(batchID: batch.batchId, representation: "gzip")]?.validatedReceipt)
            XCTAssertEqual(try Data(contentsOf: path), original)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testAccountTransportKeepsCapturedPreferenceAcrossCapabilityResponse() async throws {
        let fence = PreparedPreferenceFence()
        let admission = await preferenceAdmission(fence)
        let f = try await fixture()
        do {
            let requests = PreparedRequestCount()
            let capabilities = try W5ReceiptFixture.bytes(["type": "capabilities", "protocolVersion": "1.2",
                "receiverStateId": receiver, "userId": f.context.scope.userID,
                "streams": ["hrSample"], "maxRecords": 1000, "maxBodyBytes": 1_048_576])
            PreparedURLProtocol.set { request in
                requests.add(); XCTAssertEqual(request.httpMethod, "GET")
                fence.revoke() // Accepted while the actual synthetic capability await is in flight.
                return (200, capabilities)
            }
            let transport = try CloudAccountPushTransport(endpoint: .init(url: endpoint, host: "project.example"),
                context: f.context, accessToken: "synthetic", session: f.session, isCurrent: { _ in true },
                dependentAdmission: admission)
            guard case .available = try await transport.capabilities() else { throw PreparedStop.crash }
            let saved = try append(f)
            do {
                try await transport.base.prepareSelection(saved.selection, progressVersion: saved.progressVersion)
                XCTFail("capability response lost the captured preference")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(requests.value, 1)
            try await assertNoPreparedPublication(f)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testGuardedTransportCannotBypassReservationWithDirectPayloadHelpers() async throws {
        let fence = PreparedPreferenceFence()
        let admission = await preferenceAdmission(fence)
        let f = try await fixture()
        do {
            PreparedURLProtocol.set { _ in XCTFail("unprepared helper started a request"); throw PreparedStop.crash }
            // Deliberately do NOT call requirePreparedSelections: carrying the capability is enough.
            let transport = CloudPushTransport(endpoint: .init(url: endpoint, host: "project.example"),
                bearerToken: "synthetic", context: f.context, session: f.session, dependentAdmission: admission)
            try transport.bindReceiverState(receiver)
            let inline = try append(f).selection.restoredInlineBatches()[0]
            let (binary, _) = try await raw(f)
            do { _ = try await transport.post(inline); XCTFail("unguarded inline POST") }
            catch { XCTAssertEqual(error as? CloudUploadError, .invalidRequest) }
            do { _ = try await transport.postBinary(binary); XCTFail("unguarded legacy binary POST") }
            catch { XCTAssertEqual(error as? CloudUploadError, .invalidRequest) }
            do { _ = try await transport.createObjectIntent(.init(batch: binary), lane: lane); XCTFail("unguarded object intent") }
            catch { XCTAssertEqual(error as? CloudUploadError, .invalidRequest) }
            try await assertNoPreparedPublication(f)
            let unsynced = try await f.store.registryWriter.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rawBatch WHERE syncedAt IS NULL")
            }
            XCTAssertEqual(unsynced, 1)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testPreferenceRevocationAfterObjectAdmissionPreservesReceiptAssociationAndSourceCleanup() async throws {
        let fence = PreparedPreferenceFence()
        let admission = await preferenceAdmission(fence)
        let f = try await fixture(dependentAdmission: admission)
        do {
            let (batch, _) = try await raw(f)
            try serveObject(batch)
            let p = try progress(f, version: "1.2")
            let result = await coordinator(f, p, version: "1.2", beforeAssociation: { fence.revoke() }, freshSource: true)
                .pushObjects(.rawBatch, deviceId: device, lane: lane)
            guard case .accepted = result else { throw PreparedStop.rejected(String(describing: result)) }
            XCTAssertFalse(fence.current)
            XCTAssertEqual(fence.boundaryChecks, 1)
            let synced = try await f.store.registryWriter.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rawBatch WHERE syncedAt IS NOT NULL")
            }
            XCTAssertEqual(synced, 1)
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
            let debt = await p.pendingCommits(); XCTAssertTrue(debt.isEmpty)
            let selections = try await f.runtime.queue.preparedSelections(sourceID: source, endpoint: endpoint,
                receiverStateID: receiver, captured: f.context)
            XCTAssertTrue(selections.isEmpty)
        } catch { await close(f); throw error }
        await close(f)
    }

    func testLegacyReservedObjectRecoveryDoesNotRequireOrCertifyCurrentPreference() async throws {
        let fence = PreparedPreferenceFence()
        fence.revoke()
        let admission = await preferenceAdmission(fence)
        let f = try await fixture(dependentAdmission: admission)
        do {
            let (batch, rows) = try await raw(f)
            let saved = try binarySelection(f, batch: batch, rows: rows)
            // Legacy caller's immutable W5 operation carries no retroactive preference certificate.
            try await f.runtime.queue.prepareSelection(saved, captured: f.context)
            try serveObject(batch)
            let blocked = try await CloudPushPreparedRecovery.recover(queue: f.runtime.queue, context: f.context,
                sourceID: source, endpoint: endpoint, receiverStateID: receiver, directory: f.runtime.progressDirectory,
                coordinator: { self.coordinator(f, $0, version: $1) })
            XCTAssertFalse(blocked)
            XCTAssertEqual(fence.boundaryChecks, 0)
            let current = await admission.validate(); XCTAssertFalse(current)
            let synced = try await f.store.registryWriter.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rawBatch WHERE syncedAt IS NOT NULL")
            }
            XCTAssertEqual(synced, 1)
            XCTAssertTrue(try CloudUploadJournal(directory: f.layout.uploadDirectory).load().isEmpty)
        } catch { await close(f); throw error }
        await close(f)
    }
}

private final class PreparedPreferenceFence: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var checks = 0
    var current: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    var boundaryChecks: Int { lock.lock(); defer { lock.unlock() }; return checks }
    func revoke() { lock.lock(); defer { lock.unlock() }; valid = false }
    func check() throws {
        lock.lock(); defer { lock.unlock() }; checks += 1
        guard valid else { throw CancellationError() }
    }
}

private actor PreparedValidationGate {
    private var open = false
    private var waiting: CheckedContinuation<Bool, Never>?
    func value() async -> Bool {
        if open { return true }
        return await withCheckedContinuation { waiting = $0 }
    }
    func release() { open = true; waiting?.resume(returning: true); waiting = nil }
}

private final class PreparedQueueEntryBarrier: @unchecked Sendable {
    private let entered: XCTestExpectation
    private let released = DispatchSemaphore(value: 0)
    init(entered: XCTestExpectation) { self.entered = entered }
    func hold() {
        entered.fulfill()
        XCTAssertEqual(released.wait(timeout: .now() + 5), .success, "test queue barrier timed out")
    }
    func release() { released.signal() }
}

private extension CloudUploadQueue {
    func holdPreparedPreferenceTestEntry(_ barrier: PreparedQueueEntryBarrier) { barrier.hold() }
}

private enum PreparedStop: Error { case crash, rejected(String) }
private final class PreparedWriteFault: @unchecked Sendable {
    let position: Int
    private let lock = NSLock()
    private var count = 0
    init(_ position: Int) { self.position = position }
    func write(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }; count += 1
        if count == position { throw PreparedStop.crash }
    }
}
private final class PreparedRequestCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
private final class PreparedAdapter: CloudUploadSessionAdapter, @unchecked Sendable {
    struct Created { let task: CloudUploadTaskSnapshot; let request: URLRequest; let file: URL }
    private let lock = NSLock()
    private var created = 0
    private var latest: Created?
    private var live: [CloudUploadTaskSnapshot] = []
    private var cancelledIDs: Set<Int> = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return created }
    var last: Created? { lock.lock(); defer { lock.unlock() }; return latest }
    var cancelled: Set<Int> { lock.lock(); defer { lock.unlock() }; return cancelledIDs }
    func seed(_ task: CloudUploadTaskSnapshot) { lock.lock(); defer { lock.unlock() }; live.append(task) }
    private func snapshots() -> [CloudUploadTaskSnapshot] { lock.lock(); defer { lock.unlock() }; return live }
    func tasks() async -> [CloudUploadTaskSnapshot] { snapshots() }
    func create(request: URLRequest, file: URL, description: String) -> CloudUploadTaskSnapshot {
        lock.lock(); defer { lock.unlock() }; created += 1
        let task = CloudUploadTaskSnapshot(identifier: created, description: description)
        latest = .init(task: task, request: request, file: file)
        return task
    }
    func resume(_ identifier: Int) {}
    func cancel(_ identifier: Int) { lock.lock(); defer { lock.unlock() }; cancelledIDs.insert(identifier) }
}
private struct PreparedNoSelectionSource: PushSnapshotSource {
    func knownDeviceIds(capabilities: PushCapabilities) async throws -> [String] { throw PreparedStop.crash }
    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) async throws -> PushAppendRecord? { throw PreparedStop.crash }
    func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushAppendRecord] { throw PreparedStop.crash }
    func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) async throws -> [PushMutableRecord] { throw PreparedStop.crash }
    func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) async throws -> PushBinaryRow? { throw PreparedStop.crash }
    func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushBinaryRow] { throw PreparedStop.crash }
    func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) async throws { throw PreparedStop.crash }
}
// Mill's two review test bodies are preserved verbatim; only fixture location/cleanup is adapted.
final class PreparedWriteErrorReviewTests: XCTestCase {
    private let source = "3a3486dd-5030-4e17-a00d-a781399890f9"
    private let receiver = "99999999-9999-4999-8999-999999999999"
    private let endpoint = "https://project.example/functions/v1/push"
    private var roots: [URL] = []
    private enum Stop: Error { case writeFailure }
    private final class FailFirstWrite: @unchecked Sendable {
        let lock = NSLock()
        var fired = false
        func observe(_ url: URL) throws {
            lock.lock(); defer { lock.unlock() }
            if !fired { fired = true; throw Stop.writeFailure }
        }
    }
    private struct NoNetwork: CloudUploadSessionAdapter {
        func tasks() async -> [CloudUploadTaskSnapshot] { [] }
        func create(request: URLRequest, file: URL, description: String) -> CloudUploadTaskSnapshot {
            XCTFail("no network is authorized in this review"); return .init(identifier: 1, description: description)
        }
        func resume(_ identifier: Int) { XCTFail("no network") }
        func cancel(_ identifier: Int) {}
    }
    private func queue(_ layout: AccountStorageLayout, _ context: AccountSessionContext,
                       fault: FailFirstWrite? = nil) throws -> CloudUploadQueue {
        try CloudUploadQueue(context: context, layout: layout, adapter: NoNetwork(),
            authorize: { _ in XCTFail("no auth"); throw Stop.writeFailure }, isCurrent: { _ in true },
            policy: { .init(concurrency: 0, allowsCellular: false, allowsConstrained: false) },
            control: { _ in XCTFail("no control request"); throw Stop.writeFailure },
            journalWriteObserver: { try fault?.observe($0) })
    }
    private func selection(_ context: AccountSessionContext, answer: Bool) throws -> CloudPushPreparedSelection {
        let window = PushWindow(fromDay: "2026-09-18", toDay: "2026-09-18", startTsInclusive: 100, endTsExclusive: 86500)
        let records = [PushMutableRecord(key: ["day": .string("2026-09-18"), "question": .string("synthetic")],
            data: ["answeredYes": .bool(answer), "notes": .null, "numericValue": .null])]
        let batches = try PushProtocol.mutableBatches(table: .journal, sourceId: source, deviceId: "synthetic", window: window, records: records)
        let progress = PushWindowProgress(window: window, batchId: batches[0].replacementId!,
            dayHashes: ["2026-09-18": try PushProtocol.mutableSnapshotHash(table: .journal, records: records)])
        let selected = try PushPreparedSelection(inline: batches, commit: .init(kind: .mutable,
            table: "journal", deviceID: "synthetic", batchIDs: batches.map(\.batchId), window: progress))
        return try .init(context: context, endpoint: endpoint, receiverStateID: receiver, progressVersion: "1.2",
            selection: selected, inlineGzip: try batches.map { try PushBinaryCompression.gzip($0.body) })
    }
    private func fixture() throws -> (AccountStorageLayout, AccountSessionContext) {
        let scope = try AccountScope(projectURL: "https://project.example", userID: "11111111-1111-4111-8111-111111111111")
        let context = AccountSessionContext(scope: scope, generation: UUID())
        let directory = try preparedSelectionFixtureBaseDirectory().appendingPathComponent("prepared-write-review-" + UUID().uuidString)
        roots.append(directory)
        return (.init(baseDirectory: directory, scope: scope), context)
    }
    override func tearDownWithError() throws {
        for root in roots { try FileManager.default.removeItem(at: root) }
        roots.removeAll()
        try super.tearDownWithError()
    }
    func testSameProcessWriteFailureMustKeepOriginalLaneReserved() async throws {
        let (layout, context) = try fixture()
        let original = try selection(context, answer: false), correction = try selection(context, answer: true)
        XCTAssertEqual(original.laneID, correction.laneID)
        XCTAssertNotEqual(original.id, correction.id)
        let q = try queue(layout, context, fault: FailFirstWrite())
        do { try await q.prepareSelection(original, captured: context); XCTFail("write fault missing") }
        catch { XCTAssertTrue(error is Stop) }
        let firstPath = layout.uploadDirectory.appendingPathComponent(original.id + ".selection")
        XCTAssertEqual(try CloudPushPreparedSelection.decode(Data(contentsOf: firstPath)).id, original.id)

        var blocked = false
        do { try await q.prepareSelection(correction, captured: context) }
        catch { blocked = true }
        XCTAssertTrue(blocked, "A durable original reservation must block a newer same-lane selection without requiring process death")
        await q.suspend()
        let reopened = try queue(layout, context)
        let recovered = try await reopened.preparedSelections(sourceID: source, endpoint: endpoint,
            receiverStateID: receiver, captured: context)
        print("REVIEW durable same-lane selections after live retry: \(recovered.map(\.id))")
        XCTAssertEqual(recovered.count, 1, "Restart must not discover two snapshots for the same reserved lane")
        await reopened.suspend()
    }
    func testRestartAfterSameWriteFailurePreservesOriginalLaneControl() async throws {
        let (layout, context) = try fixture()
        let original = try selection(context, answer: false), correction = try selection(context, answer: true)
        let q = try queue(layout, context, fault: FailFirstWrite())
        do { try await q.prepareSelection(original, captured: context); XCTFail("write fault missing") } catch {}
        await q.suspend()
        let reopened = try queue(layout, context)
        var blocked = false
        do { try await reopened.prepareSelection(correction, captured: context) }
        catch { blocked = true; XCTAssertEqual(error as? CloudUploadError, .retryScheduled) }
        XCTAssertTrue(blocked)
        let recovered = try await reopened.preparedSelections(sourceID: source, endpoint: endpoint,
            receiverStateID: receiver, captured: context)
        XCTAssertEqual(recovered.map(\.id), [original.id])
        await reopened.suspend()
    }
}

private final class PreparedURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: (URLRequest) throws -> (Int, Data) = { _ in throw CloudUploadError.unavailable }
    static func set(_ value: @escaping (URLRequest) throws -> (Int, Data)) { lock.lock(); defer { lock.unlock() }; handler = value }
    static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw PreparedStop.crash }
        stream.open(); defer { stream.close() }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return bytes }
            guard count > 0 else { throw stream.streamError ?? PreparedStop.crash }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let callback = Self.handler; Self.lock.unlock()
        do {
            let (status, bytes) = try callback(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
