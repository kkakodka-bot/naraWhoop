import Foundation
import CryptoKit

// Offline review tool, never called by a test. Read an independently executed cfb9443 current
// corpus and native compatibility-run log; emit immutable qualified-result digests to stdout.
// Historical corpora are read-only and every reconstructed digest must equal a native-run digest.
let args = CommandLine.arguments
guard args.count == 4 else { fatalError("usage: qualified-oracle-receipt.swift CURRENT_CORPUS BASE_LOG REPOSITORY") }
let corpus = URL(fileURLWithPath: args[1]), repository = URL(fileURLWithPath: args[3])
func object(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}
func bytes(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
let manifest = try object(corpus.appendingPathComponent("manifest.json"))
let revision = "cfb94434b1b4ed4dba587e5c4e7af405e782e560"
guard manifest["sourceRevision"] as? String == revision else { fatalError("not the reconciled native base") }
let log = try String(contentsOfFile: args[2], encoding: .utf8)
var native: [String: [String: String]] = ["v1": [:], "v2": [:]]
for line in log.split(separator: "\n") {
    let parts = line.split(separator: " ")
    guard parts.count >= 3, ["IMMUTABLE_KERNEL_COMPAT", "FIVE_SEAM_DEFAULT_V2"].contains(parts[0]) else { continue }
    let version = parts[0] == "IMMUTABLE_KERNEL_COMPAT" ? "v1" : "v2"
    native[version]![String(parts[1])] = String(parts[2].dropFirst("sha256=".count))
}
var versions: [String: [[String: Any]]] = [:]
for version in ["v1", "v2"] {
    var entries: [[String: Any]] = []
    for entry in manifest["cases"] as! [[String: Any]] {
        let id = entry["id"] as! String, filename = entry["file"] as! String
        let capturedData = try Data(contentsOf: corpus.appendingPathComponent(filename))
        guard digest(capturedData) == entry["sha256"] as? String else { fatalError("capture hash changed") }
        var current = try object(corpus.appendingPathComponent(filename))
        let historicalURL = repository.appendingPathComponent("Tests/Fixtures/w4-whole-day-swift-\(version)/\(filename)")
        let historical = try object(historicalURL)
        var expected = current["expected"] as! [String: Any]
        var selection = expected["selection"] as! [String: Any]
        selection["hrvWindows"] = (selection["hrvWindows"] as! [[String: Any]]).map { row -> [String: Any] in
            guard row["measurementValid"] as? Bool == false, row["baselineEligible"] as? Bool == false,
                  row["rmssd"] is NSNull else { fatalError("unqualified RR became a measurement") }
            var copy = row
            for key in ["measurementValid", "reason", "baselineEligible", "baselineReason"] { copy.removeValue(forKey: key) }
            return copy
        }
        expected["selection"] = selection; current["expected"] = expected
        if version == "v1" {
            var input = current["input"] as! [String: Any]
            input["raw"] = (historical["input"] as! [String: Any])["raw"]
            current["input"] = input
        }
        let hash = digest(try bytes(current))
        guard native[version]?[id] == hash else { fatalError("native \(version) full DTO differs for \(id)") }
        entries.append(["id": id, "fullSHA256": hash, "expectedSHA256": digest(try bytes(expected)),
                        "historicalSHA256": digest(try Data(contentsOf: historicalURL))])
    }
    guard entries.count == 13, native[version]?.count == 13 else { fatalError("incomplete corpus") }
    versions[version] = entries
}
let output: [String: Any] = ["schemaVersion": 1, "contract": "qualified-physiology-base-v1",
    "sourceRevision": revision, "producer": "actual-native-swift-reconciled-base", "versions": versions]
FileHandle.standardOutput.write(try bytes(output))
