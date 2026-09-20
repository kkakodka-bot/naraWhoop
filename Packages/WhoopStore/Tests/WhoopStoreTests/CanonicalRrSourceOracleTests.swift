import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class CanonicalRrSourceOracleTests: XCTestCase {
    private struct Wire: Decodable {
        let name: String; let hex: String; let ms: [Int]; let channel: Int
    }

    func testPacketToStoreReplayKeepsDecodedUnitsAndSource() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rr_packet_store_server_oracle", withExtension: "json"))
        for entry in try JSONDecoder().decode([Wire].self, from: Data(contentsOf: url)) {
            let chars = Array(entry.hex)
            let bytes = stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! }
            let frame = parseFrame(bytes, family: .whoop5)
            XCTAssertEqual(frame.crcOK, true, entry.name)
            let streams = entry.channel == 5
                ? extractHistoricalStreams([frame], deviceClockRef: 0, wallClockRef: 0)
                : extractStreams([frame], deviceClockRef: 0, wallClockRef: 0)
            XCTAssertEqual(streams.rr.map(\.rrMs), entry.ms, entry.name)
            let store = try await WhoopStore.inMemory()
            try await store.registryWriter.write { db in
                try db.execute(sql: "UPDATE pairedDevice SET model = '5.0 MG' WHERE id = 'my-whoop'")
            }
            _ = try await store.insert(streams, deviceId: "my-whoop")
            let replay = try await store.insert(streams, deviceId: "my-whoop")
            XCTAssertEqual(replay.rr, 0, entry.name)
            let selected = try await store.rrIntervals(deviceId: "my-whoop", from: 0, to: Int.max, limit: 100)
            XCTAssertEqual(selected.map(\.rrMs), entry.channel == 5 ? entry.ms : [], entry.name)
        }
    }

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let name: String
            let family: String
            let rows: [[Int?]]
            let expected: [Int]
        }
        let cases: [Case]
    }

    func testCanonicalNativeReadMatchesSharedServerFixture() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "canonical_rr_source_oracle", withExtension: "json"))
        for entry in try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).cases {
            let store = try await WhoopStore.inMemory()
            try await store.registryWriter.write { db in
                try db.execute(sql: "UPDATE pairedDevice SET model = ? WHERE id = 'my-whoop'",
                               arguments: [entry.family == "WHOOP5" ? "5.0 MG" : "4.0"])
                for row in entry.rows {
                    try db.execute(sql: """
                        INSERT INTO rrInterval (deviceId, ts, rrMs, seq, ord, srcChannel, tsSuspect)
                        VALUES ('my-whoop', ?, ?, ?, ?, ?, ?)
                        """, arguments: StatementArguments(row))
                }
            }
            let result = try await store.rrIntervals(deviceId: "my-whoop", from: 0, to: 1000, limit: 100)
            let expected = entry.expected.map { entry.rows[$0] }
            XCTAssertEqual(result.map(\.ts), expected.map { $0[0]! }, entry.name)
            XCTAssertEqual(result.map(\.rrMs), expected.map { $0[1]! }, entry.name)
            XCTAssertEqual(result.map(\.seq), expected.map { $0[2]! }, entry.name)
            XCTAssertEqual(result.map(\.ord), expected.map { $0[3] }, entry.name)
            XCTAssertEqual(result.map { $0.srcChannel?.rawValue }, expected.map { $0[4] }, entry.name)
        }
    }
}
