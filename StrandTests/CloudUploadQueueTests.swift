import XCTest
import NoopPush
import Darwin
#if canImport(CloudUploadHarness)
@testable import CloudUploadHarness
#else
@testable import Strand
#endif

private func uploadQueueFixtureBaseDirectory() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["NARA_TEST_FIXTURE_ROOT"] else {
        return (ProcessInfo.processInfo.environment["NARA_TEST_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory)
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

private func cloudSyntheticRSS() throws -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { throw CloudUploadError.unavailable }
    return UInt64(info.resident_size)
}

final class CloudUploadQueueTests: XCTestCase {
    private let resourceBudget = ResourceBudget(thermal: { 0 }, lowPower: { false })
    private var fixtureRoots: [URL] = []
    override func tearDownWithError() throws {
        for root in fixtureRoots where FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        fixtureRoots.removeAll()
        try super.tearDownWithError()
    }
    func testMissingFleetCompletionRecoversOnceAndDoesNotPersistCredential() async throws {
        let (_, context, layout) = try fixture()
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        var job = CloudUploadJob(id: AccountScope.digest("missing-fleet"), owner: context.scope,
            generation: context.generation, endpoint: endpoint, deviceID: "", createdAt: Date(),
            operation: .request, method: "POST", headers: [:])
        try journal.persistBody(Data([1, 2, 3]), job: &job)
        job.phase = .pausedTerminal
        job.responseStatus = 401
        job.responseDisposition = .authentication
        try journal.save(job)
        let adapter = UploadAdapter()
        let q = try CloudUploadQueue(context: context, layout: layout, adapter: adapter,
            authorize: { _ in "installation-test-token" }, isCurrent: { _ in true },
            policy: { .init(concurrency: 1, allowsCellular: false, allowsConstrained: false) },
            control: { _ in throw CloudUploadError.unavailable }, fleetToken: { "fleet-test-secret" }, resourceBudget: resourceBudget)
        try await q.reconcile()
        let created = try XCTUnwrap(adapter.first)
        XCTAssertEqual(created.request.value(forHTTPHeaderField: "X-NOOP-Fleet-Token"), "fleet-test-secret")
        XCTAssertEqual(created.request.value(forHTTPHeaderField: "Authorization"), "Bearer installation-test-token")
        XCTAssertEqual(try Data(contentsOf: created.file), Data([1, 2, 3]))
        let metadata = String(decoding: try XCTUnwrap(journal.metadata.read(job.id + ".json")), as: UTF8.self)
        XCTAssertFalse(metadata.contains("fleet-test-secret"))
        XCTAssertFalse(metadata.contains("installation-test-token"))
        await q.receive(created.task, status: 401, body: Data(), error: false)
        try await q.reconcile()
        XCTAssertEqual(adapter.count, 1, "A real rejection must remain paused, not retry forever")
        XCTAssertEqual(try journal.load()[job.id]?.phase, .pausedTerminal)
    }

    private let endpoint = "https://project.example/functions/v1/push"
    private func fixture() throws -> (URL, AccountSessionContext, AccountStorageLayout) {
        let url = try uploadQueueFixtureBaseDirectory().appendingPathComponent("w5-" + UUID().uuidString)
        fixtureRoots.append(url)
        let scope = try AccountScope(projectURL: "https://project.example", userID: "11111111-1111-1111-1111-111111111111")
        return (url, .init(scope: scope, generation: UUID()), .init(baseDirectory: url, scope: scope))
    }
    private func queue(_ context: AccountSessionContext, _ layout: AccountStorageLayout, _ adapter: UploadAdapter,
                       current: @escaping CloudUploadQueue.Current = { _ in true }, limit: Int = 2,
                       capacity: Int = 1_000_000) throws -> CloudUploadQueue {
        try CloudUploadQueue(context: context, layout: layout, adapter: adapter, authorize: { _ in "synthetic-token" },
            isCurrent: current, policy: { .init(concurrency: limit, allowsCellular: false, allowsConstrained: false) },
            control: { _ in throw CloudUploadError.unavailable }, maximumBytes: capacity, resourceBudget: resourceBudget)
    }
    private func eventually(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not reached", file: file, line: line)
        throw CloudUploadError.unavailable
    }

    func testRotationCheckpointCommitsPairAndReopensPerReceiverWithoutLegacyDefaults() async throws {
        let (_, context, layout) = try fixture()
        let namespace = AccountScope.digest("synthetic-receiver-a"), other = AccountScope.digest("synthetic-receiver-b")
        let fingerprint = AccountScope.digest("synthetic-sorted-device-list")
        let first = try queue(context, layout, UploadAdapter())
        let initial = try await first.rotationCheckpoint(namespace: namespace, captured: context)
        XCTAssertEqual(initial, .init(index: 0, carryMore: false))
        try await first.saveRotationCheckpoint(namespace: namespace, index: 9, carryMore: true,
            deviceListFingerprint: fingerprint, captured: context)
        let reopened = try queue(context, layout, UploadAdapter())
        let saved = try await reopened.rotationCheckpoint(namespace: namespace, captured: context)
        XCTAssertEqual(saved, .init(index: 9, carryMore: true, deviceListFingerprint: fingerprint))
        let separate = try await reopened.rotationCheckpoint(namespace: other, captured: context)
        XCTAssertEqual(separate, .init(index: 0, carryMore: false))
        do {
            try await reopened.saveRotationCheckpoint(namespace: namespace, index: -1, carryMore: false, captured: context)
            XCTFail("invalid partial update accepted")
        } catch {}
        let retained = try await reopened.rotationCheckpoint(namespace: namespace, captured: context)
        XCTAssertEqual(retained, saved)
        do {
            try await reopened.saveRotationCheckpoint(namespace: namespace, index: 0, carryMore: false,
                captured: .init(scope: context.scope, generation: UUID()))
            XCTFail("stale generation changed rotation debt")
        } catch {}
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        defer { journal.close() }
        let name = try XCTUnwrap(journal.metadata.names(kind: "rotation").first)
        XCTAssertEqual(try journal.metadata.names(kind: "rotation").count, 1)
        XCTAssertThrowsError(try journal.metadata.transaction {
            try journal.metadata.put(name, data: JSONEncoder().encode(CloudRotationCheckpoint(index: 0, carryMore: false)))
            throw CloudUploadError.storageFull
        })
        let afterFailedTransaction = try await reopened.rotationCheckpoint(namespace: namespace, captured: context)
        XCTAssertEqual(afterFailedTransaction, saved)
        for invalid in ["", "short", String(repeating: "A", count: 64)] {
            do {
                try await reopened.saveRotationCheckpoint(namespace: namespace, index: 0, carryMore: false,
                    deviceListFingerprint: invalid, captured: context)
                XCTFail("malformed membership fingerprint accepted")
            } catch {}
        }
        let afterInvalidWrite = try await reopened.rotationCheckpoint(namespace: namespace, captured: context)
        XCTAssertEqual(afterInvalidWrite, saved)
        // Legacy pair decodes with no invented fingerprint; coordinator safely restarts it.
        try journal.metadata.put(name, data: Data(#"{"index":9,"carryMore":true}"#.utf8))
        let legacy = try await reopened.rotationCheckpoint(namespace: namespace, captured: context)
        XCTAssertEqual(legacy, .init(index: 9, carryMore: true))
        try journal.metadata.put(name, data: Data(#"{"index":9,"carryMore":true,"deviceListFingerprint":"bad"}"#.utf8))
        do { _ = try await reopened.rotationCheckpoint(namespace: namespace, captured: context); XCTFail("corrupt fingerprint accepted") }
        catch {}
        XCTAssertEqual(try journal.metadata.integrityCheck(), "ok")
    }

    private func streamedSelection(_ context: AccountSessionContext, directory: URL) throws -> CloudPushPreparedSelection {
        let rows: [PushBinaryRow] = [.rawBatch(.init(rowId: 1, batchId: "synthetic-file-archive", capturedAt: 1,
            deviceClockRef: 1, wallClockRef: 1, startTs: 1, endTs: 1, frameCount: 1, byteSize: 262144,
            framesBlob: Data(repeating: 31, count: 262144)))]
        let batch = try PushProtocol.binaryObjectBatch(table: .rawBatch, sourceId: W5ReceiptFixture.source,
            deviceId: "synthetic-file-device", startCursor: nil, rows: rows, protocolVersion: "1.2", payloadDirectory: directory)
        let lane = PushObjectLane(endpoint: "/functions/v1/push/objects", maxObjectBytes: 8_000_000, urlTtlSec: 60, streams: [.rawBatch])
        return try .init(context: context, endpoint: endpoint, receiverStateID: "synthetic-file-receiver", progressVersion: "1.2",
            selection: .init(binary: batch, rows: rows, manifest: .init(batch: batch), lane: lane,
                commit: .init(kind: .binary, table: "rawBatch", deviceID: batch.deviceId, batchIDs: [batch.batchId],
                    cursor: batch.endCursor, rawBatchIDs: ["synthetic-file-archive"])), inlineGzip: [])
    }

    func testStreamedWireSurvivesScratchRetirementAndColdQueueReplay() async throws {
        let (_, context, layout) = try fixture()
        let q = try queue(context, layout, UploadAdapter(), capacity: 32 * 1_048_576)
        let preparation = try await q.beginBinaryPreparation(maximumWireBytes: 4 * 1_048_576, captured: context)
        let saved = try streamedSelection(context, directory: preparation.directory)
        let wire = try XCTUnwrap(saved.selection.objectPayloadFile), original = try wire.materialized()
        try await q.prepareSelection(saved, captured: context)
        try await q.finishBinaryPreparation(preparation, captured: context)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparation.directory.path))
        let restored = try await q.preparedSelection(saved.id, captured: context)
        XCTAssertEqual(restored.selection.version, 3)
        XCTAssertEqual(try restored.selection.objectPayloadFile?.materialized(), original)
        XCTAssertEqual(restored.selection.objectPayloadFile?.url.deletingLastPathComponent(), layout.uploadDirectory)
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        defer { journal.close() }
        try journal.loadSelections(owner: context.scope)
        let jobs = try journal.load()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(journal.selectionIndex[saved.id]?.wireFile, wire.name)
        let job = try XCTUnwrap(jobs.values.first)
        XCTAssertFalse(job.acknowledged)
        XCTAssertNotEqual(job.phase, .receiptSaved)
        XCTAssertEqual(try Data(contentsOf: journal.bodyURL(job)), original)
        XCTAssertEqual(try journal.selection(saved.id)?.selection.objectPayloadFile?.materialized(), original)
        let manifest = try XCTUnwrap(journal.metadata.read(saved.id + ".selection"))
        XCTAssertLessThan(manifest.count, 16 * 1024)
        XCTAssertFalse(String(decoding: manifest, as: UTF8.self).contains(preparation.directory.path))
        XCTAssertEqual(try journal.metadata.names(kind: "packing"), [])
        XCTAssertEqual(try journal.metadata.names(kind: "wireintent"), [])
    }

    func testStreamedPublicationSurvivesPostCommitFailureAndNeverLosesSourceMembership() throws {
        let (_, context, layout) = try fixture()
        let fault = UploadJournalFault()
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, maximumBytes: 32 * 1_048_576,
            afterWrite: { url in if url.pathExtension == "selection", fault.take() { throw CloudUploadError.storageFull } },
            resourceBudget: resourceBudget)
        try journal.loadSelections(owner: context.scope)
        let preparation = try journal.beginBinaryPreparation(maximumWireBytes: 4 * 1_048_576)
        let saved = try streamedSelection(context, directory: preparation.directory)
        fault.arm()
        XCTAssertThrowsError(try journal.reserve(saved, legacyJobs: 0))
        try journal.finishBinaryPreparation(preparation)
        journal.close()
        let cold = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        defer { cold.close() }
        try cold.loadSelections(owner: context.scope)
        let restored = try XCTUnwrap(cold.selection(saved.id))
        XCTAssertEqual(restored.commit.rawBatchIDs, ["synthetic-file-archive"])
        XCTAssertEqual(restored.selection.objectPayloadFile?.sha256, saved.selection.objectPayloadFile?.sha256)
        XCTAssertFalse(try XCTUnwrap(cold.continuations[saved.id]).sourceCommitted)
        XCTAssertThrowsError(try cold.retireSelection(saved.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(restored.selection.objectPayloadFile).url.path))
    }

    func testUnpublishedStreamLeaseRecoversOnlyOwnedScratchAndRejectsOtherAccountRoot() throws {
        let (_, context, layout) = try fixture(), (_, _, otherLayout) = try fixture()
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        defer { journal.close() }
        try journal.loadSelections(owner: context.scope)
        let other = try CloudUploadJournal(directory: otherLayout.uploadDirectory, resourceBudget: resourceBudget)
        defer { other.close() }
        try other.loadSelections(owner: context.scope)
        let foreign = try other.beginBinaryPreparation(maximumWireBytes: 4 * 1_048_576)
        let saved = try streamedSelection(context, directory: foreign.directory)
        XCTAssertThrowsError(try journal.reserve(saved, legacyJobs: 0))
        XCTAssertNil(try journal.metadata.read(saved.id + ".selection"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(saved.selection.objectPayloadFile).url.path))
        try other.recoverBinaryPreparations()
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreign.directory.path))
        XCTAssertEqual(try other.metadata.names(kind: "packing"), [])
    }

    func testSyntheticLargeBacklogRestorationUsesOnlyOneDecodedLaneAndReportsHostRSS() throws {
        let (_, context, layout) = try fixture()
        let writer = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        var ids: [String] = []
        for ordinal in 0..<32 {
            try autoreleasepool {
                let device = "synthetic-memory-lane-\(ordinal)"
                let key = UUID().uuidString.lowercased()
                let blob = Data(repeating: UInt8(ordinal), count: 512 * 1024)
                let rows: [PushBinaryRow] = [.rawBatch(.init(rowId: 1, batchId: key, capturedAt: 1,
                    deviceClockRef: 1, wallClockRef: 1, startTs: 1, endTs: 1, frameCount: 1,
                    byteSize: Int32(blob.count), framesBlob: blob))]
                let batch = try PushProtocol.binaryObjectBatch(table: .rawBatch, sourceId: W5ReceiptFixture.source,
                    deviceId: device, startCursor: nil, rows: rows, protocolVersion: "1.2")
                let lane = PushObjectLane(endpoint: "/functions/v1/push/objects", maxObjectBytes: 8_000_000,
                    urlTtlSec: 300, streams: [.rawBatch])
                let saved = try CloudPushPreparedSelection(context: context, endpoint: endpoint,
                    receiverStateID: "synthetic-memory-receiver", progressVersion: "1.2",
                    selection: .init(binary: batch, rows: rows, manifest: .init(batch: batch), lane: lane,
                        commit: .init(kind: .binary, table: "rawBatch", deviceID: device,
                            batchIDs: [batch.batchId], cursor: batch.endCursor, rawBatchIDs: [key])), inlineGzip: [])
                try writer.reserve(saved, legacyJobs: 0); ids.append(saved.id)
            }
        }
        let queuedBytes = writer.selectionIndex.values.reduce(0) { $0 + $1.segmentBytes }
        writer.close()
        let baselineRSS = try cloudSyntheticRSS()
        let reader = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        try reader.loadSelections(owner: context.scope)
        let indexRSS = try cloudSyntheticRSS()
        XCTAssertEqual(reader.cachedSelectionCount, 0)
        XCTAssertEqual(reader.selectionIndex.count, 32)
        var peakRSS = indexRSS
        for id in ids {
            try autoreleasepool {
                XCTAssertEqual(try reader.selection(id)?.id, id)
                XCTAssertEqual(reader.cachedSelectionCount, 1)
                peakRSS = max(peakRSS, try cloudSyntheticRSS())
            }
        }
        if let fixtures = ProcessInfo.processInfo.environment["NARA_TEST_FIXTURE_ROOT"] {
            let artifact = URL(fileURLWithPath: fixtures).deletingLastPathComponent()
            let sha = (try? String(contentsOf: artifact.appendingPathComponent("source-head.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "NOT_RECORDED"
            let report: [String: Any] = ["schema_version": 1, "data": "synthetic_only", "source_sha": sha,
                "platform": ProcessInfo.processInfo.operatingSystemVersionString, "selection_count": 32,
                "queued_segment_bytes": queuedBytes, "baseline_rss_bytes": baselineRSS,
                "index_loaded_rss_bytes": indexRSS, "peak_lane_loaded_rss_bytes": peakRSS,
                "maximum_cached_selections": 1, "physical_iphone_gate": "NOT_MEASURED"]
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: artifact.appendingPathComponent("selection-memory.json"))
        }
    }

    func testInterruptedSpoolPublicationAccountsAndRecoversEachRenameBoundary() throws {
        for point in CloudSelectionSpool.PublicationPoint.allCases {
            let (root, context, layout) = try fixture()
                let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
            let selection = try admissionSelection(context)
            let source = root.appendingPathComponent("synthetic-source-evidence")
            let original = try selection.encoded()
            try original.write(to: source)
            let reservation = try journal.quota.reservation(for: selection)
            XCTAssertThrowsError(try CloudSelectionSpool.encode(selection, journal: journal, reservation: reservation) { observed in
                if observed == point { throw CloudUploadError.storageFull }
            })
            XCTAssertGreaterThan(try journal.metadata.fileBytes(selection.id + ".spoolpending"), 0)
            let reopened = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
            try reopened.loadSelections(owner: context.scope)
            XCTAssertNil(try reopened.metadata.read(selection.id + ".spoolintent"))
            XCTAssertEqual(try reopened.metadata.fileBytes(selection.id + ".spoolpending"), 0)
            XCTAssertTrue(reopened.selectionIndex.isEmpty)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: layout.uploadDirectory, includingPropertiesForKeys: nil)
                .contains { ["segment", "spoolpending"].contains($0.pathExtension) })
            try reopened.reserve(selection, legacyJobs: 0)
            XCTAssertEqual(try reopened.selection(selection.id)?.encoded(), original)
            XCTAssertEqual(try reopened.metadata.integrityCheck(), "ok")
        }
    }

    func testLegacyMetadataImportPreservesBytesAndSQLiteAuthorityPreventsResurrection() throws {
        let (_, context, layout) = try fixture()
        try FileManager.default.createDirectory(at: layout.uploadDirectory, withIntermediateDirectories: true)
        let id = AccountScope.digest("legacy-paused-outcome")
        var outcome = CloudControlOutcome(id: id, owner: context.scope)
        outcome.status = 422; outcome.failures = 3; outcome.paused = true; outcome.disposition = .terminal
        let legacy = layout.uploadDirectory.appendingPathComponent(id + ".control")
        let bytes = try JSONEncoder().encode(outcome)
        try bytes.write(to: legacy)
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        XCTAssertEqual(try journal.loadControlOutcomes(owner: context.scope)[id]?.failures, 3)
        XCTAssertEqual(try journal.metadata.integrityCheck(), "ok")
        try journal.removeControlOutcome(id)
        let reopened = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        XCTAssertNil(try reopened.loadControlOutcomes(owner: context.scope)[id])
        XCTAssertEqual(try Data(contentsOf: legacy), bytes, "legacy evidence remains, but cannot revive settled debt")
        let wrong = try AccountScope(projectURL: context.scope.projectURL, userID: "22222222-2222-2222-2222-222222222222")
        try journal.loadSelections(owner: context.scope)
        XCTAssertThrowsError(try reopened.loadSelections(owner: wrong))
    }

    func testMetadataTransactionRollbackRetainsPreviousOutcomeAndAccounting() throws {
        let (_, _, layout) = try fixture()
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        try journal.metadata.put("synthetic.control", data: Data([1]))
        let before = try journal.metadata.accounting()
        XCTAssertThrowsError(try journal.metadata.transaction {
            try journal.metadata.put("synthetic.control", data: Data([2]))
            try journal.metadata.recordFile("synthetic.segment", bytes: 1_000_000)
            throw CloudUploadError.storageFull
        })
        let reopened = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        XCTAssertEqual(try reopened.metadata.read("synthetic.control"), Data([1]))
        XCTAssertEqual(try reopened.metadata.fileBytes("synthetic.segment"), 0)
        XCTAssertEqual(try reopened.metadata.accounting().files, before.files)
        XCTAssertEqual(try reopened.metadata.integrityCheck(), "ok")
    }

    func testLegacySelectionMigratesWithoutChangingIdentityOrAnySavedWireBytes() throws {
        let (_, context, layout) = try fixture()
        try FileManager.default.createDirectory(at: layout.uploadDirectory, withIntermediateDirectories: true)
        let original = try admissionSelection(context)
        let legacy = layout.uploadDirectory.appendingPathComponent(original.id + ".selection")
        let bytes = try original.encoded()
        try bytes.write(to: legacy)
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        try journal.loadSelections(owner: context.scope)
        XCTAssertEqual(journal.cachedSelectionCount, 0)
        let restored = try XCTUnwrap(journal.selection(original.id))
        XCTAssertEqual(try restored.encoded(), bytes)
        XCTAssertEqual(restored.inlineGzip, original.inlineGzip)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        let index = try XCTUnwrap(journal.selectionIndex[original.id])
        try CloudSelectionSpool.verifySegment(layout.uploadDirectory.appendingPathComponent(index.segment), expected: index.segment, bytes: index.segmentBytes)
        let metadata = try XCTUnwrap(journal.metadata.read(original.id + ".selection"))
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains(original.inlineGzip[0].base64EncodedString()))
        XCTAssertEqual(try journal.metadata.integrityCheck(), "ok")
    }

    func testSelectionIndexLoadsNoBodiesAndRetainsAtMostOneDecodedLane() throws {
        let (_, context, layout) = try fixture()
        let writer = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        try writer.loadSelections(owner: context.scope)
        var ids: [String] = []
        for ordinal in 0..<24 {
            let selection = try admissionSelection(context, device: "synthetic-lane-\(ordinal)")
            try writer.reserve(selection, legacyJobs: 0); ids.append(selection.id)
        }
        let reopened = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        try reopened.loadSelections(owner: context.scope)
        XCTAssertEqual(reopened.selectionIndex.count, 24)
        XCTAssertEqual(reopened.cachedSelectionCount, 0)
        for id in ids {
            XCTAssertEqual(try reopened.selection(id)?.id, id)
            XCTAssertEqual(reopened.cachedSelectionCount, 1)
        }
    }

    func testCorruptSpoolIsRetainedAndNeverDecodedAsValidSelection() throws {
        let (_, context, layout) = try fixture()
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        let original = try admissionSelection(context)
        try journal.reserve(original, legacyJobs: 0)
        let index = try XCTUnwrap(journal.selectionIndex[original.id])
        let path = layout.uploadDirectory.appendingPathComponent(index.segment)
        var corrupt = try Data(contentsOf: path); corrupt[0] ^= 1
        try corrupt.write(to: path)
        let reopened = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        try reopened.loadSelections(owner: context.scope)
        XCTAssertThrowsError(try reopened.selection(original.id))
        XCTAssertEqual(try Data(contentsOf: path), corrupt)
        XCTAssertNotNil(try reopened.metadata.read(original.id + ".selection"))
    }

    func testReceiptAuthorizedSpoolRetirementResumesAfterUnlinkFailure() throws {
        let (root, context, layout) = try fixture()
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        let original = try admissionSelection(context)
        try journal.reserve(original, legacyJobs: 0)
        XCTAssertThrowsError(try journal.retireSelection(original.id))
        var state = try XCTUnwrap(journal.continuations[original.id]); state.sourceCommitted = true
        try journal.saveContinuation(state)
        let index = try XCTUnwrap(journal.selectionIndex[original.id])
        let path = layout.uploadDirectory.appendingPathComponent(index.segment)
        let held = root.appendingPathComponent("retained-synthetic-segment")
        try FileManager.default.moveItem(at: path, to: held)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        XCTAssertThrowsError(try journal.retireSelection(original.id))
        XCTAssertNotNil(try journal.metadata.read(original.id + ".retirement"))
        try FileManager.default.removeItem(at: path) // Empty fixture directory, never production recovery.
        try FileManager.default.moveItem(at: held, to: path)
        let reopened = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        try reopened.loadSelections(owner: context.scope)
        XCTAssertTrue(reopened.selectionIndex.isEmpty)
        XCTAssertNil(try reopened.metadata.read(original.id + ".retirement"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testLegacyProgressSharesAccountDatabaseAndDoesNotReimportOldCursor() async throws {
        let (_, _, layout) = try fixture()
        let progressDirectory = layout.uploadDirectory.appendingPathComponent("source-progress")
        try FileManager.default.createDirectory(at: progressDirectory, withIntermediateDirectories: true)
        let namespace = "synthetic-migration-progress"
        let path = CloudPushProgressStore.stateFile(namespace: namespace, directory: progressDirectory)
        let bytes = Data("{\"devices\":[\"legacy-synthetic\"],\"cursors\":{},\"windows\":{},\"objects\":{},\"pending\":{}}".utf8)
        try bytes.write(to: path)
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        let progress = try CloudPushProgressStore(namespace: namespace, directory: progressDirectory)
        let firstDevices = try await progress.knownDeviceIds()
        XCTAssertEqual(firstDevices, ["legacy-synthetic"])
        try await progress.rememberDeviceId("new-synthetic")
        XCTAssertNotNil(try journal.metadata.read(path.lastPathComponent))
        let reopened = try CloudPushProgressStore(namespace: namespace, directory: progressDirectory)
        let restoredDevices = try await reopened.knownDeviceIds()
        XCTAssertEqual(restoredDevices, ["legacy-synthetic", "new-synthetic"])
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: progressDirectory.appendingPathComponent("cloud-metadata.sqlite").path))
    }

    func testFileBodyPersistedBeforeResumeAndResponseReplaysAfterReopen() async throws {
        let (_, context, layout) = try fixture()
        let adapter = UploadAdapter()
        let q = try queue(context, layout, adapter)
        let data = Data("immutable upload bytes".utf8)
        let pending = Task { try await q.request(endpoint: endpoint, body: data, headers: [:], captured: context) }
        try await eventually { adapter.count == 1 }
        let created = try XCTUnwrap(adapter.first)
        XCTAssertEqual(try Data(contentsOf: created.file), data)
        XCTAssertFalse(created.request.allowsCellularAccess)
        XCTAssertNil(created.request.httpBody)
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        let saved = try XCTUnwrap(journal.load().values.first)
        XCTAssertEqual(saved.taskIdentifier, created.task.identifier)
        let correlation = try XCTUnwrap(saved.correlation)
        XCTAssertFalse(String(data: try XCTUnwrap(journal.metadata.read(saved.id + ".json")), encoding: .utf8)!.contains("synthetic-token"))
        await q.receive(created.task, status: 200, body: Data("saved-response".utf8), error: false)
        let completed = try await pending.value
        XCTAssertEqual(completed.body, Data("saved-response".utf8))
        let replacement = AccountSessionContext(scope: context.scope, generation: UUID())
        let secondAdapter = UploadAdapter()
        let reopened = try queue(replacement, layout, secondAdapter)
        let response = try await reopened.request(endpoint: endpoint, body: data, headers: [:], captured: replacement)
        XCTAssertEqual(response.body, Data("saved-response".utf8))
        XCTAssertEqual(secondAdapter.count, 0)
        XCTAssertEqual(try Data(contentsOf: created.file), data)
        XCTAssertEqual(try journal.load()[saved.id]?.correlation, correlation, "relaunch must not invent a new job correlation")
    }

    func testRelaunchAdoptsTaskDescriptionAcrossTaskIDCommitCrashWithoutDuplicate() async throws {
        let (_, context, layout) = try fixture()
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        var job = CloudUploadJob(id: AccountScope.digest("crash"), owner: context.scope, generation: UUID(),
            endpoint: endpoint, deviceID: "", createdAt: Date(), operation: .request, method: "POST", headers: [:])
        try journal.persistBody(Data([1, 2, 3]), job: &job)
        job.phase = .transferring; job.attempt = UUID()
        job.allowsCellular = false; job.allowsConstrained = false
        try journal.save(job)
        let adapter = UploadAdapter()
        adapter.seed(.init(identifier: 42, description: job.taskDescription))
        let q = try queue(context, layout, adapter)
        try await q.reconcile()
        XCTAssertEqual(adapter.count, 0)
        XCTAssertEqual(try journal.load()[job.id]?.taskIdentifier, 42)
        XCTAssertEqual(try journal.load()[job.id]?.generation, context.generation)
        await q.receive(.init(identifier: 42, description: job.taskDescription), status: 200, body: Data([9]), error: false)
        XCTAssertEqual(try journal.load()[job.id]?.phase, .responseSaved)
    }

    func testMissingTaskRetriesSameBytesAndCancelsUnknownTask() async throws {
        let (_, context, layout) = try fixture()
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        var job = CloudUploadJob(id: AccountScope.digest("missing"), owner: context.scope, generation: context.generation,
            endpoint: endpoint, deviceID: "", createdAt: Date(), operation: .request, method: "POST", headers: [:])
        let body = Data([3, 4, 5])
        try journal.persistBody(body, job: &job)
        job.phase = .transferring; job.attempt = UUID(); job.taskIdentifier = 70
        try journal.save(job)
        let adapter = UploadAdapter(); adapter.seed(.init(identifier: 77, description: "unassigned"))
        let q = try queue(context, layout, adapter)
        try await q.reconcile()
        XCTAssertEqual(adapter.count, 1)
        XCTAssertEqual(adapter.cancelled, [77])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(adapter.first).file), body)
    }

    func testLogoutFencesLateCallbackAndUnassignedLayoutIsRejected() async throws {
        let (root, context, layout) = try fixture()
        let fence = UploadFence()
        let adapter = UploadAdapter()
        let q = try queue(context, layout, adapter, current: { _ in fence.current })
        let pending = Task { try await q.request(endpoint: endpoint, body: Data([4]), headers: [:], captured: context) }
        try await eventually { adapter.count == 1 }
        let task = try XCTUnwrap(adapter.first).task
        fence.revoke()
        await q.suspend()
        await q.receive(task, status: 200, body: Data([1]), error: false)
        do { _ = try await pending.value; XCTFail("stale operation accepted") } catch { XCTAssertEqual(error as? CloudUploadError, .staleOwner) }
        let saved = try XCTUnwrap(CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget).load().values.first)
        XCTAssertNil(saved.responseBody)
        XCTAssertThrowsError(try queue(context, .init(baseDirectory: root, scope: nil), UploadAdapter()))
        let other = try AccountScope(projectURL: context.scope.projectURL, userID: "22222222-2222-2222-2222-222222222222")
        XCTAssertThrowsError(try queue(.init(scope: other, generation: UUID()), layout, UploadAdapter()))
    }

    func testImmutableBodiesLowDiskAndCorruptionFailClosed() throws {
        let (_, context, layout) = try fixture()
        let baseline = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, maximumBytes: baseline.storageAccounting().used + 4, resourceBudget: resourceBudget)
        var job = CloudUploadJob(id: AccountScope.digest("body"), owner: context.scope, generation: context.generation,
            endpoint: endpoint, deviceID: "", createdAt: Date(), operation: .request, method: "POST", headers: [:])
        XCTAssertThrowsError(try journal.persistBody(Data(repeating: 1, count: 5), job: &job))
        try journal.persistBody(Data([1, 2]), job: &job)
        XCTAssertThrowsError(try journal.persistBody(Data([1, 3]), job: &job))
        XCTAssertEqual(try Data(contentsOf: journal.bodyURL(job)), Data([1, 2]))
        try Data([4, 5]).write(to: journal.bodyURL(job)) // Controlled corruption, never app data.
        XCTAssertThrowsError(try journal.verifyBody(job))
    }

    func testCriticalThermalDefersWithoutCreatingTask() async throws {
        let (_, context, layout) = try fixture()
        let adapter = UploadAdapter()
        let q = try queue(context, layout, adapter, limit: 0)
        do { _ = try await q.request(endpoint: endpoint, body: Data([1]), headers: [:], captured: context); XCTFail() }
        catch { XCTAssertEqual(error as? CloudUploadError, .retryScheduled) }
        XCTAssertEqual(adapter.count, 0)
        XCTAssertEqual(try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget).load().count, 1)
    }

    func testInjectedResourcePressureStillDefersWithAnAdmittingNetworkPolicy() async throws {
        let (root, context, layout) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = ResourceBudget(thermal: { ProcessInfo.ThermalState.critical.rawValue }, lowPower: { false })
        let adapter = UploadAdapter()
        let q = try CloudUploadQueue(context: context, layout: layout,
            adapter: adapter, authorize: { _ in XCTFail("Pressure must block before authorization"); return "unused" },
            isCurrent: { _ in true },
            policy: { .init(concurrency: 1, allowsCellular: false, allowsConstrained: false) },
            control: { _ in XCTFail("Pressure must block control requests"); throw CloudUploadError.unavailable }, resourceBudget: budget)
        do {
            _ = try await q.request(endpoint: endpoint, body: Data([3, 5, 7]), headers: [:], captured: context)
            XCTFail("Resource pressure was ignored")
        } catch { XCTAssertEqual(error as? CloudUploadError, .retryScheduled) }
        XCTAssertEqual(adapter.count, 0)
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory)
        let saved = try XCTUnwrap(journal.load().values.first)
        XCTAssertEqual(try Data(contentsOf: journal.bodyURL(saved)), Data([3, 5, 7]))
        XCTAssertFalse(saved.acknowledged)
        XCTAssertNil(saved.validatedReceipt)
    }

    func testDisabledPushRetainsQueueAndReceiptsWithoutAuthorizationOrTasks() async throws {
        try await verifyDeniedAdmission(enabled: false, termsAccepted: true)
    }

    func testMissingTermsRetainsQueueAndReceiptsWithoutAuthorizationOrTasks() async throws {
        try await verifyDeniedAdmission(enabled: true, termsAccepted: false)
    }

    private func verifyDeniedAdmission(enabled: Bool, termsAccepted: Bool) async throws {
        let (_, context, layout) = try fixture()
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        let receipt = try requestReceipt()
        let completed = try receivedJob(context, layout, receipt: receipt)
        var object = try objectJob(context, layout)
        object.signedExpiry = .distantPast
        object.needsNewIntent = true
        try journal.save(object)
        let adapter = UploadAdapter()
        let q = try CloudUploadQueue(context: context, layout: layout, adapter: adapter,
            authorize: { _ in XCTFail("denied admission must not request credentials"); throw CloudUploadError.unavailable },
            isCurrent: { _ in true },
            policy: { [resourceBudget] in .current(wifiOnly: false, enabled: enabled && termsAccepted, resourceBudget: resourceBudget) },
            control: { _ in XCTFail("denied admission must not renew an intent"); throw CloudUploadError.unavailable }, resourceBudget: resourceBudget)
        try await q.reconcile()
        do {
            _ = try await q.request(endpoint: endpoint, body: Data([5, 7]), headers: [:], captured: context)
            XCTFail("denied admission scheduled a request")
        } catch { XCTAssertEqual(error as? CloudUploadError, .retryScheduled) }
        let reopened = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        let jobs = try reopened.load()
        XCTAssertEqual(jobs.count, 3)
        XCTAssertEqual(jobs[completed.id]?.responseBody, receipt)
        XCTAssertEqual(jobs[completed.id]?.acknowledged, false)
        XCTAssertEqual(try Data(contentsOf: reopened.bodyURL(completed)), Data([8, 6, 4, 2]))
        XCTAssertEqual(try Data(contentsOf: reopened.bodyURL(object)), Data([2, 4, 6]))
        let pending = try XCTUnwrap(jobs.values.first { $0.id != completed.id && $0.id != object.id })
        XCTAssertEqual(try Data(contentsOf: reopened.bodyURL(pending)), Data([5, 7]))
        XCTAssertTrue(jobs.values.allSatisfy { $0.taskIdentifier == nil })
        XCTAssertEqual(adapter.count, 0)
        XCTAssertTrue(adapter.resumed.isEmpty)
    }

    func testDisabledPushAndMissingTermsCancelRestoredTasksButRetainBytesAndReceipt() async throws {
        for (enabled, termsAccepted) in [(false, true), (true, false)] {
            let (_, context, layout) = try fixture()
                let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
            let receipt = try requestReceipt()
            let completed = try receivedJob(context, layout, receipt: receipt)
            var object = try objectJob(context, layout)
            object.phase = .transferring; object.attempt = UUID(); object.taskIdentifier = 42
            object.allowsCellular = false; object.allowsConstrained = false
            try journal.save(object)
            let task = CloudUploadTaskSnapshot(identifier: 42, description: object.taskDescription)
            let adapter = UploadAdapter()
            adapter.seed(task)
            let policy = UploadPolicyBox()
            let q = try CloudUploadQueue(context: context, layout: layout, adapter: adapter,
                authorize: { _ in XCTFail("disabled queue requested credentials"); throw CloudUploadError.unavailable },
                isCurrent: { _ in true }, policy: { policy.value },
                control: { _ in XCTFail("disabled queue renewed an intent"); throw CloudUploadError.unavailable }, resourceBudget: resourceBudget)
            try await q.reconcile()
            XCTAssertEqual(adapter.resumed, [42])
            policy.setConsent(enabled: enabled, termsAccepted: termsAccepted)
            try await q.reconcile()
            XCTAssertEqual(adapter.cancelled, [42])
            XCTAssertEqual(adapter.resumed, [42])
            XCTAssertEqual(adapter.count, 0)
            await q.receive(task, status: 200, body: Data("late-cancelled-result".utf8), error: false)
            let saved = try journal.load()
            XCTAssertEqual(saved[object.id]?.phase, .retryPending)
            XCTAssertNil(saved[object.id]?.taskIdentifier)
            XCTAssertNil(saved[object.id]?.responseBody)
            XCTAssertEqual(saved[completed.id]?.responseBody, receipt)
            XCTAssertEqual(try Data(contentsOf: journal.bodyURL(object)), Data([2, 4, 6]))
            XCTAssertEqual(try Data(contentsOf: journal.bodyURL(completed)), Data([8, 6, 4, 2]))
            XCTAssertEqual(adapter.count, 0)
        }
    }

    func testConsentRevocationDuringAuthorizationCancelsExistingTaskWithoutAnotherWake() async throws {
        let (_, context, layout) = try fixture()
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        var object = try objectJob(context, layout)
        object.phase = .transferring; object.attempt = UUID(); object.taskIdentifier = 42
        object.allowsCellular = false; object.allowsConstrained = false
        try journal.save(object)
        let adapter = UploadAdapter()
        adapter.seed(.init(identifier: 42, description: object.taskDescription))
        let policy = UploadPolicyBox(limit: 2)
        let entered = expectation(description: "authorization suspended")
        let gate = UploadAuthorizationGate()
        defer { Task { await gate.release() } }
        let q = try CloudUploadQueue(context: context, layout: layout, adapter: adapter,
            authorize: { _ in entered.fulfill(); return await gate.token() },
            isCurrent: { _ in true }, policy: { policy.value },
            control: { _ in XCTFail("no intent renewal expected"); throw CloudUploadError.unavailable }, resourceBudget: resourceBudget)
        try await q.reconcile()
        let pending = Task { try await q.request(endpoint: endpoint, body: Data([9, 7, 5]), headers: [:], captured: context) }
        defer { pending.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        policy.setConsent(enabled: true, termsAccepted: false)
        try await q.reconcile()
        XCTAssertTrue(adapter.cancelled.contains(42), "revocation cannot wait for a credential refresh to finish")
        await gate.release()
        do { _ = try await pending.value; XCTFail("revoked admission created a task") }
        catch { XCTAssertEqual(error as? CloudUploadError, .retryScheduled) }
        try await eventually { adapter.cancelled.contains(42) }
        XCTAssertEqual(adapter.count, 0)
        XCTAssertEqual(try Data(contentsOf: journal.bodyURL(object)), Data([2, 4, 6]))
        let saved = try journal.load()
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(saved.values.allSatisfy { $0.responseBody == nil && !$0.acknowledged })
    }

    func testConsentRevocationDuringIntentAuthorizationDoesNotRenewOrUpload() async throws {
        let (_, context, layout) = try fixture()
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        var object = try objectJob(context, layout)
        object.needsNewIntent = true
        object.signedExpiry = .distantPast
        try journal.save(object)
        let adapter = UploadAdapter()
        let policy = UploadPolicyBox()
        let entered = expectation(description: "intent authorization suspended")
        let gate = UploadAuthorizationGate()
        defer { Task { await gate.release() } }
        let q = try CloudUploadQueue(context: context, layout: layout, adapter: adapter,
            authorize: { _ in entered.fulfill(); return await gate.token() },
            isCurrent: { _ in true }, policy: { policy.value },
            control: { _ in XCTFail("consent was revoked before intent renewal"); throw CloudUploadError.unavailable }, resourceBudget: resourceBudget)
        let reconciliation = Task { try await q.reconcile() }
        defer { reconciliation.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        policy.setConsent(enabled: false, termsAccepted: true)
        try await q.reconcile()
        await gate.release()
        try await reconciliation.value
        let saved = try XCTUnwrap(journal.load()[object.id])
        XCTAssertEqual(saved.phase, .prepared)
        XCTAssertEqual(saved.failures, 0, "admission denial is not a failed HTTP attempt")
        XCTAssertNil(saved.nextAttemptAt)
        XCTAssertEqual(saved.objectID, object.objectID)
        XCTAssertEqual(saved.objectKey, object.objectKey)
        XCTAssertEqual(saved.payloadSHA256, object.payloadSHA256)
        XCTAssertTrue(saved.needsNewIntent)
        XCTAssertNil(saved.taskIdentifier)
        XCTAssertEqual(try Data(contentsOf: journal.bodyURL(saved)), Data([2, 4, 6]))
        XCTAssertEqual(adapter.count, 0)
        XCTAssertTrue(adapter.resumed.isEmpty)
    }

    private func objectJob(_ context: AccountSessionContext, _ layout: AccountStorageLayout) throws -> CloudUploadJob {
        let objectID = "33333333-3333-3333-3333-333333333333"
        var job = CloudUploadJob(id: CloudUploadQueue.objectJobID(endpoint: endpoint, objectID: objectID),
            owner: context.scope, generation: context.generation, endpoint: endpoint, deviceID: "", createdAt: Date(),
            operation: .objectPut, method: "PUT", headers: [:])
        job.objectID = objectID
        job.objectKey = W5ReceiptFixture.objectKey(owner: context.scope.userID,
                                                  device: "synthetic-device", stream: "rawBatch")
        job.manifest = try W5ReceiptFixture.bytes(["protocolVersion": "1.2", "objectId": objectID,
            "batchId": objectID, "sourceId": W5ReceiptFixture.source, "deviceId": "synthetic-device",
            "stream": "rawBatch", "startTs": 1, "endTs": 1, "sampleCount": 1,
            "uncompressedBytes": 3, "compressedBytes": 3,
            "contentSha256": PushDurabilityReceipt.sha256(Data([2, 4, 6])), "contentEncoding": "zstd"])
        job.lanePath = "/functions/v1/push/objects"
        job.signedURL = "https://bucket.example/signed"
        job.signedHeaders = ["content-type": "application/octet-stream"]
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        try journal.persistBody(Data([2, 4, 6]), job: &job)
        try journal.save(job)
        return job
    }

    private func receipt(_ job: CloudUploadJob, key: String? = nil, status: String = "verified") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "objectAck", "protocolVersion": PushProtocol.objectVersion,
            "objectId": job.objectID!, "objectKey": key ?? job.objectKey!, "status": status, "duplicate": false,
            "durabilityReceipt": W5ReceiptFixture.receipt(owner: job.owner.userID, device: "synthetic-device",
                object: job.objectID!, batch: job.objectID!, source: W5ReceiptFixture.source, stream: "rawBatch",
                decoded: PushDurabilityReceipt.sha256(Data([2, 4, 6])), wire: job.payloadSHA256!,
                decodedBytes: 3, wireBytes: 3, key: job.objectKey!)])
    }

    func testIntentCapturesCompletionModeOnceAndLaterCapabilitiesCannotChangeIt() async throws {
        let (_, context, layout) = try fixture()
        let adapter = UploadAdapter(), q = try queue(context, layout, adapter)
        let rows: [PushBinaryRow] = [.ppgWaveform(.init(rowId: 1, ts: 100, burstIndex: nil, samples: Data([1])))]
        let batch = try PushProtocol.binaryObjectBatch(table: .ppgWaveformSample, sourceId: W5ReceiptFixture.source,
            deviceId: "synthetic", startCursor: nil, rows: rows, protocolVersion: "1.2")
        let manifest = PushObjectManifest(batch: batch)
        let intent = PushObjectIntent(objectId: batch.objectId, objectKey: "staging/synthetic",
            uploadUrl: "https://bucket.example/synthetic", requiredHeaders: [:], expiresAt: nil, duplicate: false)
        let asynchronous = PushObjectLane(endpoint: "/functions/v1/push/objects", maxObjectBytes: 8_000_000,
            urlTtlSec: nil, streams: [.ppgWaveformSample], completionMode: .asynchronousV1)
        try await q.recordIntent(manifest, lane: asynchronous, intent: intent, endpoint: endpoint, captured: context)
        let synchronous = PushObjectLane(endpoint: asynchronous.endpoint, maxObjectBytes: asynchronous.maxObjectBytes,
            urlTtlSec: nil, streams: asynchronous.streams)
        try await q.recordIntent(manifest, lane: synchronous, intent: intent, endpoint: endpoint, captured: context)
        let saved = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget).load()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.values.first?.completionMode, .asynchronousV1)
        XCTAssertEqual(saved.values.first?.manifest, try manifest.encode())
        XCTAssertEqual(adapter.count, 0)
        await q.suspend()
    }

    func testCapturedAsyncCompletionModeSurvivesRetryAndNeverAppearsOnPUT() async throws {
        for mode: PushObjectCompletionMode? in [nil, .asynchronousV1] {
            let (_, context, layout) = try fixture()
            var job = try objectJob(context, layout)
            job.completionMode = mode
            let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
            try journal.save(job)
            let adapter = UploadAdapter()
            let q = try queue(context, layout, adapter)
            try await q.reconcile()
            let put = try XCTUnwrap(adapter.first)
            XCTAssertNil(put.request.value(forHTTPHeaderField: "Noop-Push-Completion"))
            await q.receive(put.task, status: 200, body: Data(), error: false)
            let completion = try XCTUnwrap(adapter.last)
            XCTAssertEqual(completion.request.value(forHTTPHeaderField: "Noop-Push-Completion"), mode?.rawValue)
            let pending = try JSONSerialization.data(withJSONObject: ["type": "error", "protocolVersion": "1.2", "code": "verification_pending", "objectId": job.objectID!, "state": "pending_verification"])
            await q.receive(completion.task, status: 503, body: pending, error: false, retryAfter: "120")
            await q.receive(completion.task, status: 503, body: pending, error: false, retryAfter: "120")
            let saved = try XCTUnwrap(journal.load()[job.id])
            XCTAssertEqual(saved.completionMode, mode)
            XCTAssertEqual(saved.failures, 1)
            XCTAssertEqual(saved.responseCode, "verification_pending")
            XCTAssertEqual(saved.responseRetryAfter, "120")
            XCTAssertEqual(saved.phase, .retryPending)
            XCTAssertNil(saved.validatedReceipt); XCTAssertFalse(saved.acknowledged)
            XCTAssertNotNil(saved.nextAttemptAt)
            await q.suspend()
            let reopenedAdapter = UploadAdapter()
            let reopened = try queue(context, layout, reopenedAdapter)
            try await reopened.reconcile()
            XCTAssertEqual(reopenedAdapter.count, 0, "Retry-After must survive relaunch")
            XCTAssertEqual(try journal.load()[job.id]?.completionMode, mode)
            XCTAssertEqual(try Data(contentsOf: journal.bodyURL(saved)), Data([2, 4, 6]))
            await reopened.suspend()
        }
    }

    func testObjectPUTAndReceiverReceiptAreSeparateDurableSteps() async throws {
        let (_, context, layout) = try fixture()
        let job = try objectJob(context, layout)
        let adapter = UploadAdapter()
        let q = try queue(context, layout, adapter)
        try await q.reconcile()
        let put = try XCTUnwrap(adapter.first)
        XCTAssertEqual(put.request.httpMethod, "PUT")
        XCTAssertNil(put.request.value(forHTTPHeaderField: "Authorization"))
        await q.receive(put.task, status: 200, body: Data(), error: false)
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        var persisted = try XCTUnwrap(journal.load()[job.id])
        XCTAssertEqual(persisted.correlation, UUID(uuidString: job.objectID!))
        XCTAssertEqual(persisted.operation, .objectComplete)
        XCTAssertNotEqual(persisted.phase, .receiptSaved)
        let afterPUT = try await q.lastVerifiedReceiptDate(captured: context)
        XCTAssertNil(afterPUT, "HTTP PUT success is not a verified cloud receipt")
        let pendingPresentation = try await q.presentationStatus(captured: context)
        XCTAssertEqual(pendingPresentation.pendingJobs, 1)
        XCTAssertNil(pendingPresentation.lastVerifiedReceipt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: put.file.path))
        let completion = try XCTUnwrap(adapter.last)
        XCTAssertEqual(completion.request.httpMethod, "POST")
        XCTAssertTrue(completion.request.url!.path.hasSuffix("/\(job.objectID!)/complete"))
        XCTAssertEqual(try Data(contentsOf: completion.file), Data())
        await q.receive(completion.task, status: 200, body: try receipt(job), error: false)
        persisted = try XCTUnwrap(journal.load()[job.id])
        XCTAssertEqual(persisted.phase, .receiptSaved)
        XCTAssertEqual(persisted.correlation, UUID(uuidString: job.objectID!))
        let reopenedAdapter = UploadAdapter()
        let reopened = try queue(context, layout, reopenedAdapter)
        let ack = try await reopened.completeObject(endpoint: endpoint, objectID: job.objectID!, captured: context)
        XCTAssertEqual(ack.objectKey, job.objectKey)
        let verifiedDate = try await reopened.lastVerifiedReceiptDate(captured: context)
        XCTAssertEqual(verifiedDate, ack.durabilityReceipt.flatMap { PushDurabilityReceipt.date($0.indexedAt) })
        let verifiedPresentation = try await reopened.presentationStatus(captured: context)
        XCTAssertEqual(verifiedPresentation.lastVerifiedReceipt, verifiedDate)
        XCTAssertEqual(verifiedPresentation.pendingJobs, 1, "receipt is saved but source cleanup is still owed")
        XCTAssertEqual(verifiedPresentation.transferringJobs, 0)
        do {
            _ = try await reopened.presentationStatus(captured: .init(scope: context.scope, generation: UUID()))
            XCTFail("presentation crossed account generation")
        } catch { XCTAssertEqual(error as? CloudUploadError, .staleOwner) }
        XCTAssertEqual(reopenedAdapter.count, 0)
        XCTAssertEqual(try Data(contentsOf: put.file), Data([2, 4, 6]))
        XCTAssertEqual(try journal.load()[job.id]?.correlation, UUID(uuidString: job.objectID!))
    }

    func testCrashAfterSavedCompletionRecoversReceiptWithoutNetwork() async throws {
        let (_, context, layout) = try fixture()
        var job = try objectJob(context, layout)
        job.operation = .objectComplete; job.phase = .responseSaved
        job.responseStatus = 200; job.responseBody = try receipt(job)
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        try journal.save(job)
        let adapter = UploadAdapter()
        let q = try queue(context, layout, adapter)
        try await q.reconcile()
        XCTAssertEqual(try journal.load()[job.id]?.phase, .receiptSaved)
        XCTAssertEqual(adapter.count, 0)
        _ = try await q.completeObject(endpoint: endpoint, objectID: job.objectID!, captured: context)
    }

    func testWrongObjectKeyNeverCreatesReceiptOrDeletesBody() async throws {
        let (_, context, layout) = try fixture()
        var job = try objectJob(context, layout)
        job.operation = .objectComplete; job.phase = .uploaded
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        try journal.save(job)
        let adapter = UploadAdapter()
        let q = try queue(context, layout, adapter)
        try await q.reconcile()
        await q.receive(try XCTUnwrap(adapter.first).task, status: 200, body: try receipt(job, key: "another/key"), error: false)
        XCTAssertEqual(try journal.load()[job.id]?.phase, .pausedTerminal)
        XCTAssertNotNil(try journal.load()[job.id]?.responseBody)
        XCTAssertEqual(try Data(contentsOf: journal.bodyURL(job)), Data([2, 4, 6]))
    }

    func testExpiryRenewalPreservesObjectKeyIDAndFile() async throws {
        let (_, context, layout) = try fixture()
        var job = try objectJob(context, layout)
        job.signedExpiry = Date(timeIntervalSince1970: 0)
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        try journal.save(job)
        let original = job
        let reply = try JSONSerialization.data(withJSONObject: ["type": "objectIntent", "protocolVersion": PushProtocol.objectVersion,
            "objectId": job.objectID!, "objectKey": job.objectKey!, "duplicate": false,
            "uploadUrl": "https://bucket.example/refreshed", "requiredHeaders": ["content-type": "application/octet-stream"]])
        let adapter = UploadAdapter()
        let q = try CloudUploadQueue(context: context, layout: layout, adapter: adapter, authorize: { _ in "test" },
            isCurrent: { _ in true }, policy: { .init(concurrency: 1, allowsCellular: true, allowsConstrained: false) },
            control: { request in
                XCTAssertEqual(request.httpBody, original.manifest)
                return .init(statusCode: 200, body: reply)
            }, resourceBudget: resourceBudget)
        try await q.reconcile()
        let created = try XCTUnwrap(adapter.first)
        XCTAssertEqual(created.request.url?.absoluteString, "https://bucket.example/refreshed")
        XCTAssertEqual(created.file, try journal.bodyURL(original))
        XCTAssertEqual(try journal.load()[job.id]?.objectID, original.objectID)
        XCTAssertEqual(try journal.load()[job.id]?.objectKey, original.objectKey)
        XCTAssertEqual(try journal.load()[job.id]?.payloadSHA256, original.payloadSHA256)
        await q.receive(created.task, status: 403, body: Data(), error: false)
        XCTAssertEqual(try journal.load()[job.id]?.needsNewIntent, true)
        XCTAssertEqual(try journal.load()[job.id]?.signedURLRenewalCount, 1)
        XCTAssertEqual(try journal.load()[job.id]?.authenticationRefreshCount ?? 0, 0,
            "an expired storage URL must not consume the receiver credential refresh allowance")
        XCTAssertEqual(try journal.load()[job.id]?.phase, .retryPending)
    }

    func testCancellationDetachesWaiterButKeepsTransferAndConcurrencyIsCapped() async throws {
        let (_, context, layout) = try fixture()
        let adapter = UploadAdapter()
        let q = try queue(context, layout, adapter, limit: 100)
        let tasks = (0..<3).map { n in Task { try await q.request(endpoint: endpoint, body: Data([UInt8(n)]), headers: [:], captured: context) } }
        try await eventually { adapter.count == 2 }
        for task in tasks { task.cancel() }
        for task in tasks { do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) } }
        XCTAssertEqual(adapter.cancelled, [])
        XCTAssertEqual(try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget).load().count, 3)
        XCTAssertEqual(adapter.count, 2)
    }

    func testRefreshExpirationAndBackgroundEventCompletionAreExactlyOnce() async {
        let refresh = expectation(description: "refresh completion")
        refresh.assertForOverFulfill = true
        let once = CloudPushRefreshCompletion { success in XCTAssertFalse(success); refresh.fulfill() }
        once.finish(success: false); once.finish(success: true)
        let event = expectation(description: "background events completion")
        event.assertForOverFulfill = true
        let delivery = CloudUploadEventCompletion()
        delivery.finish() // An unrelated prior event cycle must not release the next handler.
        delivery.store { XCTAssertTrue(Thread.isMainThread); event.fulfill() }
        delivery.finish(); delivery.finish()
        await fulfillment(of: [refresh, event], timeout: 1)
    }

    func testRealFileUploadTaskUsingControlledURLProtocol() async throws {
        let (_, context, layout) = try fixture()
        let job = try objectJob(context, layout)
        let file = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget).bodyURL(job)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadURLProtocol.self]
        let adapter = CloudUploadURLSession(identifier: "w5-test", configuration: config)
        defer { adapter.invalidate() }
        let completed = expectation(description: "file upload callback")
        let listener = Task {
            for await event in adapter.events {
                if case let .completed(task, status, body, error, _) = event {
                    XCTAssertEqual(task.description, "controlled-file")
                    XCTAssertEqual(status, 200); XCTAssertFalse(error)
                    XCTAssertEqual(body, Data("controlled-receipt".utf8))
                    completed.fulfill(); break
                }
            }
        }
        defer { listener.cancel() }
        var request = URLRequest(url: URL(string: "https://w5.invalid/test")!)
        request.httpMethod = "PUT"
        let task = adapter.create(request: request, file: file, description: "controlled-file")
        adapter.resume(task.identifier)
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(try Data(contentsOf: file), Data([2, 4, 6]))
    }

    func testRuntimeControlPlaneHonorsInjectedSessionAndPersistsTypedResponse() async throws {
        let (_, context, layout) = try fixture()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeControlURLProtocol.self]
        let runtime = try CloudPushBackgroundRuntime(context: context, layout: layout,
            authorize: { _ in "synthetic-token" }, isCurrent: { _ in true },
            policy: { .init(concurrency: 1, allowsCellular: false, allowsConstrained: false) },
            sessionConfiguration: configuration, resourceBudget: resourceBudget)
        do { _ = try await runtime.queue.capabilities(endpoint: endpoint, captured: context) } catch {}
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        let outcome = try XCTUnwrap(journal.loadControlOutcomes(owner: context.scope).values.first)
        XCTAssertEqual(outcome.status, 200)
        XCTAssertTrue(outcome.paused)
        XCTAssertEqual(outcome.receiverCode, "response_invalid")
        await runtime.retire()
    }

    func testRuntimeRetirementPreventsDuplicateSessionAndAllowsSameOwnerRelogin() async throws {
        let (_, context, layout) = try fixture()
        func make(_ captured: AccountSessionContext) throws -> CloudPushBackgroundRuntime {
            try CloudPushBackgroundRuntime(context: captured, layout: layout, authorize: { _ in "unused-test" },
                isCurrent: { _ in true }, policy: { .init(concurrency: 1, allowsCellular: false, allowsConstrained: false) },
                sessionConfiguration: .ephemeral, resourceBudget: resourceBudget)
        }
        let initial = try make(context)
        XCTAssertThrowsError(try make(.init(scope: context.scope, generation: UUID())))
        await initial.retire()
        XCTAssertFalse(initial.handleEvents(identifier: initial.identifier, completionHandler: { XCTFail() }))
        let replacement = try make(.init(scope: context.scope, generation: UUID()))
        XCTAssertEqual(initial.identifier, replacement.identifier)
        await replacement.retire()
    }

    func testOwnerlessDrainFinishesWithoutCredentialsAndDoesNotOpenAccountFiles() async throws {
        let (root, context, _) = try fixture()
        let complete = expectation(description: "ownerless delegate drain")
        complete.assertForOverFulfill = true
        XCTAssertTrue(CloudPushBackgroundRuntime.drainEvents(identifier: CloudPushBackgroundRuntime.sessionIdentifier(scope: context.scope),
            completionHandler: { XCTAssertTrue(Thread.isMainThread); complete.fulfill() }, sessionConfiguration: .ephemeral))
        await fulfillment(of: [complete], timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(CloudPushBackgroundRuntime.drainEvents(identifier: "other.owner.session", completionHandler: { XCTFail() }))
    }

    func testCloudPushTransportActuallyUsesScopedFileBackedRuntime() async throws {
        let (_, context, layout) = try fixture()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TransportURLProtocol.self]
        let runtime = try CloudPushBackgroundRuntime(context: context, layout: layout, authorize: { _ in "synthetic-token" },
            isCurrent: { _ in true }, policy: { .init(concurrency: 1, allowsCellular: false, allowsConstrained: false) },
            sessionConfiguration: config, resourceBudget: resourceBudget)
        CloudPushBackgroundRuntime.install(runtime)
        let batch = try PushProtocol.appendBatch(table: .hrSample, sourceId: "44444444-4444-4444-4444-444444444444",
            deviceId: "synthetic-device", startCursor: nil,
            records: [.init(rowId: 1, key: ["ts": .int(100)], data: ["bpm": .int(60)])])
        let transport = CloudPushTransport(endpoint: .init(url: endpoint, host: "project.example"),
            bearerToken: "not-used-for-background-body", context: context)
        try transport.bindReceiverState("synthetic-receiver")
        do { _ = try await transport.post(batch); XCTFail("bare HTTP success is not an ACK") }
        catch let error as PushTransportException {
            XCTAssertEqual(error.failure.code, .ackInvalid)
            XCTAssertFalse(error.failure.retryable)
        } catch { XCTFail("invalid receipt was not returned as a typed terminal outcome") }
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        let saved = try XCTUnwrap(journal.load().values.first)
        XCTAssertEqual(saved.phase, .pausedTerminal)
        XCTAssertEqual(try Data(contentsOf: journal.bodyURL(saved)), try CloudPushTransport.gzip(batch.body))
        XCTAssertEqual(saved.headers["Content-Encoding"], "gzip")
        CloudPushBackgroundRuntime.install(nil)
        await runtime.retire()
        do {
            _ = try await transport.post(batch)
            XCTFail("the captured account transport must not outlive its runtime")
        } catch { XCTAssertEqual(error as? CloudUploadError, .staleOwner) }

        // Enrollment explicitly supports direct token-scoped transport. It must not adopt the
        // retired account's journal, and this protocol test must never contact an external host.
        let directConfig = URLSessionConfiguration.ephemeral
        directConfig.protocolClasses = [DirectEnrollmentURLProtocol.self]
        let directSession = URLSession(configuration: directConfig)
        defer { directSession.invalidateAndCancel() }
        let metadataBefore = try journal.load()
        let enrollment = CloudPushTransport(endpoint: .init(url: endpoint, host: "project.example"),
            uploadToken: "enrollment-only", fleetToken: "fixture-fleet", session: directSession,
            uploadSession: directSession)
        let response = try await enrollment.post(batch)
        XCTAssertEqual(response.statusCode, 202)
        XCTAssertEqual(response.body, Data("enrollment-fixture".utf8))
        XCTAssertEqual(Set(try journal.load().keys), Set(metadataBefore.keys))
        XCTAssertEqual(try journal.load()[saved.id]?.phase, .pausedTerminal)
        XCTAssertEqual(try Data(contentsOf: journal.bodyURL(saved)), try CloudPushTransport.gzip(batch.body))
    }

    func testReceiverResetCannotReplayOldResponseAndOnlyCommittedJobsAreRetired() async throws {
        let (_, context, layout) = try fixture()
        let adapter = UploadAdapter()
        let q = try queue(context, layout, adapter)
        let batch = cleanupBatch()
        let body = batch.body
        let oldReceipt = try requestReceipt(batchID: "55555555-5555-4555-8555-555555555555", marker: "old")
        let newReceipt = try requestReceipt(batchID: "55555555-5555-4555-8555-555555555555", marker: "new")
        let first = Task { try await q.request(endpoint: endpoint, body: body, headers: [:], captured: context,
                                               receiverStateID: "receiver-before-reset", batchID: "55555555-5555-4555-8555-555555555555") }
        try await eventually { adapter.count == 1 }
        let firstTask = try XCTUnwrap(adapter.first)
        await q.receive(firstTask.task, status: 200, body: oldReceipt, error: false)
        _ = try await first.value
        try await q.validateResponse(batch: batch, response: .init(statusCode: 200, body: oldReceipt),
                                     captured: context, receiverStateID: "receiver-before-reset")
        let second = Task { try await q.request(endpoint: endpoint, body: body, headers: [:], captured: context,
                                                receiverStateID: "receiver-after-reset", batchID: "55555555-5555-4555-8555-555555555555") }
        try await eventually { adapter.count == 2 }
        let secondTask = try XCTUnwrap(adapter.last)
        XCTAssertNotEqual(firstTask.file, secondTask.file)
        do {
            try await q.sourceCommitted(batchID: "55555555-5555-4555-8555-555555555555", receiverStateID: "receiver-after-reset", captured: context)
            XCTFail("cannot retire unacknowledged bytes")
        } catch { XCTAssertEqual(error as? CloudUploadError, .invalidReceipt) }
        try await q.sourceCommitted(batchID: "55555555-5555-4555-8555-555555555555", receiverStateID: "receiver-before-reset", captured: context)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstTask.file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondTask.file.path))
        await q.receive(secondTask.task, status: 200, body: newReceipt, error: false)
        let result = try await second.value
        XCTAssertEqual(result.body, newReceipt)
        try await q.validateResponse(batch: batch, response: result, captured: context, receiverStateID: "receiver-after-reset")
        try await q.sourceCommitted(batchID: "55555555-5555-4555-8555-555555555555", receiverStateID: "receiver-after-reset", captured: context)
        XCTAssertEqual(try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget).load().count, 0)
    }

    func testRelaunchFinishesCommittedCleanupAndOrphanFileAdoptionDoesNotNeedDoubleSpace() async throws {
        let (_, context, layout) = try fixture()
        let baseline = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, maximumBytes: baseline.storageAccounting().used + 3, resourceBudget: resourceBudget)
        var job = CloudUploadJob(id: AccountScope.digest("orphan"), owner: context.scope, generation: context.generation,
            endpoint: endpoint, deviceID: "", createdAt: Date(), operation: .request, method: "POST", headers: [:])
        let original = job
        try journal.persistBody(Data([1, 2, 3]), job: &job)
        var recovered = original
        try journal.persistBody(Data([1, 2, 3]), job: &recovered)
        XCTAssertEqual(job.payloadSHA256, recovered.payloadSHA256)
        job.acknowledged = true
        try journal.save(job)
        let adapter = UploadAdapter()
        let q = try queue(context, layout, adapter)
        try await q.reconcile()
        XCTAssertEqual(try journal.load().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try journal.bodyURL(job).path))
        XCTAssertEqual(adapter.count, 0)
    }

    func testLogoutDuringAuthorizationDoesNotCreateTask() async throws {
        let (_, context, layout) = try fixture()
        let fence = UploadFence()
        let adapter = UploadAdapter()
        let q = try CloudUploadQueue(context: context, layout: layout, adapter: adapter,
            authorize: { _ in fence.revoke(); return "stale-synthetic-token" }, isCurrent: { _ in fence.current },
            policy: { .init(concurrency: 1, allowsCellular: false, allowsConstrained: false) },
            control: { _ in throw CloudUploadError.unavailable }, resourceBudget: resourceBudget)
        do { _ = try await q.request(endpoint: endpoint, body: Data([1]), headers: [:], captured: context); XCTFail() }
        catch { XCTAssertEqual(error as? CloudUploadError, .staleOwner) }
        XCTAssertEqual(adapter.count, 0)
        XCTAssertEqual(try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget).load().count, 1)
    }

    func testWiFiPolicyTighteningCancelsThenReschedulesSameFileWithoutOverlappingBudget() async throws {
        let (_, context, layout) = try fixture()
        let policy = UploadPolicyBox()
        let adapter = UploadAdapter()
        let q = try CloudUploadQueue(context: context, layout: layout, adapter: adapter, authorize: { _ in "synthetic" },
            isCurrent: { _ in true }, policy: { policy.value }, control: { _ in throw CloudUploadError.unavailable }, resourceBudget: resourceBudget)
        let pending = Task { try await q.request(endpoint: endpoint, body: Data([1, 2]), headers: [:], captured: context) }
        try await eventually { adapter.count == 1 }
        let old = try XCTUnwrap(adapter.first)
        XCTAssertTrue(old.request.allowsCellularAccess)
        policy.requireWiFi()
        try await q.reconcile()
        XCTAssertEqual(adapter.cancelled, [old.task.identifier])
        XCTAssertEqual(adapter.count, 1) // Cancellation still consumes the one-task network budget.
        await q.receive(old.task, status: 200, body: Data("stale-policy-result".utf8), error: false)
        let replacement = try XCTUnwrap(adapter.last)
        XCTAssertEqual(adapter.count, 2)
        XCTAssertEqual(old.file, replacement.file)
        XCTAssertFalse(replacement.request.allowsCellularAccess)
        XCTAssertNotEqual(old.task.description, replacement.task.description)
        await q.receive(replacement.task, status: 200, body: Data("current-result".utf8), error: false)
        let result = try await pending.value
        XCTAssertEqual(result.body, Data("current-result".utf8))
    }

    private func requestReceipt(batchID: String = "55555555-5555-4555-8555-555555555555", status: String = "accepted", marker: String = "test") throws -> Data {
        var object = W5ReceiptFixture.inline(cleanupBatch(), owner: "11111111-1111-1111-1111-111111111111")
        object["batchId"] = batchID; object["status"] = status; object["testMarker"] = marker
        return try W5ReceiptFixture.bytes(object)
    }

    private func cleanupBatch() -> PushBatch {
        PushBatch(protocolVersion: "1.0", batchId: "55555555-5555-4555-8555-555555555555", sourceId: W5ReceiptFixture.source,
            table: PushAppendTable.hrSample, deviceId: "synthetic-device", mode: "append", startCursor: nil,
            endCursor: nil, recordCount: 1, window: nil, body: Data([8, 6, 4, 2]))
    }

    private func receivedJob(_ context: AccountSessionContext, _ layout: AccountStorageLayout,
                             receipt: Data) throws -> CloudUploadJob {
        var job = CloudUploadJob(id: AccountScope.digest("cleanup"), owner: context.scope, generation: context.generation,
            endpoint: endpoint, deviceID: "", createdAt: Date(), operation: .request, method: "POST", headers: [:])
        job.phase = .responseSaved; job.responseStatus = 200; job.responseBody = receipt
        job.validatedReceipt = try? PushAck.parse(receipt).durabilityReceipt
        job.batchID = "55555555-5555-4555-8555-555555555555"; job.receiverStateID = "receiver-1"
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        try journal.persistBody(Data([8, 6, 4, 2]), job: &job)
        try journal.save(job)
        return job
    }

    func testMalformedWrongBatchAndUnacceptedReceiptsCannotAuthorizeDeletion() async throws {
        let invalid = [Data("not-json".utf8), try requestReceipt(batchID: "different-batch"),
                       try requestReceipt(status: "pending")]
        for receipt in invalid {
            let (_, context, layout) = try fixture()
                let job = try receivedJob(context, layout, receipt: receipt)
            let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
            let q = try queue(context, layout, UploadAdapter())
            do { try await q.sourceCommitted(batchID: "55555555-5555-4555-8555-555555555555", receiverStateID: "receiver-1", captured: context); XCTFail() }
            catch { XCTAssertEqual(error as? CloudUploadError, .invalidReceipt) }
            XCTAssertEqual(try Data(contentsOf: journal.bodyURL(job)), Data([8, 6, 4, 2]))
            XCTAssertEqual(try journal.load()[job.id]?.responseBody, receipt)
            XCTAssertEqual(try journal.load()[job.id]?.acknowledged, false)
        }
    }

    func testCleanupFilesystemFailureRetainsExactBodyAndReceiptDebt() async throws {
        guard geteuid() != 0 else { throw XCTSkip("permission failure requires an unprivileged test process") }
        let (_, context, layout) = try fixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: layout.uploadDirectory.path)
        }
        let job = try receivedJob(context, layout, receipt: requestReceipt())
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        let originalReceipt = try journal.load()[job.id]?.responseBody
        let q = try queue(context, layout, UploadAdapter())
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: layout.uploadDirectory.path)
        do { try await q.sourceCommitted(batchID: "55555555-5555-4555-8555-555555555555", receiverStateID: "receiver-1", captured: context); XCTFail() }
        catch { XCTAssertNotNil(error as NSError) }
        XCTAssertEqual(try journal.load()[job.id]?.responseBody, originalReceipt)
        XCTAssertEqual(try Data(contentsOf: journal.bodyURL(job)), Data([8, 6, 4, 2]))
    }

    func testUnexpectedBodyDirectoryIsNotRecursivelyDeletedAndCleanupResumes() async throws {
        let (root, context, layout) = try fixture()
        let receipt = try requestReceipt()
        let job = try receivedJob(context, layout, receipt: receipt)
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        let body = try journal.bodyURL(job)
        let preserved = root.appendingPathComponent("preserved.body")
        try FileManager.default.moveItem(at: body, to: preserved)
        try FileManager.default.createDirectory(at: body, withIntermediateDirectories: false)
        let sentinel = body.appendingPathComponent("must-not-delete")
        try Data([1, 3, 5]).write(to: sentinel)
        let q = try queue(context, layout, UploadAdapter())
        do { try await q.sourceCommitted(batchID: "55555555-5555-4555-8555-555555555555", receiverStateID: "receiver-1", captured: context); XCTFail() }
        catch { XCTAssertTrue(error is POSIXError) }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([1, 3, 5]))
        XCTAssertEqual(try journal.load()[job.id]?.responseBody, receipt)
        XCTAssertEqual(try journal.load()[job.id]?.acknowledged, true)
        // Repair only the controlled fixture, then simulate a process restart after cleanup failed.
        try FileManager.default.removeItem(at: body)
        try FileManager.default.moveItem(at: preserved, to: body)
        let reopened = try queue(context, layout, UploadAdapter())
        try await reopened.reconcile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: body.path))
        XCTAssertNil(try journal.load()[job.id])
    }

    func testCrashAfterCommittedBodyRemovalRetainsReceiptUntilRecoveryAndSpareJobsSurvive() async throws {
        let (_, context, layout) = try fixture()
        let receipt = try requestReceipt()
        var job = try receivedJob(context, layout, receipt: receipt)
        let spare = try objectJob(context, layout)
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        job.acknowledged = true
        try journal.save(job)
        try FileManager.default.removeItem(at: journal.bodyURL(job))
        XCTAssertEqual(try journal.load()[job.id]?.responseBody, receipt)
        let reopened = try queue(context, layout, UploadAdapter(), limit: 0)
        try await reopened.reconcile()
        XCTAssertNil(try journal.load()[job.id])
        XCTAssertNotNil(try journal.load()[spare.id])
        XCTAssertEqual(try Data(contentsOf: journal.bodyURL(spare)), Data([2, 4, 6]))
    }

    func testPartialBatchCleanupMarkerRecoversFallbackSiblingWithoutDeletingUnrelatedBatch() async throws {
        let (_, context, layout) = try fixture()
        var accepted = try receivedJob(context, layout, receipt: requestReceipt())
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        var fallback = CloudUploadJob(id: AccountScope.digest("gzip-representation"), owner: context.scope,
            generation: context.generation, endpoint: endpoint, deviceID: "", createdAt: Date(),
            operation: .request, method: "POST", headers: ["Content-Encoding": "gzip"])
        fallback.batchID = accepted.batchID; fallback.receiverStateID = accepted.receiverStateID
        fallback.phase = .responseSaved; fallback.responseStatus = 415; fallback.responseBody = Data()
        try journal.persistBody(Data([0x1f, 0x8b, 1]), job: &fallback)
        try journal.save(fallback)
        let spare = try objectJob(context, layout)
        accepted.acknowledged = true // Crash after the first marker, before marking its fallback sibling.
        try journal.save(accepted)
        let reopened = try queue(context, layout, UploadAdapter(), limit: 0)
        try await reopened.reconcile()
        let remaining = try journal.load()
        XCTAssertNil(remaining[accepted.id]); XCTAssertNil(remaining[fallback.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try journal.bodyURL(accepted).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try journal.bodyURL(fallback).path))
        XCTAssertNotNil(remaining[spare.id])
        XCTAssertEqual(try Data(contentsOf: journal.bodyURL(spare)), Data([2, 4, 6]))
    }
    private func admissionSelection(_ context: AccountSessionContext, row: Int64 = 1,
                                    device: String = "admission-device") throws -> CloudPushPreparedSelection {
        let batch = try PushProtocol.appendBatch(table: .hrSample, sourceId: W5ReceiptFixture.source,
            deviceId: device, startCursor: nil,
            records: [.init(rowId: row, key: ["ts": .int(row)], data: ["bpm": .int(60)])])
        return try .init(context: context, endpoint: endpoint, receiverStateID: "admission-receiver", progressVersion: "1.2",
            selection: .init(inline: [batch], commit: .init(kind: .append, table: "hrSample", deviceID: device,
                batchIDs: [batch.batchId], cursor: batch.endCursor)), inlineGzip: [CloudPushTransport.gzip(batch.body)])
    }

    private func admissionFiles(_ layout: AccountStorageLayout) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: layout.uploadDirectory, includingPropertiesForKeys: [.isRegularFileKey]) {
            if !url.lastPathComponent.hasPrefix("cloud-metadata.sqlite"),
               try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[url.lastPathComponent] = try Data(contentsOf: url)
            }
        }
        // WAL/shared-memory lock bytes can change on a read-only transaction. Compare logical
        // durable metadata plus exact immutable files, never SQLite's transient lock representation.
        let metadata = try CloudMetadataStore(directory: layout.uploadDirectory)
        for kind in ["json", "selection", "selection-index", "continuation", "control", "progress", "receipt", "spoolintent", "retirement"] {
            for name in try metadata.names(kind: kind) { result["metadata:" + name] = try metadata.read(name) }
        }
        return result
    }

    func testFreshPreferenceBoundaryRejectsBeforeAnyReservationOrBodyWrite() async throws {
        let (_, context, layout) = try fixture()
        let adapter = UploadAdapter(), calls = UploadAdmissionCount()
        let q = try queue(context, layout, adapter, capacity: 8_000_000)
        let selection = try admissionSelection(context)
        let before = try admissionFiles(layout)
        do {
            try await q.prepareSelection(selection, captured: context, beforeFreshAdmission: {
                calls.add(); throw CancellationError()
            })
            XCTFail("revoked preference admitted a new immutable selection")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(try admissionFiles(layout), before)
        XCTAssertTrue(try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget).load().isEmpty)
        let saved = try await q.preparedSelectionIDs(sourceID: selection.sourceID, endpoint: endpoint,
            receiverStateID: selection.receiverStateID, captured: context)
        XCTAssertTrue(saved.isEmpty)
        try await q.reconcile()
        XCTAssertEqual(adapter.count, 0)
    }

    func testVerifiedReceiptDebtDrainsAfterRelaunchAtPreparationJobLimit() async throws {
        let (_, context, layout) = try fixture()
        let adapter = UploadAdapter()
        let q = try queue(context, layout, adapter, capacity: 128_000_000)
        let first = try admissionSelection(context, device: "quota-lane-0")
        for index in 0..<64 {
            try await q.prepareSelection(try admissionSelection(context, device: "quota-lane-\(index)"), captured: context)
        }
        XCTAssertEqual(resourceBudget.snapshot(for: .cloudPreparation).reason, .queuedCloud)
        let batch = try first.selection.restoredInlineBatches()[0]
        let pending = Task {
            try await q.request(endpoint: first.endpoint, body: first.inlineGzip[0],
                headers: ["Content-Type": "application/x-ndjson; charset=utf-8", "Content-Encoding": "gzip"],
                captured: context, receiverStateID: first.receiverStateID, batchID: batch.batchId, selectionID: first.id)
        }
        try await eventually { adapter.count == 1 }
        let upload = try XCTUnwrap(adapter.first)
        let bytes = try W5ReceiptFixture.bytes(W5ReceiptFixture.inline(batch, owner: context.scope.userID))
        await q.receive(upload.task, status: 200, body: bytes, error: false)
        let response = try await pending.value
        try await q.validateResponse(batch: batch, response: response, captured: context,
            receiverStateID: first.receiverStateID, selectionID: first.id)
        await q.suspend()

        let reopenedAdapter = UploadAdapter()
        let reopened = try queue(context, layout, reopenedAdapter, capacity: 128_000_000)
        XCTAssertEqual(resourceBudget.snapshot(for: .cloudPreparation).reason, .queuedCloud,
            "restored debt must affect admission before a new task or journal write")
        do {
            try await reopened.prepareSelection(try admissionSelection(context, device: "new-quota-lane"), captured: context)
            XCTFail("full queue admitted a new source selection")
        } catch { XCTAssertEqual(error as? CloudUploadError, .retryScheduled) }

        let restored = try await reopened.preparedSelection(first.id, captured: context)
        try await reopened.prepareSelection(restored, captured: context, beforeFreshAdmission: {
            XCTFail("receipt recovery borrowed fresh source admission")
        })
        let replay = try await reopened.request(endpoint: restored.endpoint, body: restored.inlineGzip[0],
            headers: ["Content-Type": "application/x-ndjson; charset=utf-8", "Content-Encoding": "gzip"],
            captured: context, receiverStateID: restored.receiverStateID, batchID: batch.batchId, selectionID: restored.id)
        try await reopened.validateResponse(batch: batch, response: replay, captured: context,
            receiverStateID: restored.receiverStateID, selectionID: restored.id)
        XCTAssertEqual(reopenedAdapter.count, 0, "an exact saved receipt needs no replacement transfer")

        let progress = try CloudPushProgressStore(namespace: restored.progressNamespace,
            directory: layout.uploadDirectory.appendingPathComponent("source-progress"))
        try await progress.associateInline(batch: batch,
            receipt: try XCTUnwrap(PushAck.parse(replay.body).durabilityReceipt), prepared: restored)
        let committer = CloudPushSourceCommitter(progress: progress, check: {}, acknowledge: { _ in },
            cleanup: { _ in XCTFail("prepared debt used legacy cleanup") },
            cleanupPrepared: { try await reopened.preparedSourceCommitted(selectionID: $0, captured: context) },
            retirePrepared: { try await reopened.retireSelection($0, captured: context) })
        try await committer.commit(restored.commit, preparedSelectionID: restored.id)
        let debt = await progress.pendingCommits()
        XCTAssertTrue(debt.isEmpty)
        let cursor = try await progress.cursor(table: .hrSample, deviceId: batch.deviceId)
        XCTAssertEqual(cursor, batch.endCursor)
        XCTAssertEqual(try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget).load().count, 126)
        XCTAssertNil(resourceBudget.snapshot(for: .cloudPreparation).reason)
        await reopened.suspend()
    }

    func testInjectedHistoryBudgetStopsQueueWorkAndResumesWithoutAffectingAnotherBudget() async throws {
        let (_, blockedContext, blockedLayout) = try fixture()
        let (_, healthyContext, healthyLayout) = try fixture()
        _ = try objectJob(blockedContext, blockedLayout)
        _ = try objectJob(healthyContext, healthyLayout)
        let historyBudget = ResourceBudget(cooldown: 0, thermal: { 0 }, lowPower: { false })
        let history = UUID()
        historyBudget.history(owner: history, active: true)
        let blockedAdapter = UploadAdapter(), healthyAdapter = UploadAdapter()
        let blocked = try CloudUploadQueue(context: blockedContext, layout: blockedLayout, adapter: blockedAdapter,
            authorize: { _ in "synthetic-token" }, isCurrent: { _ in true },
            policy: { .init(concurrency: 1, allowsCellular: false, allowsConstrained: false) },
            control: { _ in throw CloudUploadError.unavailable }, resourceBudget: historyBudget)
        let healthy = try queue(healthyContext, healthyLayout, healthyAdapter)
        do {
            try await blocked.checkSelectionEncodingAdmission(captured: blockedContext)
            XCTFail("history pressure admitted new encoding")
        } catch { XCTAssertEqual(error as? CloudUploadError, .retryScheduled) }
        try await blocked.reconcile()
        try await healthy.reconcile()
        XCTAssertEqual(blockedAdapter.count, 0)
        XCTAssertEqual(healthyAdapter.count, 1)
        XCTAssertTrue(historyBudget.permits(.localCommit))
        XCTAssertTrue(historyBudget.permits(.acknowledgement))

        historyBudget.history(owner: history, active: false)
        try await blocked.checkSelectionEncodingAdmission(captured: blockedContext)
        try await blocked.reconcile()
        XCTAssertEqual(blockedAdapter.count, 1)
        await blocked.suspend()
        await healthy.suspend()
    }

    func testExactReservedReplaySkipsFreshBoundaryButChangedSameIDBytesAreRejected() async throws {
        let (_, context, layout) = try fixture()
        let adapter = UploadAdapter(), calls = UploadAdmissionCount()
        let q = try queue(context, layout, adapter, capacity: 8_000_000)
        let selection = try admissionSelection(context)
        try await q.prepareSelection(selection, captured: context, beforeFreshAdmission: { calls.add() })
        XCTAssertEqual(calls.value, 1)
        let before = try admissionFiles(layout)
        let replay = try admissionSelection(.init(scope: context.scope, generation: UUID()))
        XCTAssertEqual(replay.id, selection.id)
        XCTAssertNotEqual(replay.capturedGeneration, selection.capturedGeneration)
        try await q.prepareSelection(replay, captured: context, beforeFreshAdmission: {
            XCTFail("exact reservation required new preference authority"); throw CancellationError()
        })
        XCTAssertEqual(try admissionFiles(layout), before, "first capture generation/correlation/bytes must survive replay")
        let changed = try admissionSelection(context, row: 2)
        XCTAssertNotEqual(changed.id, selection.id)
        var forged = try XCTUnwrap(JSONSerialization.jsonObject(with: changed.encoded()) as? [String: Any])
        forged["id"] = selection.id
        XCTAssertThrowsError(try CloudPushPreparedSelection.decode(JSONSerialization.data(withJSONObject: forged))) {
            XCTAssertEqual($0 as? CloudUploadError, .corruptJournal)
        }
        do {
            try await q.prepareSelection(changed, captured: context, beforeFreshAdmission: { throw CancellationError() })
            XCTFail("new bytes borrowed the old reservation's admission")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try admissionFiles(layout), before)
        XCTAssertEqual(adapter.count, 0)
        // Existing-ID replay must still verify the published body's immutable bytes.
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        let job = try XCTUnwrap(journal.load()[selection.jobID(batchID: selection.commit.batchIDs[0], representation: "identity")])
        let bodyPath = try journal.bodyURL(job)
        let changedBody = Data("changed bytes under the same reserved identity".utf8)
        try changedBody.write(to: bodyPath)
        do {
            try await q.prepareSelection(selection, captured: context, beforeFreshAdmission: {
                XCTFail("immutable replay corruption is not a request for new admission"); throw CancellationError()
            })
            XCTFail("existing ID hid changed immutable bytes")
        } catch { XCTAssertEqual(error as? CloudUploadError, .changedPayload) }
        XCTAssertEqual(try Data(contentsOf: bodyPath), changedBody, "rejection must retain corrupt evidence, not overwrite it")
    }

    func testTornReservedPublicationKeepsExactAdmissionAfterPreferenceRevocation() async throws {
        let (root, context, _) = try fixture()
        let selection = try admissionSelection(context)
        for position in [1, 3, 7] {
            let layout = AccountStorageLayout(baseDirectory: root.appendingPathComponent("write-\(position)"), scope: context.scope)
            let writes = UploadAdmissionCount(), checks = UploadAdmissionCount(), adapter = UploadAdapter()
            let q = try CloudUploadQueue(context: context, layout: layout, adapter: adapter,
                authorize: { _ in XCTFail("preparation cannot authorize delivery"); throw CloudUploadError.unavailable },
                isCurrent: { _ in true }, policy: { .init(concurrency: 2, allowsCellular: false, allowsConstrained: false) },
                control: { _ in throw CloudUploadError.unavailable }, maximumBytes: 8_000_000,
                journalWriteObserver: { _ in
                    XCTAssertEqual(checks.value, 1, "every write follows the original boundary check")
                    writes.add()
                    if writes.value == position { throw CloudUploadError.unavailable }
                }, resourceBudget: resourceBudget)
            do {
                try await q.prepareSelection(selection, captured: context, beforeFreshAdmission: { checks.add() })
                XCTFail("missing injected publication failure")
            } catch { XCTAssertEqual(error as? CloudUploadError, .unavailable) }
            try await q.prepareSelection(selection, captured: context, beforeFreshAdmission: {
                XCTFail("torn reservation recaptured preference authority"); throw CancellationError()
            })
            let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
            try journal.loadSelections(owner: context.scope)
            XCTAssertEqual(journal.continuations[selection.id]?.published, true)
            XCTAssertEqual(try journal.selection(selection.id)?.encoded(), try selection.encoded())
            let jobs = try journal.load()
            XCTAssertEqual(jobs.count, 2)
            for job in jobs.values { try journal.verifyBody(job); XCTAssertEqual(job.deliveryAdmitted, false) }
            try await q.reconcile()
            XCTAssertEqual(adapter.count, 0)
            XCTAssertEqual(checks.value, 1)
            await q.suspend()
        }
    }

    func testReservedReplayStillRequiresCurrentCapturedAccount() async throws {
        let (_, context, layout) = try fixture()
        let account = UploadFence(), adapter = UploadAdapter()
        let q = try queue(context, layout, adapter, current: { _ in account.current }, capacity: 8_000_000)
        let selection = try admissionSelection(context)
        try await q.prepareSelection(selection, captured: context)
        let before = try admissionFiles(layout)
        account.revoke()
        do {
            try await q.prepareSelection(selection, captured: context, beforeFreshAdmission: {
                XCTFail("account revocation must precede preference admission")
            })
            XCTFail("exact bytes bypassed account fencing")
        } catch { XCTAssertEqual(error as? CloudUploadError, .staleOwner) }
        XCTAssertEqual(try admissionFiles(layout), before)
        XCTAssertEqual(adapter.count, 0)
    }

    func testPreferenceRevocationDuringAuthorizationAllowsOnlyAlreadyReservedBytes() async throws {
        let (_, context, layout) = try fixture()
        let preference = UploadFence(), adapter = UploadAdapter(), gate = UploadAuthorizationGate()
        let entered = expectation(description: "admitted delivery awaiting synthetic credentials")
        defer { Task { await gate.release() } }
        let q = try CloudUploadQueue(context: context, layout: layout, adapter: adapter,
            authorize: { _ in entered.fulfill(); return await gate.token() }, isCurrent: { _ in true },
            policy: { .init(concurrency: 2, allowsCellular: false, allowsConstrained: false) },
            control: { _ in throw CloudUploadError.unavailable }, maximumBytes: 8_000_000, resourceBudget: resourceBudget)
        let selection = try admissionSelection(context), batch = try selection.selection.restoredInlineBatches()[0]
        let check: @Sendable () throws -> Void = { guard preference.current else { throw CancellationError() } }
        try await q.prepareSelection(selection, captured: context, beforeFreshAdmission: check)
        let headers = ["Content-Type": "application/x-ndjson; charset=utf-8", "Content-Encoding": "gzip"]
        let pending = Task {
            try await q.request(endpoint: endpoint, body: selection.inlineGzip[0], headers: headers,
                captured: context, receiverStateID: selection.receiverStateID, batchID: batch.batchId, selectionID: selection.id)
        }
        defer { pending.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        preference.revoke()
        let unrelated = try admissionSelection(context, device: "not-previously-admitted")
        do {
            try await q.prepareSelection(unrelated, captured: context, beforeFreshAdmission: check)
            XCTFail("authorization suspension admitted new preference bytes")
        } catch { XCTAssertTrue(error is CancellationError) }
        await gate.release()
        try await eventually { adapter.count == 1 }
        let task = try XCTUnwrap(adapter.first)
        XCTAssertEqual(try Data(contentsOf: task.file), selection.inlineGzip[0])
        let receipt = try W5ReceiptFixture.bytes(W5ReceiptFixture.inline(batch, owner: context.scope.userID))
        await q.receive(task.task, status: 200, body: receipt, error: false)
        let response = try await pending.value
        try await q.validateResponse(batch: batch, response: response, captured: context,
            receiverStateID: selection.receiverStateID, selectionID: selection.id)
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: resourceBudget)
        let saved = try journal.load()
        XCTAssertEqual(saved.count, 2)
        XCTAssertNotNil(saved[selection.jobID(batchID: batch.batchId, representation: "gzip")]?.validatedReceipt)
        XCTAssertTrue(saved.values.allSatisfy { $0.preparedSelectionID == selection.id && !$0.acknowledged })
        XCTAssertEqual(adapter.count, 1)
        // A transfer receipt alone is not source cleanup or current preference-job settlement.
        try journal.loadSelections(owner: context.scope)
        XCTAssertEqual(journal.continuations[selection.id]?.sourceCommitted, false)
    }
}

private final class UploadAdmissionCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class UploadFence: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var current: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func revoke() { lock.lock(); valid = false; lock.unlock() }
}

private final class UploadPolicyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cellular = true
    private var limit: Int
    private var enabled = true
    private var termsAccepted = true
    init(limit: Int = 1) { self.limit = limit }
    var value: CloudUploadPolicy {
        lock.lock(); defer { lock.unlock() }
        if !enabled || !termsAccepted {
            return .current(wifiOnly: !cellular, enabled: enabled && termsAccepted)
        }
        return .init(concurrency: limit, allowsCellular: cellular, allowsConstrained: false)
    }
    func requireWiFi() { lock.lock(); cellular = false; lock.unlock() }
    func setConsent(enabled: Bool, termsAccepted: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.enabled = enabled; self.termsAccepted = termsAccepted
    }
}

private actor UploadAuthorizationGate {
    private var open = false
    private var waiting: CheckedContinuation<String, Never>?
    func token() async -> String {
        if open { return "synthetic-token" }
        return await withCheckedContinuation { waiting = $0 }
    }
    func release() {
        open = true
        waiting?.resume(returning: "synthetic-token")
        waiting = nil
    }
}

private final class UploadAdapter: CloudUploadSessionAdapter, @unchecked Sendable {
    struct Created { let task: CloudUploadTaskSnapshot; let request: URLRequest; let file: URL }
    private let lock = NSLock()
    private var live: [CloudUploadTaskSnapshot] = []
    private var created: [Created] = []
    private var cancellations: [Int] = []
    private var resumptions: [Int] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return created.count }
    var first: Created? { lock.lock(); defer { lock.unlock() }; return created.first }
    var last: Created? { lock.lock(); defer { lock.unlock() }; return created.last }
    var cancelled: [Int] { lock.lock(); defer { lock.unlock() }; return cancellations }
    var resumed: [Int] { lock.lock(); defer { lock.unlock() }; return resumptions }
    func seed(_ task: CloudUploadTaskSnapshot) { lock.lock(); live.append(task); lock.unlock() }
    private func snapshot() -> [CloudUploadTaskSnapshot] { lock.lock(); defer { lock.unlock() }; return live }
    func tasks() async -> [CloudUploadTaskSnapshot] { snapshot() }
    func create(request: URLRequest, file: URL, description: String) -> CloudUploadTaskSnapshot {
        lock.lock(); defer { lock.unlock() }
        let task = CloudUploadTaskSnapshot(identifier: 100 + created.count, description: description)
        created.append(.init(task: task, request: request, file: file)); live.append(task)
        return task
    }
    func resume(_ identifier: Int) { lock.lock(); resumptions.append(identifier); lock.unlock() }
    func cancel(_ identifier: Int) { lock.lock(); cancellations.append(identifier); lock.unlock() }
}

private final class UploadURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.host, "w5.invalid")
        XCTAssertEqual(request.httpMethod, "PUT")
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8)
            let count = stream.read(&buffer, maxLength: buffer.count)
            XCTAssertEqual(Array(buffer.prefix(max(0, count))), [2, 4, 6])
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("controlled-receipt".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class TransportURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.host, "project.example")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("bounded-receiver-response".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class DirectEnrollmentURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.host, "project.example")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer enrollment-only")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-NOOP-Fleet-Token"), "fixture-fleet")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 202,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("enrollment-fixture".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RuntimeControlURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("synthetic-invalid-capability".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class UploadJournalFault: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    func arm() { lock.lock(); defer { lock.unlock() }; active = true }
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; let value = active; active = false; return value }
}
