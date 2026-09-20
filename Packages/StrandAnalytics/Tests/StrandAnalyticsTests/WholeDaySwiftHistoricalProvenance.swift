import CryptoKit
import Foundation

/// Historical provenance is pinned to immutable Git blobs, not whatever source happens to be
/// checked out today. Live replay must still match every saved output; a current-source corpus
/// is a separate gate and must never use this historical verification to ignore source drift.
enum WholeDaySwiftHistoricalProvenance {
    enum Version {
        case v1, v2
        var directory: String { self == .v1 ? "w4-whole-day-swift-v1" : "w4-whole-day-swift-v2" }
        var checkpoint: String {
            self == .v1 ? "8b7da7c1f0a905f8c973925b54175ed619d3b0e4" : "b5183a569e3e56924b15e7f03960d38194522adf"
        }
        var manifestSHA256: String {
            self == .v1 ? "d948f5b7dffbd71dece63586ecce08fb3c497c87995bf2685d6469d0782fa245"
                : "a12ec687e5d075c52825c1fb45b8680d239059b403a756d81940d330b9ae5b86"
        }
        var sourceCount: Int { self == .v1 ? 215 : 217 }
    }
    enum Failure: Error, Equatable { case invalidManifest, invalidSource, missingBlob, changedBlob }

    @discardableResult
    static func verify(_ version: Version, repository: URL) throws -> [String: Any] {
        let url = repository.appendingPathComponent("Tests/Fixtures/\(version.directory)/manifest.json")
        let bytes = try Data(contentsOf: url)
        guard digest(bytes) == version.manifestSHA256,
              let manifest = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let hashes = manifest["sourceHashes"] as? [String: String],
              hashes.count == version.sourceCount else { throw Failure.invalidManifest }
        try verifySources(hashes, checkpoint: version.checkpoint) { checkpoint, path in
            try readBlob(checkpoint: checkpoint, path: path, repository: repository)
        }
        return manifest
    }

    static func readBlob(checkpoint: String, path: String, repository: URL,
                         environment: [String: String]? = nil) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-replace-objects", "--no-lazy-fetch", "-C", repository.path, "cat-file", "blob", "\(checkpoint):\(path)"]
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Drain before waiting: some source blobs exceed the pipe's capacity.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.missingBlob }
        return data
    }

    static func verifySources(_ hashes: [String: String], checkpoint: String,
                              readBlob: (String, String) throws -> Data) throws {
        guard checkpoint.count == 40, checkpoint.allSatisfy({ "0123456789abcdef".contains($0) }),
              !hashes.isEmpty else { throw Failure.invalidSource }
        for (path, expected) in hashes.sorted(by: { $0.key < $1.key }) {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.hasPrefix("Packages/"), path.hasSuffix(".swift"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !path.contains(":"), !path.contains("\n"), !path.contains("\r"),
                  expected.count == 64, expected.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw Failure.invalidSource
            }
            guard digest(try readBlob(checkpoint, path)) == expected else { throw Failure.changedBlob }
        }
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
