import Foundation
import XCTest
import zlib
import CNoopZstd
@testable import NoopPush

final class PushBinaryStreamBufferTests: XCTestCase {
    func testRetiredCallerOwnedDirectoryIsNotRecreatedAfterAdmission() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        var checked = false, pulled = false
        XCTAssertThrowsError(try PushBinaryStreamEncoder.encode(table: .v18AuxSample, rowCount: 1,
            encoding: "gzip", directory: path, requireExistingDirectory: true,
            allowsWork: {
                // Simulate account-runtime recovery retiring the lease at the admission boundary.
                if !checked { try? FileManager.default.removeItem(at: path); checked = true }
                return true
            }, nextRow: {
                pulled = true
                return .v18Aux(.init(rowId: 1, ts: 1, fields: Data([7])))
            }))
        XCTAssertTrue(checked)
        XCTAssertFalse(pulled, "A retired packing lease must fail before materializing source rows")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testExistingCallerOwnedDirectoryPublishesNormally() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        var rows = [PushBinaryRow.v18Aux(.init(rowId: 1, ts: 1, fields: Data([7])))].makeIterator()
        let artifact = try PushBinaryStreamEncoder.encode(table: .v18AuxSample, rowCount: 1,
            encoding: "gzip", directory: path, requireExistingDirectory: true, nextRow: { rows.next() })
        XCTAssertEqual(artifact.fileURL.deletingLastPathComponent().path, path.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path.path),
                       [artifact.fileURL.lastPathComponent])
    }

    func testIncompressibleMultiBufferOutputPreservesBothDigestsAndDecodes() throws {
        var random: UInt64 = 8191
        let blob = Data((0..<1_048_777).map { _ -> UInt8 in
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: random >> 32)
        })
        let row = PushBinaryRow.v18Aux(.init(rowId: 1, ts: 1, fields: blob, recordIndex: 123))
        let expected = try PushBinaryCodec.pack(table: .v18AuxSample, rows: [row], v18IdentityV2: true)
        for encoding in ["gzip", "zstd"] {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: path) }
            var iterator = [row].makeIterator()
            let artifact = try PushBinaryStreamEncoder.encode(table: .v18AuxSample, rowCount: 1,
                encoding: encoding, v18IdentityV2: true, directory: path,
                expectedDecodedBytes: expected.count, nextRow: { iterator.next() })
            let wire = try Data(contentsOf: artifact.fileURL)
            XCTAssertGreaterThan(wire.count, 1_000_000)
            XCTAssertEqual(artifact.wireSha256, PushBinaryCodec.sha256Hex(wire))
            XCTAssertEqual(artifact.contentSha256, PushBinaryCodec.sha256Hex(expected))
            var decoded = Data(count: expected.count)
            if encoding == "zstd" {
                var size = 0
                let status = wire.withUnsafeBytes { input in decoded.withUnsafeMutableBytes { output in
                    noop_zstd_decompress(input.bindMemory(to: UInt8.self).baseAddress, input.count,
                        output.bindMemory(to: UInt8.self).baseAddress, output.count, &size)
                }}
                XCTAssertEqual(status, 0); XCTAssertEqual(size, expected.count)
            } else {
                var stream = z_stream()
                XCTAssertEqual(inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION,
                    Int32(MemoryLayout<z_stream>.size)), Z_OK)
                defer { inflateEnd(&stream) }
                let status = wire.withUnsafeBytes { input in decoded.withUnsafeMutableBytes { output in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(input.count)
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_FINISH)
                }}
                XCTAssertEqual(status, Z_STREAM_END)
                XCTAssertEqual(wire, try PushBinaryCompression.compressObject(expected, encoding: "gzip"))
            }
            XCTAssertEqual(decoded, expected)
        }
    }

    func testThrowingSourceAfterCompressedBytesExistCleansTemporaryOutput() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        var pulled = 0
        enum SourceFailure: Error { case interrupted }
        XCTAssertThrowsError(try PushBinaryStreamEncoder.encode(table: .v18AuxSample, rowCount: 2,
            encoding: "gzip", directory: path, nextRow: {
                pulled += 1
                if pulled > 1 { throw SourceFailure.interrupted }
                return .v18Aux(.init(rowId: 1, ts: 1, fields: Data(repeating: 7, count: 262_144)))
            })) { XCTAssertTrue($0 is SourceFailure) }
        XCTAssertEqual(pulled, 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty)
    }
}
