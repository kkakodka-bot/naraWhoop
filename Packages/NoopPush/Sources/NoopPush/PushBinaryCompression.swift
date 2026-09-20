import Foundation
import zlib
#if canImport(CNoopZstd)
import CNoopZstd
#endif

public enum PushBinaryCompression {
    public static func compress(_ decoded: Data, encoding: String) throws -> Data {
        switch encoding {
        case "gzip":
            return try gzip(decoded)
        case "zstd":
            return try zstd(decoded)
        default:
            throw PushProtocolException("unsupported binary contentEncoding")
        }
    }

    /// Object-lane variant: same codecs, but bounded by the 1.2 object limits instead of the
    /// inline 4 MiB body limit. The negotiated ceiling (`PushObjectLane.maxObjectBytes`) is
    /// enforced by the coordinator against the result.
    public static func compressObject(_ decoded: Data, encoding: String) throws -> Data {
        switch encoding {
        case "gzip":
            return try gzip(decoded, maxDecoded: PushProtocolLimits.maxObjectDecodedBytes, maxWire: PushProtocolLimits.maxObjectWireBytes)
        case "zstd":
            return try zstd(decoded, maxDecoded: PushProtocolLimits.maxObjectDecodedBytes, maxWire: PushProtocolLimits.maxObjectWireBytes)
        default:
            throw PushProtocolException("unsupported binary contentEncoding")
        }
    }

    public static func gzip(_ decoded: Data) throws -> Data {
        try gzip(decoded, maxDecoded: PushProtocolLimits.maxBodyBytes, maxWire: PushProtocolLimits.maxWireBodyBytes)
    }

    private static func gzip(_ decoded: Data, maxDecoded: Int, maxWire: Int) throws -> Data {
        guard decoded.count <= maxDecoded else {
            throw PushProtocolException("binary payload exceeds decoded limit")
        }
        var stream = z_stream()
        var status = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw PushProtocolException("gzip init failed") }
        defer { deflateEnd(&stream) }

        var output = Data(capacity: decoded.count)
        decoded.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(decoded.count)
            let chunk = 64 * 1024
            var buffer = [UInt8](repeating: 0, count: chunk)
            repeat {
                buffer.withUnsafeMutableBufferPointer { outputBuffer in
                    stream.next_out = outputBuffer.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = deflate(&stream, Z_FINISH)
                }
                let produced = chunk - Int(stream.avail_out)
                if produced > 0 { output.append(buffer, count: produced) }
            } while status == Z_OK
        }
        guard status == Z_STREAM_END else { throw PushProtocolException("gzip failed") }
        guard output.count <= maxWire else {
            throw PushProtocolException("gzip payload exceeds wire limit")
        }
        return output
    }

    public static func zstd(_ decoded: Data) throws -> Data {
        try zstd(decoded, maxDecoded: PushProtocolLimits.maxBodyBytes, maxWire: PushProtocolLimits.maxWireBodyBytes)
    }

    private static func zstd(_ decoded: Data, maxDecoded: Int, maxWire: Int) throws -> Data {
        guard decoded.count <= maxDecoded else {
            throw PushProtocolException("binary payload exceeds decoded limit")
        }
        #if canImport(CNoopZstd)
        var outputPointer: UnsafeMutablePointer<UInt8>?
        var outputCount = 0
        let status = decoded.withUnsafeBytes { bytes in
            noop_zstd_compress(bytes.bindMemory(to: UInt8.self).baseAddress, decoded.count,
                               &outputPointer, &outputCount)
        }
        guard status == 0, let outputPointer else { throw PushProtocolException("zstd failed") }
        defer { noop_zstd_free(outputPointer) }
        guard outputCount <= maxWire else { throw PushProtocolException("zstd payload exceeds wire limit") }
        return Data(bytes: outputPointer, count: outputCount)
        #else
        return try zstdRawFrame(decoded, maxDecoded: maxDecoded, maxWire: maxWire)
        #endif
    }

    /// Portable fallback for iOS, where Apple Compression has no Zstandard codec. RFC 8878
    /// sections 3.1.1.1–2 permit raw blocks inside a Zstandard frame. No compression savings are
    /// claimed: wire size is input size + 10 header bytes + 3 bytes per block (at least one).
    /// A 128 KiB window bounds decoder workspace independently of the total object size.
    /// https://www.rfc-editor.org/rfc/rfc8878.html#section-3.1.1
    static func zstdRawFrame(_ decoded: Data, maxDecoded: Int, maxWire: Int) throws -> Data {
        guard decoded.count <= maxDecoded, decoded.count <= Int(UInt32.max) else {
            throw PushProtocolException("binary payload exceeds decoded limit")
        }
        let blockBytes = 128 * 1024
        let blockCount = max(1, (decoded.count + blockBytes - 1) / blockBytes)
        let wireBytes = decoded.count + 10 + 3 * blockCount
        guard wireBytes <= maxWire else { throw PushProtocolException("zstd payload exceeds wire limit") }
        var output = Data(capacity: wireBytes)
        // Magic; 4-byte content size, no dictionary/checksum, non-single-segment; 128 KiB window.
        output.append(contentsOf: [0x28, 0xb5, 0x2f, 0xfd, 0x80, 0x38])
        let size = UInt32(decoded.count)
        for shift in stride(from: 0, to: 32, by: 8) {
            output.append(UInt8(truncatingIfNeeded: size >> shift))
        }
        var offset = 0
        repeat {
            let count = min(blockBytes, decoded.count - offset)
            let isLast = offset + count == decoded.count
            let header = UInt32(count << 3) | (isLast ? 1 : 0) // raw block type = 0
            for shift in stride(from: 0, to: 24, by: 8) {
                output.append(UInt8(truncatingIfNeeded: header >> shift))
            }
            let start = decoded.index(decoded.startIndex, offsetBy: offset)
            output.append(decoded[start..<decoded.index(start, offsetBy: count)])
            offset += count
        } while offset < decoded.count
        return output
    }
}
