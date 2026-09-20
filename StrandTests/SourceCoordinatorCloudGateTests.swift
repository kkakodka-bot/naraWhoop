import Combine
import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

@MainActor
final class SourceCoordinatorCloudGateTests: XCTestCase {
    private let strap = "polar-test"
    private let peripheral = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!

    private func registry(_ store: WhoopStore) -> DeviceRegistry {
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryWriter))
        registry.reload()
        registry.add(PairedDevice(id: strap, brand: "Polar", model: "H10", peripheralId: peripheral.uuidString,
            sourceKind: .liveBLE, capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
        registry.setActive(strap)
        return registry
    }

    private func coordinator(_ registry: DeviceRegistry, _ state: SourcePolicyState,
                             store: @escaping () async -> WhoopStore?) -> SourceCoordinator {
        SourceCoordinator(registry: registry, live: LiveState(), storeHandle: store,
            startWhoop: { state.whoopStarts += 1 }, stopWhoop: { state.whoopStops += 1 },
            setWhoopPreferredPeripheral: { _ in }, setWhoopActiveDeviceId: { _ in },
            connectedPeripheralUUID: Empty<String?, Never>().eraseToAnyPublisher(),
            collectionAllowed: { state.enrolled && state.termsAccepted }, notifications: state.notifications,
            sourceFactory: { id, callbacks in
                let source = FakeCloudGatedSource(deviceId: id, persist: callbacks.persist)
                state.sources.append(source)
                return source
            })
    }

    func testRestoredGenericPairingDoesNotConnectBeforeEnrollmentAndConsent() async throws {
        let store = try await WhoopStore.inMemory(), state = SourcePolicyState()
        let registry = registry(store)
        let coordinator = coordinator(registry, state, store: { store })
        coordinator.start()
        XCTAssertTrue(state.sources.isEmpty)
        state.enrolled = true
        coordinator.reconcilePrivacyPolicy()
        XCTAssertTrue(state.sources.isEmpty, "Enrollment cannot substitute for current consent")
        state.termsAccepted = true
        coordinator.reconcilePrivacyPolicy()
        XCTAssertEqual(state.sources.count, 1)
        XCTAssertEqual(state.sources.first?.connections, [peripheral])
        XCTAssertEqual(state.sources.first?.scans, 0)
        coordinator.start()
        coordinator.reconcilePrivacyPolicy()
        XCTAssertEqual(state.sources.count, 1, "Repeated setup must not start another source")
    }

    func testRevocationStopsSourceAndOldCallbacksStayFencedAfterSameOwnerResume() async throws {
        let store = try await WhoopStore.inMemory(), state = SourcePolicyState(ready: true)
        let registry = registry(store)
        let coordinator = coordinator(registry, state, store: { store })
        coordinator.start()
        let old = try XCTUnwrap(state.sources.first)
        state.enrolled = false
        coordinator.reconcilePrivacyPolicy()
        XCTAssertEqual(old.stops, 1)
        let stops = state.whoopStops
        coordinator.reconcilePrivacyPolicy()
        XCTAssertEqual(old.stops, 1)
        XCTAssertEqual(state.whoopStops, stops)
        old.emit(ts: 100)
        state.enrolled = true
        coordinator.reconcilePrivacyPolicy()
        XCTAssertEqual(state.sources.count, 2)
        old.emit(ts: 101)
        state.sources[1].emit(ts: 102)
        let rows = try await waitForRows(store, expected: 1)
        XCTAssertEqual(rows.map(\.ts), [102])
        XCTAssertEqual(registry.activeDeviceId, strap)
    }

    func testQueuedPersistenceCannotResumeAfterConsentRevocation() async throws {
        let store = try await WhoopStore.inMemory(), state = SourcePolicyState(ready: true)
        let gate = CaptureStoreGate()
        let entered = expectation(description: "Persistence awaits the capture store")
        let registry = registry(store)
        let coordinator = coordinator(registry, state, store: {
            if gate.shouldWait {
                gate.shouldWait = false
                entered.fulfill()
                await gate.wait()
            }
            return store
        })
        coordinator.start()
        state.sources[0].emit(ts: 100)
        await fulfillment(of: [entered], timeout: 2)
        state.termsAccepted = false
        coordinator.reconcilePrivacyPolicy()
        state.termsAccepted = true
        coordinator.reconcilePrivacyPolicy()
        gate.release()
        state.sources[1].emit(ts: 102)
        let rows = try await waitForRows(store, expected: 1)
        XCTAssertEqual(rows.map(\.ts), [102])
    }

    func testBlockedDeviceSelectionResumesOnlyLatestSelectedStrap() async throws {
        let store = try await WhoopStore.inMemory(), state = SourcePolicyState()
        let registry = registry(store)
        let coordinator = coordinator(registry, state, store: { store })
        coordinator.start()
        registry.add(PairedDevice(id: "huami-test", brand: "Amazfit", model: "Band", peripheralId: nil,
            sourceKind: .huami, capabilities: [.hr], status: .paired, addedAt: 2, lastSeenAt: 2))
        registry.setActive("huami-test")
        XCTAssertTrue(state.sources.isEmpty)
        state.enrolled = true
        state.termsAccepted = true
        coordinator.reconcilePrivacyPolicy()
        XCTAssertEqual(state.sources.map(\.deviceId), ["huami-test"])
        XCTAssertEqual(state.sources.first?.scans, 1)
        XCTAssertEqual(state.whoopStarts, 0)
    }

    func testEnrollmentNotificationStopsGenericSourceAndTermsNotificationResumesIt() async throws {
        let store = try await WhoopStore.inMemory(), state = SourcePolicyState(ready: true)
        let registry = registry(store)
        let coordinator = coordinator(registry, state, store: { store })
        coordinator.start()
        let old = try XCTUnwrap(state.sources.first)
        state.enrolled = false
        state.notifications.post(name: .cloudEnrollmentDidChange, object: nil)
        for _ in 0..<100 where old.stops == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(old.stops, 1)
        state.enrolled = true
        state.notifications.post(name: UserDefaults.didChangeNotification, object: nil)
        for _ in 0..<100 where state.sources.count == 1 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(state.sources.count, 2)
    }

    func testWhoopResumeTargetsSelectedDeviceOnceWithoutGenericScan() async throws {
        let store = try await WhoopStore.inMemory(), state = SourcePolicyState()
        let registry = registry(store)
        registry.setActive("my-whoop")
        let coordinator = coordinator(registry, state, store: { store })
        coordinator.start()
        XCTAssertEqual(state.whoopStarts, 0)
        state.enrolled = true
        state.termsAccepted = true
        coordinator.reconcilePrivacyPolicy()
        coordinator.reconcilePrivacyPolicy()
        XCTAssertEqual(state.whoopStarts, 1)
        XCTAssertTrue(state.sources.isEmpty)
    }

    func testRevocationNotificationStillFencesOldSourceAfterImmediateReenrollment() async throws {
        let store = try await WhoopStore.inMemory(), state = SourcePolicyState(ready: true)
        let registry = registry(store)
        let coordinator = coordinator(registry, state, store: { store })
        coordinator.start()
        let old = try XCTUnwrap(state.sources.first)
        // The MainActor receives this after the credentials have already been restored.
        state.notifications.post(name: .cloudEnrollmentDidChange, object: nil, userInfo: ["revoked": true])
        for _ in 0..<100 where state.sources.count == 1 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(old.stops, 1)
        XCTAssertEqual(state.sources.count, 2)
        guard state.sources.count == 2 else { return }
        old.emit(ts: 100)
        state.sources[1].emit(ts: 102)
        let rows = try await waitForRows(store, expected: 1)
        XCTAssertEqual(rows.map(\.ts), [102])
    }

    private func waitForRows(_ store: WhoopStore, expected: Int) async throws -> [HRSample] {
        for _ in 0..<100 {
            let rows = try await store.hrSamples(deviceId: strap, from: 0, to: 1000, limit: 100)
            if rows.count >= expected { return rows }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Expected accepted source data to reach the real SQLite store")
        return try await store.hrSamples(deviceId: strap, from: 0, to: 1000, limit: 100)
    }
}

@MainActor
private final class SourcePolicyState {
    let notifications = NotificationCenter()
    var enrolled: Bool
    var termsAccepted: Bool
    var sources: [FakeCloudGatedSource] = []
    var whoopStarts = 0
    var whoopStops = 0
    init(ready: Bool = false) { enrolled = ready; termsAccepted = ready }
}

@MainActor
private final class FakeCloudGatedSource: LiveHRSource {
    let deviceId: String
    let persist: (Streams) -> Void
    var connections: [UUID] = []
    var scans = 0
    var stops = 0
    init(deviceId: String, persist: @escaping (Streams) -> Void) { self.deviceId = deviceId; self.persist = persist }
    func connect(_ id: UUID) { connections.append(id) }
    func scan() { scans += 1 }
    func stop() { stops += 1 }
    func emit(ts: Int) { persist(Streams(hr: [.init(ts: ts, bpm: 60)])) }
}

@MainActor
private final class CaptureStoreGate {
    var shouldWait = true
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
