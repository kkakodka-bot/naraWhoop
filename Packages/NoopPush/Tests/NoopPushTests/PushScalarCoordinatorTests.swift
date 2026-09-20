import Foundation
import XCTest
@testable import NoopPush

final class PushScalarCoordinatorTests: XCTestCase {
    private let tables: Set<PushAppendTable> = [.stepSample, .sleepStateSample, .ppgHrSample]
    private let owner = try! AccountScope(projectURL: "https://fixture.invalid", userID: "11111111-1111-4111-8111-111111111111")
    private let sourceID = "3a3486dd-5030-4e17-a00d-a781399890f9"

    func testAllThreeNegotiatedStreamsRequireReceiptAssociationBeforeCursor() async throws {
        let state = ScalarFixtureState(owner: owner)
        let coordinator = PushCoordinator(source: ScalarFixtureSource(), transport: state, progress: state,
            sourceId: sourceID, receiptOwner: owner,
            associateInlineReceipt: { batch, receipt in try await state.associate(batch, receipt) })
        let caps = PushCapabilities(appendTables: tables, mutableTables: [], protocolVersion: "1.4")
        let first = await coordinator.pushKnownDevices(capabilities: caps)
        XCTAssertEqual(first.acceptedBatches, 3); XCTAssertEqual(first.acceptedRecords, 3)
        XCTAssertEqual(first.rejectedBatches, 0)
        let events = await state.events
        XCTAssertEqual(events, ["post:stepSample:1.4", "receipt:stepSample", "cursor:stepSample",
            "post:sleepStateSample:1.4", "receipt:sleepStateSample", "cursor:sleepStateSample",
            "post:ppgHrSample:1.4", "receipt:ppgHrSample", "cursor:ppgHrSample"])
        let second = await coordinator.pushKnownDevices(capabilities: caps)
        XCTAssertEqual(second.acceptedBatches, 0); XCTAssertEqual(second.rejectedBatches, 0)
        let afterRetry = await state.events
        XCTAssertEqual(afterRetry, events)
    }

    func testScalarSchemaMismatchOrFailedAssociationNeverAdvancesAndRetryIsByteStable() async throws {
        for mode in [ScalarFixtureState.Fault.schema, .association] {
            let state = ScalarFixtureState(owner: owner, fault: mode)
            let coordinator = PushCoordinator(source: ScalarFixtureSource(), transport: state, progress: state,
                sourceId: sourceID, receiptOwner: owner,
                associateInlineReceipt: { batch, receipt in try await state.associate(batch, receipt) })
            let failed = await coordinator.pushAppend(.stepSample, deviceId: "device", protocolVersion: "1.4")
            guard case .rejected = failed else { return XCTFail("invalid receipt or failed association must retain progress") }
            let cursor = await state.cursor(table: .stepSample, deviceId: "device")
            XCTAssertNil(cursor)
            await state.setFault(nil)
            let retry = await coordinator.pushAppend(.stepSample, deviceId: "device", protocolVersion: "1.4")
            guard case .accepted = retry else { return XCTFail("expected successful exact retry") }
            let bodies = await state.bodies
            XCTAssertEqual(bodies.count, 2); XCTAssertEqual(bodies.first, bodies.last)
        }
    }

    func testKnownProvenanceIsHeldBeforeTransportForOlderReceiver() async throws {
        let state = ScalarFixtureState(owner: owner)
        let coordinator = PushCoordinator(source: ScalarFixtureSource(knownProvenance: true), transport: state, progress: state,
            sourceId: sourceID, receiptOwner: owner,
            associateInlineReceipt: { batch, receipt in try await state.associate(batch, receipt) })
        let result = await coordinator.pushAppend(.stepSample, deviceId: "device", protocolVersion: "1.3")
        guard case .rejected = result else { return XCTFail("known provenance must not downgrade") }
        let events = await state.events
        XCTAssertTrue(events.isEmpty)
        let accepted = await coordinator.pushAppend(.stepSample, deviceId: "device", protocolVersion: "1.4")
        guard case .accepted = accepted else { return XCTFail("negotiated provenance should be sent") }
    }
}

private struct ScalarFixtureSource: PushSnapshotSource {
    var knownProvenance = false
    func knownDeviceIds(capabilities: PushCapabilities) async throws -> [String] { ["device"] }
    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) async throws -> PushAppendRecord? {
        rowId == 1 ? row(table) : nil
    }
    func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushAppendRecord] {
        afterRowId < 1 ? [row(table)] : []
    }
    private func row(_ table: PushAppendTable) -> PushAppendRecord {
        var data: [String: PushJSONValue]
        switch table {
        case .stepSample: data = ["counter": .int(65535), "activityClass": .null]
        case .sleepStateSample: data = ["state": .int(2), "rawByte": .int(32)]
        case .ppgHrSample: data = ["bpm": .int(65), "conf": .null]
        default: preconditionFailure("scalar fixture")
        }
        if knownProvenance { data["provenance"] = .map(["v": .int(1), "origin": .string("whoop-v18")]) }
        return .init(rowId: 1, key: ["ts": .int(100)], data: data)
    }
    func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) async throws -> [PushMutableRecord] { [] }
    func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) async throws -> PushBinaryRow? { nil }
    func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushBinaryRow] { [] }
    func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) async throws {}
}

private actor ScalarFixtureState: PushProgressStore, PushTransport {
    enum Fault { case schema, association }
    let owner: AccountScope
    var fault: Fault?
    var events: [String] = []
    var bodies: [Data] = []
    var cursors: [PushAppendTable: PushCursor] = [:]
    var associated: Set<String> = []
    init(owner: AccountScope, fault: Fault? = nil) { self.owner = owner; self.fault = fault }
    func setFault(_ value: Fault?) { fault = value }
    func knownDeviceIds() -> Set<String> { ["device"] }
    func rememberDeviceId(_ deviceId: String) {}
    func cursor(table: PushAppendTable, deviceId: String) -> PushCursor? { cursors[table] }
    func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) throws {
        guard associated.contains(table.wireName) else { throw PushProtocolException("cursor before receipt") }
        cursors[table] = cursor; events.append("cursor:" + table.wireName)
    }
    func binaryCursor(table: PushBinaryTable, deviceId: String) -> PushCursor? { nil }
    func saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) {}
    func window(table: PushMutableTable, deviceId: String) -> PushWindowProgress? { nil }
    func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) {}
    func associate(_ batch: PushBatch, _ receipt: PushDurabilityReceipt) throws {
        if fault == .association { throw PushProtocolException("injected association failure") }
        guard receipt.matches(batch, owner: owner) else { throw PushProtocolException("invalid receipt") }
        associated.insert(batch.table.wireName); events.append("receipt:" + batch.table.wireName)
    }
    func post(_ batch: PushBatch) throws -> PushTransportResponse {
        events.append("post:" + batch.table.wireName + ":" + batch.protocolVersion)
        bodies.append(batch.body)
        let receipt: [String: Any] = ["version": 1, "state": "verified_indexed",
            "receiptId": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "ownerUserId": owner.userID,
            "deviceId": PushDurabilityReceipt.canonicalDevice(owner: owner.userID, device: batch.deviceId),
            "objectId": batch.batchId, "batchId": batch.batchId, "sourceId": batch.sourceId,
            "stream": batch.table.wireName, "schemaVersion": fault == .schema ? 1 : 2,
            "objectKey": "fixture/verified", "contentSha256": PushDurabilityReceipt.sha256(batch.body),
            "wireSha256": String(repeating: "a", count: 64), "compressedBytes": 128,
            "uncompressedBytes": batch.body.count, "verifiedAt": "2026-09-18T00:00:00Z", "indexedAt": "2026-09-18T00:00:01Z"]
        let cursor = batch.endCursor!
        let ack: [String: Any] = ["protocolVersion": batch.protocolVersion, "batchId": batch.batchId,
            "stream": batch.table.wireName, "deviceId": batch.deviceId,
            "endCursor": ["rowId": cursor.rowId, "keySha256": cursor.naturalKeyFingerprint],
            "acceptedRows": batch.recordCount, "status": "accepted", "durabilityReceipt": receipt]
        return .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: ack, options: [.sortedKeys]))
    }
    func postBinary(_ batch: PushBinaryBatch) throws -> PushTransportResponse { throw PushProtocolException("not scalar") }
}
