import XCTest
import WhoopProtocol
@testable import WhoopStore

final class RecentBatterySamplesTests: XCTestCase {
    func testForecastGetsNewestValidRowsInOrderWithoutChangingExportReader() async throws {
        let store = try await WhoopStore.inMemory()
        let rows = (1...10).map { BatterySample(ts: $0, soc: Double(100 - $0), mv: nil) }
        _ = try await store.insert(Streams(battery: rows + [BatterySample(ts: 11, soc: nil, mv: 3900),
                                                          BatterySample(ts: 12, soc: 255, mv: nil)]), deviceId: "a")
        _ = try await store.insert(Streams(battery: [BatterySample(ts: 10, soc: 5, mv: nil)]), deviceId: "b")
        let recent = try await store.recentBatterySamples(deviceId: "a", from: 1, to: 12, limit: 3)
        XCTAssertEqual(recent.map(\.ts), [8, 9, 10])
        XCTAssertEqual(recent.compactMap(\.soc), [92, 91, 90])
        let exported = try await store.batterySamples(deviceId: "a", from: 1, to: 12, limit: 3)
        XCTAssertEqual(exported.map(\.ts), [1, 2, 3])
        let bounded = try await store.recentBatterySamples(deviceId: "a", from: 7, to: 8, limit: 3)
        XCTAssertEqual(bounded.map(\.ts), [7, 8])
        let empty = try await store.recentBatterySamples(deviceId: "a", from: 1, to: 12, limit: 0)
        XCTAssertTrue(empty.isEmpty)
    }
}
