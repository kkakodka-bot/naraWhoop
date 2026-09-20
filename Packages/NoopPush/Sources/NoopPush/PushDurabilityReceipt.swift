import Foundation
import CryptoKit

/// Intake durability v1, not a transport-level success flag. Unknown versions fail closed.
public struct PushDurabilityReceipt: Codable, Equatable, Sendable {
    public let version: Int
    public let state: String
    public let receiptId: String
    public let ownerUserId: String
    public let deviceId: String
    public let objectId: String
    public let batchId: String
    public let sourceId: String
    public let stream: String
    public let schemaVersion: Int
    public let objectKey: String
    public let contentSha256: String
    public let wireSha256: String
    public let compressedBytes: Int64
    public let uncompressedBytes: Int64
    public let verifiedAt: String
    public let indexedAt: String

    public var isValid: Bool {
        guard let verified = Self.date(verifiedAt), let indexed = Self.date(indexedAt),
              verified.timeIntervalSince1970 > 0, indexed >= verified else { return false }
        return version == 1 && state == "verified_indexed" && schemaVersion > 0
            && [receiptId, ownerUserId, deviceId, objectId, batchId, sourceId].allSatisfy(Self.uuid)
            && !stream.isEmpty && !objectKey.isEmpty && objectKey.count <= 1024
            && objectKey.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && [contentSha256, wireSha256].allSatisfy(Self.digest)
            && compressedBytes > 0 && uncompressedBytes > 0
            && Self.date(verifiedAt) != nil && Self.date(indexedAt) != nil
    }

    public func matches(_ manifest: PushObjectManifest, owner: AccountScope,
                        wireSHA256: String, wireBytes: Int) -> Bool {
        isValid && ownerUserId == owner.userID
            && deviceId == Self.canonicalDevice(owner: owner.userID, device: manifest.deviceId)
            && objectId == manifest.objectId && batchId == manifest.batchId && sourceId == manifest.sourceId
            && stream == manifest.stream
            && schemaVersion == PushProtocol.schemaVersion(stream: manifest.stream, protocolVersion: manifest.protocolVersion)
            && contentSha256 == manifest.contentSha256 && wireSha256 == wireSHA256
            && compressedBytes == manifest.compressedBytes && compressedBytes == Int64(wireBytes)
            && uncompressedBytes == manifest.uncompressedBytes
    }

    /// Inline intake recompresses decoded NDJSON on the server, so its wire digest/size attest the
    /// archive, not the client's gzip representation. The exact decoded bytes are bound here.
    public func matches(_ batch: PushBatch, owner: AccountScope) -> Bool {
        isValid && ownerUserId == owner.userID
            && deviceId == Self.canonicalDevice(owner: owner.userID, device: batch.deviceId)
            && objectId == batch.batchId && batchId == batch.batchId && sourceId == batch.sourceId
            && stream == batch.table.wireName
            && schemaVersion == PushProtocol.schemaVersion(stream: batch.table.wireName, protocolVersion: batch.protocolVersion)
            && contentSha256 == Self.sha256(batch.body) && uncompressedBytes == Int64(batch.body.count)
    }

    // Byte-identical to Edge keys.ts noopDeviceId/uuidFromParts, including UUID variant check.
    public static func canonicalDevice(owner: String, device: String) -> String {
        if device.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                        options: [.regularExpression, .caseInsensitive]) != nil { return device.lowercased() }
        var hex = Array(sha256(Data("\(owner)|noop|\(device.isEmpty ? "strap" : device)".utf8)).prefix(32))
        hex[12] = "5"; hex[16] = "a"
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }.joined(separator: "-")
    }
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func date(_ value: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions.insert(.withFractionalSeconds)
        if let date = f.date(from: value) { return date }
        f.formatOptions.remove(.withFractionalSeconds)
        return f.date(from: value)
    }
    private static func uuid(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    private static func digest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

/// Replayable progress plus cleanup debt. Receipt association must precede writing this intent.
public struct PushSourceCommit: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case append, binary, mutable }
    public let kind: Kind
    public let table: String
    public let deviceID: String
    public let batchIDs: [String]
    public let cursor: PushCursor?
    public let window: PushWindowProgress?
    public let rawBatchIDs: [String]
    public init(kind: Kind, table: String, deviceID: String, batchIDs: [String], cursor: PushCursor? = nil,
                window: PushWindowProgress? = nil, rawBatchIDs: [String] = []) {
        self.kind = kind; self.table = table; self.deviceID = deviceID; self.batchIDs = batchIDs
        self.cursor = cursor; self.window = window; self.rawBatchIDs = rawBatchIDs
    }
}
