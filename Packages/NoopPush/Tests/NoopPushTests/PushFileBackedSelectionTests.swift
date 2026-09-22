import XCTest
@testable import NoopPush

final class PushFileBackedSelectionTests: XCTestCase {
    private let source = "3a3486dd-5030-4e17-a00d-a781399890f9"
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-wire-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        return path
    }
    private func rows() -> [(PushBinaryTable, String, [PushBinaryRow])] {
        [(.ppgWaveformSample, "1.2", [.ppgWaveform(.init(rowId: 4, ts: 100, burstIndex: 1, samples: Data([1, 2])))]),
         (.ppgWaveformSample, "1.3", [.ppgWaveform(.init(rowId: 4, ts: 100, burstIndex: 1, samples: Data([1, 2]), recordIndex: 19))]),
         (.v18AuxSample, "1.4", [.v18Aux(.init(rowId: 7, ts: 100, fields: Data([3]), recordIndex: 19, resourceKey: "synthetic-resource"))]),
         (.rawImuSession, "1.2", [.rawImuSession(.init(rowId: 1, ts: 100, columns: Data(repeating: 2, count: 1200)))]),
         (.rawBatch, "1.2", [.rawBatch(.init(rowId: 9, batchId: "synthetic-archive", capturedAt: 100, deviceClockRef: 99,
             wallClockRef: 100, startTs: 100, endTs: 100, frameCount: 1, byteSize: 4, framesBlob: Data([1, 2, 3, 4])))])]
    }
    func testFileEncodingKeepsExactDecodedAndStableIdentitiesForEverySupportedKind() throws {
        for (table, version, rows) in rows() {
            let root = try directory()
            let legacy = try PushProtocol.binaryObjectBatch(table: table, sourceId: source, deviceId: "synthetic", startCursor: nil,
                rows: rows, protocolVersion: version, decodedLimit: 4 * 1_048_576)
            let file = try PushProtocol.binaryObjectBatch(table: table, sourceId: source, deviceId: "synthetic", startCursor: nil,
                rows: rows, protocolVersion: version, decodedLimit: 4 * 1_048_576, payloadDirectory: root)
            XCTAssertEqual(file.contentSha256, legacy.contentSha256)
            XCTAssertEqual(file.batchId, legacy.batchId)
            XCTAssertEqual(file.objectId, legacy.objectId)
            XCTAssertEqual(file.endCursor, legacy.endCursor)
            XCTAssertEqual(file.manifestJSON, legacy.manifestJSON)
            let payload = try XCTUnwrap(file.payloadFile)
            XCTAssertEqual(file.wireBytes, payload.byteCount)
            XCTAssertEqual(file.wireSHA256, payload.sha256)
            if file.contentEncoding == "gzip" { XCTAssertEqual(try file.payload, try legacy.payload) }
            let leaf = root.appendingPathComponent(payload.name)
            try FileManager.default.linkItem(at: payload.url, to: leaf)
            let lane = PushObjectLane(endpoint: "/objects", maxObjectBytes: 8_000_000, urlTtlSec: 60, streams: [table])
            let commit = PushSourceCommit(kind: .binary, table: table.wireName, deviceID: "synthetic", batchIDs: [file.batchId],
                cursor: file.endCursor, rawBatchIDs: table == .rawBatch ? ["synthetic-archive"] : [])
            let saved = try PushPreparedSelection(binary: file, rows: rows, manifest: .init(batch: file), lane: lane, commit: commit)
            XCTAssertEqual(saved.version, 3)
            XCTAssertNil(saved.objectPayload)
            let encoded = try saved.encoded()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let object = try XCTUnwrap(json["binary"] as? [String: Any])
            XCTAssertNil(object["payload"])
            XCTAssertNotNil(object["payloadFile"])
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(root.path))
            XCTAssertThrowsError(try PushPreparedSelection.decode(encoded), "An account directory must bind file references")
            let restored = try PushPreparedSelection.decode(encoded, payloadDirectory: root)
            XCTAssertEqual(try restored.encoded(), encoded)
            XCTAssertEqual(try restored.identityData(), try saved.identityData())
            let restoredBatch = try XCTUnwrap(restored.restoredObject()?.batch)
            XCTAssertEqual(restoredBatch.payloadFile?.url, leaf)
            XCTAssertEqual(try restoredBatch.payload, try file.payload)
        }
    }
    func testFileReferenceRejectsWrongAccountDirectoryChangedBytesAndSymlink() throws {
        let root = try directory(), other = try directory()
        let (table, version, rows) = rows()[0]
        let batch = try PushProtocol.binaryObjectBatch(table: table, sourceId: source, deviceId: "synthetic", startCursor: nil,
            rows: rows, protocolVersion: version, payloadDirectory: root)
        let file = try XCTUnwrap(batch.payloadFile), bytes = try JSONEncoder().encode(file)
        let decoder = JSONDecoder(); decoder.userInfo[PushImmutablePayloadFile.directoryKey] = other
        XCTAssertThrowsError(try decoder.decode(PushImmutablePayloadFile.self, from: bytes))
        let leaf = other.appendingPathComponent(file.name)
        try Data(repeating: 0, count: file.byteCount).write(to: leaf)
        XCTAssertThrowsError(try decoder.decode(PushImmutablePayloadFile.self, from: bytes))
        try FileManager.default.removeItem(at: leaf)
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: file.url)
        XCTAssertThrowsError(try decoder.decode(PushImmutablePayloadFile.self, from: bytes))
    }
}
