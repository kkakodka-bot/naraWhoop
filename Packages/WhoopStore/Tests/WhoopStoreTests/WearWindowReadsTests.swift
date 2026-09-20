import XCTest
import WhoopProtocol
@testable import WhoopStore

final class WearWindowReadsTests: XCTestCase {
    func testWearReadIncludesPriorOwnerStateWithoutContactNoise() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(events: [
            WhoopEvent(ts: 1, kind: "WRIST_OFF(10)", payload: [:]),
            WhoopEvent(ts: 310, kind: "WRIST_ON(11)", payload: [:]),
            WhoopEvent(ts: 600, kind: "WRIST_OFF(10)", payload: [:]),
        ] + (2..<300).map { WhoopEvent(ts: $0, kind: "standard_hr_contact", payload: [:]) }), deviceId: "A")
        _ = try await store.insert(Streams(events: [WhoopEvent(ts: 299, kind: "WRIST_ON(11)", payload: [:])]), deviceId: "B")
        let events = try await store.wearEventsForWindow(deviceId: "A", from: 300, to: 599)
        XCTAssertEqual(events.map(\.ts), [1, 310])
        XCTAssertEqual(events.map(\.kind), ["WRIST_OFF(10)", "WRIST_ON(11)"])
    }
}
