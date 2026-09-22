import Foundation
import XCTest
import WhoopStore
@testable import Strand

final class RepositoryRuntimeIsolationTests: XCTestCase {
    private actor OpenGate {
        let store: WhoopStore
        let entered: XCTestExpectation
        private var release: CheckedContinuation<Void, Never>?
        init(store: WhoopStore, entered: XCTestExpectation) { self.store = store; self.entered = entered }
        func open() async -> WhoopStore {
            await withCheckedContinuation { release = $0; entered.fulfill() }
            return store
        }
        func resume() { release?.resume(); release = nil }
    }

    @MainActor
    func testEverySingleFlightWaiterRejectsOpenAfterRuntimeRevocation() async throws {
        let store = try await WhoopStore.inMemory()
        let entered = expectation(description: "real repository opener suspended")
        let gate = OpenGate(store: store, entered: entered)
        let repo = Repository(deviceId: "isolated", openStore: { await gate.open() })
        let first = Task { await repo.storeHandle() }
        await fulfillment(of: [entered], timeout: 2)
        let joined = expectation(description: "second caller joining")
        let second = Task { joined.fulfill(); return await repo.storeHandle() }
        await fulfillment(of: [joined], timeout: 2)
        repo.shutdownForAccountChange()
        await gate.resume()
        let a = await first.value
        let b = await second.value
        XCTAssertNil(a)
        XCTAssertNil(b)
        XCTAssertFalse(repo.writeFence.isValid)
        let later = await repo.storeHandle()
        XCTAssertNil(later)
    }

    @MainActor
    func testJoinedLiveOpenReturnsSameHandleAndShutdownFencesCapturedWriter() async throws {
        let store = try await WhoopStore.inMemory()
        let entered = expectation(description: "open suspended")
        let gate = OpenGate(store: store, entered: entered)
        let repo = Repository(deviceId: "isolated", openStore: { await gate.open() })
        let first = Task { await repo.storeHandle() }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task { await repo.storeHandle() }
        await gate.resume()
        let a = await first.value
        let b = await second.value
        XCTAssertTrue(a === b)
        XCTAssertNotNil(a)
        repo.shutdownForAccountChange()
        do { try await store.upsertDevice(id: "late", mac: nil, name: "late"); XCTFail("retired writer accepted") }
        catch {}
    }
}
