import Foundation
import XCTest
import CryptoKit
import zlib
import CNoopZstd
@testable import NoopPush

final class PushBinaryStreamEncoderTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noop-stream-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func encode(_ rows: [PushBinaryRow], table: PushBinaryTable, encoding: String,
                        directory: URL, identityV2: Bool = false, level: Int = 1,
                        maxWireBytes: Int = 4 * 1_048_576 + 65_536,
                        expectedBytes: Int? = nil,
                        allowsWork: @escaping () -> Bool = { true }) throws -> PushBinaryStreamEncoder.Artifact {
        var iterator = rows.makeIterator()
        return try PushBinaryStreamEncoder.encode(table: table, rowCount: rows.count, encoding: encoding,
            ppgIdentityV2: identityV2, v18IdentityV2: identityV2, directory: directory,
            maxWireBytes: maxWireBytes, expectedDecodedBytes: expectedBytes, compressionLevel: level,
            allowsWork: allowsWork, nextRow: { iterator.next() })
    }

    private func fixtures(identityV2: Bool) -> [(PushBinaryTable, [PushBinaryRow])] {
        let sliced = Data([0xFF, 0x00, 0x02, 0x7F, 0xFF]).dropFirst()
        return [
            (.ppgWaveformSample, [
                .ppgWaveform(.init(rowId: 5, ts: 50, burstIndex: nil, samples: Data([0x0A]), recordIndex: identityV2 ? 0 : nil)),
                .ppgWaveform(.init(rowId: 6, ts: 51, burstIndex: -3, samples: sliced, recordIndex: nil))]),
            (.v18AuxSample, [
                .v18Aux(.init(rowId: 7, ts: 52, fields: sliced, recordIndex: identityV2 ? Int64(UInt32.max) : nil)),
                .v18Aux(.init(rowId: 8, ts: 53, fields: Data(), recordIndex: nil))]),
            (.rawBatch, [.rawBatch(.init(rowId: 1, batchId: "fixture-μ", capturedAt: 10,
                deviceClockRef: 11, wallClockRef: 12, startTs: 1, endTs: 2,
                frameCount: 1, byteSize: Int32(sliced.count), framesBlob: sliced))]),
            (.rawImuSession, [.rawImuSession(.init(rowId: 100, ts: 100,
                columns: Data((0..<1_200).map { UInt8(truncatingIfNeeded: $0) })))])
        ]
    }

    func testAllFourKindsAndIdentityVersionsMatchExistingDecodedBytesAndDigests() throws {
        var vectors: [[String: Any]] = []
        for identityV2 in [false, true] {
            for (table, rows) in fixtures(identityV2: identityV2) {
                let expected = try PushBinaryCodec.pack(table: table, rows: rows,
                    ppgIdentityV2: identityV2, v18IdentityV2: identityV2)
                for (encoding, level) in [("gzip", 1), ("zstd", 1), ("zstd", 3)] {
                    let artifact = try encode(rows, table: table, encoding: encoding, directory: directory(),
                        identityV2: identityV2, level: level, expectedBytes: expected.count)
                    let wire = try Data(contentsOf: artifact.fileURL)
                    XCTAssertEqual(try decode(wire, encoding: encoding, size: expected.count), expected)
                    XCTAssertEqual(artifact.contentSha256, PushBinaryCodec.sha256Hex(expected))
                    XCTAssertEqual(artifact.wireSha256, PushBinaryCodec.sha256Hex(wire))
                    XCTAssertEqual(artifact.uncompressedBytes, expected.count)
                    XCTAssertEqual(artifact.wireBytes, wire.count)
                    XCTAssertEqual(artifact.rowCount, rows.count)
                    XCTAssertEqual(artifact.fileURL.lastPathComponent, artifact.wireSha256 + ".body")
                    if encoding == "gzip" {
                        XCTAssertEqual(wire, try PushBinaryCompression.compressObject(expected, encoding: encoding))
                    }
                    vectors.append(["table": table.rawValue, "identity_v2": identityV2,
                        "encoding": encoding, "level": level, "decoded_base64": expected.base64EncodedString(),
                        "decoded_sha256": artifact.contentSha256, "wire_base64": wire.base64EncodedString(),
                        "wire_sha256": artifact.wireSha256])
                }
            }
        }
        let value: [String: Any] = ["schema_version": 1, "synthetic_only": true, "zstd_version": 10507, "vectors": vectors]
        let encoded = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        if let path = ProcessInfo.processInfo.environment["NOOP_STREAM_GOLDEN_OUTPUT"] {
            try encoded.write(to: URL(fileURLWithPath: path), options: .atomic)
        } else {
            let url = try XCTUnwrap(Bundle.module.url(forResource: "streaming-npb1-golden", withExtension: "json"))
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! NSDictionary
            XCTAssertEqual(value as NSDictionary, expected)
        }
    }

    func testKotlinOracleAndPrefixHashAreByteExact() throws {
        let rows: [PushBinaryRow] = [.ppgWaveform(.init(rowId: 5, ts: 50, burstIndex: nil, samples: Data([0x0A])))]
        var iterator = rows.makeIterator(), decoded = Data(), prefixed = SHA256()
        let prefix = Data("canonical-header\n".utf8)
        prefixed.update(data: prefix)
        let size = try PushBinaryStreamEncoder.visitDecodedBytes(table: .ppgWaveformSample, rowCount: 1,
            nextRow: { iterator.next() }) { bytes in decoded.append(contentsOf: bytes); prefixed.update(bufferPointer: bytes) }
        XCTAssertEqual(size, 32)
        XCTAssertEqual(decoded.map { String(format: "%02x", $0) }.joined(),
            "4e5042310101010000000500000000000000320000000000000000010000000a")
        XCTAssertEqual(PushBinaryCodec.sha256Hex(decoded), "7a4521405729fb0e7ce3c7a8d63c8dad7c2372c7a9738b4eec05fa86fcfb9e8d")
        XCTAssertEqual(Data(prefixed.finalize()), Data(SHA256.hash(data: prefix + decoded)))
    }

    func testZstdBothMeasuredLevelsWithAndWithoutPledgedLengthDecode() throws {
        let rows: [PushBinaryRow] = (1...100).map { .rawImuSession(.init(rowId: Int64($0), ts: Int64($0),
            columns: Data(repeating: UInt8($0 % 10), count: 1_200))) }
        let decoded = try PushBinaryCodec.pack(table: .rawImuSession, rows: rows)
        for level in [1, 3] {
            for expected in [nil, Optional(decoded.count)] {
                let artifact = try encode(rows, table: .rawImuSession, encoding: "zstd", directory: directory(),
                    level: level, expectedBytes: expected)
                let wire = try Data(contentsOf: artifact.fileURL)
                XCTAssertEqual(try decode(wire, encoding: "zstd", size: decoded.count), decoded)
                XCTAssertLessThan(wire.count, decoded.count / 10)
            }
        }
    }

    func testLargeSingleBlobIsDeliveredInBoundedSlices() throws {
        let row = PushBinaryRow.rawBatch(.init(rowId: 1, batchId: "synthetic", capturedAt: 1,
            deviceClockRef: 1, wallClockRef: 1, startTs: 1, endTs: 2,
            frameCount: 1, byteSize: 3 * 1_048_576, framesBlob: Data(repeating: 17, count: 3 * 1_048_576)))
        var iterator = [row].makeIterator(), maximum = 0, callbacks = 0
        let count = try PushBinaryStreamEncoder.visitDecodedBytes(table: .rawBatch, rowCount: 1,
            nextRow: { iterator.next() }) { bytes in maximum = max(maximum, bytes.count); callbacks += 1 }
        XCTAssertEqual(maximum, 65_536)
        XCTAssertGreaterThan(callbacks, 48)
        XCTAssertEqual(count, try PushBinaryCodec.packedRowSize(row) + 6)
    }

    func testRowsArePulledIncrementallyAndDefaultRowBudgetIsEnforced() throws {
        var requested = 0, emittedSinceLastRow = true
        let count = try PushBinaryStreamEncoder.visitDecodedBytes(table: .v18AuxSample, rowCount: 2_000,
            nextRow: {
                XCTAssertTrue(emittedSinceLastRow)
                guard requested < 2_000 else { return nil }
                requested += 1; emittedSinceLastRow = false
                return .v18Aux(.init(rowId: Int64(requested), ts: Int64(requested), fields: Data(repeating: 9, count: 1_024)))
            }) { _ in emittedSinceLastRow = true }
        XCTAssertEqual(requested, 2_000)
        XCTAssertEqual(count, 10 + 2_000 * 1_044)
        XCTAssertThrowsError(try PushBinaryStreamEncoder.visitDecodedBytes(table: .v18AuxSample,
            rowCount: 2_001, nextRow: { XCTFail(); return nil }, consume: { _ in XCTFail() }))
    }

    func testRevokedAdmissionBetweenRowsAndInsideBlobLeavesNoArtifact() throws {
        for revokeInsideBlob in [false, true] {
            let path = try directory()
            var admitted = true, checks = 0, row = 0
            XCTAssertThrowsError(try PushBinaryStreamEncoder.encode(table: .v18AuxSample, rowCount: 2,
                encoding: "gzip", directory: path, allowsWork: {
                    checks += 1
                    return admitted && (!revokeInsideBlob || checks < 18)
                }, nextRow: {
                    row += 1
                    if row > 2 { return nil }
                    if !revokeInsideBlob && row == 2 { admitted = false }
                    return .v18Aux(.init(rowId: Int64(row), ts: Int64(row), fields: Data(repeating: 7, count: 512 * 1_024)))
                })) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty)
        }
    }

    func testWireAndDecodedLimitsAndLengthMismatchLeaveNoTemporaryFiles() throws {
        let rows = fixtures(identityV2: false)[0].1
        for failure in ["wire", "decoded", "length"] {
            let path = try directory()
            var iterator = rows.makeIterator()
            XCTAssertThrowsError(try PushBinaryStreamEncoder.encode(table: .ppgWaveformSample,
                rowCount: rows.count, encoding: "gzip", directory: path,
                maxDecodedBytes: failure == "decoded" ? 10 : 4 * 1_048_576,
                maxWireBytes: failure == "wire" ? 1 : 4 * 1_048_576,
                expectedDecodedBytes: failure == "length" ? 1 : nil, nextRow: { iterator.next() }))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty)
        }
    }

    func testInvalidRowsAndDeclaredCountsFailClosed() throws {
        let row = PushBinaryRow.v18Aux(.init(rowId: 1, ts: 1, fields: Data([2])))
        for rows in [[], [row, row]] {
            var iterator = rows.makeIterator()
            XCTAssertThrowsError(try PushBinaryStreamEncoder.visitDecodedBytes(table: .v18AuxSample,
                rowCount: 1, nextRow: { iterator.next() }, consume: { _ in }))
        }
        let malformed: [(PushBinaryTable, PushBinaryRow, Bool)] = [
            (.ppgWaveformSample, row, false),
            (.rawImuSession, .rawImuSession(.init(rowId: 1, ts: 1, columns: Data())), false),
            (.v18AuxSample, .v18Aux(.init(rowId: 1, ts: 1, fields: Data(), recordIndex: -1)), true),
            (.v18AuxSample, .v18Aux(.init(rowId: 1, ts: 1, fields: Data(), recordIndex: Int64(UInt32.max) + 1)), true),
            (.ppgWaveformSample, .ppgWaveform(.init(rowId: 1, ts: 1, burstIndex: nil, samples: Data(), recordIndex: 0)), false)
        ]
        for (table, row, v2) in malformed {
            let path = try directory()
            XCTAssertThrowsError(try encode([row], table: table, encoding: "gzip", directory: path, identityV2: v2))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty)
        }
    }

    func testRepeatedPublicationReusesVerifiedImmutableFileWithoutReplacement() throws {
        let path = try directory(), rows = fixtures(identityV2: false)[0].1
        let first = try encode(rows, table: .ppgWaveformSample, encoding: "gzip", directory: path)
        let before = try FileManager.default.attributesOfItem(atPath: first.fileURL.path)
        let second = try encode(rows, table: .ppgWaveformSample, encoding: "gzip", directory: path)
        let after = try FileManager.default.attributesOfItem(atPath: second.fileURL.path)
        XCTAssertEqual(first.fileURL, second.fileURL)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual((after[.posixPermissions] as? NSNumber)?.intValue, 0o400)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path.path), [first.fileURL.lastPathComponent])
    }

    func testExistingCorruptDigestFileIsPreservedAndNeverOverwritten() throws {
        let path = try directory(), rows = fixtures(identityV2: false)[0].1
        let first = try encode(rows, table: .ppgWaveformSample, encoding: "gzip", directory: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: first.fileURL.path)
        let corrupt = Data(repeating: 0, count: first.wireBytes)
        try corrupt.write(to: first.fileURL)
        XCTAssertThrowsError(try encode(rows, table: .ppgWaveformSample, encoding: "gzip", directory: path))
        XCTAssertEqual(try Data(contentsOf: first.fileURL), corrupt)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path.path), [first.fileURL.lastPathComponent])
    }

    private func decode(_ bytes: Data, encoding: String, size: Int) throws -> Data {
        var decoded = Data(count: max(size, 1))
        if encoding == "zstd" {
            var written = 0
            let status = bytes.withUnsafeBytes { input in decoded.withUnsafeMutableBytes { output in
                noop_zstd_decompress(input.bindMemory(to: UInt8.self).baseAddress, input.count,
                    output.bindMemory(to: UInt8.self).baseAddress, output.count, &written)
            }}
            XCTAssertEqual(status, 0); XCTAssertEqual(written, size)
        } else {
            var stream = z_stream()
            XCTAssertEqual(inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
            defer { inflateEnd(&stream) }
            let status = bytes.withUnsafeBytes { input in decoded.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(output.count)
                return inflate(&stream, Z_FINISH)
            }}
            XCTAssertEqual(status, Z_STREAM_END); XCTAssertEqual(Int(stream.total_out), size)
        }
        return decoded.prefix(size)
    }
}
