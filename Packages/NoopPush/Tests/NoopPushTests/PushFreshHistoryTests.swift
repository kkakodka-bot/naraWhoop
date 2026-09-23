import Foundation
import XCTest
@testable import NoopPush

final class PushFreshHistoryTests: XCTestCase {
    func testExportActualSwiftFreshHistoryPairs() throws {
        let source = "00000000-0000-4000-8000-000000000071"
        let device = "fresh-history-validation"
        var pairs: [[String: Any]] = []
        for (index, table) in [PushAppendTable.hrSample, .gravitySample].enumerated() {
            for freshFirst in [true, false] {
                let timestamp = Int64(1_788_796_800 + index * 10 + (freshFirst ? 0 : 1))
                let values: [String: PushJSONValue] = table == .hrSample
                    ? ["bpm": .int(62)] : ["x": .double(0.25), "y": .double(0), "z": .double(1), "dynAccel": .null]
                let rows = [PushAppendRecord(rowId: timestamp, key: ["ts": .int(timestamp)], data: values)]
                let history = try PushProtocol.appendBatch(table: table, sourceId: source,
                    deviceId: device, startCursor: nil, records: rows)
                let fresh = try PushProtocol.appendBatch(table: table, sourceId: source,
                    deviceId: device, startCursor: nil, records: rows, freshAppend: true)
                XCTAssertNotEqual(history.batchId, fresh.batchId)
                XCTAssertEqual(history.body.split(separator: 10).dropFirst(), fresh.body.split(separator: 10).dropFirst())
                let bodies: [String: Any] = Dictionary(uniqueKeysWithValues: [("fresh", fresh), ("history", history)].map { lane, batch in
                    (lane, ["batchId": batch.batchId, "bodyBase64": batch.body.base64EncodedString(),
                            "bodySha256": PushDurabilityReceipt.sha256(batch.body)] as [String: Any])
                })
                pairs.append(["stream": table.wireName, "timestamp": timestamp,
                    "arrivalOrder": freshFirst ? ["fresh", "history"] : ["history", "fresh"], "bodies": bodies])
            }
        }
        XCTAssertEqual(pairs.count, 4)
        if let directory = ProcessInfo.processInfo.environment["NOOP_FRESH_HISTORY_FIXTURES"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let artifact: [String: Any] = ["schemaVersion": 1, "syntheticOnly": true,
                "sourceId": source, "deviceId": device, "producer": "actual_swift_PushProtocol_appendBatch", "pairs": pairs]
            try JSONSerialization.data(withJSONObject: artifact, options: [.sortedKeys, .prettyPrinted])
                .write(to: output.appendingPathComponent("fresh-history.json"), options: .atomic)
        }
    }

    func testRecentRowsReachFirstShortWakeWithoutAdvancingHistory() async throws {
        let fixture = FreshHistoryFixture()
        let coordinator = PushCoordinator(source: fixture, transport: fixture, progress: fixture,
            sourceId: "11111111-1111-4111-8111-111111111111", today: { Date(timeIntervalSince1970: 20_000) },
            wakeBudget: PushWakeBudget(rowsPerJob: 1, maximumRequests: 1))
        _ = await coordinator.pushKnownDevices(capabilities: .init(appendTables: [.hrSample], mutableTables: []))
        let sent = await fixture.sent, history = await fixture.history, fresh = await fixture.fresh
        XCTAssertEqual(sent.first?.endCursor?.rowId, 10_001, "recent input must not wait for the ten-thousand-row history")
        XCTAssertNil(history, "a fresh receipt must not skip unacknowledged history")
        XCTAssertEqual(fresh?.rowId, 10_001)
    }
    func testSharedAndroidSwiftFreshIdentityGolden() throws {
        let rows: [PushAppendRecord] = [.init(rowId: 1, key: ["ts": .int(100)], data: ["bpm": .int(62)])]
        let history = try PushProtocol.appendBatch(table: .hrSample, sourceId: "00000000-0000-4000-8000-000000000010",
            deviceId: "wearable", startCursor: nil, records: rows)
        let fresh = try PushProtocol.appendBatch(table: .hrSample, sourceId: history.sourceId,
            deviceId: history.deviceId, startCursor: nil, records: rows, freshAppend: true)
        XCTAssertEqual(history.batchId, "c4afd85c-4827-56a8-b6bb-cfb6168339ef")
        XCTAssertEqual(fresh.batchId, "884f3108-6768-54c4-9f1b-82236a5e842b")
        XCTAssertEqual(PushDurabilityReceipt.sha256(history.body), "3301fbc9c97a5e80d53eb50b9158980e9799a52323f0d6f130558643390f7a8f")
        XCTAssertEqual(PushDurabilityReceipt.sha256(fresh.body), "d0ecbd8c3caece9fd34d90d662795e0a199e43f3d652628fc63ca8ca7fa1a6a7")
    }

    func testFreshAndHistorySameRowsHaveDifferentStableIDsAndRetainOriginalWireTimes() throws {
        let rows: [PushAppendRecord] = [.init(rowId: 1, key: ["ts": .int(19_999)], data: ["bpm": .int(60)])]
        let history = try PushProtocol.appendBatch(table: .hrSample, sourceId: "11111111-1111-4111-8111-111111111111",
            deviceId: "device", startCursor: nil, records: rows)
        let fresh = try PushProtocol.appendBatch(table: .hrSample, sourceId: history.sourceId,
            deviceId: history.deviceId, startCursor: nil, records: rows, freshAppend: true, maximumDecodedBytes: 65_536)
        XCTAssertNotEqual(fresh.batchId, history.batchId)
        XCTAssertThrowsError(try PushPreparedSelection(inline: [history], commit: .init(kind: .freshAppend,
            table: "hrSample", deviceID: "device", batchIDs: [history.batchId], cursor: history.endCursor)))
        XCTAssertEqual(fresh.endCursor, history.endCursor)
        XCTAssertEqual(fresh.body.split(separator: 10).dropFirst(), history.body.split(separator: 10).dropFirst())
        XCTAssertFalse(String(decoding: fresh.body, as: UTF8.self).contains("identityDomain"))
        let selection = try PushPreparedSelection(inline: [fresh], commit: .init(kind: .freshAppend,
            table: "hrSample", deviceID: "device", batchIDs: [fresh.batchId], cursor: fresh.endCursor))
        let restored = try JSONDecoder().decode(PushPreparedSelection.self, from: JSONEncoder().encode(selection))
        XCTAssertEqual(try restored.restoredInlineBatches().first?.body, fresh.body)
        XCTAssertEqual(restored.commit.kind, .freshAppend)
        enum LegacyKind: String, Decodable { case append, binary, mutable }
        XCTAssertThrowsError(try JSONDecoder().decode(LegacyKind.self, from: Data("\"freshAppend\"".utf8)))
    }

    func testShortWakesRotateAndEventuallyDrainHistoryWithoutJumpingItsCursor() async throws {
        let fixture = FreshHistoryFixture(historyCount: 6)
        var position = FreshPosition()
        for _ in 0..<12 {
            // Recreate coordinator and JSON-roundtrip checkpoint, as after process recreation.
            position = try JSONDecoder().decode(FreshPosition.self, from: JSONEncoder().encode(position))
            let coordinator = PushCoordinator(source: fixture, transport: fixture, progress: fixture,
                sourceId: "11111111-1111-4111-8111-111111111111", today: { Date(timeIntervalSince1970: 20_000) },
                wakeBudget: PushWakeBudget(rowsPerJob: 2, maximumRequests: 1))
            let run = await coordinator.pushKnownDevices(startDeviceIndex: position.device, startLaneIndex: position.lane,
                expectedDeviceListFingerprint: position.fingerprint, capabilities: .init(appendTables: [.hrSample], mutableTables: []))
            position = .init(device: run.nextDeviceIndex, lane: run.nextLaneIndex, fingerprint: run.deviceListFingerprint)
        }
        let sent = await fixture.sent, history = await fixture.history
        XCTAssertEqual(sent.map { $0.endCursor!.rowId }, [7, 2, 4, 6, 7])
        XCTAssertEqual(history?.rowId, 7)
        XCTAssertNotEqual(sent.first!.batchId, sent.last!.batchId)
    }

    func testFailureAdvancesDurableSchedulingButNeverSourceProgress() async throws {
        let fixture = FreshHistoryFixture(historyCount: 2, failFirst: true)
        let checkpoints = FreshCheckpoints()
        let first = await PushCoordinator(source: fixture, transport: fixture, progress: fixture,
            sourceId: "11111111-1111-4111-8111-111111111111", today: { Date(timeIntervalSince1970: 20_000) },
            wakeBudget: PushWakeBudget(rowsPerJob: 1, maximumRequests: 1))
            .pushKnownDevices(capabilities: .init(appendTables: [.hrSample], mutableTables: []), checkpoint: { d, l, r, f in
                await checkpoints.save(.init(device: d, lane: l, fingerprint: f))
            })
        XCTAssertTrue(first.hasRetryableFailure)
        let failedFresh = await fixture.fresh, failedHistory = await fixture.history
        XCTAssertNil(failedFresh); XCTAssertNil(failedHistory)
        let persisted = await checkpoints.last
        let saved = try XCTUnwrap(persisted)
        XCTAssertEqual(saved.lane, 1)
        _ = await PushCoordinator(source: fixture, transport: fixture, progress: fixture,
            sourceId: "11111111-1111-4111-8111-111111111111", today: { Date(timeIntervalSince1970: 20_000) },
            wakeBudget: PushWakeBudget(rowsPerJob: 1, maximumRequests: 1))
            .pushKnownDevices(startDeviceIndex: saved.device, startLaneIndex: saved.lane,
                expectedDeviceListFingerprint: saved.fingerprint, capabilities: .init(appendTables: [.hrSample], mutableTables: []))
        let history = await fixture.history
        XCTAssertEqual(history?.rowId, 1)
    }

    func testPartialDiscoveryShipsKnownDeviceAndKeepsDiscoveryDebt() async {
        let fixture = FreshHistoryFixture(historyCount: 1, discoveryComplete: false)
        let result = await PushCoordinator(source: fixture, transport: fixture, progress: fixture,
            sourceId: "11111111-1111-4111-8111-111111111111", today: { Date(timeIntervalSince1970: 20_000) })
            .pushKnownDevices(capabilities: .init(appendTables: [.hrSample], mutableTables: []))
        XCTAssertGreaterThan(result.acceptedBatches, 0)
        XCTAssertFalse(result.discoveryComplete); XCTAssertTrue(result.hasMoreAppendRows)
    }

    func testBulkDeferralDoesNotBlockFreshAndRetainsHistoryDebt() async {
        let fixture = FreshHistoryFixture(historyCount: 3)
        let result = await PushCoordinator(source: fixture, transport: fixture, progress: fixture,
            sourceId: "11111111-1111-4111-8111-111111111111", today: { Date(timeIntervalSince1970: 20_000) })
            .pushKnownDevices(capabilities: .init(appendTables: [.hrSample], mutableTables: []), allowsHistoricalPreparation: { false })
        let history = await fixture.history, fresh = await fixture.fresh
        XCTAssertNil(history); XCTAssertEqual(fresh?.rowId, 4)
        XCTAssertTrue(result.hasMoreAppendRows)
    }

    func testDirectFreshEncoderAndSavedSelectionEnforceBounds() throws {
        let rows: [PushAppendRecord] = (1...200).map { .init(rowId: Int64($0), key: ["ts": .int(Int64($0))], data: ["bpm": .int(60)]) }
        let history = try PushProtocol.appendBatch(table: .hrSample, sourceId: "11111111-1111-4111-8111-111111111111",
            deviceId: "device", startCursor: nil, records: rows)
        let fresh = try PushProtocol.appendBatch(table: .hrSample, sourceId: history.sourceId,
            deviceId: history.deviceId, startCursor: nil, records: rows, freshAppend: true)
        XCTAssertEqual(history.recordCount, 200); XCTAssertEqual(fresh.recordCount, 128)
        XCTAssertThrowsError(try PushPreparedSelection(inline: [history], commit: .init(kind: .freshAppend,
            table: "hrSample", deviceID: "device", batchIDs: [history.batchId], cursor: history.endCursor)))
        let oversized: [PushAppendRecord] = [.init(rowId: 1, key: ["ts": .int(1), "kind": .string("fixture")],
            data: ["payloadJSON": .string(String(repeating: "x", count: 65_536))])]
        XCTAssertThrowsError(try PushProtocol.appendBatch(table: .event, sourceId: history.sourceId,
            deviceId: history.deviceId, startCursor: nil, records: oversized, freshAppend: true))
    }

    func testFreshPreparationCapsRowsAndActualDecodedBody() async throws {
        let fixture = FreshHistoryFixture(historyCount: 0)
        for timestamp in 19700..<19999 { await fixture.addRecent(timestamp: Int64(timestamp)) }
        let result = await PushCoordinator(source: fixture, transport: fixture, progress: fixture,
            sourceId: "11111111-1111-4111-8111-111111111111", today: { Date(timeIntervalSince1970: 20_000) })
            .pushFreshAppend(.hrSample, deviceId: "device")
        guard case .accepted(_, let count, let more, _) = result else { return XCTFail("fresh batch was not accepted") }
        let sent = await fixture.sent
        XCTAssertEqual(count, 128); XCTAssertTrue(more)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sent.first).body.count, 65536)
        let history = await fixture.history; XCTAssertNil(history)
    }

    func testContinuouslyArrivingHRAndGravityGetBoundedTurnsDespiteBusyHistory() async throws {
        let fixture = FreshHistoryFixture(historyCount: 1000)
        var position = FreshPosition(), hrWakes: [Int] = [], gravityWakes: [Int] = [], historicalPosts = 0
        for wake in 0..<24 {
            await fixture.addRecent(timestamp: Int64(20_000 + wake))
            let before = await fixture.sent.count
            let now = Date(timeIntervalSince1970: Double(20_000 + wake))
            let run = await PushCoordinator(source: fixture, transport: fixture, progress: fixture,
                sourceId: "11111111-1111-4111-8111-111111111111", today: { now },
                wakeBudget: PushWakeBudget(rowsPerJob: 128, maximumRequests: 1))
                .pushKnownDevices(startDeviceIndex: position.device, startLaneIndex: position.lane,
                    expectedDeviceListFingerprint: position.fingerprint,
                    capabilities: .init(appendTables: [.hrSample, .gravitySample, .battery, .event], mutableTables: []))
            position = .init(device: run.nextDeviceIndex, lane: run.nextLaneIndex, fingerprint: run.deviceListFingerprint)
            let batches = await fixture.sent
            XCTAssertEqual(batches.count, before + 1)
            let batch = try XCTUnwrap(batches.last)
            if batch.endCursor!.rowId <= 1000 { historicalPosts += 1 }
            else if batch.table.wireName == "hrSample" { hrWakes.append(wake) }
            else if batch.table.wireName == "gravitySample" { gravityWakes.append(wake) }
        }
        XCTAssertGreaterThan(historicalPosts, 0, "fresh arrival must not starve historical acknowledgements")
        for services in [hrWakes, gravityWakes] {
            XCTAssertGreaterThan(services.count, 3)
            XCTAssertLessThanOrEqual(try XCTUnwrap(services.first), 1)
            XCTAssertTrue(zip(services, services.dropFirst()).allSatisfy { $1 - $0 <= 4 }, "service turns: \(services)")
        }
    }

    func testPreparedHistoryCannotPreemptFreshAndGetsItsNextTurn() async {
        let fixture = FreshHistoryFixture(historyCount: 3), resumed = FreshCheckpoints()
        let pending = PushPendingLane(selectionID: "saved-history", kind: .append, table: "hrSample", deviceID: "device")
        let first = await PushCoordinator(source: fixture, transport: fixture, progress: fixture,
            sourceId: "11111111-1111-4111-8111-111111111111", today: { Date(timeIntervalSince1970: 20_000) },
            wakeBudget: PushWakeBudget(maximumRequests: 1)).pushKnownDevices(
                capabilities: .init(appendTables: [.hrSample], mutableTables: []), pendingLanes: [pending], resumePreparedLane: { _ in
                    await resumed.save(.init()); return .rejected(reason: "offline", retryable: true, failure: nil)
                })
        let before = await resumed.last; XCTAssertNil(before)
        _ = await PushCoordinator(source: fixture, transport: fixture, progress: fixture,
            sourceId: "11111111-1111-4111-8111-111111111111", today: { Date(timeIntervalSince1970: 20_000) },
            wakeBudget: PushWakeBudget(maximumRequests: 1)).pushKnownDevices(startDeviceIndex: first.nextDeviceIndex,
                startLaneIndex: first.nextLaneIndex, expectedDeviceListFingerprint: first.deviceListFingerprint,
                capabilities: .init(appendTables: [.hrSample], mutableTables: []), pendingLanes: [pending], resumePreparedLane: { _ in
                    await resumed.save(.init()); return .rejected(reason: "offline", retryable: true, failure: nil)
                })
        let after = await resumed.last, history = await fixture.history
        XCTAssertNotNil(after); XCTAssertNil(history)
    }

}

private actor FreshHistoryFixture: PushSnapshotSource, PushProgressStore, PushTransport {
    var histories: [PushAppendTable: PushCursor] = [:]
    var freshCursors: [PushAppendTable: PushCursor] = [:]
    var history: PushCursor? { histories[.hrSample] }
    var fresh: PushCursor? { freshCursors[.hrSample] }
    var sent: [PushBatch] = []
    var rows: [PushAppendRecord]
    let discoveryComplete: Bool
    var failFirst: Bool
    init(historyCount: Int = 10_000, failFirst: Bool = false, discoveryComplete: Bool = true) {
        self.failFirst = failFirst; self.discoveryComplete = discoveryComplete
        rows = (1...(historyCount + 1)).map { index in
            let timestamp: Int64 = index == historyCount + 1 ? 19_999 : Int64(index)
            return PushAppendRecord(rowId: Int64(index), key: ["ts": .int(timestamp)], data: ["bpm": .int(60)])
        }
    }
    func discoverDevices(capabilities: PushCapabilities) -> PushDeviceDiscovery { .init(deviceIDs: ["device"], isComplete: discoveryComplete) }
    func addRecent(timestamp: Int64) {
        rows.append(.init(rowId: (rows.last?.rowId ?? 0) + 1, key: ["ts": .int(timestamp)], data: ["bpm": .int(60)]))
    }
    private func row(_ value: PushAppendRecord, for table: PushAppendTable) -> PushAppendRecord {
        switch table {
        case .gravitySample: return .init(rowId: value.rowId, key: value.key, data: ["x": .double(0), "y": .double(0), "z": .double(1), "dynAccel": .null])
        case .battery: return .init(rowId: value.rowId, key: value.key, data: ["soc": .int(50), "mv": .null, "charging": .bool(false)])
        case .event: return .init(rowId: value.rowId, key: ["ts": value.key["ts"]!, "kind": .string("fixture")], data: ["payloadJSON": .null])
        default: return value
        }
    }
    func knownDeviceIds(capabilities: PushCapabilities) -> [String] { ["device"] }
    func knownDeviceIds() -> Set<String> { ["device"] }
    func rememberDeviceId(_ deviceId: String) {}
    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) -> PushAppendRecord? { rows.first { $0.rowId == rowId }.map { row($0, for: table) } }
    func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) -> [PushAppendRecord] {
        Array(rows.filter { $0.rowId > afterRowId }.prefix(limit)).map { row($0, for: table) }
    }
    func freshAppendPage(table: PushAppendTable, deviceId: String, afterRowId: Int64,
                         sinceTs: Int64, throughTs: Int64, limit: Int, limits: PushSourceReadLimits) -> PushAppendPage {
        let selected = rows.filter { $0.rowId > afterRowId && ($0.key["ts"]?.int64Value ?? 0) >= sinceTs
            && ($0.key["ts"]?.int64Value ?? 0) <= throughTs }
        return .init(rows: Array(selected.prefix(limit)).map { row($0, for: table) }, hasMore: selected.count > limit)
    }
    func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) -> [PushMutableRecord] { [] }
    func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) -> PushBinaryRow? { nil }
    func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) -> [PushBinaryRow] { [] }
    func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) {}
    func cursor(table: PushAppendTable, deviceId: String) -> PushCursor? { histories[table] }
    func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) { histories[table] = cursor }
    func freshCursor(table: PushAppendTable, deviceId: String) -> PushCursor? { freshCursors[table] }
    func saveFreshCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) { freshCursors[table] = cursor }
    func binaryCursor(table: PushBinaryTable, deviceId: String) -> PushCursor? { nil }
    func saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) {}
    func window(table: PushMutableTable, deviceId: String) -> PushWindowProgress? { nil }
    func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) {}
    func post(_ batch: PushBatch) throws -> PushTransportResponse {
        sent.append(batch)
        if failFirst { failFirst = false; throw PushTransportException(PushFailure(code: .networkIO)) }
        let end = batch.endCursor!
        return .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: [
            "protocolVersion": batch.protocolVersion, "batchId": batch.batchId, "stream": batch.table.wireName,
            "deviceId": batch.deviceId, "acceptedRows": batch.recordCount, "status": "accepted",
            "endCursor": ["rowId": end.rowId, "keySha256": end.naturalKeyFingerprint],
        ]))
    }
    func postBinary(_ batch: PushBinaryBatch) throws -> PushTransportResponse { throw PushProtocolException("unexpected binary") }
}

private struct FreshPosition: Codable {
    var device: Int = 0, lane: Int = 0
    var fingerprint: String? = nil
}
private actor FreshCheckpoints {
    var last: FreshPosition?
    func save(_ value: FreshPosition) { last = value }
}
