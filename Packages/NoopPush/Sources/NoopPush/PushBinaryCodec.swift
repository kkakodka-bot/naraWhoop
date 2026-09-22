import Foundation
import CryptoKit

/// Platform-neutral packed payload for `bin_gzip_noop_push_v1` / `protobuf_zstd_noop_push_v1`.
public enum PushBinaryCodec {
    public static let magic = Data("NPB1".utf8)
    public static let formatVersion: UInt8 = 1

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

    public static func pack(table: PushBinaryTable, rows: [PushBinaryRow], ppgIdentityV2: Bool = false,
                            v18IdentityV2: Bool = false) throws -> Data {
        guard !rows.isEmpty else { throw PushProtocolException("binary object must contain a row") }
        switch table {
        case .ppgWaveformSample:
            let records = try rows.map { row -> PushPpgWaveformRecord in
                guard case .ppgWaveform(let record) = row else {
                    throw PushProtocolException("binary row kind mismatch")
                }
                return record
            }
            return try packPpgRecords(records, identityV2: ppgIdentityV2)
        case .v18AuxSample:
            let records = try rows.map { row -> PushV18AuxRecord in
                guard case .v18Aux(let record) = row else {
                    throw PushProtocolException("binary row kind mismatch")
                }
                return record
            }
            return try packV18Records(records, identityV2: v18IdentityV2)
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
    public static func packedRowSize(_ row: PushBinaryRow, ppgIdentityV2: Bool = false,
                                      v18IdentityV2: Bool = false) throws -> Int {
        switch row {
        case .ppgWaveform(let record):
            return 8 + 8 + 1 + (record.burstIndex != nil ? 4 : 0) + 4 + record.samples.count
                + (ppgIdentityV2 ? (record.recordIndex == nil ? 1 : 9) : 0)
        case .v18Aux(let record):
            return 8 + 8 + 4 + record.fields.count + (v18IdentityV2 ? (record.recordIndex == nil ? 1 : 9) : 0)
        case .rawImuSession(let record):
            guard record.columns.count == imuRecordPayloadBytes else {
                throw PushProtocolException("rawImuSession record must carry \(imuColumnsPerRecord) i16 columns")
            }
            return 8 + 8 + 4 + record.columns.count
        case .rawBatch(let record):
            return 2 + record.batchId.utf8.count + 8 * 5 + 4 + 4 + 4 + record.framesBlob.count
        }
    }

    private static func packPpgRecords(_ records: [PushPpgWaveformRecord], identityV2: Bool) throws -> Data {
        guard identityV2 || records.allSatisfy({ $0.recordIndex == nil }) else {
            throw PushProtocolException("PPG record identity requires negotiated protocol 1.3")
        }
        var out = header(kind: .ppgWaveformSample)
        if identityV2 { out[4] = 2 }
        appendU32(Int32(records.count), to: &out)
        for record in records {
            appendI64(record.rowId, to: &out)
            appendI64(record.ts, to: &out)
            if identityV2 {
                if let index = record.recordIndex {
                    guard index >= 0 else { throw PushProtocolException("invalid PPG record index") }
                    out.append(1)
                    appendI64(index, to: &out)
                } else { out.append(0) }
            }
            if let burstIndex = record.burstIndex {
                out.append(1)
                appendI32(burstIndex, to: &out)
            } else {
                out.append(0)
            }
            try appendBlob(record.samples, to: &out)
        }
        return out
    }

    private static func packV18Records(_ records: [PushV18AuxRecord], identityV2: Bool) throws -> Data {
        guard identityV2 || records.allSatisfy({ $0.recordIndex == nil }) else {
            throw PushProtocolException("auxiliary record identity requires negotiated protocol 1.4")
        }
        var out = header(kind: .v18AuxSample)
        if identityV2 { out[4] = 2 }
        appendU32(Int32(records.count), to: &out)
        for record in records {
            appendI64(record.rowId, to: &out)
            appendI64(record.ts, to: &out)
            if identityV2 {
                if let index = record.recordIndex {
                    guard (0...Int64(UInt32.max)).contains(index) else { throw PushProtocolException("invalid auxiliary record index") }
                    out.append(1); appendI64(index, to: &out)
                } else { out.append(0) }
            }
            try appendBlob(record.fields, to: &out)
        }
        return out
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

    private static func header(kind: Kind) -> Data {
        var out = Data(capacity: 6)
        out.append(magic)
        out.append(formatVersion)
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
