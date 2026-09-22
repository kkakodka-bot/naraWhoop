import Foundation
import XCTest
import zlib
#if canImport(CNoopZstd)
import CNoopZstd
#endif
@testable import NoopPush

final class PushCompressionTests: XCTestCase {
    func testGzipEmptyAndMultiChunkRoundTrip() throws {
        for count in [0, 1, 65_537, 270_000] {
            let input = payload(count)
            let wire = try PushBinaryCompression.gzip(input)
            var stream = z_stream()
            XCTAssertEqual(inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION,
                                        Int32(MemoryLayout<z_stream>.size)), Z_OK)
            defer { inflateEnd(&stream) }
            var decoded = Data(count: max(1, count))
            let status = wire.withUnsafeBytes { source in
                decoded.withUnsafeMutableBytes { target in
                    stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(source.count)
                    stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(target.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            XCTAssertEqual(status, Z_STREAM_END)
            XCTAssertEqual(Int(stream.total_out), count)
            XCTAssertEqual(decoded.prefix(count), input)
        }
    }

    #if canImport(CNoopZstd)
    func testProductionAndPortableZstdAgainstPinnedReferenceDecoder() throws {
        XCTAssertEqual(noop_zstd_version(), 10507)
        for count in [0, 1, 255, 256, 131_071, 131_072, 131_073, 4_194_304] {
            let input = payload(count)
            let portable = try PushBinaryCompression.zstdRawFrame(input,
                maxDecoded: count, maxWire: count + 4096)
            let native = try PushBinaryCompression.compressObject(input, encoding: "zstd")
            for wire in [portable, native] {
                var decoded = Data(count: max(1, count))
                var written = 0
                let status = wire.withUnsafeBytes { source in
                    decoded.withUnsafeMutableBytes { target in
                        noop_zstd_decompress(source.bindMemory(to: UInt8.self).baseAddress, source.count,
                            target.bindMemory(to: UInt8.self).baseAddress, target.count, &written)
                    }
                }
                XCTAssertEqual(status, 0, "count=\(count)")
                XCTAssertEqual(written, count)
                XCTAssertEqual(decoded.prefix(count), input)
            }
        }
    }

    func testPinnedGoldenFramesBothLevelsAndDecodedDigestCompatibility() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "zstd-1.5.7-golden", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(root["upstream_version"] as? String, "1.5.7")
        let vectors = try XCTUnwrap(root["vectors"] as? [[String: Any]])
        for vector in vectors {
            let decoded = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(vector["decoded_base64"] as? String)))
            XCTAssertEqual(PushDurabilityReceipt.sha256(decoded), vector["decoded_sha256"] as? String)
            for frame in try XCTUnwrap(vector["frames"] as? [[String: Any]]) {
                let wire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(frame["wire_base64"] as? String)))
                XCTAssertEqual(PushDurabilityReceipt.sha256(wire), frame["wire_sha256"] as? String)
                var output = Data(count: max(1, decoded.count)), written = 0
                let status = wire.withUnsafeBytes { source in
                    output.withUnsafeMutableBytes { target in
                        noop_zstd_decompress(source.bindMemory(to: UInt8.self).baseAddress, source.count,
                            target.bindMemory(to: UInt8.self).baseAddress, target.count, &written)
                    }
                }
                XCTAssertEqual(status, 0)
                XCTAssertEqual(output.prefix(written), decoded)
            }
            let current = try PushBinaryCompression.compressObject(decoded, encoding: "zstd")
            if vector["name"] as? String == "synthetic_repetition" {
                XCTAssertLessThan(current.count, decoded.count / 10, "production codec must compress instead of emitting raw blocks")
            }
        }
    }

    func testOnlyMeasuredCompressionLevelsAreAdmitted() {
        var allocation: UnsafeMutablePointer<UInt8>?
        var written = 99
        XCTAssertNotEqual(noop_zstd_compress_level(nil, 0, 22, &allocation, &written), 0)
        XCTAssertNil(allocation)
        XCTAssertEqual(written, 0)
    }
    #endif

    func testPortableZstdBoundsAndSlicedData() throws {
        let input = payload(1_000).dropFirst(17)
        let first = try PushBinaryCompression.zstdRawFrame(input, maxDecoded: 983, maxWire: 996)
        XCTAssertEqual(first.count, 996)
        XCTAssertEqual(first.suffix(983), input)
        XCTAssertEqual(first, try PushBinaryCompression.zstdRawFrame(Data(input), maxDecoded: 983, maxWire: 996))
        XCTAssertThrowsError(try PushBinaryCompression.zstdRawFrame(input, maxDecoded: 982, maxWire: 996))
        XCTAssertThrowsError(try PushBinaryCompression.zstdRawFrame(input, maxDecoded: 983, maxWire: 995))
        XCTAssertEqual(try PushBinaryCompression.zstdRawFrame(Data(), maxDecoded: 0, maxWire: 13).count, 13)
    }

    private func payload(_ count: Int) -> Data {
        var state: UInt64 = 1234567
        return Data((0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: state >> 32)
        })
    }
}
