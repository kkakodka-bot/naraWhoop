import XCTest
@testable import NoopPush

final class PushRegistryTests: XCTestCase {

    struct CloudFixture: Decodable {
        struct Entry: Decodable {
            let classification: String
            let wireStream: String?
            let delivery: String?
        }
        let tables: [String: Entry]
    }

    func testV1_1WireStreamsMatchCloudIngestionRegistry() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cloud_ingestion_registry", withExtension: "json"))
        let fixture = try JSONDecoder().decode(CloudFixture.self, from: Data(contentsOf: url))
        let shipped = fixture.tables.values
            .filter { $0.classification == "shipped" }
            .compactMap(\.wireStream)
        let expected = Set(shipped).subtracting(PushRegistryV1_2.additionalBinaryStreams)
        XCTAssertEqual(PushRegistryV1_1.streamNames, expected,
                       "PushRegistryV1_1 must name every shipped wire stream in cloud_ingestion_registry.json except 1.2-only binary streams")
    }

    func testV1_2WireStreamsMatchCloudIngestionRegistry() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cloud_ingestion_registry", withExtension: "json"))
        let fixture = try JSONDecoder().decode(CloudFixture.self, from: Data(contentsOf: url))
        let shipped = fixture.tables.values
            .filter { $0.classification == "shipped" }
            .compactMap(\.wireStream)
        XCTAssertEqual(PushRegistryV1_2.streamNames, Set(shipped),
                       "PushRegistryV1_2 must name every shipped wire stream in cloud_ingestion_registry.json")
    }

    func testV1IsSubsetOfV1_1() {
        XCTAssertTrue(PushRegistryV1.streamNames.isSubset(of: PushRegistryV1_1.streamNames))
    }

    func testAllThreeRegistryCopiesAreByteIdentical() throws {
        let bundledURL = try XCTUnwrap(Bundle.module.url(forResource: "cloud_ingestion_registry", withExtension: "json"))
        let bundled = try Data(contentsOf: bundledURL)
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for path in [
            "Packages/NoopPush/Tests/NoopPushTests/Resources/cloud_ingestion_registry.json",
            "Packages/WhoopStore/Tests/WhoopStoreTests/Resources/cloud_ingestion_registry.json",
            "android/app/src/test/resources/cloud_ingestion_registry.json"
        ] {
            XCTAssertEqual(bundled, try Data(contentsOf: repository.appendingPathComponent(path)),
                           "Registry copies must agree on local-only entries as well as shipped streams: \(path)")
        }
    }
}
