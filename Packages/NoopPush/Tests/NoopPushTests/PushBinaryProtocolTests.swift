import XCTest
@testable import NoopPush

private let sourceA = "3a3486dd-5030-4e17-a00d-a781399890f9"

final class PushBinaryProtocolTests: XCTestCase {
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
        XCTAssertEqual((try first.payload), (try retry.payload))
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
