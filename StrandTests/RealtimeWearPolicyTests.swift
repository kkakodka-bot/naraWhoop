import XCTest
@testable import Strand

@MainActor
final class RealtimeWearPolicyTests: XCTestCase {
    func testRepeatedWristTransitionsPreserveOnlyCurrentIntent() {
        let state = LiveState()
        let manager = BLEManager(state: state, startCentral: false)
        var writes: [Bool] = []
        manager.realtimeToggleForTesting = { writes.append($0); return true }
        manager.startRealtime()
        state.worn = false
        manager.wristStateDidChange()
        manager.wristStateDidChange()
        manager.startRealtime()
        state.worn = true
        manager.wristStateDidChange()
        state.worn = false
        manager.wristStateDidChange()
        manager.stopRealtime()
        state.worn = true
        manager.wristStateDidChange()
        XCTAssertEqual(writes, [true, false, true, false])
    }

    func testFailedReleaseRemainsOwed() {
        let state = LiveState()
        let manager = BLEManager(state: state, startCentral: false)
        var writes: [Bool] = []
        var failed = false
        manager.realtimeToggleForTesting = { want in
            writes.append(want)
            if !want && !failed { failed = true; return false }
            return true
        }
        manager.startRealtime()
        state.worn = false
        manager.wristStateDidChange()
        manager.wristStateDidChange()
        XCTAssertEqual(writes, [true, false, false])
    }

    func testOffWristIntentCannotArmAfterAccountShutdown() {
        let state = LiveState()
        state.worn = false
        let manager = BLEManager(state: state, startCentral: false)
        var writes: [Bool] = []
        manager.realtimeToggleForTesting = { writes.append($0); return true }
        manager.startRealtime()
        manager.shutdownForAccountChange()
        state.worn = true
        manager.wristStateDidChange()
        XCTAssertTrue(writes.isEmpty)
    }
}
