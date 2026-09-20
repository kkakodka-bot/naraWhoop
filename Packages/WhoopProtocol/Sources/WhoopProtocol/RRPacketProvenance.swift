import Foundation
import CryptoKit

/// Immutable checked WHOOP5 v18 sensor record. V1 retains bytes, not a reconstructed beat clock.
public struct RRPacketProvenance: Codable, Equatable, Sendable {
    public let packetId: String
    public let ts: Int
    public let sensorTs: Int
    public let recordIndex: Int
    public let rawHex: String
    public let srcChannel: Int
    public let schemaVersion: Int
    public let decoderVersion: String
    public let clockVersion: String
    public let timestampPrecisionSeconds: Double
    public let clockOffsetSeconds: Int
    public let declaredCount: Int

    public struct Word: Equatable, Sendable {
        public let index: Int
        public let rawTicks: Int
        public var rrMs: Int { Whoop5RR.milliseconds(ticks: UInt16(rawTicks)) }
    }
    /// Only complete declared arrays prove local adjacency. Zeros keep their original slot.
    public var words: [Word] {
        guard (1...4).contains(declaredCount), let bytes = Self.bytes(rawHex),
              let checked = Self.checked(bytes, mappedTs: ts), checked == self else { return [] }
        let payloadEnd = (Int(bytes[2]) | (Int(bytes[3]) << 8)) + 4
        guard 24 + declaredCount * 2 <= payloadEnd else { return [] }
        return (0..<declaredCount).map { Word(index: $0, rawTicks: Int(bytes[24 + $0 * 2]) | Int(bytes[25 + $0 * 2]) << 8) }
    }
    public func mapped(to timestamp: Int) -> Self? {
        Self(packetId: packetId, ts: timestamp, sensorTs: sensorTs, recordIndex: recordIndex, rawHex: rawHex,
            srcChannel: srcChannel, schemaVersion: schemaVersion, decoderVersion: decoderVersion,
            clockVersion: timestamp == sensorTs ? "sensor-second-unmapped" : "legacy-stale-clock-snap300-v1",
            timestampPrecisionSeconds: timestamp == sensorTs ? 1 : 300,
            clockOffsetSeconds: timestamp - sensorTs, declaredCount: declaredCount)
    }
    public static func bytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0, hex.count <= 131_086 else { return nil }
        let chars = Array(hex.utf8)
        func digit(_ c: UInt8) -> UInt8? {
            if (48...57).contains(c) { return c - 48 }
            if (97...102).contains(c) { return c - 87 }
            return nil
        }
        var bytes: [UInt8] = []; bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let a = digit(chars[i]), let b = digit(chars[i + 1]) else { return nil }
            bytes.append(a * 16 + b)
        }
        return bytes
    }
    public static func checked(_ frame: [UInt8], mappedTs: Int? = nil) -> Self? {
        guard frame.count >= 28, frame[8] == 47, frame[9] == 18,
              verifyFrame(frame, family: .whoop5).ok else { return nil }
        let payloadEnd = (Int(frame[2]) | Int(frame[3]) << 8) + 4
        guard payloadEnd + 4 == frame.count, payloadEnd >= 24 else { return nil }
        func u32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(frame[offset + $1]) << ($1 * 8) }
        }
        let sensorTs = u32(15), ts = mappedTs ?? sensorTs
        func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
            let alphabet = Array("0123456789abcdef".utf8)
            var output: [UInt8] = []
            for byte in bytes { output.append(alphabet[Int(byte >> 4)]); output.append(alphabet[Int(byte & 15)]) }
            return String(decoding: output, as: UTF8.self)
        }
        let hash = hex(SHA256.hash(data: Data(frame[8..<payloadEnd])))
        return Self(packetId: hash, ts: ts, sensorTs: sensorTs, recordIndex: u32(11),
            rawHex: hex(frame), srcChannel: 5, schemaVersion: 1,
            decoderVersion: "whoop5-v18-original-words-v1",
            clockVersion: ts == sensorTs ? "sensor-second-unmapped" : "legacy-stale-clock-snap300-v1",
            timestampPrecisionSeconds: ts == sensorTs ? 1 : 300,
            clockOffsetSeconds: ts - sensorTs, declaredCount: Int(frame[23]))
    }
}
