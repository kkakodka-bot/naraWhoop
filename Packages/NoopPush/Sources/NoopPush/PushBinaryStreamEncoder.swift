import Foundation
import CryptoKit
import zlib
#if canImport(CNoopZstd)
import CNoopZstd
#endif
import Darwin

/// Fresh object preparation only. Saved legacy bodies keep their exact bytes and identities.
/// Memory is bounded by one source row, two 64 KiB buffers, and the codec's bounded context;
/// this API never constructs the full decoded or compressed selection in Data.
public enum PushBinaryStreamEncoder {
    public static let bufferBytes = 64 * 1024

    public struct Artifact: Sendable {
        public let fileURL: URL
        public let contentSha256: String
        public let wireSha256: String
        public let uncompressedBytes: Int
        public let wireBytes: Int
        public let rowCount: Int
        public let contentEncoding: String
    }

    /// The caller supplies the account-scoped directory and an admission closure that also
    /// fences account/device changes. `nextRow` must contain exactly the declared selection.
    /// A published filename is the compressed-byte digest, never a mutable selection name.
    public static func encode(
        table: PushBinaryTable, rowCount: Int, encoding: String,
        ppgIdentityV2: Bool = false, v18IdentityV2: Bool = false,
        directory: URL, maxDecodedBytes: Int = 4 * 1_048_576,
        maxWireBytes: Int = 4 * 1_048_576 + bufferBytes, maxRows: Int = 2_000,
        expectedDecodedBytes: Int? = nil, compressionLevel: Int = 1,
        allowsWork: @escaping () -> Bool = { true }, nextRow: () throws -> PushBinaryRow?
    ) throws -> Artifact {
        try checkAdmission(allowsWork)
        guard encoding == "gzip" || encoding == "zstd", [1, 3].contains(compressionLevel),
              maxWireBytes > 0, maxWireBytes <= PushProtocolLimits.maxObjectWireBytes,
              expectedDecodedBytes.map({ $0 > 0 && $0 <= maxDecodedBytes }) ?? true else {
            throw PushProtocolException("invalid streaming encoding limits")
        }
        let file = try ImmutableOutput(directory: directory)
        defer { file.closeAndRemoveTemporary() }
        let compressor = try Compressor(encoding: encoding, level: compressionLevel,
                                        expectedBytes: expectedDecodedBytes)
        var decodedHash = SHA256(), wireHash = SHA256(), wireBytes = 0
        let output: (UnsafeRawBufferPointer) throws -> Void = { bytes in
            try checkAdmission(allowsWork)
            guard bytes.count <= maxWireBytes - wireBytes else {
                throw PushProtocolException("binary payload exceeds wire limit")
            }
            try file.write(bytes)
            wireHash.update(bufferPointer: bytes)
            wireBytes += bytes.count
        }
        let decodedBytes = try visitDecodedBytes(table: table, rowCount: rowCount,
            ppgIdentityV2: ppgIdentityV2, v18IdentityV2: v18IdentityV2,
            maxDecodedBytes: maxDecodedBytes, maxRows: maxRows, allowsWork: allowsWork,
            nextRow: nextRow) { bytes in
                decodedHash.update(bufferPointer: bytes)
                try compressor.append(bytes, allowsWork: allowsWork, output: output)
            }
        guard expectedDecodedBytes.map({ $0 == decodedBytes }) ?? true else {
            throw PushProtocolException("binary decoded length changed")
        }
        try compressor.finish(allowsWork: allowsWork, output: output)
        try checkAdmission(allowsWork)
        let decodedDigest = hex(decodedHash.finalize()), wireDigest = hex(wireHash.finalize())
        let destination = try file.publish(digest: wireDigest, byteCount: wireBytes, allowsWork: allowsWork)
        return Artifact(fileURL: destination, contentSha256: decodedDigest, wireSha256: wireDigest,
            uncompressedBytes: decodedBytes, wireBytes: wireBytes, rowCount: rowCount, contentEncoding: encoding)
    }

    /// Exact NPB1 serialization in borrowed slices of at most 64 KiB. The buffer is valid only
    /// during `consume`. Replaying a bounded selected row iterator lets the caller preserve
    /// existing stable UUIDs whose hash prefixes depend on the decoded digest and batch UUID,
    /// without holding a decoded spool or rereading the whole backlog.
    @discardableResult
    public static func visitDecodedBytes(
        table: PushBinaryTable, rowCount: Int, ppgIdentityV2: Bool = false,
        v18IdentityV2: Bool = false, maxDecodedBytes: Int = 4 * 1_048_576,
        maxRows: Int = 2_000, allowsWork: () -> Bool = { true },
        nextRow: () throws -> PushBinaryRow?, consume: (UnsafeRawBufferPointer) throws -> Void
    ) throws -> Int {
        guard rowCount > 0, rowCount <= maxRows, rowCount <= Int(Int32.max),
              maxRows > 0, maxDecodedBytes > 0,
              maxDecodedBytes <= PushProtocolLimits.maxObjectDecodedBytes,
              table != .rawBatch || rowCount == 1 else {
            throw PushProtocolException("invalid streaming selection limits")
        }
        var total = 0
        func emit(_ data: Data) throws {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try checkAdmission(allowsWork)
                    let count = min(bufferBytes, bytes.count - offset)
                    guard count <= maxDecodedBytes - total else {
                        throw PushProtocolException("binary payload exceeds decoded limit")
                    }
                    try consume(UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + count)]))
                    total += count
                    offset += count
                }
            }
        }
        var header = PushBinaryCodec.magic
        let identityV2 = (table == .ppgWaveformSample && ppgIdentityV2) || (table == .v18AuxSample && v18IdentityV2)
        header.append(identityV2 ? 2 : PushBinaryCodec.formatVersion)
        header.append(PushBinaryCodec.kind(for: table).rawValue)
        if table != .rawBatch { appendLE(Int32(rowCount), to: &header) }
        try emit(header)
        for _ in 0..<rowCount {
            try checkAdmission(allowsWork)
            guard let row = try nextRow() else { throw PushProtocolException("binary selection ended early") }
            // Only fixed-size field headers are allocated. Blob Data is borrowed and sliced.
            var fields = Data(capacity: 64)
            let blob: Data
            switch (table, row) {
            case (.ppgWaveformSample, .ppgWaveform(let record)):
                guard ppgIdentityV2 || record.recordIndex == nil else {
                    throw PushProtocolException("PPG record identity requires negotiated protocol 1.3")
                }
                appendLE(record.rowId, to: &fields); appendLE(record.ts, to: &fields)
                if ppgIdentityV2 { try appendIdentity(record.recordIndex, maximum: Int64.max, to: &fields) }
                if let burstIndex = record.burstIndex { fields.append(1); appendLE(burstIndex, to: &fields) }
                else { fields.append(0) }
                blob = record.samples
            case (.v18AuxSample, .v18Aux(let record)):
                guard v18IdentityV2 || record.recordIndex == nil else {
                    throw PushProtocolException("auxiliary record identity requires negotiated protocol 1.4")
                }
                appendLE(record.rowId, to: &fields); appendLE(record.ts, to: &fields)
                if v18IdentityV2 { try appendIdentity(record.recordIndex, maximum: Int64(UInt32.max), to: &fields) }
                blob = record.fields
            case (.rawImuSession, .rawImuSession(let record)):
                guard record.columns.count == PushBinaryCodec.imuRecordPayloadBytes else {
                    throw PushProtocolException("rawImuSession record must carry 600 i16 columns")
                }
                appendLE(record.rowId, to: &fields); appendLE(record.ts, to: &fields)
                blob = record.columns
            case (.rawBatch, .rawBatch(let record)):
                guard record.batchId.utf8.count <= Int(UInt16.max) else {
                    throw PushProtocolException("binary string exceeds limit")
                }
                appendLE(UInt16(record.batchId.utf8.count), to: &fields)
                try emit(fields)
                try emit(Data(record.batchId.utf8))
                fields.removeAll(keepingCapacity: true)
                for value in [record.capturedAt, record.deviceClockRef, record.wallClockRef, record.startTs, record.endTs] {
                    appendLE(value, to: &fields)
                }
                appendLE(record.frameCount, to: &fields); appendLE(record.byteSize, to: &fields)
                blob = record.framesBlob
            default: throw PushProtocolException("binary row kind mismatch")
            }
            guard blob.count <= PushProtocolLimits.maxBodyBytes else {
                throw PushProtocolException("binary blob exceeds decoded limit")
            }
            appendLE(Int32(blob.count), to: &fields)
            try emit(fields)
            try emit(blob)
        }
        try checkAdmission(allowsWork)
        guard try nextRow() == nil else { throw PushProtocolException("binary selection has extra rows") }
        return total
    }

    private static func appendIdentity(_ index: Int64?, maximum: Int64, to data: inout Data) throws {
        guard let index else { data.append(0); return }
        guard index >= 0, index <= maximum else { throw PushProtocolException("invalid binary record index") }
        data.append(1); appendLE(index, to: &data)
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private static func checkAdmission(_ allowsWork: () -> Bool) throws {
        guard !Task.isCancelled, allowsWork() else { throw CancellationError() }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private final class Compressor {
        private var gzip = z_stream()
        private var gzipInitialized = false
        #if canImport(CNoopZstd)
        private var zstd: OpaquePointer?
        #endif
        private var buffer = [UInt8](repeating: 0, count: bufferBytes)

        init(encoding: String, level: Int, expectedBytes: Int?) throws {
            if encoding == "gzip" {
                // Same gzip parameters as the existing encoder; stream chunking adds no flushes.
                let status = deflateInit2_(&gzip, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                    MAX_WBITS + 16, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY,
                    ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                guard status == Z_OK else { throw PushProtocolException("gzip init failed") }
                gzipInitialized = true
            } else {
                #if canImport(CNoopZstd)
                zstd = noop_zstd_stream_create(Int32(level), UInt64(expectedBytes ?? 0), expectedBytes == nil ? 0 : 1)
                guard zstd != nil else { throw PushProtocolException("zstd init failed") }
                #else
                throw PushProtocolException("streaming zstd codec unavailable")
                #endif
            }
        }

        deinit {
            if gzipInitialized { deflateEnd(&gzip) }
            #if canImport(CNoopZstd)
            if let zstd { noop_zstd_stream_destroy(zstd) }
            #endif
        }

        func append(_ bytes: UnsafeRawBufferPointer, allowsWork: () -> Bool,
                    output: (UnsafeRawBufferPointer) throws -> Void) throws {
            try process(bytes, finishing: false, allowsWork: allowsWork, output: output)
        }

        func finish(allowsWork: () -> Bool, output: (UnsafeRawBufferPointer) throws -> Void) throws {
            try process(UnsafeRawBufferPointer(start: nil, count: 0), finishing: true,
                        allowsWork: allowsWork, output: output)
        }

        private func process(_ bytes: UnsafeRawBufferPointer, finishing: Bool,
                             allowsWork: () -> Bool, output: (UnsafeRawBufferPointer) throws -> Void) throws {
            var consumed = 0, done = false
            repeat {
                try checkAdmission(allowsWork)
                var produced = 0, used = 0
                if gzipInitialized {
                    gzip.next_in = bytes.baseAddress.map { UnsafeMutablePointer<Bytef>(mutating: $0.assumingMemoryBound(to: Bytef.self).advanced(by: consumed)) }
                    gzip.avail_in = uInt(bytes.count - consumed)
                    let before = gzip.avail_in
                    let status = buffer.withUnsafeMutableBufferPointer { target in
                        gzip.next_out = target.baseAddress; gzip.avail_out = uInt(bufferBytes)
                        return deflate(&gzip, finishing ? Z_FINISH : Z_NO_FLUSH)
                    }
                    used = Int(before - gzip.avail_in)
                    produced = bufferBytes - Int(gzip.avail_out)
                    gzip.next_in = nil
                    guard status == Z_OK || status == Z_STREAM_END || (!finishing && status == Z_BUF_ERROR && gzip.avail_in == 0) else {
                        throw PushProtocolException("gzip streaming failed")
                    }
                    done = finishing ? status == Z_STREAM_END : gzip.avail_in == 0 && gzip.avail_out > 0
                } else {
                    #if canImport(CNoopZstd)
                    var finished: Int32 = 0
                    let status = buffer.withUnsafeMutableBufferPointer { target in
                        noop_zstd_stream_encode(zstd,
                            bytes.baseAddress?.assumingMemoryBound(to: UInt8.self).advanced(by: consumed), bytes.count - consumed,
                            &used, target.baseAddress, target.count, &produced, finishing ? 1 : 0, &finished)
                    }
                    guard status == 0 else { throw PushProtocolException("zstd streaming failed") }
                    done = finishing ? finished != 0 : consumed + used == bytes.count
                    #else
                    throw PushProtocolException("streaming zstd codec unavailable")
                    #endif
                }
                consumed += used
                if produced > 0 {
                    try buffer.withUnsafeBytes { try output(UnsafeRawBufferPointer(rebasing: $0[..<produced])) }
                }
                guard done || used > 0 || produced > 0 else { throw PushProtocolException("binary encoder made no progress") }
            } while !done
        }
    }

    private final class ImmutableOutput {
        let directory: URL
        let temporary: URL
        private var descriptor: Int32 = -1

        init(directory: URL) throws {
            guard directory.isFileURL else { throw PushProtocolException("binary spool requires a file directory") }
            self.directory = directory
            temporary = directory.appendingPathComponent(".prepare-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            #endif
            descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw posixError() }
            do {
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
                #endif
            } catch { closeAndRemoveTemporary(); throw error }
        }

        deinit { closeAndRemoveTemporary() }

        func closeAndRemoveTemporary() {
            if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
            Darwin.unlink(temporary.path)
        }

        func write(_ bytes: UnsafeRawBufferPointer) throws {
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }

        func publish(digest: String, byteCount: Int, allowsWork: () -> Bool) throws -> URL {
            try checkAdmission(allowsWork)
            guard fchmod(descriptor, 0o400) == 0, fsync(descriptor) == 0 else { throw posixError() }
            let destination = directory.appendingPathComponent(digest + ".body")
            // link is atomic and refuses to replace an existing immutable body, including a symlink.
            if Darwin.link(temporary.path, destination.path) != 0 {
                guard errno == EEXIST else { throw posixError() }
                try validateExisting(destination, digest: digest, byteCount: byteCount, allowsWork: allowsWork)
            }
            let directoryFD = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
            guard directoryFD >= 0 else { throw posixError() }
            defer { Darwin.close(directoryFD) }
            guard fsync(directoryFD) == 0 else { throw posixError() }
            // From this point the complete immutable body is durable. An interruption may leave
            // this valid unreferenced artifact for conservative cleanup, never a partial body.
            return destination
        }

        private func validateExisting(_ url: URL, digest: String, byteCount: Int, allowsWork: () -> Bool) throws {
            let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw posixError() }
            defer { Darwin.close(fd) }
            var attributes = stat()
            guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
                  attributes.st_size == byteCount else { throw PushProtocolException("immutable body collision") }
            var hash = SHA256(), buffer = [UInt8](repeating: 0, count: bufferBytes)
            while true {
                try checkAdmission(allowsWork)
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw posixError() }
                if count == 0 { break }
                buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            }
            guard hex(hash.finalize()) == digest else { throw PushProtocolException("immutable body collision") }
        }

        private func posixError() -> Error { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
