import Foundation
import WhoopProtocol

/// Second corpus revision, still schema 1 / recipe contract w4-whole-day-v1.
/// The first corpus and its generator remain immutable historical evidence.
enum WholeDaySwiftV2Corpus {
    typealias Exporter = WholeDaySwiftParityExporter
    static let parentManifestSHA256 = "d948f5b7dffbd71dece63586ecce08fb3c497c87995bf2685d6469d0782fa245"
    static let directoryName = "w4-whole-day-swift-v2"

    static var repository: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root
    }
    static var directory: URL { repository.appendingPathComponent("Tests/Fixtures/\(directoryName)") }
    static var parentDirectory: URL { repository.appendingPathComponent("Tests/Fixtures/w4-whole-day-swift-v1") }

    /// Entirely synthetic, zero-filled v18 envelope, never sent to hardware. The only populated
    /// measurement is the raw band flag. Both checksums and extraction use production Swift APIs.
    /// This is a decoder control, NOT a source frame/provenance assertion for the generated rows.
    static func decodeBandByte(_ raw: UInt8) throws -> SleepStateSample {
        let timestamp = 1_781_485_200
        var frame = [UInt8](repeating: 0, count: 124)
        frame[0] = 0xAA
        frame[1] = 1
        frame[2] = 116
        frame[8] = 47
        frame[9] = 18
        for i in 0..<4 { frame[15 + i] = UInt8(truncatingIfNeeded: timestamp >> (8 * i)) }
        frame[81] = raw
        let headerCRC = crc16Modbus(frame, 0, 6)
        frame[6] = UInt8(truncatingIfNeeded: headerCRC)
        frame[7] = UInt8(truncatingIfNeeded: headerCRC >> 8)
        let payloadCRC = crc32(frame, 8, 120)
        for i in 0..<4 { frame[120 + i] = UInt8(truncatingIfNeeded: payloadCRC >> (8 * i)) }
        let parsed = parseFrame(frame, family: .whoop5)
        guard verifyFrame(frame, family: .whoop5).ok, parsed.ok, parsed.crcOK == true else {
            throw Exporter.Failure.invalidRecipe
        }
        let samples = extractHistoricalStreams([parsed], deviceClockRef: timestamp, wallClockRef: timestamp).sleepState
        guard samples.count == 1, let sample = samples.first,
              sample.ts == timestamp, sample.rawByte == Int(raw) else { throw Exporter.Failure.invalidRecipe }
        return sample
    }

    static func recipes() throws -> [Exporter.Recipe] {
        // The old resting-block recipe intended state 1, but incorrectly encoded it in bit 0.
        // For NEW synthetic inputs use byte 0x10 and derive state with the real v18 decoder.
        // Do not attach the decoder-control frame's identity/provenance to unrelated recipe rows.
        let decoded = try decodeBandByte(0x10)
        guard decoded.state == 1 else { throw Exporter.Failure.invalidRecipe }
        return try Exporter.kernelRecipes().map { original in
            var recipe = original
            recipe.raw["bandState"] = try original.raw["bandState"]!.map { old in
                var row = old
                guard let state = old["state"] as? Int, let raw = old["rawByte"] as? Int else {
                    throw Exporter.Failure.invalidRecipe
                }
                if state == 1 && raw == 1 {
                    row["rawByte"] = decoded.rawByte!
                    row["state"] = decoded.state
                } else if state != (raw >> 4) & 3 || !(0...255).contains(raw) {
                    // Only the reviewed construction defect is corrected, not arbitrary invalid data.
                    throw Exporter.Failure.invalidRecipe
                }
                return row
            }
            return recipe
        }
    }

    static func sourceHashes() throws -> [String: String] {
        var hashes: [String: String] = [:]
        for package in ["StrandAnalytics", "WhoopProtocol", "WhoopStore"] {
            let base = repository.appendingPathComponent("Packages/\(package)/Sources")
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else {
                throw Exporter.Failure.invalidRecipe
            }
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let relative = String(file.path.dropFirst(repository.path.count + 1))
                hashes[relative] = Exporter.digest(try Data(contentsOf: file))
            }
        }
        for name in ["WholeDaySwiftParityExporter.swift", "WholeDaySwiftParityExporterTests.swift",
                     "WholeDaySwiftKernelRecipes.swift", "WholeDaySwiftV2Corpus.swift", "WholeDaySwiftV2CorpusTests.swift"] {
            let path = "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/\(name)"
            hashes[path] = Exporter.digest(try Data(contentsOf: repository.appendingPathComponent(path)))
        }
        return hashes
    }

    static func validateTarget(_ target: String) throws -> URL {
        let output = URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
        // An export is write-once to this explicitly authorized new directory. Never overwrite v1,
        // a previous v2, or redirect via symlink. A failed partial export is left for inspection.
        // Compare paths: URL equality distinguishes a trailing directory slash before it exists.
        guard output.path == directory.path, output.resolvingSymlinksInPath().path == output.path,
              !FileManager.default.fileExists(atPath: output.path) else { throw Exporter.Failure.unsafeOutput }
        return output
    }

    static func write(_ cases: [(String, Data)], target: String, sourceHashes: [String: String]) throws {
        let output = try validateTarget(target)
        guard cases.count == 13, Set(cases.map(\.0)).count == cases.count,
              cases.allSatisfy({ $0.0.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil }),
              cases.allSatisfy({ $0.1.count <= 32 * 1_024 * 1_024 }),
              cases.reduce(0, { $0 + $1.1.count }) <= 512 * 1_024 * 1_024,
              try self.sourceHashes() == sourceHashes else { throw Exporter.Failure.unsafeOutput }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path, "rev-parse", "HEAD"]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Exporter.Failure.invalidRecipe }
        let revision = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { throw Exporter.Failure.invalidRecipe }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        var entries: [[String: Any]] = []
        for (id, data) in cases {
            let file = output.appendingPathComponent("\(id).json")
            try data.write(to: file, options: .withoutOverwriting)
            entries.append(["id": id, "file": file.lastPathComponent, "sha256": Exporter.digest(data), "mode": "kernel_calendar"])
        }
        let manifest: [String: Any] = ["schemaVersion": 1, "producer": "actual-swift", "recipe": "w4-whole-day-v1",
            "sourceRevision": revision, "sourceHashes": sourceHashes, "cases": entries]
        try Exporter.bytes(manifest).write(to: output.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
    }
}
