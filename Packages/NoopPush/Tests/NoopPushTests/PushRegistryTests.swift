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
        let fileBackedStreams = Set(PushRegistryV1_2.additionalStreams.map(\.wireName))
        XCTAssertEqual(PushRegistryV1_2.streamNames, Set(shipped).union(fileBackedStreams),
                       "PushRegistryV1_2 must name every shipped DB stream plus file-backed event labels")
    }

    func testV1IsSubsetOfV1_1() {
        XCTAssertTrue(PushRegistryV1.streamNames.isSubset(of: PushRegistryV1_1.streamNames))
    }
}
