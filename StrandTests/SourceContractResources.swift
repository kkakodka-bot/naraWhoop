import Foundation
import CryptoKit
import XCTest

/// Source assertions run inside a sandboxed app host. The build stage bundles exact
/// current source, so tests never need permission to reopen the external checkout.
enum SourceContractResources {
    private struct Manifest: Decodable {
        struct File: Decodable { let sha256: String; let bytes: Int }
        let schema_version: Int
        let source_revision: String
        let files: [String: File]
    }

    static func data(_ path: String, in bundle: Bundle) throws -> Data {
        let root = try XCTUnwrap(bundle.resourceURL).appendingPathComponent("SourceContracts", isDirectory: true)
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.schema_version, 1)
        XCTAssertEqual(manifest.source_revision.count, 40)
        let expected = try XCTUnwrap(manifest.files[path], "Unstaged source contract: \(path)")
        let bytes = try Data(contentsOf: root.appendingPathComponent(path))
        let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(bytes.count, expected.bytes, "Source size changed after build: \(path)")
        XCTAssertEqual(actual, expected.sha256, "Source hash changed after build: \(path)")
        return bytes
    }

    static func text(_ path: String, in bundle: Bundle) throws -> String {
        try XCTUnwrap(String(data: data(path, in: bundle), encoding: .utf8), "Source is not UTF-8: \(path)")
    }
}
