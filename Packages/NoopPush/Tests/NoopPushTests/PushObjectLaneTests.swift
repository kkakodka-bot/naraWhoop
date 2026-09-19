import XCTest
@testable import NoopPush

private let sourceA = "3a3486dd-5030-4e17-a00d-a781399890f9"

final class PushObjectLaneTests: XCTestCase {
    private func imuColumns(seed: Int16) -> Data {
        var data = Data(count: PushBinaryCodec.imuRecordPayloadBytes)
        for index in 0..<PushBinaryCodec.imuColumnsPerRecord {
            let value = Int16(truncatingIfNeeded: seed + Int16(index))
            data[index * 2] = UInt8(truncatingIfNeeded: value)
            data[index * 2 + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        return data
    }

    func testBinaryObjectOracleLiterals() throws {
        let ppgNoBurstDecoded = try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: [
            .ppgWaveform(PushPpgWaveformRecord(rowId: 5, ts: 50, burstIndex: nil, samples: Data([0x0A]))),
        ])
        XCTAssertEqual(
            ppgNoBurstDecoded.map { String(format: "%02x", $0) }.joined(),
            "4e5042310101010000000500000000000000320000000000000000010000000a"
        )
        let ppgNoBurst = try PushProtocol.binaryObjectBatch(
            table: .ppgWaveformSample, sourceId: sourceA, deviceId: "strap-a", startCursor: nil,
            rows: [.ppgWaveform(PushPpgWaveformRecord(rowId: 5, ts: 50, burstIndex: nil, samples: Data([0x0A])))],
            protocolVersion: PushProtocol.objectVersion,
            decodedLimit: PushProtocolLimits.maxObjectDecodedBytes,
        )
        XCTAssertEqual(ppgNoBurst.contentSha256, "7a4521405729fb0e7ce3c7a8d63c8dad7c2372c7a9738b4eec05fa86fcfb9e8d")
        XCTAssertEqual(ppgNoBurst.batchId, "ef297f52-8888-5262-af98-0ba35b3421be")
        XCTAssertEqual(ppgNoBurst.objectId, "39c2fdd4-c580-5360-b924-fb42d414fda7")

        let imuRow = PushRawImuRecord(rowId: 1_700_000_000, ts: 1_700_000_000, columns: imuColumns(seed: -1))
        let imuDecoded = try PushBinaryCodec.pack(table: .rawImuSession, rows: [.rawImuSession(imuRow)])
        XCTAssertEqual(
            imuDecoded.map { String(format: "%02x", $0) }.joined(),
            "4e50423101040100000000f153650000000000f1536500000000b0040000ffff00000100020003000400050006000700080009000a000b000c000d000e000f0010001100120013001400150016001700180019001a001b001c001d001e001f0020002100220023002400250026002700280029002a002b002c002d002e002f0030003100320033003400350036003700380039003a003b003c003d003e003f0040004100420043004400450046004700480049004a004b004c004d004e004f0050005100520053005400550056005700580059005a005b005c005d005e005f0060006100620063006400650066006700680069006a006b006c006d006e006f0070007100720073007400750076007700780079007a007b007c007d007e007f0080008100820083008400850086008700880089008a008b008c008d008e008f0090009100920093009400950096009700980099009a009b009c009d009e009f00a000a100a200a300a400a500a600a700a800a900aa00ab00ac00ad00ae00af00b000b100b200b300b400b500b600b700b800b900ba00bb00bc00bd00be00bf00c000c100c200c300c400c500c600c700c800c900ca00cb00cc00cd00ce00cf00d000d100d200d300d400d500d600d700d800d900da00db00dc00dd00de00df00e000e100e200e300e400e500e600e700e800e900ea00eb00ec00ed00ee00ef00f000f100f200f300f400f500f600f700f800f900fa00fb00fc00fd00fe00ff0000010101020103010401050106010701080109010a010b010c010d010e010f0110011101120113011401150116011701180119011a011b011c011d011e011f0120012101220123012401250126012701280129012a012b012c012d012e012f0130013101320133013401350136013701380139013a013b013c013d013e013f0140014101420143014401450146014701480149014a014b014c014d014e014f0150015101520153015401550156015701580159015a015b015c015d015e015f0160016101620163016401650166016701680169016a016b016c016d016e016f0170017101720173017401750176017701780179017a017b017c017d017e017f0180018101820183018401850186018701880189018a018b018c018d018e018f0190019101920193019401950196019701980199019a019b019c019d019e019f01a001a101a201a301a401a501a601a701a801a901aa01ab01ac01ad01ae01af01b001b101b201b301b401b501b601b701b801b901ba01bb01bc01bd01be01bf01c001c101c201c301c401c501c601c701c801c901ca01cb01cc01cd01ce01cf01d001d101d201d301d401d501d601d701d801d901da01db01dc01dd01de01df01e001e101e201e301e401e501e601e701e801e901ea01eb01ec01ed01ee01ef01f001f101f201f301f401f501f601f701f801f901fa01fb01fc01fd01fe01ff0100020102020203020402050206020702080209020a020b020c020d020e020f0210021102120213021402150216021702180219021a021b021c021d021e021f0220022102220223022402250226022702280229022a022b022c022d022e022f0230023102320233023402350236023702380239023a023b023c023d023e023f0240024102420243024402450246024702480249024a024b024c024d024e024f025002510252025302540255025602"
        )
        let imu = try PushProtocol.binaryObjectBatch(
            table: .rawImuSession, sourceId: sourceA, deviceId: "strap-a", startCursor: nil,
            rows: [.rawImuSession(imuRow)],
            protocolVersion: PushProtocol.objectVersion,
            decodedLimit: PushProtocolLimits.maxObjectDecodedBytes,
        )
        XCTAssertEqual(imu.contentSha256, "ab4f2f112a7a6838316e017665d70a5c7fdbfd97b575c41c537a853cc3ac78bb")
        XCTAssertEqual(imu.batchId, "ebc28c54-617a-550c-a316-8251b264e688")
        XCTAssertEqual(imu.objectId, "761fc0f5-7d98-5b17-ab49-5aa566447568")
        XCTAssertEqual(imu.sampleCount, 1)
        XCTAssertEqual(
            String(data: try PushObjectManifest(batch: imu).encode(), encoding: .utf8),
            String(data: try PushObjectManifest(batch: imu).encode(), encoding: .utf8)
        )

        let imuWindowRows: [PushBinaryRow] = (0..<3601).map { offset in
            let ts = 1_700_000_000 + Int64(offset)
            return .rawImuSession(PushRawImuRecord(rowId: ts, ts: ts, columns: imuColumns(seed: Int16(offset))))
        }
        let windowBatch = try PushProtocol.binaryObjectBatch(
            table: .rawImuSession, sourceId: sourceA, deviceId: "strap-a", startCursor: nil, rows: imuWindowRows,
            protocolVersion: PushProtocol.objectVersion,
            decodedLimit: PushProtocolLimits.maxObjectDecodedBytes,
        )
        XCTAssertEqual(windowBatch.sampleCount, 3600)

        let ppgBurstRow = PushPpgWaveformRecord(rowId: 10, ts: 100, burstIndex: 2, samples: Data([0x01, 0x02]))
        let ppgBurstDecoded = try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: [.ppgWaveform(ppgBurstRow)])
        XCTAssertEqual(
            ppgBurstDecoded.map { String(format: "%02x", $0) }.joined(),
            "4e5042310101010000000a0000000000000064000000000000000102000000020000000102"
        )
        let ppgBurst = try PushProtocol.binaryObjectBatch(
            table: .ppgWaveformSample, sourceId: sourceA, deviceId: "strap-a", startCursor: nil,
            rows: [.ppgWaveform(ppgBurstRow)],
            protocolVersion: PushProtocol.objectVersion,
            decodedLimit: PushProtocolLimits.maxObjectDecodedBytes,
        )
        XCTAssertEqual(ppgBurst.contentSha256, "97202e61885a87bcd72a78dff3be4d5273d1b4910b752cc007453e45dc62d3b9")
        XCTAssertEqual(ppgBurst.batchId, "b68c8c9e-c055-5326-93a2-f3462f171621")
        XCTAssertEqual(ppgBurst.objectId, "9f16be5d-d1cd-56ca-9f7e-39105c5562c0")

        let v18Row = PushV18AuxRecord(rowId: 1, ts: 10, fields: Data([0xAB]))
        let v18Decoded = try PushBinaryCodec.pack(table: .v18AuxSample, rows: [.v18Aux(v18Row)])
        XCTAssertEqual(
            v18Decoded.map { String(format: "%02x", $0) }.joined(),
            "4e50423101020100000001000000000000000a0000000000000001000000ab"
        )
        let v18 = try PushProtocol.binaryObjectBatch(
            table: .v18AuxSample, sourceId: sourceA, deviceId: "strap", startCursor: nil, rows: [.v18Aux(v18Row)],
            protocolVersion: PushProtocol.objectVersion,
            decodedLimit: PushProtocolLimits.maxObjectDecodedBytes,
        )
        XCTAssertEqual(v18.contentSha256, "74fa28c092a172385f99eacb2826660ff7c47afbe89b1197273aca6176f0bb08")
        XCTAssertEqual(v18.batchId, "4a3f3494-07bc-52f1-baa0-030b3996ffee")
        XCTAssertEqual(v18.objectId, "07982003-53ce-55da-ab08-89c961555278")

        let rawBatchRow = PushRawBatchRecord(
            rowId: 1, batchId: "batch-1", capturedAt: 100, deviceClockRef: 90, wallClockRef: 100,
            startTs: 100, endTs: 200, frameCount: 2, byteSize: 4, framesBlob: Data([0x01, 0x02, 0x03, 0x04])
        )
        let rawBatchDecoded = try PushBinaryCodec.pack(table: .rawBatch, rows: [.rawBatch(rawBatchRow)])
        XCTAssertEqual(
            rawBatchDecoded.map { String(format: "%02x", $0) }.joined(),
            "4e5042310103070062617463682d3164000000000000005a0000000000000064000000000000006400000000000000c80000000000000002000000040000000400000001020304"
        )
        let rawBatch = try PushProtocol.binaryObjectBatch(
            table: .rawBatch, sourceId: sourceA, deviceId: "strap-a", startCursor: nil, rows: [.rawBatch(rawBatchRow)],
            protocolVersion: PushProtocol.objectVersion,
            decodedLimit: PushProtocolLimits.maxObjectDecodedBytes,
        )
        XCTAssertEqual(rawBatch.contentSha256, "cc0e6daf0ff9d5696767968a9faef4c031368bf8a5efdd490520517a34fef749")
        XCTAssertEqual(rawBatch.batchId, "ed3d5ac8-09af-529d-a7a1-b6a56abef5bb")
        XCTAssertEqual(rawBatch.objectId, "22cc7400-3e75-5ed5-bc24-3875d185de70")
    }

    func testResumeAfterKillSkipsPutWhenUploaded() async throws {
        let row = PushRawImuRecord(rowId: 100, ts: 100, columns: imuColumns(seed: 1))
        let batch = try PushProtocol.binaryObjectBatch(
            table: .rawImuSession, sourceId: sourceA, deviceId: "dev", startCursor: nil,
            rows: [.rawImuSession(row)],
            protocolVersion: PushProtocol.objectVersion,
            decodedLimit: PushProtocolLimits.maxObjectDecodedBytes,
        )
        let lane = PushObjectLane(
            endpoint: "/api/push/objects", maxObjectBytes: Int64(PushProtocolLimits.maxObjectWireBytes),
            urlTtlSec: 3600, streams: [.rawImuSession]
        )
        let progress = MemoryObjectProgress()
        try await progress.saveInFlightObject(
            table: .rawImuSession, deviceId: "dev",
            object: PushInFlightObject(
                objectId: batch.objectId, objectKey: "k/resume", contentSha256: batch.contentSha256, uploaded: true
            )
        )
        var intentCalls = 0
        var uploadCalls = 0
        var completeCalls = 0
        let transport = FakeObjectTransport(
            onIntent: { _ in
                intentCalls += 1
                throw PushTransportException(PushFailure(code: .localData))
            },
            onUpload: { _, _ in uploadCalls += 1 },
            onComplete: { _ in
                completeCalls += 1
                return PushObjectAck(
                    objectId: batch.objectId, status: "ready", objectKey: "k/resume", duplicate: false
                )
            }
        )
        let result = await PushCoordinator(
            source: FakeImuSource(rows: [row]),
            transport: transport,
            progress: progress,
            sourceId: sourceA,
        ).pushObjects(.rawImuSession, deviceId: "dev", lane: lane)
        guard case .accepted = result else {
            return XCTFail("expected accepted, got \(result)")
        }
        XCTAssertEqual(intentCalls, 0)
        XCTAssertEqual(uploadCalls, 0)
        XCTAssertEqual(completeCalls, 1)
    }

    func testInvalidObjectManifestIsNonRetryable() async throws {
        let row = PushRawImuRecord(rowId: 100, ts: 100, columns: imuColumns(seed: 1))
        let lane = PushObjectLane(
            endpoint: "/api/push/objects", maxObjectBytes: Int64(PushProtocolLimits.maxObjectWireBytes),
            urlTtlSec: 3600, streams: [.rawImuSession]
        )
        var intentCalls = 0
        let transport = FakeObjectTransport(
            onIntent: { _ in
                intentCalls += 1
                throw PushTransportException(PushFailure.http(status: 400, receiverCode: "invalid_object_manifest"))
            },
            onUpload: { _, _ in XCTFail("upload must not run") },
            onComplete: { _ in XCTFail("complete must not run"); return PushObjectAck(objectId: "", status: "", objectKey: "", duplicate: false) }
        )
        let result = await PushCoordinator(
            source: FakeImuSource(rows: [row]),
            transport: transport,
            progress: MemoryObjectProgress(),
            sourceId: sourceA,
        ).pushObjects(.rawImuSession, deviceId: "dev", lane: lane)
        guard case .rejected(_, let retryable, _) = result else {
            return XCTFail("expected rejection")
        }
        XCTAssertFalse(retryable)
        XCTAssertEqual(intentCalls, 1)
    }

    func testResumeBeforePutReusesObjectKey() async throws {
        let row = PushRawImuRecord(rowId: 100, ts: 100, columns: imuColumns(seed: 1))
        let batch = try PushProtocol.binaryObjectBatch(
            table: .rawImuSession, sourceId: sourceA, deviceId: "dev", startCursor: nil,
            rows: [.rawImuSession(row)],
            protocolVersion: PushProtocol.objectVersion,
            decodedLimit: PushProtocolLimits.maxObjectDecodedBytes,
        )
        let lane = PushObjectLane(
            endpoint: "/api/push/objects", maxObjectBytes: Int64(PushProtocolLimits.maxObjectWireBytes),
            urlTtlSec: 3600, streams: [.rawImuSession]
        )
        let progress = MemoryObjectProgress()
        try await progress.saveInFlightObject(
            table: .rawImuSession, deviceId: "dev",
            object: PushInFlightObject(
                objectId: batch.objectId, objectKey: "k/resume", contentSha256: batch.contentSha256, uploaded: false
            )
        )
        var intentCalls = 0
        var uploadCalls = 0
        var completeCalls = 0
        let transport = FakeObjectTransport(
            onIntent: { _ in
                intentCalls += 1
                return PushObjectIntent(
                    objectId: batch.objectId, objectKey: "k/resume", uploadUrl: "https://b2.example/put",
                    requiredHeaders: [:], expiresAt: nil, duplicate: false
                )
            },
            onUpload: { intent, _ in
                uploadCalls += 1
                XCTAssertEqual(intent.objectKey, "k/resume")
            },
            onComplete: { _ in
                completeCalls += 1
                return PushObjectAck(
                    objectId: batch.objectId, status: "ready", objectKey: "k/resume", duplicate: false
                )
            }
        )
        let result = await PushCoordinator(
            source: FakeImuSource(rows: [row]),
            transport: transport,
            progress: progress,
            sourceId: sourceA,
        ).pushObjects(.rawImuSession, deviceId: "dev", lane: lane)
        guard case .accepted = result else {
            return XCTFail("expected accepted, got \(result)")
        }
        XCTAssertEqual(intentCalls, 1)
        XCTAssertEqual(uploadCalls, 1)
        XCTAssertEqual(completeCalls, 1)
    }

    func testObjectIdConflictRetriesOnceThenGivesUp() async throws {
        let row = PushRawImuRecord(rowId: 100, ts: 100, columns: imuColumns(seed: 1))
        let lane = PushObjectLane(
            endpoint: "/api/push/objects", maxObjectBytes: Int64(PushProtocolLimits.maxObjectWireBytes),
            urlTtlSec: 3600, streams: [.rawImuSession]
        )
        var intentCalls = 0
        let transport = FakeObjectTransport(
            onIntent: { _ in
                intentCalls += 1
                throw PushTransportException(PushFailure.http(status: 409, receiverCode: "object_id_conflict"))
            },
            onUpload: { _, _ in XCTFail("upload must not run") },
            onComplete: { _ in XCTFail("complete must not run"); return PushObjectAck(objectId: "", status: "", objectKey: "", duplicate: false) }
        )
        let result = await PushCoordinator(
            source: FakeImuSource(rows: [row]),
            transport: transport,
            progress: MemoryObjectProgress(),
            sourceId: sourceA,
        ).pushObjects(.rawImuSession, deviceId: "dev", lane: lane)
        guard case .rejected(_, let retryable, _) = result else {
            return XCTFail("expected rejection")
        }
        XCTAssertFalse(retryable)
        XCTAssertEqual(intentCalls, 2)
    }

    func testObjectLaneUnavailableIsRetryable() async throws {
        let row = PushRawImuRecord(rowId: 100, ts: 100, columns: imuColumns(seed: 1))
        let lane = PushObjectLane(
            endpoint: "/api/push/objects", maxObjectBytes: Int64(PushProtocolLimits.maxObjectWireBytes),
            urlTtlSec: 3600, streams: [.rawImuSession]
        )
        let transport = FakeObjectTransport(
            onIntent: { _ in
                throw PushTransportException(PushFailure.http(status: 503, receiverCode: "object_lane_unavailable"))
            },
            onUpload: { _, _ in XCTFail("upload must not run") },
            onComplete: { _ in XCTFail("complete must not run"); return PushObjectAck(objectId: "", status: "", objectKey: "", duplicate: false) }
        )
        let result = await PushCoordinator(
            source: FakeImuSource(rows: [row]),
            transport: transport,
            progress: MemoryObjectProgress(),
            sourceId: sourceA,
        ).pushObjects(.rawImuSession, deviceId: "dev", lane: lane)
        guard case .rejected(_, let retryable, _) = result else {
            return XCTFail("expected rejection")
        }
        XCTAssertTrue(retryable)
    }

    func testCapabilityAbsenceRetainsBinaryRows() async {
        let caps = PushCapabilities(
            appendTables: [], mutableTables: [], binaryTables: [.rawImuSession],
            protocolVersion: PushProtocol.objectVersion, receiverStateId: PushCapabilities.unscopedReceiverStateId,
            objectLane: nil
        )
        let result = await PushCoordinator(
            source: FakeImuSource(rows: []),
            transport: FakeObjectTransport(),
            progress: MemoryObjectProgress(),
            sourceId: sourceA,
        ).pushKnownDevices(capabilities: caps, binaryEnabled: true)
        XCTAssertEqual(result.acceptedBatches, 0)
        XCTAssertFalse(result.hasMoreBinaryRows)
    }
}

private struct FakeImuSource: PushSnapshotSource {
    let rows: [PushRawImuRecord]
    func knownDeviceIds(capabilities: PushCapabilities) async throws -> [String] { ["dev"] }
    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) async throws -> PushAppendRecord? { nil }
    func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushAppendRecord] { [] }
    func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) async throws -> [PushMutableRecord] { [] }
    func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) async throws -> PushBinaryRow? { nil }
    func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushBinaryRow] {
        rows.filter { $0.ts > afterRowId }.prefix(limit).map { .rawImuSession($0) }
    }
    func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) async throws {}
}

private final class MemoryObjectProgress: PushProgressStore {
    private var inflight: [String: PushInFlightObject] = [:]
    func knownDeviceIds() async throws -> Set<String> { [] }
    func rememberDeviceId(_ deviceId: String) async throws {}
    func cursor(table: PushAppendTable, deviceId: String) async throws -> PushCursor? { nil }
    func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) async throws {}
    func binaryCursor(table: PushBinaryTable, deviceId: String) async throws -> PushCursor? { nil }
    func saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) async throws {}
    func window(table: PushMutableTable, deviceId: String) async throws -> PushWindowProgress? { nil }
    func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) async throws {}
    func inFlightObject(table: PushBinaryTable, deviceId: String) async throws -> PushInFlightObject? {
        inflight["\(table.wireName).\(deviceId)"]
    }
    func saveInFlightObject(table: PushBinaryTable, deviceId: String, object: PushInFlightObject?) async throws {
        let key = "\(table.wireName).\(deviceId)"
        if let object { inflight[key] = object } else { inflight.removeValue(forKey: key) }
    }
}

private struct FakeObjectTransport: PushTransport {
    var onIntent: (PushObjectManifest) async throws -> PushObjectIntent = { _ in
        throw PushTransportException(PushFailure(code: .localData))
    }
    var onUpload: (PushObjectIntent, Data) async throws -> Void = { _, _ in }
    var onComplete: (String) async throws -> PushObjectAck = { _ in
        throw PushTransportException(PushFailure(code: .localData))
    }
    func post(_ batch: PushBatch) async throws -> PushTransportResponse {
        throw PushTransportException(PushFailure(code: .localData))
    }
    func createObjectIntent(_ manifest: PushObjectManifest, lane: PushObjectLane) async throws -> PushObjectIntent {
        try await onIntent(manifest)
    }
    func uploadObject(_ intent: PushObjectIntent, body: Data) async throws {
        try await onUpload(intent, body)
    }
    func completeObject(objectId: String, lane: PushObjectLane) async throws -> PushObjectAck {
        try await onComplete(objectId)
    }
}
