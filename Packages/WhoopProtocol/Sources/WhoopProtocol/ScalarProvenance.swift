import Foundation
import CryptoKit

public enum ScalarProvenanceError: Error, Equatable {
    case invalidValue
    case unsupportedShape
    case exceedsLimit
}

/// Describes an observed source or a newly executed derivation. Nil on a legacy sample
/// means unknown; it must not be replaced with today's settings during readback.
public struct ScalarProvenance: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable {
        case whoopV18 = "whoop-v18"
        case whoopV26PpgDerived = "whoop-v26-ppg-derived"
        case legacyUnknown = "legacy-unknown"
    }
    public enum Algorithm: String, Codable, Sendable {
        case ppgACF = "ppg-acf-v1"
        case ppgACFSubLag = "ppg-acf-sublag-v1"
    }
    public enum InputSelection: String, Codable, Sendable {
        case lastRecordPerSecond = "last-record-per-second-v1"
        case concatenateRecordsPerSecond = "concat-records-per-second-v1"
    }
    public let v: Int
    public let origin: Origin
    public let recordIndex: Int?
    public let frameSHA256: String?
    public let algorithm: Algorithm?
    public let sampleRateHz: Int?
    public let windowSettingSeconds: Int?
    public let inputStartTs: Int?
    public let inputEndTs: Int?
    public let inputSHA256: String?
    public let inputSelection: InputSelection?

    public init(v: Int = 1, origin: Origin, recordIndex: Int? = nil, frameSHA256: String? = nil,
                algorithm: Algorithm? = nil, sampleRateHz: Int? = nil, windowSettingSeconds: Int? = nil,
                inputStartTs: Int? = nil, inputEndTs: Int? = nil, inputSHA256: String? = nil,
                inputSelection: InputSelection? = nil) throws {
        self.v = v; self.origin = origin; self.recordIndex = recordIndex; self.frameSHA256 = frameSHA256
        self.algorithm = algorithm; self.sampleRateHz = sampleRateHz; self.windowSettingSeconds = windowSettingSeconds
        self.inputStartTs = inputStartTs; self.inputEndTs = inputEndTs; self.inputSHA256 = inputSHA256
        self.inputSelection = inputSelection
        guard v == 1 else { throw ScalarProvenanceError.unsupportedShape }
        let jsonSafeLimit: Int64 = 9_007_199_254_740_991
        guard [v, recordIndex, sampleRateHz, windowSettingSeconds, inputStartTs, inputEndTs]
            .compactMap({ $0 }).allSatisfy({ (-jsonSafeLimit...jsonSafeLimit).contains(Int64($0)) }) else {
            throw ScalarProvenanceError.invalidValue
        }
        if let recordIndex, UInt32(exactly: recordIndex) == nil { throw ScalarProvenanceError.invalidValue }
        for digest in [frameSHA256, inputSHA256].compactMap({ $0 }) {
            guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw ScalarProvenanceError.invalidValue }
        }
        switch origin {
        case .whoopV18, .legacyUnknown:
            guard algorithm == nil, sampleRateHz == nil, windowSettingSeconds == nil,
                  inputStartTs == nil, inputEndTs == nil, inputSHA256 == nil, inputSelection == nil else {
                throw ScalarProvenanceError.invalidValue
            }
            if origin == .legacyUnknown, recordIndex != nil || frameSHA256 != nil { throw ScalarProvenanceError.invalidValue }
        case .whoopV26PpgDerived:
            guard recordIndex == nil, frameSHA256 == nil, algorithm != nil,
                  let sampleRateHz, sampleRateHz > 0, let windowSettingSeconds, windowSettingSeconds > 0,
                  let inputStartTs, let inputEndTs, inputStartTs < inputEndTs, inputSHA256 != nil else {
                throw ScalarProvenanceError.invalidValue
            }
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case v, origin, recordIndex, frameSHA256, algorithm, sampleRateHz, windowSettingSeconds
        case inputStartTs, inputEndTs, inputSHA256, inputSelection
    }
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        guard Set(keys).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw ScalarProvenanceError.unsupportedShape
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        for key in c.allKeys {
            if try c.decodeNil(forKey: key) { throw ScalarProvenanceError.invalidValue }
        }
        try self.init(v: c.decode(Int.self, forKey: .v), origin: c.decode(Origin.self, forKey: .origin),
            recordIndex: c.decodeIfPresent(Int.self, forKey: .recordIndex),
            frameSHA256: c.decodeIfPresent(String.self, forKey: .frameSHA256),
            algorithm: c.decodeIfPresent(Algorithm.self, forKey: .algorithm),
            sampleRateHz: c.decodeIfPresent(Int.self, forKey: .sampleRateHz),
            windowSettingSeconds: c.decodeIfPresent(Int.self, forKey: .windowSettingSeconds),
            inputStartTs: c.decodeIfPresent(Int.self, forKey: .inputStartTs),
            inputEndTs: c.decodeIfPresent(Int.self, forKey: .inputEndTs),
            inputSHA256: c.decodeIfPresent(String.self, forKey: .inputSHA256),
            inputSelection: c.decodeIfPresent(InputSelection.self, forKey: .inputSelection))
    }

    public func canonicalJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(self)
        guard bytes.count <= 1024 else { throw ScalarProvenanceError.exceedsLimit }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func decodeJSON(_ json: String?) throws -> Self? {
        guard let json else { return nil }
        let bytes = Data(json.utf8)
        guard bytes.count <= 1024 else { throw ScalarProvenanceError.exceedsLimit }
        return try JSONDecoder().decode(Self.self, from: bytes)
    }

    static func observedV18(_ frame: ParsedFrame) -> Self? {
        guard frame.parsed["hist_version"]?.intValue == 18 else { return nil }
        if let digest = frame.frameSHA256 {
            return try? Self(origin: .whoopV18, recordIndex: frame.parsed["record_index"]?.intValue,
                             frameSHA256: digest)
        }
        let hex = Array(frame.rawHex.utf8)
        guard !hex.isEmpty, hex.count.isMultiple(of: 2), frame.lenBytes == hex.count / 2 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var bytes = Data(capacity: frame.lenBytes)
        for i in stride(from: 0, to: hex.count, by: 2) {
            guard let hi = nibble(hex[i]), let lo = nibble(hex[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
        }
        return try? Self(origin: .whoopV18, recordIndex: frame.parsed["record_index"]?.intValue,
                         frameSHA256: digest(bytes))
    }

    /// Wire golden shared with Android: exact selected input bytes, before any filtering.
    public static func ppgInputBytes(_ records: [PpgWaveformSample]) throws -> Data {
        guard !records.isEmpty, let recordCount = UInt32(exactly: records.count) else {
            throw ScalarProvenanceError.invalidValue
        }
        var bytes = Data("w1-ppg-input-v1\n".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
        }
        append(recordCount)
        var previous: Int?
        for record in records {
            // Concatenating producers preserve encounter order within one second. The framing
            // retains every record boundary; it does not normalize their input to Swift's choice.
            guard previous.map({ $0 <= record.ts }) ?? true,
                  let sampleCount = UInt32(exactly: record.samples.count) else { throw ScalarProvenanceError.invalidValue }
            previous = record.ts
            append(Int64(record.ts))
            if let index = record.recordIndex {
                guard UInt32(exactly: index) != nil else { throw ScalarProvenanceError.invalidValue }
                bytes.append(1); append(Int64(index))
            } else { bytes.append(0) }
            append(sampleCount)
            for sample in record.samples {
                guard let i16 = Int16(exactly: sample) else { throw ScalarProvenanceError.invalidValue }
                append(i16)
            }
        }
        return bytes
    }

    static func derivedPPG(_ records: [PpgWaveformSample], fs: Int, windowSeconds: Int,
                           subLagInterp: Bool) -> Self? {
        guard let first = records.first, let last = records.last, last.ts < Int.max,
              let bytes = try? ppgInputBytes(records) else { return nil }
        return try? Self(origin: .whoopV26PpgDerived,
            algorithm: subLagInterp ? .ppgACFSubLag : .ppgACF, sampleRateHz: fs,
            windowSettingSeconds: windowSeconds, inputStartTs: first.ts, inputEndTs: last.ts + 1,
            inputSHA256: digest(bytes), inputSelection: .lastRecordPerSecond)
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
