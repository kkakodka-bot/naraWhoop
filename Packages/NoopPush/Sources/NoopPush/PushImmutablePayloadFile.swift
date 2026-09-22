import Foundation
import CryptoKit

/// Immutable wire bytes. Persistent encoding contains a digest-keyed leaf, never an absolute path.
/// The account-owned decoder supplies its directory; unbound file references fail closed.
public struct PushImmutablePayloadFile: Codable, Sendable {
    public static let directoryKey = CodingUserInfoKey(rawValue: "NoopPush.accountPayloadDirectory")!
    public let url: URL
    public let byteCount: Int
    public let sha256: String
    public var name: String { sha256 + ".wire" }

    public init(url: URL, byteCount: Int, sha256: String) throws {
        guard url.isFileURL, byteCount > 0, byteCount <= PushProtocolLimits.maxObjectWireBytes,
              PushPreparedSelection.digest(sha256) else { throw PushPreparedSelection.invalid() }
        self.url = url; self.byteCount = byteCount; self.sha256 = sha256
        try verify()
    }
    private enum CodingKeys: String, CodingKey { case name, byteCount, sha256 }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(byteCount, forKey: .byteCount)
        try c.encode(sha256, forKey: .sha256)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        let count = try c.decode(Int.self, forKey: .byteCount), hash = try c.decode(String.self, forKey: .sha256)
        guard name == hash + ".wire", let directory = decoder.userInfo[Self.directoryKey] as? URL else {
            throw PushPreparedSelection.invalid()
        }
        try self.init(url: directory.appendingPathComponent(name), byteCount: count, sha256: hash)
    }
    public func verify() throws {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, info.fileSize == byteCount else {
            throw PushPreparedSelection.invalid()
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256(), count = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard chunk.count <= byteCount - count else { throw PushPreparedSelection.invalid() }
            count += chunk.count; digest.update(data: chunk)
        }
        guard count == byteCount, digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw PushPreparedSelection.invalid()
        }
    }
    /// Explicit compatibility boundary for adapters which do not support file-backed transfer.
    public func materialized() throws -> Data { try verify(); return try Data(contentsOf: url) }
}

public struct PushBinaryPreparation: Sendable {
    public let id: UUID
    public let directory: URL
    public init(id: UUID, directory: URL) { self.id = id; self.directory = directory }
}
