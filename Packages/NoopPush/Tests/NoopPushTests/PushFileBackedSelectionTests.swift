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
        [(.ppgWaveformSample, "1.2", [.ppgWaveform(.init(rowId: 4, ts: 1_800_000_000, burstIndex: 1, samples: Data([1, 2])))]),
         (.ppgWaveformSample, "1.3", [.ppgWaveform(.init(rowId: 4, ts: 1_800_000_000, burstIndex: 1, samples: Data([1, 2]), recordIndex: 19))]),
         (.v18AuxSample, "1.4", [.v18Aux(.init(rowId: 7, ts: 1_800_000_000, fields: Data([3]), recordIndex: 19, resourceKey: "synthetic-resource"))]),
         (.rawImuSession, "1.2", [.rawImuSession(.init(rowId: 1, ts: 1_800_000_000, columns: Data(repeating: 2, count: 1200)))]),
         (.rawBatch, "1.2", [.rawBatch(.init(rowId: 9, batchId: "synthetic-archive", capturedAt: 1_800_000_000, deviceClockRef: 1_799_999_999,
             wallClockRef: 1_800_000_000, startTs: 1_800_000_000, endTs: 1_800_000_000, frameCount: 1, byteSize: 4, framesBlob: Data([1, 2, 3, 4])))])]
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
            XCTAssertNotEqual(file.objectId, legacy.objectId)
            XCTAssertEqual(UUID(uuidString: file.objectId)?.uuidString.lowercased(), file.objectId)
            XCTAssertEqual(file.endCursor, legacy.endCursor)
            var fileHeader = try XCTUnwrap(JSONSerialization.jsonObject(with: file.manifestJSON) as? [String: AnyHashable])
            var legacyHeader = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy.manifestJSON) as? [String: AnyHashable])
            fileHeader.removeValue(forKey: "objectId"); legacyHeader.removeValue(forKey: "objectId")
            XCTAssertEqual(fileHeader, legacyHeader)
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
    func testRepresentationIdentitySeparatesSameLengthValidGzipFramesAndRetainsLegacySelection() throws {
        let root = try directory()
        let (table, version, rows) = rows()[0]
        let legacy = try PushProtocol.binaryObjectBatch(table: table, sourceId: source, deviceId: "synthetic", startCursor: nil,
            rows: rows, protocolVersion: version)
        let oldWire = try legacy.payload
        var changedWire = oldWire
        changedWire[4] = changedWire[4] ^ 1 // Gzip MTIME only: same decoded bytes and encoded length.
        XCTAssertEqual(changedWire.count, oldWire.count)
        let originalID = try PushProtocol.immutableObjectID(batchId: legacy.batchId, contentEncoding: "gzip",
            wireSHA256: PushDurabilityReceipt.sha256(oldWire), wireBytes: oldWire.count)
        let changedID = try PushProtocol.immutableObjectID(batchId: legacy.batchId, contentEncoding: "gzip",
            wireSHA256: PushDurabilityReceipt.sha256(changedWire), wireBytes: changedWire.count)
        XCTAssertNotEqual(originalID, changedID)
        XCTAssertNotEqual(originalID, legacy.objectId)
        let streamed = try PushProtocol.binaryObjectBatch(table: table, sourceId: source, deviceId: "synthetic", startCursor: nil,
            rows: rows, protocolVersion: version, payloadDirectory: root)
        XCTAssertEqual(streamed.objectId, originalID)
        let commit = PushSourceCommit(kind: .binary, table: table.wireName, deviceID: "synthetic", batchIDs: [legacy.batchId], cursor: legacy.endCursor)
        let saved = try PushPreparedSelection(binary: legacy, rows: rows, manifest: .init(batch: legacy),
            lane: .init(endpoint: "/objects", maxObjectBytes: 8_000_000, urlTtlSec: 60, streams: [table]), commit: commit)
        let original = try saved.encoded()
        let replayed = try PushPreparedSelection.decode(original)
        XCTAssertEqual(try replayed.encoded(), original)
        XCTAssertEqual(try replayed.restoredObject()?.batch.objectId, legacy.objectId)
        XCTAssertEqual(replayed.objectPayload, oldWire)
    }

    func testLegacyRawZstdAndCompressedFileHaveDifferentObjectIDsWithSameDecodedIdentity() throws {
        let root = try directory(), (table, version, rows) = rows()[3]
        let legacy = try PushProtocol.binaryObjectBatch(table: table, sourceId: source, deviceId: "synthetic", startCursor: nil,
            rows: rows, protocolVersion: version)
        let decoded = try PushBinaryCodec.pack(table: table, rows: rows)
        let rawFrame = try PushBinaryCompression.zstdRawFrame(decoded, maxDecoded: decoded.count, maxWire: decoded.count + 1024)
        var manifestJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(PushObjectManifest(batch: legacy))) as? [String: Any])
        manifestJSON["compressedBytes"] = rawFrame.count
        let oldManifest = try JSONDecoder().decode(PushObjectManifest.self, from: JSONSerialization.data(withJSONObject: manifestJSON))
        let oldBatch = try PushBinaryBatch.restoring(manifest: oldManifest, endCursor: legacy.endCursor,
            manifestJSON: legacy.manifestJSON, payload: rawFrame, wireSHA256: PushDurabilityReceipt.sha256(rawFrame), rows: rows)
        let streamed = try PushProtocol.binaryObjectBatch(table: table, sourceId: source, deviceId: "synthetic", startCursor: nil,
            rows: rows, protocolVersion: version, payloadDirectory: root)
        XCTAssertEqual(streamed.batchId, oldBatch.batchId)
        XCTAssertEqual(streamed.contentSha256, oldBatch.contentSha256)
        XCTAssertNotEqual(streamed.objectId, oldBatch.objectId)
        XCTAssertLessThan(streamed.wireBytes, rawFrame.count)
        let lane = PushObjectLane(endpoint: "/objects", maxObjectBytes: 8_000_000, urlTtlSec: 60, streams: [table])
        let saved = try PushPreparedSelection(binary: oldBatch, rows: rows, manifest: .init(batch: oldBatch), lane: lane,
            commit: .init(kind: .binary, table: table.wireName, deviceID: "synthetic", batchIDs: [oldBatch.batchId], cursor: oldBatch.endCursor))
        let replayed = try PushPreparedSelection.decode(saved.encoded())
        XCTAssertEqual(replayed.objectPayload, rawFrame)
        XCTAssertEqual(try replayed.restoredObject()?.batch.objectId, oldBatch.objectId)
        if let output = ProcessInfo.processInfo.environment["NARA_REPRESENTATION_FIXTURE_ROOT"] {
            var isDirectory: ObjCBool = false
            guard output.hasPrefix("/"), FileManager.default.fileExists(atPath: output, isDirectory: &isDirectory), isDirectory.boolValue else {
                return XCTFail("representation fixture root must exist")
            }
            let artifact: [String: Any] = ["schema_version": 1, "synthetic_only": true,
                "decoded_base64": decoded.base64EncodedString(),
                "legacy": ["manifest": try JSONSerialization.jsonObject(with: oldManifest.encode()),
                           "wire_base64": rawFrame.base64EncodedString(), "wire_sha256": oldBatch.wireSHA256],
                "streamed": ["manifest": try JSONSerialization.jsonObject(with: PushObjectManifest(batch: streamed).encode()),
                             "wire_base64": try streamed.payload.base64EncodedString(), "wire_sha256": streamed.wireSHA256]]
            try JSONSerialization.data(withJSONObject: artifact, options: [.sortedKeys, .prettyPrinted])
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("representation-compatibility.json"))
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
