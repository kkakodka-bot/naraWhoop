import XCTest
@testable import NoopPush

private let sourceA = "3a3486dd-5030-4e17-a00d-a781399890f9"

final class PushBinaryProtocolTests: XCTestCase {
    func testSingleSecondRawCaptureGetsHalfOpenManifestAndRetainsOriginalEvidenceOnRetry() throws {
        let row = rawCapture(start: 1_700_000_000, end: 1_700_000_000)
        let rows: [PushBinaryRow] = [.rawBatch(row)]
        let decoded = try PushBinaryCodec.pack(table: .rawBatch, rows: rows)
        XCTAssertEqual(decoded.map { String(format: "%02x", $0) }.joined(),
            "4e5042310103070062617463682d3164000000000000005a00000000000000640000000000000000f153650000000000f153650000000002000000040000000400000001020304")
        let first = try rawObject(row)
        let retry = try rawObject(row)
        XCTAssertEqual(first.startTs, 1_700_000_000)
        XCTAssertEqual(first.endTs, 1_700_000_001)
        XCTAssertEqual(first.sampleCount, 2)
        XCTAssertEqual(first.contentSha256, "81e90626f5f4bfef74c2da704ec899e08eb4655d5d60624116521efef4968d42")
        XCTAssertEqual(first.batchId, "66e88d6c-184b-562d-a049-24e59feaf04a")
        XCTAssertEqual(first.objectId, "4b2e1680-76d5-56bd-89ae-419dae696a57")
        XCTAssertEqual(first.manifestJSON, retry.manifestJSON)
        XCTAssertEqual(first.payload, retry.payload)
        XCTAssertEqual(first.payload, try PushBinaryCompression.compressObject(decoded, encoding: "zstd"))
        XCTAssertNil(first.endCursor)
        XCTAssertNil(retry.endCursor)
        let manifest = try JSONSerialization.jsonObject(with: first.manifestJSON) as! [String: Any]
        XCTAssertEqual((manifest["endTs"] as? NSNumber)?.int64Value, 1_700_000_001)
        XCTAssertNil(manifest["coverage"], "Capture indexing must not assert sensor continuity")
    }

    func testMultiSecondRawCaptureKeepsPackedInclusiveEndAndMatchesKotlinIdentity() throws {
        let row = rawCapture(start: 100, end: 200)
        let decoded = try PushBinaryCodec.pack(table: .rawBatch, rows: [.rawBatch(row)])
        XCTAssertEqual(decoded.map { String(format: "%02x", $0) }.joined(),
            "4e5042310103070062617463682d3164000000000000005a0000000000000064000000000000006400000000000000c80000000000000002000000040000000400000001020304")
        let batch = try rawObject(row)
        XCTAssertEqual(batch.startTs, 100)
        XCTAssertEqual(batch.endTs, 201)
        XCTAssertEqual(batch.contentSha256, "cc0e6daf0ff9d5696767968a9faef4c031368bf8a5efdd490520517a34fef749")
        XCTAssertEqual(batch.batchId, "ed3d5ac8-09af-529d-a7a1-b6a56abef5bb")
        XCTAssertEqual(batch.objectId, "22cc7400-3e75-5ed5-bc24-3875d185de70")
        XCTAssertNil(batch.endCursor)
    }

    func testRawCaptureBoundsRejectReversalAndOverflowWithoutTrapOrWrap() {
        for row in [rawCapture(start: 101, end: 100), rawCapture(start: 100, end: Int64.max)] {
            XCTAssertThrowsError(try rawObject(row)) { XCTAssertTrue($0 is PushProtocolException) }
        }
    }

    private func rawCapture(start: Int64, end: Int64) -> PushRawBatchRecord {
        PushRawBatchRecord(rowId: 1, batchId: "batch-1", capturedAt: 100, deviceClockRef: 90,
            wallClockRef: 100, startTs: start, endTs: end, frameCount: 2, byteSize: 4,
            framesBlob: Data([1, 2, 3, 4]))
    }

    private func rawObject(_ row: PushRawBatchRecord) throws -> PushBinaryBatch {
        try PushProtocol.binaryObjectBatch(table: .rawBatch, sourceId: sourceA, deviceId: "strap-a",
            startCursor: nil, rows: [.rawBatch(row)], protocolVersion: PushProtocol.objectVersion,
            decodedLimit: PushProtocolLimits.maxObjectDecodedBytes)
    }

    func testPpgBinaryObjectIsDeterministic() throws {
        let rows: [PushBinaryRow] = [
            .ppgWaveform(PushPpgWaveformRecord(rowId: 10, ts: 100, burstIndex: 2, samples: Data([0x01, 0x02]))),
            .ppgWaveform(PushPpgWaveformRecord(rowId: 11, ts: 101, burstIndex: nil, samples: Data([0x03]))),
        ]
        let first = try PushProtocol.binaryObjectBatch(
            table: .ppgWaveformSample, sourceId: sourceA, deviceId: "strap-a", startCursor: nil, rows: rows
        )
        let retry = try PushProtocol.binaryObjectBatch(
            table: .ppgWaveformSample, sourceId: sourceA, deviceId: "strap-a", startCursor: nil, rows: rows
        )
        XCTAssertEqual(first.batchId, retry.batchId)
        XCTAssertEqual(first.objectId, retry.objectId)
        XCTAssertEqual(first.contentSha256, retry.contentSha256)
        XCTAssertEqual(first.payload, retry.payload)
        XCTAssertEqual("gzip", first.contentEncoding)
        let manifest = try JSONSerialization.jsonObject(with: first.manifestJSON) as! [String: Any]
        XCTAssertEqual("binaryObject", manifest["type"] as? String)
        XCTAssertEqual("ppgWaveformSample", manifest["stream"] as? String)
        XCTAssertEqual(2, manifest["sampleCount"] as? Int)
    }

    func testBinaryAckMatchesBatch() throws {
        let batch = try PushProtocol.binaryObjectBatch(
            table: .v18AuxSample,
            sourceId: sourceA,
            deviceId: "strap",
            startCursor: nil,
            rows: [.v18Aux(PushV18AuxRecord(rowId: 1, ts: 10, fields: Data([0xAB])))],
        )
        let ack = PushAck(
            protocolVersion: batch.protocolVersion,
            batchId: batch.batchId,
            stream: batch.wireName,
            deviceId: batch.deviceId,
            endCursor: batch.endCursor,
            acceptedRows: batch.sampleCount,
            status: "accepted"
        )
        XCTAssertTrue(ack.exactlyMatches(batch))
    }

    func testBinaryObjectOracleLiteralsMatchKotlin() throws {
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
    }
}
