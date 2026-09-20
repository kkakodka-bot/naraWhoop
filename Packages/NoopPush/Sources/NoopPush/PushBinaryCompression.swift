import Foundation
#if canImport(CNoopZstd)
import CNoopZstd
#endif
import zlib

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
        try decoded.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(decoded.count)
            let chunk = 64 * 1024
            var buffer = [UInt8](repeating: 0, count: chunk)
            repeat {
                buffer.withUnsafeMutableBufferPointer { bytes in
                    stream.next_out = bytes.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = deflate(&stream, Z_FINISH)
                }
                let produced = chunk - Int(stream.avail_out)
                guard produced <= maxWire - output.count else {
                    throw PushProtocolException("gzip payload exceeds wire limit")
                }
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
        var allocation: UnsafeMutablePointer<UInt8>?
        var written = 0
        let status = decoded.withUnsafeBytes { src in
            noop_zstd_compress(src.bindMemory(to: UInt8.self).baseAddress, src.count, &allocation, &written)
        }
        guard status == 0, let allocation else { throw PushProtocolException("zstd failed") }
        defer { noop_zstd_free(allocation) }
        guard written <= maxWire else {
            throw PushProtocolException("zstd payload exceeds wire limit")
        }
        return Data(bytes: allocation, count: written)
        #else
        return try zstdRawFrame(decoded, maxDecoded: maxDecoded, maxWire: maxWire)
        #endif
    }

    /// RFC 8878 raw-block encoding for platforms without libzstd (including iOS).
    /// Apple's Compression framework has no Zstandard codec. This produces a real
    /// Zstandard frame, but makes no compression-ratio promise. Decoded object identity
    /// is independent of codec output. A fixed 128 KiB window bounds decoder memory.
    /// https://www.rfc-editor.org/rfc/rfc8878.html#section-3.1.1
    static func zstdRawFrame(_ decoded: Data, maxDecoded: Int, maxWire: Int) throws -> Data {
        guard decoded.count <= maxDecoded, decoded.count <= Int(UInt32.max) else {
            throw PushProtocolException("binary payload exceeds decoded limit")
        }
        let blockSize = 128 * 1024
        let blocks = max(1, (decoded.count + blockSize - 1) / blockSize)
        let wireSize = 10 + 3 * blocks + decoded.count
        guard wireSize <= maxWire else { throw PushProtocolException("zstd payload exceeds wire limit") }
        var output = Data(capacity: wireSize)
        // Content-size flag 2, no single segment/dictionary/checksum; window log 17.
        output.append(contentsOf: [0x28, 0xB5, 0x2F, 0xFD, 0x80, 0x38])
        let count = UInt32(decoded.count)
        for shift in stride(from: 0, to: 32, by: 8) {
            output.append(UInt8(truncatingIfNeeded: count >> shift))
        }
        var offset = 0
        repeat {
            let size = min(blockSize, decoded.count - offset)
            let last = offset + size == decoded.count
            let header = UInt32(size << 3) | (last ? 1 : 0)
            for shift in stride(from: 0, to: 24, by: 8) {
                output.append(UInt8(truncatingIfNeeded: header >> shift))
            }
            let start = decoded.startIndex + offset
            output.append(decoded[start..<(start + size)])
            offset += size
        } while offset < decoded.count
        return output
    }
}
