import Foundation
import XCTest
import NoopPush
#if canImport(CloudUploadHarness)
@testable import CloudUploadHarness
#else
@testable import Strand
#endif

final class CloudMetadataMigrationTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws {
        for root in roots { try FileManager.default.removeItem(at: root) }
        roots.removeAll()
        try super.tearDownWithError()
    }

    private func fixture() throws -> (URL, AccountSessionContext, CloudPushPreparedSelection) {
        let base = ProcessInfo.processInfo.environment["NARA_TEST_FIXTURE_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("metadata-migration-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        let owner = try AccountScope(projectURL: "https://project.example", userID: "11111111-1111-4111-8111-111111111111")
        let context = AccountSessionContext(scope: owner, generation: UUID())
        let batch = try PushProtocol.appendBatch(table: .battery,
            sourceId: "22222222-2222-4222-8222-222222222222", deviceId: "synthetic-migration-device",
            startCursor: nil, records: [.init(rowId: 1, key: ["ts": .int(1_800_000_000)],
                data: ["soc": .int(50), "mv": .null, "charging": .null])])
        let selection = try CloudPushPreparedSelection(context: context,
            endpoint: owner.projectURL + "/functions/v1/push", receiverStateID: "synthetic-receiver", progressVersion: "1.2",
            selection: .init(inline: [batch], commit: .init(kind: .append, table: batch.table.wireName,
                deviceID: batch.deviceId, batchIDs: [batch.batchId], cursor: batch.endCursor)),
            inlineGzip: [CloudPushTransport.gzip(batch.body)])
        return (root, context, selection)
    }

    func testLegacyStartupUnderHistoryPressureDefersExactConversionUntilAdmitted() throws {
        let (root, context, original) = try fixture()
        let saved = try original.encoded()
        let path = root.appendingPathComponent(original.id + ".selection")
        try saved.write(to: path)
        let budget = ResourceBudget(cooldown: 0, thermal: { 0 }, lowPower: { false })
        let history = UUID(); budget.history(owner: history, active: true)
        let journal = try CloudUploadJournal(directory: root, resourceBudget: budget)
        defer { journal.close() }
        try journal.loadSelections(owner: context.scope)
        XCTAssertEqual(journal.selectionIndex[original.id]?.isLegacy, true)
        XCTAssertEqual(journal.cachedSelectionCount, 0)
        XCTAssertEqual(try journal.metadata.read(original.id + ".selection"), saved)
        XCTAssertNil(try journal.metadata.read(original.id + ".selection-index"))
        XCTAssertThrowsError(try journal.selection(original.id)) { XCTAssertEqual($0 as? CloudUploadError, .retryScheduled) }
        XCTAssertTrue(try journal.metadata.names(kind: "spoolintent").isEmpty)
        budget.history(owner: history, active: false)
        XCTAssertEqual(try journal.selection(original.id)?.encoded(), saved)
        XCTAssertEqual(journal.selectionIndex[original.id]?.isLegacy, false)
        XCTAssertNotNil(try journal.metadata.read(original.id + ".selection-index"))
        XCTAssertEqual(try Data(contentsOf: path), saved)
        XCTAssertEqual(try journal.metadata.integrityCheck(), "ok")
    }

    func testDeferredLegacyConversionStillValidatesPayloadAndPreservesCorruptEvidence() throws {
        let (root, context, original) = try fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original.encoded()) as? [String: Any])
        object["inlineGzip"] = ["invalid-base64"]
        let saved = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try saved.write(to: root.appendingPathComponent(original.id + ".selection"))
        let journal = try CloudUploadJournal(directory: root, resourceBudget: ResourceBudget(thermal: { 0 }, lowPower: { false }))
        defer { journal.close() }
        try journal.loadSelections(owner: context.scope)
        XCTAssertEqual(journal.selectionIndex[original.id]?.isLegacy, true)
        XCTAssertThrowsError(try journal.selection(original.id))
        XCTAssertEqual(try journal.metadata.read(original.id + ".selection"), saved)
        XCTAssertNil(try journal.metadata.read(original.id + ".selection-index"))
    }

    func testRetirementRetryRejectsCorruptIdentityBeforeUnlink() throws {
        let (root, _, original) = try fixture()
        let journal = try CloudUploadJournal(directory: root, resourceBudget: ResourceBudget(thermal: { 0 }, lowPower: { false }))
        defer { journal.close() }
        try journal.reserve(original, legacyJobs: 0)
        var state = try XCTUnwrap(journal.continuations[original.id]); state.sourceCommitted = true
        try journal.saveContinuation(state)
        let index = try XCTUnwrap(journal.selectionIndex[original.id])
        let segment = root.appendingPathComponent(index.segment)
        let held = root.appendingPathComponent("retained-segment")
        try FileManager.default.moveItem(at: segment, to: held)
        try FileManager.default.createDirectory(at: segment, withIntermediateDirectories: false)
        XCTAssertThrowsError(try journal.retireSelection(original.id))
        try FileManager.default.removeItem(at: segment)
        try FileManager.default.moveItem(at: held, to: segment)
        let record = original.id + ".retirement"
        let saved = try XCTUnwrap(journal.metadata.read(record))
        var corrupt = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        corrupt["id"] = AccountScope.digest("different-retirement")
        let bytes = try JSONSerialization.data(withJSONObject: corrupt)
        try journal.metadata.put(record, data: bytes)
        XCTAssertThrowsError(try journal.retireSelection(original.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: segment.path))
        XCTAssertEqual(try journal.metadata.read(record), bytes)
        try journal.metadata.put(record, data: saved)
        try journal.retireSelection(original.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: segment.path))
        XCTAssertNil(try journal.metadata.read(record))
    }
}
