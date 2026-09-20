import XCTest
@testable import WhoopProtocol

final class EmptyHistoryVerificationTests: XCTestCase {
    private let families: [DeviceFamily] = [.whoop4, .whoop5]

    private func frame(_ family: DeviceFamily, type: UInt8 = 49, command: UInt8,
                       payload: [UInt8] = []) -> [UInt8] {
        if family == .whoop5 {
            return puffinCommandFrame(cmd: command, seq: 0, payload: payload, type: type)
        }
        var bytes = frameFromPayload(payload, type: type, cmd: command)
        bytes[3] = crc8(Array(bytes[1...2]))
        return bytes
    }

    func testEmptySessionRequiresStartThenCompleteForBothFamilies() {
        for family in families {
            var verifier = EmptyHistoryVerification()
            XCTAssertEqual(verifier.receive(frame(family, command: 1), family: family), .waiting)
            XCTAssertEqual(verifier.receive(frame(family, command: 3), family: family), .empty)
        }
    }

    func testUnsolicitedCompleteCannotFinishSetup() {
        for family in families {
            var verifier = EmptyHistoryVerification()
            XCTAssertEqual(verifier.receive(frame(family, command: 3), family: family), .rejected)
        }
    }

    func testOldRecordsAndEventsFailWithoutAcknowledgement() {
        for family in families {
            for type: UInt8 in [47, 48] {
                var verifier = EmptyHistoryVerification()
                _ = verifier.receive(frame(family, command: 1), family: family)
                XCTAssertEqual(verifier.receive(frame(family, type: type, command: 0,
                                                      payload: [255, 1, 2]), family: family), .rejected)
                XCTAssertEqual(verifier.receive(frame(family, command: 3), family: family), .rejected)
            }
        }
    }

    func testEmptyChunkCanBeAcknowledgedButIsNotCompletion() {
        for family in families {
            var verifier = EmptyHistoryVerification()
            _ = verifier.receive(frame(family, command: 1), family: family)
            let payload: [UInt8] = Array(repeating: 0, count: 10) + [1, 2, 3, 4, 5, 6, 7, 8]
            XCTAssertEqual(verifier.receive(frame(family, command: 2, payload: payload), family: family),
                           .acknowledge([1, 1, 2, 3, 4, 5, 6, 7, 8]))
            XCTAssertEqual(verifier.receive(frame(family, command: 3), family: family), .empty)
        }
    }

    func testCorruptFrameCannotBecomeAnEmptySession() {
        for family in families {
            var verifier = EmptyHistoryVerification()
            _ = verifier.receive(frame(family, command: 1), family: family)
            var corrupt = frame(family, type: 47, command: 0)
            corrupt[corrupt.count - 1] ^= 1
            XCTAssertEqual(verifier.receive(corrupt, family: family), .rejected)
            XCTAssertEqual(verifier.receive(frame(family, command: 3), family: family), .rejected)
        }
    }

    func testFragmentedMetadataIsAcceptedWithoutDroppingBytes() {
        for family in families {
            var verifier = EmptyHistoryVerification()
            let start = frame(family, command: 1)
            XCTAssertEqual(verifier.receiveNotification(Array(start.prefix(3)), characteristic: "data", family: family), [])
            XCTAssertEqual(verifier.receiveNotification(Array(start.dropFirst(3)), characteristic: "data", family: family), [.waiting])
            XCTAssertEqual(verifier.receiveNotification(frame(family, command: 3), characteristic: "data", family: family), [.empty])
        }
    }

    func testIncompleteHistoryOnAnotherCharacteristicPreventsSuccess() {
        for family in families {
            var verifier = EmptyHistoryVerification()
            _ = verifier.receiveNotification(frame(family, command: 1), characteristic: "metadata", family: family)
            let record = frame(family, type: 47, command: 0, payload: Array(repeating: 0, count: 100))
            _ = verifier.receiveNotification(Array(record.prefix(12)), characteristic: "history", family: family)
            XCTAssertEqual(verifier.receiveNotification(frame(family, command: 3), characteristic: "metadata", family: family), [.rejected])
        }
    }

    func testGarbageAndDataAfterCompleteInSameNotificationFailClosed() {
        for family in families {
            var verifier = EmptyHistoryVerification()
            XCTAssertEqual(verifier.receiveNotification([0] + frame(family, command: 1),
                                                       characteristic: "data", family: family), [.rejected])
            verifier = EmptyHistoryVerification()
            _ = verifier.receiveNotification(frame(family, command: 1), characteristic: "data", family: family)
            XCTAssertEqual(verifier.receiveNotification(frame(family, command: 3) + frame(family, type: 47, command: 0),
                                                       characteristic: "data", family: family), [.rejected])
        }
    }

    func testShortEndAndRepeatedStartFailClosed() {
        for family in families {
            var verifier = EmptyHistoryVerification()
            _ = verifier.receive(frame(family, command: 1), family: family)
            XCTAssertEqual(verifier.receive(frame(family, command: 2, payload: [1]), family: family), .rejected)
            verifier = EmptyHistoryVerification()
            _ = verifier.receive(frame(family, command: 1), family: family)
            XCTAssertEqual(verifier.receive(frame(family, command: 1), family: family), .rejected)
        }
    }
}
