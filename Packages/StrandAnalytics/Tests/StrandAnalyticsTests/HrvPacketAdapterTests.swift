import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class HrvPacketAdapterTests: XCTestCase {
    func testNativePacketAdapterRetainsZeroAndDoesNotBorrowOtherTransport() throws {
        let p = try XCTUnwrap(RRPacketProvenance.checked(RRPacketProvenance.bytes("aa011a00010023592f12000000000000f153650000003c03000400000002c74eaa5b")!))
        let legacy = [RRInterval(ts: p.ts, rrMs: 1000, srcChannel: .whoop5Historical),
                      RRInterval(ts: p.ts + 1, rrMs: 800, srcChannel: .whoop5Historical),
                      RRInterval(ts: p.ts + 2, rrMs: 900, srcChannel: .whoop5Standard)]
        let observations = try XCTUnwrap(PhysiologyQuality.packetOrLegacy([p], legacy: legacy, deviceId: "d", userId: "u"))
        XCTAssertEqual(observations.count, 4)
        XCTAssertEqual(observations.prefix(3).map(\.ordinal), [0, 1, 2])
        XCTAssertFalse(observations[1].originalAccepted)
        XCTAssertTrue(observations.allSatisfy { $0.userId == "u" && $0.source == "whoop5_history" && $0.verifiedSpan == nil && $0.deviceFirmware == nil })
        XCTAssertNil(observations.last?.startBeatId)
        let result = HrvWindow.measure(start: HrvWindow.alignedStart(p.ts), observations: Array(observations.prefix(3)))
        XCTAssertEqual(result.validPairCount, 0)
        XCTAssertEqual(result.reason, "timing_coverage_unverified")
        XCTAssertNil(result.observedRMSSD)
        XCTAssertNil(PhysiologyQuality.packetOrLegacy([], legacy: legacy, deviceId: "d"))
    }
}
