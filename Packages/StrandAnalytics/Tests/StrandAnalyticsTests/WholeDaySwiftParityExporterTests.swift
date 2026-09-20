import Foundation
import XCTest
@testable import StrandAnalytics

final class WholeDaySwiftParityExporterTests: XCTestCase {
    func testActualSwiftCorpusAndSelectedRRIdentities() async throws {
        typealias Exporter = WholeDaySwiftParityExporter
        let recipes = try Exporter.kernelRecipes()
        var corpus: [(String, Data)] = []
        for recipe in recipes {
            let value = try await Exporter.export(recipe)
            let expected = try XCTUnwrap(value["expected"] as? [String: Any])
            let selection = try XCTUnwrap(expected["selection"] as? [String: Any])
            let streams = try XCTUnwrap(selection["streams"] as? [String: Any])
            if recipe.id == "whoop5-channel5-order-exclusions" {
                XCTAssertEqual(streams["rr"] as? [String], ["rr-2", "rr-1"])
            }
            if recipe.id == "whoop5-channel7-suspect5-future5" {
                XCTAssertEqual(streams["rr"] as? [String], ["rr-1", "rr-2"])
            }
            let result = try XCTUnwrap(expected["result"] as? [String: Any])
            let sessions = try XCTUnwrap(result["sleep"] as? [[String: Any]])
            let daily = try XCTUnwrap(result["daily"] as? [String: Any])
            let windows = try XCTUnwrap(selection["hrvWindows"] as? [[String: Any]])
            if recipe.id.hasPrefix("dense-night") {
                XCTAssertEqual(sessions.count, 1, recipe.id)
                XCTAssertTrue(sessions.allSatisfy { $0["hrOnly"] as? Bool == false }, recipe.id)
                if !recipe.id.contains("no-rr") { XCTAssertFalse(windows.isEmpty, recipe.id) }
            }
            if recipe.id == "dense-night-v1-deep-hrv" {
                XCTAssertFalse(windows.filter { $0["stage"] as? String == "deep" && $0["rmssd"] is Double }.isEmpty)
                XCTAssertNotNil(daily["avgHrv"] as? Double)
            }
            if recipe.id == "dense-night-v1-no-rr-deep-hrv" {
                XCTAssertTrue(daily["avgHrv"] is NSNull)
                XCTAssertTrue(windows.isEmpty)
            }
            if recipe.id == "dense-night-v2-no-deep-hrv" {
                XCTAssertTrue(daily["avgHrv"] is NSNull)
                XCTAssertFalse(windows.isEmpty)
                XCTAssertFalse(windows.contains { $0["stage"] as? String == "deep" })
            }
            if recipe.id == "fragmented-main-night-and-nap" {
                XCTAssertGreaterThanOrEqual(sessions.count, 3)
                XCTAssertEqual((selection["mainNightIndices"] as? [Int])?.count, 2)
            }
            if recipe.id == "dense-night-v2-and-workout" {
                XCTAssertFalse(try XCTUnwrap(result["workouts"] as? [[String: Any]]).isEmpty)
            }
            if recipe.id == "whoop5-hr-only-night" {
                XCTAssertFalse(sessions.isEmpty, "the corpus must exercise actual HR-only staging")
                XCTAssertTrue(sessions.allSatisfy { $0["hrOnly"] as? Bool == true })
            }
            print("SWIFT_DAY_CASE \(recipe.id) sleep=\(sessions.count) main=\(selection["mainNightIndices"]!) windows=\(windows.count) stages=\(Set(windows.compactMap { $0["stage"] as? String }).sorted()) hrv=\(daily["avgHrv"]!)")
            XCTAssertEqual(Set(result.keys), Set(["daily", "sleep", "workouts", "scores", "sessionMotionByStart", "sessionSleepStateByStart", "detectionFunnel"]))
            corpus.append((recipe.id, try Exporter.bytes(value)))
        }
        guard testRun?.failureCount == 0 else { throw Exporter.Failure.invalidRecipe }
        if let target = ProcessInfo.processInfo.environment["W4_SWIFT_DAY_FIXTURE_DIR"] {
            try writeCorpus(corpus, target: target)
        } else {
            let directory = repository.appendingPathComponent("Tests/Fixtures/w4-whole-day-swift-v1")
            let manifest = try WholeDaySwiftHistoricalProvenance.verify(.v1, repository: repository)
            let entries = try XCTUnwrap(manifest["cases"] as? [[String: Any]])
            XCTAssertEqual(entries.compactMap { $0["id"] as? String }, corpus.map(\.0))
            for (id, actual) in corpus {
                let entry = try XCTUnwrap(entries.first { $0["id"] as? String == id })
                XCTAssertEqual(entry["file"] as? String, "\(id).json")
                let expected = try Data(contentsOf: directory.appendingPathComponent("\(id).json"))
                XCTAssertEqual(Exporter.digest(expected), entry["sha256"] as? String, id)
                XCTAssertEqual(actual, expected, "actual Swift output drift: \(id)")
            }
        }
    }

    func testIndependentStoreExportsAreByteDeterministic() async throws {
        for recipe in try WholeDaySwiftParityExporter.kernelRecipes() {
            let first = try await WholeDaySwiftParityExporter.export(recipe)
            let second = try await WholeDaySwiftParityExporter.export(recipe)
            XCTAssertEqual(try WholeDaySwiftParityExporter.bytes(first), try WholeDaySwiftParityExporter.bytes(second), recipe.id)
        }
    }

    func testSQLiteBoundarySelectionExcludesForeignAndInvalidRows() async throws {
        let recipe = try XCTUnwrap(WholeDaySwiftParityExporter.firstRecipes().first { $0.id == "whoop4-legacy-boundaries" })
        let value = try await WholeDaySwiftParityExporter.export(recipe)
        let expected = try XCTUnwrap(value["expected"] as? [String: Any])
        let selection = try XCTUnwrap(expected["selection"] as? [String: Any])
        let streams = try XCTUnwrap(selection["streams"] as? [String: Any])
        for stream in ["hr", "rr", "steps", "resp", "gravity", "skinTemp", "spo2", "bandState"] {
            XCTAssertEqual(streams[stream] as? [String], (2...8).map { "\(stream)-\($0)" })
        }
        for (key, stream) in [("dayHr", "hr"), ("daySteps", "steps"), ("dayGravity", "gravity")] {
            XCTAssertEqual(selection[key] as? [String], (5...8).map { "\(stream)-\($0)" })
        }
    }

    func testSameCountRRCorrectionChangesExportedIdentityOrder() async throws {
        var recipe = try XCTUnwrap(WholeDaySwiftParityExporter.firstRecipes().first { $0.id == "whoop5-channel5-order-exclusions" })
        func selectedRR(_ value: [String: Any]) throws -> [String] {
            let expected = try XCTUnwrap(value["expected"] as? [String: Any])
            let selection = try XCTUnwrap(expected["selection"] as? [String: Any])
            let streams = try XCTUnwrap(selection["streams"] as? [String: Any])
            return try XCTUnwrap(streams["rr"] as? [String])
        }
        let before = try selectedRR(await WholeDaySwiftParityExporter.export(recipe))
        recipe.raw["rr"]![0]["ord"] = 0
        recipe.raw["rr"]![1]["ord"] = 1
        let after = try selectedRR(await WholeDaySwiftParityExporter.export(recipe))
        XCTAssertEqual(before.count, after.count)
        XCTAssertEqual(before, ["rr-2", "rr-1"])
        XCTAssertEqual(after, ["rr-1", "rr-2"])
    }

    func testWriterRefusesAnExistingHistoricalCorpusWithoutChangingManifest() throws {
        let output = repository.appendingPathComponent("Tests/Fixtures/w4-whole-day-swift-v1")
        let manifest = output.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: manifest)
        XCTAssertThrowsError(try writeCorpus([], target: output.path))
        XCTAssertEqual(try Data(contentsOf: manifest), before)
    }

    private var repository: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root
    }

    private func writeCorpus(_ corpus: [(String, Data)], target: String) throws {
        typealias Exporter = WholeDaySwiftParityExporter
        let output = URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
        guard output.lastPathComponent == "w4-whole-day-swift-v1",
              !FileManager.default.fileExists(atPath: output.path) else { throw Exporter.Failure.unsafeOutput }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard output.resolvingSymlinksInPath() == output,
              try output.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              Set(corpus.map(\.0)).count == corpus.count,
              corpus.allSatisfy({ $0.0.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil }) else {
            throw Exporter.Failure.unsafeOutput
        }
        let root = repository
        var hashes: [String: String] = [:]
        for package in ["StrandAnalytics", "WhoopProtocol", "WhoopStore"] {
            let base = root.appendingPathComponent("Packages/\(package)/Sources")
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                hashes[relative] = Exporter.digest(try Data(contentsOf: file))
            }
        }
        for name in ["WholeDaySwiftParityExporter.swift", "WholeDaySwiftParityExporterTests.swift", "WholeDaySwiftKernelRecipes.swift"] {
            let relative = "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/\(name)"
            hashes[relative] = Exporter.digest(try Data(contentsOf: root.appendingPathComponent(relative)))
        }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "rev-parse", "HEAD"]
        process.standardOutput = pipe
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let revision = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var cases: [[String: Any]] = []
        for (id, data) in corpus {
            let file = output.appendingPathComponent("\(id).json")
            guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw Exporter.Failure.unsafeOutput }
            try data.write(to: file, options: .withoutOverwriting)
            cases.append(["id": id, "file": file.lastPathComponent, "sha256": Exporter.digest(data), "mode": "kernel_calendar"])
        }
        let manifest: [String: Any] = ["schemaVersion": 1, "producer": "actual-swift", "recipe": "w4-whole-day-v1",
            "sourceRevision": revision, "sourceHashes": hashes, "cases": cases]
        let manifestURL = output.appendingPathComponent("manifest.json")
        guard (try? manifestURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw Exporter.Failure.unsafeOutput }
        try Exporter.bytes(manifest).write(to: manifestURL, options: .withoutOverwriting)
    }
}
