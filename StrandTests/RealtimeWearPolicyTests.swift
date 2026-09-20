import XCTest
@testable import Strand

@MainActor
final class RealtimeWearPolicyTests: XCTestCase {
    func testWristOffStopsRequestedStreamAndWristOnRestoresIntent() {
        let state = LiveState()
        let manager = BLEManager(state: state, startCentral: false)
        var writes: [Bool] = []
        manager.realtimeToggleForTesting = { writes.append($0); return true }

        manager.startRealtime()
        state.worn = false
        manager.wristStateDidChange()
        manager.wristStateDidChange()
        // Opening Live again while off-body must not re-arm the stream.
        manager.startRealtime()
        state.worn = true
        manager.wristStateDidChange()
        XCTAssertEqual(writes, [true, false, true])
    }

    func testClosingLiveWhileOffWristDoesNotResumeOnWear() {
        let state = LiveState()
        let manager = BLEManager(state: state, startCentral: false)
        var writes: [Bool] = []
        manager.realtimeToggleForTesting = { writes.append($0); return true }

        manager.startRealtime()
        state.worn = false
        manager.wristStateDidChange()
        manager.stopRealtime()
        state.worn = true
        manager.wristStateDidChange()
        XCTAssertEqual(writes, [true, false])
    }

    func testFailedStopIsRetriedInsteadOfMarkedDisarmed() {
        let state = LiveState()
        let manager = BLEManager(state: state, startCentral: false)
        var writes: [Bool] = []
        var failStop = true
        manager.realtimeToggleForTesting = { want in
            writes.append(want)
            if !want && failStop { failStop = false; return false }
            return true
        }
        manager.startRealtime()
        state.worn = false
        manager.wristStateDidChange()
        manager.wristStateDidChange()
        XCTAssertEqual(writes, [true, false, false])
    }
}
