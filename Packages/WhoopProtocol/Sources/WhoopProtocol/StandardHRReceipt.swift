import Foundation

/// Original 0x2A37 notification and host receipt clocks. These are arrival clocks, NOT beat timestamps.
/// A session/ordinal identifies a notification even when several identical packets arrive in one second.
/// Neither session membership nor consecutive ordinals establishes uninterrupted sensor acquisition.
public struct StandardHRReceipt: Codable, Equatable, Sendable {
    public let receiptId: String
    public let ts: Int
    public let sessionId: String
    public let notificationOrdinal: Int64
    public let receivedUnixMs: Int64
    public let receivedMonotonicNs: Int64
    public let rawHex: String
    public let schemaVersion: Int
    public let clockVersion: String

    public static func capture(_ bytes: [UInt8], sessionId: String, notificationOrdinal: Int64,
                               receivedUnixMs: Int64, receivedMonotonicNs: Int64) -> Self? {
        guard UUID(uuidString: sessionId) != nil, notificationOrdinal >= 0,
              receivedUnixMs >= 0, receivedMonotonicNs >= 0, (1...512).contains(bytes.count) else { return nil }
        let id = sessionId.lowercased()
        return Self(receiptId: "\(id):\(notificationOrdinal)", ts: Int(receivedUnixMs / 1000),
            sessionId: id, notificationOrdinal: notificationOrdinal, receivedUnixMs: receivedUnixMs,
            receivedMonotonicNs: receivedMonotonicNs,
            rawHex: bytes.map { String(format: "%02x", $0) }.joined(), schemaVersion: 1,
            clockVersion: "host-arrival-unmapped")
    }

    public var isValid: Bool {
        guard let bytes = RRPacketProvenance.bytes(rawHex) else { return false }
        return Self.capture(bytes, sessionId: sessionId, notificationOrdinal: notificationOrdinal,
            receivedUnixMs: receivedUnixMs, receivedMonotonicNs: receivedMonotonicNs) == self
    }

    /// Exact, ordered interval words including zero/invalid physiological values. A truncated declared
    /// field invalidates the decoded array, while the original bytes remain retained for diagnosis.
    public var rrRawTicks: [Int]? {
        guard isValid, let bytes = RRPacketProvenance.bytes(rawHex), let flags = bytes.first else { return nil }
        var offset = flags & 1 == 0 ? 2 : 3
        guard bytes.count >= offset else { return nil }
        if flags & 8 != 0 { offset += 2 }
        guard bytes.count >= offset else { return nil }
        guard flags & 16 != 0 else { return bytes.count == offset ? [] : nil }
        guard bytes.count > offset, (bytes.count - offset) % 2 == 0 else { return nil }
        return stride(from: offset, to: bytes.count, by: 2).map { Int(bytes[$0]) | Int(bytes[$0 + 1]) << 8 }
    }
}
