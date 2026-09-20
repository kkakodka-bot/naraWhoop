import XCTest
import NoopPush
@testable import Strand

final class CloudPushMessagingTests: XCTestCase {
    func testSafeUploadContextAndRequestIdentitySurviveTheDisplayLimit() {
        let request = "11111111-2222-3333-4444-555555555555"
        let failure = PushFailure.http(status: 500, receiverCode: "receiver_failed",
                                       stream: "rrPacketProvenance", stage: "projection", correlationId: request)
        let message = CloudPushMessaging.pushFailureMessage(failure)
        XCTAssertLessThanOrEqual(message.count, 300)
        XCTAssertTrue(message.contains("receiver_failed"))
        XCTAssertTrue(message.contains("stream=rrPacketProvenance"))
        XCTAssertTrue(message.contains("stage=projection"))
        XCTAssertTrue(message.contains("request=\(request)"))
    }

    func testMissingOptionalDiagnosticsKeepOlderReceiverErrorsReadable() {
        let message = CloudPushMessaging.pushFailureMessage(.http(status: 500, receiverCode: "receiver_failed"))
        XCTAssertTrue(message.contains("HTTP 500"))
        XCTAssertTrue(message.hasSuffix("(receiver_failed)"))
        XCTAssertFalse(message.contains("request="))
    }
}
