import Foundation
import WhoopProtocol
@testable import StrandAnalytics

/// Current-source oracle. Historical v1 recipe files remain immutable; this recipe also records
/// the production measurement state behind every compatibility HRV window.
enum WholeDaySwiftCurrentCorpus {
    typealias Exporter = WholeDaySwiftParityExporter
    static let directoryName = "w4-whole-day-current-v2"
    static let recipeName = "w4-whole-day-v2"
    static var repository: URL { WholeDaySwiftV2Corpus.repository }

    static func export(_ recipe: Exporter.Recipe) async throws -> [String: Any] {
        var value = try await Exporter.export(recipe)
        guard var expected = value["expected"] as? [String: Any],
              var selection = expected["selection"] as? [String: Any],
              let result = expected["result"] as? [String: Any],
              let sessions = result["sleep"] as? [[String: Any]],
              let compatibilityWindows = selection["hrvWindows"] as? [[String: Any]] else {
            throw Exporter.Failure.invalidRecipe
        }
        // Read the actual Store projection again; do not infer missing timing from recipe cadence.
        let store = try await Exporter.seed(recipe), bounds = try recipe.bounds()
        let rr = try await store.rrIntervals(deviceId: Exporter.device, from: bounds["nightLo"]!,
                                           to: bounds["dayHi"]!, limit: 200_000).sortedByTsStable()
        var windows: [[String: Any]] = []
        for session in sessions {
            guard let start = session["start"] as? Int, let end = session["end"] as? Int,
                  let segments = session["stages"] as? [[String: Any]] else { throw Exporter.Failure.invalidRecipe }
            let stages = try segments.map { segment -> StageSegment in
                guard let start = segment["start"] as? Int, let end = segment["end"] as? Int,
                      let stage = segment["stage"] as? String else { throw Exporter.Failure.invalidRecipe }
                return StageSegment(start: start, end: end, stage: stage)
            }
            for window in SleepStager.sessionHrvWindows(start: start, end: end, rr: rr, stages: stages) {
                guard let measurement = window.measurement else { throw Exporter.Failure.invalidRecipe }
                var row: [String: Any] = ["sessionStart": start, "start": window.startTs, "stage": window.stage,
                    "cleanBeats": window.cleanBeats, "rmssd": Exporter.optional(window.rmssd)]
                guard windows.count < compatibilityWindows.count,
                      try Exporter.bytes(row) == Exporter.bytes(compatibilityWindows[windows.count]) else {
                    throw Exporter.Failure.invalidRecipe
                }
                row["measurementValid"] = measurement.measurementValid
                row["reason"] = Exporter.optional(measurement.reason)
                row["baselineEligible"] = measurement.baselineEligible
                row["baselineReason"] = Exporter.optional(measurement.baselineReason)
                windows.append(row)
            }
        }
        guard windows.count == compatibilityWindows.count else { throw Exporter.Failure.invalidRecipe }
        selection["hrvWindows"] = windows
        expected["selection"] = selection
        value["expected"] = expected
        return value
    }

    static func sourceHashes() throws -> [String: String] {
        var hashes = try WholeDaySwiftV2Corpus.sourceHashes()
        for name in ["WholeDaySwiftCurrentCorpus.swift", "WholeDaySwiftCurrentCorpusTests.swift",
                     "WholeDaySwiftHistoricalProvenance.swift", "HrvWindowTests.swift"] {
            let path = "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/\(name)"
            hashes[path] = Exporter.digest(try Data(contentsOf: repository.appendingPathComponent(path)))
        }
        return hashes
    }

    static func validateTarget(_ target: String) throws -> URL {
        let output = URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
        guard output.lastPathComponent == directoryName,
              output.resolvingSymlinksInPath().path == output.path,
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
        try process.run(); process.waitUntilExit()
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
        let manifest: [String: Any] = ["schemaVersion": 1, "producer": "actual-swift", "recipe": recipeName,
            "sourceRevision": revision, "sourceHashes": sourceHashes, "cases": entries]
        try Exporter.bytes(manifest).write(to: output.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
    }
}
