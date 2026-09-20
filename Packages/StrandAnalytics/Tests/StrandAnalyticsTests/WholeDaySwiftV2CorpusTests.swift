import Foundation
import XCTest
@testable import StrandAnalytics

final class WholeDaySwiftV2CorpusTests: XCTestCase {
    typealias Corpus = WholeDaySwiftV2Corpus
    typealias Exporter = WholeDaySwiftParityExporter

    func testActualDecoderRejectsHistoricalPairAndRetainsAllFlagBits() throws {
        // Negative control: the original raw byte really decodes to 0, not the recipe's claimed 1.
        let original = try Corpus.decodeBandByte(1)
        XCTAssertEqual(original.rawByte, 1)
        XCTAssertEqual(original.state, 0)
        XCTAssertNotEqual(original.state, 1)
        for raw in UInt8.min...UInt8.max {
            let decoded = try Corpus.decodeBandByte(raw)
            XCTAssertEqual(decoded.rawByte, Int(raw))
            XCTAssertEqual(decoded.state, (Int(raw) >> 4) & 3)
        }
        XCTAssertEqual(try Corpus.decodeBandByte(0x10).state, 1)
    }

    func testOnlyReviewedSyntheticInputChangesAndNoProvenanceIsInvented() throws {
        let previous = try Exporter.kernelRecipes(), current = try Corpus.recipes()
        XCTAssertEqual(previous.map(\.id), current.map(\.id))
        var affected: [String: Int] = [:]
        for (old, new) in zip(previous, current) {
            var correctedRaw = old.raw
            var count = 0
            correctedRaw["bandState"] = old.raw["bandState"]!.map { row in
                var revised = row
                if row["state"] as? Int == 1 && row["rawByte"] as? Int == 1 {
                    revised["rawByte"] = 16
                    count += 1
                }
                return revised
            }
            XCTAssertEqual(Exporter.digest(try Exporter.bytes(correctedRaw)), Exporter.digest(try Exporter.bytes(new.raw)), old.id)
            for row in new.raw["bandState"]! {
                let raw = try XCTUnwrap(row["rawByte"] as? Int)
                XCTAssertEqual(row["state"] as? Int, try Corpus.decodeBandByte(UInt8(raw)).state)
                XCTAssertTrue(row["provenance"] is NSNull, "no invented frame provenance")
            }
            if count > 0 { affected[old.id] = count }
        }
        XCTAssertEqual(affected, ["dense-night-v1": 180, "dense-night-v2": 180,
            "dense-night-v1-deep-hrv": 180, "dense-night-v2-no-deep-hrv": 180,
            "dense-night-v1-no-rr-deep-hrv": 180, "fragmented-main-night-and-nap": 480,
            "dense-night-v2-and-workout": 180])
        XCTAssertEqual(affected.values.reduce(0, +), 1_560)
    }

    func testVersionedActualSwiftExportAndImmutableParent() async throws {
        let sourceHashes = try Corpus.sourceHashes()
        let parentManifestData = try Data(contentsOf: Corpus.parentDirectory.appendingPathComponent("manifest.json"))
        XCTAssertEqual(Exporter.digest(parentManifestData), Corpus.parentManifestSHA256)
        let parentManifest = try object(parentManifestData)
        let parentEntries = try XCTUnwrap(parentManifest["cases"] as? [[String: Any]])
        let recipes = try Corpus.recipes()
        XCTAssertEqual(parentEntries.compactMap { $0["id"] as? String }, recipes.map(\.id))
        var cases: [(String, Data)] = []
        for recipe in recipes {
            let entry = try XCTUnwrap(parentEntries.first { $0["id"] as? String == recipe.id })
            let parentBytes = try Data(contentsOf: Corpus.parentDirectory.appendingPathComponent("\(recipe.id).json"))
            XCTAssertEqual(Exporter.digest(parentBytes), entry["sha256"] as? String, "immutable parent: \(recipe.id)")
            let parent = try object(parentBytes)
            let value = try await Exporter.export(recipe) // actual SQLite selection + Swift kernels
            let bytes = try Exporter.bytes(value)
            // The correction changes raw input, not the intended decoded state. Every expected field,
            // selected row ID, timestamp, physiological value, group index and state bin must still agree.
            XCTAssertEqual(Exporter.digest(try Exporter.bytes(value["expected"]!)),
                           Exporter.digest(try Exporter.bytes(parent["expected"]!)), "expected output drift: \(recipe.id)")
            let input = try XCTUnwrap(value["input"] as? [String: Any])
            var parentInput = try XCTUnwrap(parent["input"] as? [String: Any])
            parentInput["raw"] = recipe.raw
            XCTAssertEqual(Exporter.digest(try Exporter.bytes(input)), Exporter.digest(try Exporter.bytes(parentInput)), recipe.id)
            let result = try XCTUnwrap((value["expected"] as? [String: Any])?["result"] as? [String: Any])
            let band = try XCTUnwrap(result["sessionSleepStateByStart"] as? [String: Any])
            if recipe.id == "dense-night-v1" { XCTAssertEqual(Set(band.keys), ["1781485200"]) }
            print("SWIFT_V2_CASE \(recipe.id) sha256=\(Exporter.digest(bytes)) expectedMatchesParent=true")
            cases.append((recipe.id, bytes))
        }
        XCTAssertEqual(try Corpus.sourceHashes(), sourceHashes, "source changed while executing")
        XCTAssertEqual(try Data(contentsOf: Corpus.parentDirectory.appendingPathComponent("manifest.json")), parentManifestData)
        guard testRun?.failureCount == 0 else { throw Exporter.Failure.invalidRecipe }
        if let target = ProcessInfo.processInfo.environment["W4_SWIFT_V2_EXPORT_DIR"] {
            try Corpus.write(cases, target: target, sourceHashes: sourceHashes)
        } else {
            let manifest = try WholeDaySwiftHistoricalProvenance.verify(.v2, repository: Corpus.repository)
            XCTAssertEqual(manifest["schemaVersion"] as? Int, 1)
            XCTAssertEqual(manifest["recipe"] as? String, "w4-whole-day-v1")
            XCTAssertEqual(manifest["producer"] as? String, "actual-swift")
            let entries = try XCTUnwrap(manifest["cases"] as? [[String: Any]])
            XCTAssertEqual(entries.compactMap { $0["id"] as? String }, cases.map(\.0))
            for (id, bytes) in cases {
                let entry = try XCTUnwrap(entries.first { $0["id"] as? String == id })
                XCTAssertEqual(entry["file"] as? String, "\(id).json")
                XCTAssertEqual(entry["mode"] as? String, "kernel_calendar")
                let saved = try Data(contentsOf: Corpus.directory.appendingPathComponent("\(id).json"))
                XCTAssertEqual(Exporter.digest(saved), entry["sha256"] as? String, id)
                XCTAssertEqual(Exporter.digest(bytes), Exporter.digest(saved), "actual Swift replay: \(id)")
            }
        }
    }

    func testWriterRefusesParentAndExistingDirectory() throws {
        // Target checks run independently of payload validation and do not create/write anything.
        for path in [Corpus.parentDirectory.path, Corpus.repository.path] {
            XCTAssertThrowsError(try Corpus.validateTarget(path))
        }
        if FileManager.default.fileExists(atPath: Corpus.directory.path) {
            XCTAssertThrowsError(try Corpus.validateTarget(Corpus.directory.path))
        } else {
            XCTAssertEqual(try Corpus.validateTarget(Corpus.directory.path).path, Corpus.directory.path)
            XCTAssertEqual(try Corpus.validateTarget(Corpus.directory.path + "/").path, Corpus.directory.path)
        }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
