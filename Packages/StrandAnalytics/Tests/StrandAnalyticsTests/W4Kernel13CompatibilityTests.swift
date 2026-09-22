import Foundation
import XCTest
@testable import StrandAnalytics

/// Default-behavior compatibility with historical evidence, not verification of current source hashes.
/// The original source-freeze gates and manifest are deliberately left unchanged.
final class W4Kernel13CompatibilityTests: XCTestCase {
    func testCurrentDefaultDTOsMatchAllThirteenImmutableHistoricalCases() async throws {
        typealias Exporter = WholeDaySwiftParityExporter
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let directory = root.appendingPathComponent("Tests/Fixtures/w4-whole-day-swift-v1")
        let manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        XCTAssertEqual(Exporter.digest(manifestData), "d948f5b7dffbd71dece63586ecce08fb3c497c87995bf2685d6469d0782fa245")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let entries = try XCTUnwrap(manifest["cases"] as? [[String: Any]])
        let recipes = try Exporter.kernelRecipes()
        XCTAssertEqual(entries.count, 13)
        XCTAssertEqual(entries.compactMap { $0["id"] as? String }, recipes.map(\.id))
        for recipe in recipes {
            let entry = try XCTUnwrap(entries.first { $0["id"] as? String == recipe.id })
            let filename = try XCTUnwrap(entry["file"] as? String)
            XCTAssertEqual(filename, "\(recipe.id).json")
            XCTAssertEqual(entry["mode"] as? String, "kernel_calendar")
            let historical = try Data(contentsOf: directory.appendingPathComponent(filename))
            XCTAssertEqual(Exporter.digest(historical), entry["sha256"] as? String, recipe.id)
            let actual = try Exporter.bytes(await Exporter.export(recipe))
            // Covers the entire case, including every full DTO field and selected Store row identity.
            // Digests keep a failure from dumping megabytes of raw synthetic sample arrays.
            XCTAssertEqual(Exporter.digest(actual), Exporter.digest(historical), "default behavior drift: \(recipe.id)")
            print("IMMUTABLE_KERNEL_COMPAT \(recipe.id) sha256=\(Exporter.digest(actual))")
        }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("manifest.json")), manifestData)
    }
}
