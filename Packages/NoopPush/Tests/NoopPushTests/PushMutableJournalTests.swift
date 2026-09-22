import XCTest
@testable import NoopPush

final class PushMutableJournalTests: XCTestCase {
    private func coordinator(_ f: MutableJournalFixture, zone: String = "Etc/UTC") -> PushCoordinator {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
        return PushCoordinator(source: f, transport: f, progress: f, sourceId: f.source,
            today: { Date(timeIntervalSince1970: 1_790_035_200) }, calendar: calendar, receiptOwner: f.owner,
            associateInlineReceipt: { try await f.associate($0, $1) })
    }
    func testOldDaysAndSameRevisionKeysDrainOnlyAfterExactReceiptsThenAvoidSourceRereads() async throws {
        let f = try MutableJournalFixture()
        await f.setRanges([.init(revision: 7, key: "d:2020-01-01", fromDay: "2020-01-01", toDay: "2020-01-01"),
                          .init(revision: 7, key: "d:2020-01-02", fromDay: "2020-01-02", toDay: "2020-01-02")])
        let c = coordinator(f)
        guard case .accepted(_, _, true, _) = await c.pushMutable(.journal, deviceId: "synthetic") else { return XCTFail("initial baseline must retain historical debt") }
        var progress = await f.saved
        XCTAssertEqual(progress?.mutableFrontier?.revision, 0)
        guard case .accepted(_, _, true, _) = await c.pushMutable(.journal, deviceId: "synthetic") else { return XCTFail("same-revision successor remains debt") }
        progress = await f.saved
        XCTAssertEqual(progress?.mutableFrontier?.key, "d:2020-01-01")
        XCTAssertEqual(progress?.window.fromDay, "2020-01-01")
        guard case .accepted(_, 0, false, _) = await c.pushMutable(.journal, deviceId: "synthetic") else { return XCTFail("empty deletion replacement requires receipt") }
        progress = await f.saved
        XCTAssertEqual(progress?.mutableFrontier?.key, "d:2020-01-02")
        let before = await f.readWindows.count
        guard case .noData = await c.pushMutable(.journal, deviceId: "synthetic") else { return XCTFail("consumed metadata must drain") }
        let after = await f.readWindows.count
        XCTAssertEqual(before, after, "unchanged journal skips source payload scans and hashing")
    }
    func testInvalidReceiptNeverConsumesMarkerAndConcurrentMutationRemainsNextPage() async throws {
        let f = try MutableJournalFixture(), c = coordinator(f)
        _ = await c.pushMutable(.journal, deviceId: "synthetic")
        await f.setRanges([.init(revision: 8, key: "d:2020-01-01", fromDay: "2020-01-01", toDay: "2020-01-01")])
        await f.invalidReceipt(true)
        guard case .rejected = await c.pushMutable(.journal, deviceId: "synthetic") else { return XCTFail("invalid receipt consumed source") }
        var progress = await f.saved
        XCTAssertEqual(progress?.mutableFrontier?.revision, 0)
        await f.invalidReceipt(false)
        await f.mutateDuringNextPost()
        guard case .accepted = await c.pushMutable(.journal, deviceId: "synthetic") else { return XCTFail("valid captured receipt rejected") }
        progress = await f.saved
        XCTAssertEqual(progress?.mutableFrontier?.revision, 8)
        guard case .accepted = await c.pushMutable(.journal, deviceId: "synthetic") else { return XCTFail("post-snapshot mutation disappeared") }
        progress = await f.saved
        XCTAssertEqual(progress?.mutableFrontier?.revision, 9)
    }
    func testCalendarChangeResetsFrontierAndCapturedContinuationPersistsIt() async throws {
        let f = try MutableJournalFixture()
        await f.setRanges([.init(revision: 4, key: "d:2020-01-01", fromDay: "2020-01-01", toDay: "2020-01-01")])
        let c = coordinator(f)
        _ = await c.pushMutable(.journal, deviceId: "synthetic")
        _ = await c.pushMutable(.journal, deviceId: "synthetic")
        let old = await f.saved
        guard case .accepted(_, _, true, _) = await coordinator(f, zone: "America/Los_Angeles").pushMutable(.journal, deviceId: "synthetic") else { return XCTFail("zone change must resnapshot and replay") }
        let saved = await f.saved
        XCTAssertEqual(saved?.mutableFrontier?.revision, 0)
        XCTAssertNotEqual(saved?.mutableFrontier?.calendarSignature, old?.mutableFrontier?.calendarSignature)
        let lastBatch = await f.lastBatch()
        let batch = try XCTUnwrap(lastBatch)
        let selection = try PushPreparedSelection(inline: [batch], commit: .init(kind: .mutable, table: "journal", deviceID: "synthetic",
            batchIDs: [batch.batchId], window: try XCTUnwrap(saved)))
        XCTAssertEqual(try PushPreparedSelection.decode(selection.encoded()).commit.window?.mutableFrontier, saved?.mutableFrontier)
    }
    func testRunSummaryRetainsOldMutableDebt() async throws {
        let f = try MutableJournalFixture()
        await f.setRanges([.init(revision: 1, key: "d:2020-01-01", fromDay: "2020-01-01", toDay: "2020-01-01")])
        let result = await coordinator(f).pushKnownDevices(capabilities: .init(appendTables: [], mutableTables: [.journal]), binaryEnabled: false)
        XCTAssertTrue(result.hasMoreMutableRows)
        XCTAssertFalse(result.hasMoreAppendRows)
        XCTAssertEqual(result.acceptedBatches, 1)
    }
}

private actor MutableJournalFixture: PushSnapshotSource, PushTransport, PushProgressStore {
    nonisolated let source = "3a3486dd-5030-4e17-a00d-a781399890f9"
    nonisolated let owner: AccountScope
    var saved: PushWindowProgress?
    var readWindows: [PushWindow] = []
    private var ranges: [PushMutableDirtyRange] = []
    private var invalid = false, mutate = false
    private var associated: Set<String> = []
    private var posted: [PushBatch] = []
    init() throws { owner = try .init(projectURL: "https://synthetic.example", userID: "11111111-1111-4111-8111-111111111111") }
    func setRanges(_ value: [PushMutableDirtyRange]) { ranges = value }
    func invalidReceipt(_ value: Bool) { invalid = value }
    func mutateDuringNextPost() { mutate = true }
    func lastBatch() -> PushBatch? { posted.last }
    func knownDeviceIds(capabilities: PushCapabilities) -> [String] { ["synthetic"] }
    func knownDeviceIds() -> Set<String> { ["synthetic"] }
    func rememberDeviceId(_ deviceId: String) {}
    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) -> PushAppendRecord? { nil }
    func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) -> [PushAppendRecord] { [] }
    func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) -> PushBinaryRow? { nil }
    func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) -> [PushBinaryRow] { [] }
    func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) {}
    func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) -> [PushMutableRecord] { readWindows.append(window); return [] }
    func mutableDirtyRanges(table: PushMutableTable, deviceId: String, afterRevision: Int64, afterKey: String, limit: Int, calendar: Calendar) -> PushMutableDirtyPage? {
        let selected = ranges.filter { $0.revision > afterRevision || ($0.revision == afterRevision && $0.key > afterKey) }
            .sorted { $0.revision == $1.revision ? $0.key < $1.key : $0.revision < $1.revision }
        return .init(ranges: Array(selected.prefix(limit)), hasMore: selected.count > limit)
    }
    func cursor(table: PushAppendTable, deviceId: String) -> PushCursor? { nil }
    func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) {}
    func binaryCursor(table: PushBinaryTable, deviceId: String) -> PushCursor? { nil }
    func saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) {}
    func window(table: PushMutableTable, deviceId: String) -> PushWindowProgress? { saved }
    func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) throws {
        guard associated.contains(progress.batchId) else { throw PushProtocolException("frontier before receipt") }
        saved = progress
    }
    func associate(_ batch: PushBatch, _ receipt: PushDurabilityReceipt) throws {
        guard receipt.matches(batch, owner: owner) else { throw PushProtocolException("bad receipt") }
        associated.insert(batch.replacementId ?? batch.batchId)
    }
    func post(_ batch: PushBatch) throws -> PushTransportResponse {
        posted.append(batch)
        if mutate, let current = ranges.first {
            mutate = false; ranges = [.init(revision: current.revision + 1, key: current.key, fromDay: current.fromDay, toDay: current.toDay)]
        }
        let receipt: [String: Any] = ["version": 1, "state": "verified_indexed", "receiptId": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "ownerUserId": owner.userID, "deviceId": PushDurabilityReceipt.canonicalDevice(owner: owner.userID, device: batch.deviceId),
            "objectId": batch.batchId, "batchId": batch.batchId, "sourceId": batch.sourceId, "stream": batch.table.wireName,
            "schemaVersion": 1, "objectKey": "synthetic/verified", "contentSha256": invalid ? String(repeating: "0", count: 64) : PushDurabilityReceipt.sha256(batch.body),
            "wireSha256": String(repeating: "a", count: 64), "compressedBytes": 128, "uncompressedBytes": batch.body.count,
            "verifiedAt": "2026-09-18T00:00:00Z", "indexedAt": "2026-09-18T00:00:01Z"]
        let ack: [String: Any] = ["protocolVersion": batch.protocolVersion, "batchId": batch.batchId, "stream": batch.table.wireName,
            "deviceId": batch.deviceId, "endCursor": NSNull(), "acceptedRows": batch.recordCount, "status": "accepted", "durabilityReceipt": receipt]
        return .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: ack))
    }
    func postBinary(_ batch: PushBinaryBatch) throws -> PushTransportResponse { throw PushProtocolException("unused") }
}
