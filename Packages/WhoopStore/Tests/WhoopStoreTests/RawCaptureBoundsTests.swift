import XCTest
import WhoopProtocol
@testable import WhoopStore

final class RawCaptureBoundsTests: XCTestCase {
    func testSingleSecondAndEmptyCaptureAreHalfOpen() throws {
        let single = try RawBatchMeta.captureBounds(streams: Streams(hr: [HRSample(ts: 100, bpm: 60)]),
                                                    fallbackTimestamp: 999)
        XCTAssertEqual(single.startTs, 100)
        XCTAssertEqual(single.endTs, 101)
        let empty = try RawBatchMeta.captureBounds(streams: Streams(), fallbackTimestamp: 200)
        XCTAssertEqual(empty.startTs, 200)
        XCTAssertEqual(empty.endTs, 201)
    }

    func testRawOnlyAndMixedStreamsContributeToBounds() throws {
        let raw = Streams(ppgWaveform: [PpgWaveformSample(ts: 90, samples: [1], recordIndex: 1)],
                          v18Aux: [V18AuxSample(ts: 120, recordIndex: 2)])
        let bounds = try RawBatchMeta.captureBounds(streams: raw, fallbackTimestamp: 999)
        XCTAssertEqual(bounds.startTs, 90)
        XCTAssertEqual(bounds.endTs, 121)
        let mixed = try RawBatchMeta.captureBounds(
            streams: Streams(hr: [HRSample(ts: 110, bpm: 60)],
                             ppgWaveform: [PpgWaveformSample(ts: 100, samples: [1], recordIndex: 1)]),
            fallbackTimestamp: 999)
        XCTAssertEqual(mixed.startTs, 100)
        XCTAssertEqual(mixed.endTs, 111)
    }

    func testExclusiveEndOverflowFailsClosed() {
        XCTAssertThrowsError(try RawBatchMeta.captureBounds(streams: Streams(), fallbackTimestamp: .max))
    }
}
