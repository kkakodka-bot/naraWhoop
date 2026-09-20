import XCTest
@testable import Strand

@MainActor
final class WhoopOnboardingSetupTests: XCTestCase {
    private let strap = "11111111-1111-1111-1111-111111111111"
    private let other = "22222222-2222-2222-2222-222222222222"

    private func checkpointURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("setup.json")
    }

    func testNewInstallBlocksConnectionAndDataBeforeSelection() {
        let setup = WhoopOnboardingSetup(required: true, checkpointURL: checkpointURL())
        XCTAssertTrue(setup.blocksData)
        XCTAssertFalse(setup.mayConnect)
        XCTAssertFalse(setup.mayIngest(from: strap))
        XCTAssertFalse(setup.finish())
        XCTAssertNil(setup.secureLinkReady(peripheralID: strap, encrypted: true))
        XCTAssertFalse(setup.select(id: strap, name: "WHOOP 123456", serialConfirmed: false))
        XCTAssertFalse(setup.select(id: strap, name: "WHOOP 5.0", serialConfirmed: true))
        XCTAssertFalse(setup.select(id: strap, name: "WHOOP-5.0", serialConfirmed: true))
        XCTAssertFalse(setup.permitsWrite(opcode: 25, payload: Array(repeating: 0xFE, count: 8)))
    }

    func testUnencryptedLiveHRAndWrongStrapCannotStartErasing() {
        let url = checkpointURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let setup = WhoopOnboardingSetup(required: true, checkpointURL: url)
        XCTAssertTrue(setup.select(id: strap, name: "WHOOP 123456", serialConfirmed: true))
        XCTAssertNil(setup.secureLinkReady(peripheralID: strap, encrypted: false))
        XCTAssertNil(setup.secureLinkReady(peripheralID: other, encrypted: true))
        setup.verifiedEmpty(peripheralID: strap)
        XCTAssertEqual(setup.phase, .pairing)
        XCTAssertNotNil(setup.secureLinkReady(peripheralID: strap, encrypted: true))
        XCTAssertEqual(setup.phase, .resetting)
        XCTAssertTrue(setup.permitsWrite(opcode: 25, payload: Array(repeating: 0xFE, count: 8)))
        XCTAssertFalse(setup.permitsWrite(opcode: 25, payload: [0]))
        XCTAssertFalse(setup.permitsWrite(opcode: 22, payload: [0]))
        XCTAssertFalse(setup.permitsWrite(opcode: 36, payload: [0]))
        XCTAssertNil(setup.secureLinkReady(peripheralID: strap, encrypted: true))
    }

    func testWriteAckDoesNotOpenDataGateAndReadyIsBoundToSelectedStrap() {
        let url = checkpointURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let setup = WhoopOnboardingSetup(required: true, checkpointURL: url)
        _ = setup.select(id: strap, name: "WHOOP 123456", serialConfirmed: true)
        _ = setup.secureLinkReady(peripheralID: strap, encrypted: true)
        setup.eraseAcknowledged()
        XCTAssertTrue(setup.blocksData)
        XCTAssertFalse(setup.permitsWrite(opcode: 25, payload: Array(repeating: 0xFE, count: 8)))
        XCTAssertTrue(setup.permitsWrite(opcode: 22, payload: [0]))
        setup.verifiedEmpty(peripheralID: other)
        XCTAssertTrue(setup.blocksData)
        setup.verifiedEmpty(peripheralID: strap)
        XCTAssertFalse(setup.blocksData)
        XCTAssertTrue(setup.mayIngest(from: strap))
        XCTAssertFalse(setup.mayIngest(from: other))
        XCTAssertTrue(setup.finish())
        XCTAssertTrue(setup.mayIngest(from: other))
    }

    func testRelaunchAfterEraseIntentVerifiesWithoutErasingAgain() {
        let url = checkpointURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = WhoopOnboardingSetup(required: true, checkpointURL: url)
        _ = first.select(id: strap, name: "WHOOP 123456", serialConfirmed: true)
        _ = first.secureLinkReady(peripheralID: strap, encrypted: true)
        let resumed = WhoopOnboardingSetup(required: true, checkpointURL: url)
        XCTAssertFalse(resumed.mayConnect)
        resumed.retry()
        XCTAssertEqual(resumed.secureLinkReady(peripheralID: strap, encrypted: true), .verify)
        XCTAssertTrue(resumed.blocksData)
    }

    func testExplicitRetryCanClearAgainAfterFailure() {
        let url = checkpointURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let setup = WhoopOnboardingSetup(required: true, checkpointURL: url)
        _ = setup.select(id: strap, name: "WHOOP 123456", serialConfirmed: true)
        _ = setup.secureLinkReady(peripheralID: strap, encrypted: true)
        setup.fail("interrupted")
        XCTAssertTrue(setup.blocksData)
        setup.retry(eraseAgain: true)
        XCTAssertEqual(setup.secureLinkReady(peripheralID: strap, encrypted: true), .erase)
    }

    func testVerifiedReceiptSurvivesRelaunchAndDoesNotEraseTwice() {
        let url = checkpointURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let setup = WhoopOnboardingSetup(required: true, checkpointURL: url)
        _ = setup.select(id: strap, name: "WHOOP 123456", serialConfirmed: true)
        _ = setup.secureLinkReady(peripheralID: strap, encrypted: true)
        setup.eraseAcknowledged()
        setup.verifiedEmpty(peripheralID: strap)
        let resumed = WhoopOnboardingSetup(required: true, checkpointURL: url)
        XCTAssertEqual(resumed.phase, .ready)
        XCTAssertNil(resumed.secureLinkReady(peripheralID: strap, encrypted: true))
        XCTAssertTrue(resumed.mayIngest(from: strap))
    }

    func testExistingOnboardedInstallNeverAutomaticallyResets() {
        let setup = WhoopOnboardingSetup(required: false, checkpointURL: checkpointURL())
        XCTAssertFalse(setup.blocksData)
        XCTAssertTrue(setup.mayIngest(from: strap))
        XCTAssertFalse(setup.select(id: strap, name: "WHOOP 123456", serialConfirmed: true))
        XCTAssertNil(setup.secureLinkReady(peripheralID: strap, encrypted: true))
        XCTAssertNil(WhoopCommand(rawValue: 25), "The erase command must stay out of the generic command menu")
    }

    func testStartingANewOnboardingDoesNotReuseAPreviousOwnersCompletedReceipt() {
        let url = checkpointURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let setup = WhoopOnboardingSetup(required: true, checkpointURL: url)
        _ = setup.select(id: strap, name: "WHOOP 123456", serialConfirmed: true)
        _ = setup.secureLinkReady(peripheralID: strap, encrypted: true)
        setup.eraseAcknowledged()
        setup.verifiedEmpty(peripheralID: strap)
        XCTAssertTrue(setup.finish())
        let newOwner = WhoopOnboardingSetup(required: true, checkpointURL: url)
        XCTAssertEqual(newOwner.phase, .chooseDevice)
        XCTAssertTrue(newOwner.blocksData)
        XCTAssertFalse(newOwner.mayConnect)
    }

    func testCheckpointWriteFailureNeverAuthorizesErase() throws {
        let url = checkpointURL()
        let parent = url.deletingLastPathComponent()
        try Data([0]).write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let setup = WhoopOnboardingSetup(required: true, checkpointURL: url)
        XCTAssertFalse(setup.select(id: strap, name: "WHOOP 123456", serialConfirmed: true))
        XCTAssertNil(setup.secureLinkReady(peripheralID: strap, encrypted: true))
        XCTAssertTrue(setup.blocksData)
    }
}
