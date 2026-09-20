import Foundation
import XCTest

final class WholeDaySwiftHistoricalProvenanceTests: XCTestCase {
    private typealias Proof = WholeDaySwiftHistoricalProvenance
    private let path = "Packages/StrandAnalytics/Sources/StrandAnalytics/Synthetic.swift"
    private let checkpoint = String(repeating: "a", count: 40)
    private let blob = Data("// synthetic source\n".utf8)

    func testVerifiesEveryExactBlobAtOnePinnedCheckpoint() throws {
        let other = "Packages/WhoopStore/Sources/WhoopStore/Synthetic.swift"
        let hashes = [path: Proof.digest(blob), other: Proof.digest(Data("second".utf8))]
        var observed: [String] = []
        try Proof.verifySources(hashes, checkpoint: checkpoint) { revision, file in
            XCTAssertEqual(revision, checkpoint)
            observed.append(file)
            return file == path ? blob : Data("second".utf8)
        }
        XCTAssertEqual(observed, hashes.keys.sorted())
    }

    func testChangedOrMissingHistoricalBlobFails() throws {
        XCTAssertThrowsError(try Proof.verifySources([path: Proof.digest(blob)], checkpoint: checkpoint) { _, _ in
            Data("changed source".utf8)
        }) { XCTAssertEqual($0 as? Proof.Failure, .changedBlob) }
        XCTAssertThrowsError(try Proof.verifySources([path: Proof.digest(blob)], checkpoint: checkpoint) { _, _ in
            throw Proof.Failure.missingBlob
        }) { XCTAssertEqual($0 as? Proof.Failure, .missingBlob) }
    }

    func testEmptySourcesAndUnsafePathOrDigestCannotReachReader() throws {
        var reads = 0
        let read: (String, String) throws -> Data = { _, _ in reads += 1; return self.blob }
        XCTAssertThrowsError(try Proof.verifySources([:], checkpoint: checkpoint, readBlob: read))
        for bad in ["/Packages/file.swift", "Packages/../file.swift", "Packages//file.swift", "Packages/./file.swift",
                    "Packages/file.swift\n", "Packages/file:other.swift", "Sources/file.swift"] {
            XCTAssertThrowsError(try Proof.verifySources([bad: Proof.digest(blob)], checkpoint: checkpoint, readBlob: read))
        }
        for bad in ["", String(repeating: "G", count: 64), Proof.digest(blob) + "\n"] {
            XCTAssertThrowsError(try Proof.verifySources([path: bad], checkpoint: checkpoint, readBlob: read))
        }
        for bad in ["HEAD", checkpoint + "\n", String(repeating: "A", count: 40)] {
            XCTAssertThrowsError(try Proof.verifySources([path: Proof.digest(blob)], checkpoint: bad, readBlob: read))
        }
        XCTAssertEqual(reads, 0)
    }

    func testBothImmutableManifestAndSourceInventoriesArePinned() throws {
        XCTAssertEqual(Proof.Version.v1.sourceCount, 215)
        XCTAssertEqual(Proof.Version.v2.sourceCount, 217)
        XCTAssertNotEqual(Proof.Version.v1.checkpoint, Proof.Version.v2.checkpoint)
        XCTAssertNotEqual(Proof.Version.v1.manifestSHA256, Proof.Version.v2.manifestSHA256)
    }

    func testActualHistoricalGitBlobsMatchBothImmutableSourceInventories() throws {
        var repository = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        for version in [Proof.Version.v1, .v2] {
            let manifest = try Proof.verify(version, repository: repository)
            XCTAssertEqual((manifest["sourceHashes"] as? [String: String])?.count, version.sourceCount)
        }
    }

    func testActualMissingPromisorObjectFailsWithoutStartingAnyFetch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("historical-missing-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = root.appendingPathComponent("git-trace.log")
        // No transport may run even in the intentionally failing pre-repair control.
        let environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                           "GIT_ALLOW_PROTOCOL": "", "GIT_TERMINAL_PROMPT": "0", "GIT_TRACE": trace.path]
        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + args
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try git(["init", "--quiet"])
        try git(["config", "extensions.partialClone", "review"])
        try git(["config", "remote.review.promisor", "true"])
        try git(["config", "remote.review.url", root.appendingPathComponent("absent-remote").path])
        XCTAssertThrowsError(try Proof.readBlob(checkpoint: checkpoint, path: path, repository: root, environment: environment)) {
            XCTAssertEqual($0 as? Proof.Failure, .missingBlob)
        }
        let commands = try String(contentsOf: trace, encoding: .utf8)
        XCTAssertFalse(commands.contains("git fetch"), commands)
        XCTAssertFalse(commands.contains("run_command: git"), commands)
    }
}
