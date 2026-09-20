import XCTest
@testable import Strand

@MainActor
final class BLEConnectionOwnerTests: XCTestCase {
    func testScriptedAutomaticReconnectDoesNotRaceManualRequest() {
        let owner = BLEConnectionOwner()
        let id = UUID()
        var requests: [BLEConnectionOwner.Request] = []
        XCTAssertTrue(owner.request(id, link: .disconnected) { requests.append($0) })
        XCTAssertTrue(owner.connected(id))
        let prior = owner.token!
        XCTAssertNil(owner.disconnected(id, isReconnecting: true))
        XCTAssertFalse(owner.request(id, link: .connecting) { requests.append($0) })
        XCTAssertFalse(owner.accepts(prior))
        XCTAssertTrue(owner.connected(id))
        XCTAssertEqual(requests.count, 1)
    }

    func testFailureSubmitsStandingRequestInSameCallbackWithOSDelay() {
        var time: TimeInterval = 0
        let owner = BLEConnectionOwner(clock: { time })
        let id = UUID()
        var requests: [BLEConnectionOwner.Request] = []
        owner.request(id, link: .disconnected) { requests.append($0) }
        time = 0.25
        let delay = owner.disconnected(id, isReconnecting: false)!
        owner.request(id, link: .disconnected, startDelay: delay) { requests.append($0) }
        XCTAssertEqual(requests.last?.startDelay, 29.75)
        time = 100
        let next = owner.disconnected(id, isReconnecting: false)!
        owner.request(id, link: .disconnected, startDelay: next) { requests.append($0) }
        XCTAssertEqual(requests.last?.startDelay, 0)
        XCTAssertEqual(requests.count, 3)
    }

    func testIntentionalStopSurvivesRadioCallbacksAndRejectsStaleConnect() {
        let owner = BLEConnectionOwner()
        let id = UUID()
        owner.request(id, link: .disconnected) { _ in }
        owner.stop()
        owner.radioUnavailable()
        XCTAssertFalse(owner.connected(id))
        XCTAssertNil(owner.disconnected(id, isReconnecting: true))
        XCTAssertFalse(owner.request(id, link: .disconnected) { _ in XCTFail() })
        XCTAssertFalse(owner.beginRestoration())
        owner.allowExplicitConnection()
        XCTAssertTrue(owner.request(id, link: .disconnected) { _ in })
    }

    func testRestorationFailureAllowsFallbackAndRepeatedAttachIsIdempotent() {
        let owner = BLEConnectionOwner()
        let id = UUID()
        XCTAssertTrue(owner.beginRestoration())
        owner.restorationFailed()
        XCTAssertTrue(owner.request(id, link: .disconnected) { _ in })
        XCTAssertNotNil(owner.attachRestored(id))
        XCTAssertNil(owner.attachRestored(id))
    }

    func testGATTRecoveryIsBoundedAndOldGenerationCannotDeliver() {
        let owner = BLEConnectionOwner()
        let id = UUID()
        owner.request(id, link: .disconnected) { _ in }
        XCTAssertTrue(owner.connected(id))
        let prior = owner.token!
        var retries = 0, cancels = 0
        for _ in 0..<10 { owner.recover(stage: "services", retry: { retries += 1 }, reconnect: { cancels += 1 }) }
        XCTAssertEqual(retries, 2)
        XCTAssertEqual(cancels, 1)
        XCTAssertFalse(owner.accepts(prior))
        _ = owner.disconnected(id, isReconnecting: false)
        owner.request(id, link: .disconnected) { _ in }
        XCTAssertTrue(owner.connected(id))
        XCTAssertFalse(owner.accepts(prior))
        XCTAssertTrue(owner.accepts(owner.token!))
    }
}
