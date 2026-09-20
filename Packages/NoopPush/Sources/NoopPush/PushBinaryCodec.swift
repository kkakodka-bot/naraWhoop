import Foundation
import CryptoKit

/// Platform-neutral packed payload for `bin_gzip_noop_push_v1` / `protobuf_zstd_noop_push_v1`.
public enum PushBinaryCodec {
    public static let magic = Data("NPB1".utf8)
    public static let formatVersion: UInt8 = 1
    public static let ppgIdentityFormatVersion: UInt8 = 2

    public enum Kind: UInt8 {
        case ppgWaveformSample = 1
        case v18AuxSample = 2
        case rawBatch = 3
        case rawImuSession = 4
    }

    /// 100 samples/second × 6 axes, axis-major i16 LE — the record layout ImuSessionFileStore writes.
    public static let imuColumnsPerRecord = 600
    public static let imuRecordPayloadBytes = imuColumnsPerRecord * 2

    public static func kind(for table: PushBinaryTable) -> Kind {
        switch table {
        case .ppgWaveformSample: return .ppgWaveformSample
        case .v18AuxSample: return .v18AuxSample
        case .rawBatch: return .rawBatch
        case .rawImuSession: return .rawImuSession
        }
    }

    public static func pack(table: PushBinaryTable, rows: [PushBinaryRow]) throws -> Data {
        guard !rows.isEmpty else { throw PushProtocolException("binary object must contain a row") }
        switch table {
        case .ppgWaveformSample:
            let records = try rows.map { row -> PushPpgWaveformRecord in
                guard case .ppgWaveform(let record) = row else {
                    throw PushProtocolException("binary row kind mismatch")
                }
                return record
            }
            return try packPpgRecords(records)
        case .v18AuxSample:
            let records = try rows.map { row -> PushV18AuxRecord in
                guard case .v18Aux(let record) = row else {
                    throw PushProtocolException("binary row kind mismatch")
                }
                return record
            }
            return try packV18Records(records)
        case .rawBatch:
            guard rows.count == 1, case .rawBatch(let record) = rows[0] else {
                throw PushProtocolException("rawBatch upload must contain exactly one batch row")
            }
            return try packRawBatch(record)
        case .rawImuSession:
            let records = try rows.map { row -> PushRawImuRecord in
                guard case .rawImuSession(let record) = row else {
                    throw PushProtocolException("binary row kind mismatch")
                }
                return record
            }
            return try packImuRecords(records)
        }
    }

    /// Exact packed size of the header for a table, without packing. Counted kinds carry a u32
    /// record count after the 6-byte magic/version/kind header; rawBatch does not.
    public static func packedHeaderSize(for table: PushBinaryTable) -> Int {
        switch table {
        case .rawBatch: return 6
        case .ppgWaveformSample, .v18AuxSample, .rawImuSession: return 10
        }
    }

    /// Exact packed size of one row, without packing. Lets batch selection run O(n) instead of
    /// re-packing the growing candidate set per row.
    public static func packedRowSize(_ row: PushBinaryRow, ppgIdentity: Bool = false) throws -> Int {
        switch row {
        case .ppgWaveform(let record):
            return 8 + 8 + 1 + (record.burstIndex != nil ? 4 : 0) + 4 + record.samples.count
                + (ppgIdentity || record.recordIndex != nil ? 8 : 0)
        case .v18Aux(let record):
            return 8 + 8 + 4 + record.fields.count
        case .rawImuSession(let record):
            guard record.columns.count == imuRecordPayloadBytes else {
                throw PushProtocolException("rawImuSession record must carry \(imuColumnsPerRecord) i16 columns")
            }
            return 8 + 8 + 4 + record.columns.count
        case .rawBatch(let record):
            return 2 + record.batchId.utf8.count + 8 * 5 + 4 + 4 + 4 + record.framesBlob.count
        }
    }

    private static func packPpgRecords(_ records: [PushPpgWaveformRecord]) throws -> Data {
        let identity = records.contains { $0.recordIndex != nil }
        var out = header(kind: .ppgWaveformSample, version: identity ? ppgIdentityFormatVersion : formatVersion)
        appendU32(Int32(records.count), to: &out)
        for record in records {
            appendI64(record.rowId, to: &out)
            appendI64(record.ts, to: &out)
            if let burstIndex = record.burstIndex {
                out.append(1)
                appendI32(burstIndex, to: &out)
            } else {
                out.append(0)
            }
            if identity {
                if let index = record.recordIndex, !(0...Int64(UInt32.max)).contains(index) {
                    throw PushProtocolException("PPG recordIndex is outside the wire u32 range")
                }
                appendI64(record.recordIndex ?? -1, to: &out)
            }
            try appendBlob(record.samples, to: &out)
        }
        return out
    }

    private static func packV18Records(_ records: [PushV18AuxRecord]) throws -> Data {
        var out = header(kind: .v18AuxSample)
        appendU32(Int32(records.count), to: &out)
        for record in records {
            appendI64(record.rowId, to: &out)
            appendI64(record.ts, to: &out)
            try appendBlob(record.fields, to: &out)
        }
        return out
    }

    /// Reads both archived v1 PPG and identity-preserving v2 PPG. Does not infer channel or sample time.
    public static func unpackPpgRecords(_ bytes: Data) throws -> [PushPpgWaveformRecord] {
        guard bytes.count <= PushProtocolLimits.maxObjectDecodedBytes else {
            throw PushProtocolException("PPG object exceeds decoded limit")
        }
        let data = [UInt8](bytes)
        var offset = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, count <= data.count - offset else {
                throw PushProtocolException("Truncated PPG object")
            }
            defer { offset += count }
            return data[offset..<(offset + count)]
        }
        func integer(_ width: Int) throws -> UInt64 {
            try take(width).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        guard Data(try take(4)) == magic else { throw PushProtocolException("Invalid PPG magic") }
        let version = try integer(1)
        guard version == 1 || version == 2, try integer(1) == UInt64(Kind.ppgWaveformSample.rawValue) else {
            throw PushProtocolException("Unsupported PPG object version or kind")
        }
        let count = Int(try integer(4))
        guard count > 0, count <= PushProtocolLimits.maxRecords else {
            throw PushProtocolException("Invalid PPG record count")
        }
        var records: [PushPpgWaveformRecord] = []
        for _ in 0..<count {
            let rowId = Int64(bitPattern: try integer(8))
            let ts = Int64(bitPattern: try integer(8))
            let hasBurst = try integer(1)
            guard rowId > 0, hasBurst <= 1 else { throw PushProtocolException("Invalid PPG record") }
            let burst = hasBurst == 1 ? Int32(bitPattern: UInt32(try integer(4))) : nil
            let index = version == 2 ? Int64(bitPattern: try integer(8)) : -1
            guard index == -1 || (0...Int64(UInt32.max)).contains(index) else {
                throw PushProtocolException("Invalid PPG recordIndex")
            }
            let samples = Data(try take(Int(try integer(4))))
            records.append(PushPpgWaveformRecord(rowId: rowId, ts: ts, burstIndex: burst,
                samples: samples, recordIndex: index == -1 ? nil : index))
        }
        guard offset == data.count else { throw PushProtocolException("Trailing PPG object bytes") }
        return records
    }

    private static func packRawBatch(_ record: PushRawBatchRecord) throws -> Data {
        var out = header(kind: .rawBatch)
        try appendUtf8(record.batchId, to: &out)
        appendI64(record.capturedAt, to: &out)
        appendI64(record.deviceClockRef, to: &out)
        appendI64(record.wallClockRef, to: &out)
        appendI64(record.startTs, to: &out)
        appendI64(record.endTs, to: &out)
        appendI32(record.frameCount, to: &out)
        appendI32(record.byteSize, to: &out)
        try appendBlob(record.framesBlob, to: &out)
        return out
    }

    private static func packImuRecords(_ records: [PushRawImuRecord]) throws -> Data {
        var out = header(kind: .rawImuSession)
        appendU32(Int32(records.count), to: &out)
        for record in records {
            guard record.columns.count == imuRecordPayloadBytes else {
                throw PushProtocolException("rawImuSession record must carry \(imuColumnsPerRecord) i16 columns")
            }
            appendI64(record.rowId, to: &out)
            appendI64(record.ts, to: &out)
            try appendBlob(record.columns, to: &out)
        }
        return out
    }

    private static func header(kind: Kind, version: UInt8 = formatVersion) -> Data {
        var out = Data(capacity: 6)
        out.append(magic)
        out.append(version)
        out.append(kind.rawValue)
        return out
    }

    private static func appendBlob(_ blob: Data, to out: inout Data) throws {
        guard blob.count <= PushProtocolLimits.maxBodyBytes else {
            throw PushProtocolException("binary blob exceeds decoded limit")
        }
        appendU32(Int32(blob.count), to: &out)
        out.append(blob)
    }

    private static func appendUtf8(_ value: String, to out: inout Data) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= Int(UInt16.max) else {
            throw PushProtocolException("binary string exceeds limit")
        }
        var length = UInt16(bytes.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(bytes)
    }

    private static func appendI32(_ value: Int32, to out: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }

    private static func appendU32(_ value: Int32, to out: inout Data) {
        appendI32(value, to: &out)
    }

    private static func appendI64(_ value: Int64, to out: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }

    public static func sha256Hex(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
