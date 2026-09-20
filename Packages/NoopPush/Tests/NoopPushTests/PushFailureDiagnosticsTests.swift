import XCTest
@testable import NoopPush

final class PushFailureDiagnosticsTests: XCTestCase {
    func testHRSuccessAndPacketFailureKeepIndependentCursorsAndRetrySamePacket() async throws {
        let progress = DiagnosticProgress()
        let transport = DiagnosticTransport()
        let coordinator = PushCoordinator(source: DiagnosticSource(), transport: transport,
            progress: progress, sourceId: "3a3486dd-5030-4e17-a00d-a781399890f9")
        let caps = PushCapabilities(appendTables: [.hrSample, .rrPacketProvenance], mutableTables: [], binaryTables: [])
        let result = await coordinator.pushKnownDevices(capabilities: caps, binaryEnabled: false)
        XCTAssertEqual(result.acceptedBatches, 1)
        XCTAssertEqual(result.rejectedBatches, 1)
        XCTAssertTrue(result.hasRetryableFailure)
        XCTAssertEqual(result.failure?.stream, "rrPacketProvenance")
        XCTAssertEqual(result.failure?.stage, "projection")
        XCTAssertEqual(result.failure?.correlationId, "65ae1df8-84ca-4d30-978d-e92c6c2647ed")
        let hrCursor = await progress.cursor(table: .hrSample, deviceId: "private-device")
        let rrCursor = await progress.cursor(table: .rrPacketProvenance, deviceId: "private-device")
        XCTAssertEqual(hrCursor?.rowId, 1)
        XCTAssertNil(rrCursor)
        XCTAssertFalse(result.failure!.safeDiagnosticSummary!.contains("private-device"))
        await transport.allowPacket()
        let retry = await coordinator.pushKnownDevices(capabilities: caps, binaryEnabled: false)
        XCTAssertEqual(retry.acceptedBatches, 1)
        XCTAssertEqual(retry.rejectedBatches, 0)
        let finalCursor = await progress.cursor(table: .rrPacketProvenance, deviceId: "private-device")
        XCTAssertEqual(finalCursor?.rowId, 1)
        let packetBodies = await transport.packetBodies
        XCTAssertEqual(packetBodies.count, 2)
        XCTAssertEqual(packetBodies[0], packetBodies[1], "Diagnostics must not change deterministic retry identity")
    }

    func testUntrustedDiagnosticStringsAreDiscardedAndStreamComesFromLocalBatch() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "error", "protocolVersion": "1.1", "code": "push_failed",
            "stream": "hrSample", "stage": "SELECT health FROM secret", "correlationId": "token-secret",
        ])
        let failure = PushError.httpFailure(status: 500, body: data, expectedVersion: "1.1", table: PushAppendTable.rrPacketProvenance)
        XCTAssertEqual(failure.safeDiagnosticSummary, "stream=rrPacketProvenance")
        XCTAssertEqual(failure.receiverCode, "push_failed")
        XCTAssertTrue(failure.retryable)
        let oversized = Data(repeating: 65, count: PushProtocolLimits.maxAckBytes + 1)
        XCTAssertEqual(PushError.httpFailure(status: 500, body: oversized, expectedVersion: "1.1",
            table: PushAppendTable.rrInterval).safeDiagnosticSummary, "stream=rrInterval")
    }

    func testOldReceiverAndControlledContentionRemainRetryable() {
        for code in ["push_failed", "scoring_input_gate_busy"] {
            let data = Data("{\"type\":\"error\",\"protocolVersion\":\"1.1\",\"code\":\"\(code)\"}".utf8)
            let failure = PushError.httpFailure(status: code == "push_failed" ? 500 : 503,
                body: data, expectedVersion: "1.1", table: PushAppendTable.rrPacketProvenance)
            XCTAssertTrue(failure.retryable)
            XCTAssertEqual(failure.safeDiagnosticSummary, "stream=rrPacketProvenance")
        }
    }

    func testExactInlineAndObjectVersionsRetainDiagnosticsWithoutRelaxingVersionFence() {
        for version in ["1.0", "1.1", "1.2"] {
            let body = Data("""
                {"type":"error","protocolVersion":"\(version)","code":"push_failed","stage":"projection","correlationId":"65ae1df8-84ca-4d30-978d-e92c6c2647ed"}
                """.utf8)
            let failure = PushError.httpFailure(status: 500, body: body, expectedVersion: version,
                table: version == "1.2" ? nil : PushAppendTable.hrSample)
            XCTAssertEqual(failure.stage, "projection")
            XCTAssertEqual(failure.correlationId, "65ae1df8-84ca-4d30-978d-e92c6c2647ed")
            if version == "1.0" { XCTAssertEqual(failure.stream, "hrSample") }
            if version == "1.2" {
                XCTAssertNil(failure.stream)
                XCTAssertEqual(failure.attributed(to: PushBinaryTable.rawBatch).stream, "rawBatch")
            }
            XCTAssertNil(PushError.httpFailure(status: 500, body: body,
                expectedVersion: version == "1.0" ? "1.1" : "1.0").stage)
        }
    }
}

private struct DiagnosticSource: PushSnapshotSource {
    func row(_ table: PushAppendTable) -> PushAppendRecord {
        if table == .hrSample { return PushAppendRecord(rowId: 1, key: ["ts": .int(1700000000)], data: ["bpm": .int(60)]) }
        return PushAppendRecord(rowId: 1, key: ["packetId": .string(String(repeating: "a", count: 64))], data: [
            "ts": .int(1700000000), "sensorTs": .int(1700000000), "recordIndex": .int(0),
            "rawHex": .string(String(repeating: "aa", count: 28)), "srcChannel": .int(5), "schemaVersion": .int(1),
            "decoderVersion": .string("whoop5-v18-original-words-v1"), "clockVersion": .string("sensor-second-unmapped"),
            "timestampPrecisionSeconds": .int(1), "clockOffsetSeconds": .int(0), "declaredCount": .int(3)])
    }
    func knownDeviceIds(capabilities: PushCapabilities) async throws -> [String] { ["private-device"] }
    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) async throws -> PushAppendRecord? { rowId == 1 ? row(table) : nil }
    func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushAppendRecord] { afterRowId < 1 ? [row(table)] : [] }
    func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) async throws -> [PushMutableRecord] { [] }
    func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) async throws -> PushBinaryRow? { nil }
    func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushBinaryRow] { [] }
    func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) async throws {}
}

private actor DiagnosticProgress: PushProgressStore {
    var cursors: [PushAppendTable: PushCursor] = [:]
    func knownDeviceIds() async throws -> Set<String> { [] }
    func rememberDeviceId(_ deviceId: String) async throws {}
    func cursor(table: PushAppendTable, deviceId: String) async -> PushCursor? { cursors[table] }
    func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) async throws { cursors[table] = cursor }
    func binaryCursor(table: PushBinaryTable, deviceId: String) async throws -> PushCursor? { nil }
    func saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) async throws {}
    func window(table: PushMutableTable, deviceId: String) async throws -> PushWindowProgress? { nil }
    func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) async throws {}
}

private actor DiagnosticTransport: PushTransport {
    var packetBodies: [Data] = []
    private var failPacket = true
    func allowPacket() { failPacket = false }
    func post(_ batch: PushBatch) async throws -> PushTransportResponse {
        if batch.table.wireName == "rrPacketProvenance" {
            packetBodies.append(batch.body)
            if failPacket {
                return PushTransportResponse(statusCode: 500, body: Data("""
                    {"type":"error","protocolVersion":"1.1","code":"push_failed","stream":"rrPacketProvenance","stage":"projection","correlationId":"65ae1df8-84ca-4d30-978d-e92c6c2647ed"}
                    """.utf8))
            }
        }
        return PushTransportResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: [
            "acceptedRows": batch.recordCount, "batchId": batch.batchId, "deviceId": batch.deviceId,
            "endCursor": ["keySha256": batch.endCursor!.naturalKeyFingerprint, "rowId": batch.endCursor!.rowId],
            "protocolVersion": batch.protocolVersion, "status": "accepted", "stream": batch.table.wireName,
        ]))
    }
}
