import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class ServerScoreRepositoryRaceTests: XCTestCase {
    private let day = "2026-09-16"
    private let ownerA = "11111111-1111-1111-1111-111111111111"
    private let ownerB = "44444444-4444-4444-4444-444444444444"
    private let ownerKey = "noop.serverScoring.ingestOwnerId"
    private var savedOwner: Any?
    private var savedOverlayLive = false

    override func setUp() {
        super.setUp()
        savedOwner = UserDefaults.standard.object(forKey: ownerKey)
        savedOverlayLive = CloudScoreIdentity.overlayLive
        CloudScoreIdentity.clearIngestOwner()
    }

    override func tearDown() {
        if let savedOwner { UserDefaults.standard.set(savedOwner, forKey: ownerKey) }
        else { UserDefaults.standard.removeObject(forKey: ownerKey) }
        CloudScoreIdentity.markOverlayLive(savedOverlayLive)
        super.tearDown()
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if !opened { await withCheckedContinuation { continuation = $0 } }
        }
        func open() { opened = true; continuation?.resume(); continuation = nil }
    }

    func testEnrollmentResultsPopulateDashboardAndSignOutClearsThem() async throws {
        let auth = Auth(ownerA)
        let result = try snapshot(ownerA)
        let repo = ServerScoreRepository(dependencies: dependencies(auth) { _, _ in result })
        let store = try await WhoopStore.inMemory()
        repo.selectDevice(localDeviceId: "strap-a")
        repo.wire(store: store)
        await repo.refreshVisibleDays(todayKey: day)
        XCTAssertTrue(repo.state.hasServerOwnership)
        XCTAssertTrue(repo.usesEnrollmentReadback)
        XCTAssertTrue(repo.state.owns(.sleepSessions), "Tester sleep must never fall back to local session boundaries")
        XCTAssertEqual(repo.state.scalar(.sleepTotal, day: day), 480)
        XCTAssertNil(repo.state.scalar(.hrv, day: day))
        XCTAssertEqual(ServerScoreDisplay.daily(local: nil, day: day, state: repo.state)?.totalSleepMin, 480)
        XCTAssertEqual(repo.state.days[day]?.phase, .partial)
        XCTAssertFalse(repo.state.days[day]?.pending ?? true)
        XCTAssertNil(repo.state.days[day]?.snapshot, "Enrollment must not invent account snapshot provenance")
        repo.signOut()
        XCTAssertFalse(repo.state.hasServerOwnership)
        XCTAssertTrue(repo.state.enrollmentValues.isEmpty)
    }

    func testCompletedEmptyEnrollmentResultIsNotReportedAsStillComputing() async throws {
        let auth = Auth(ownerA)
        let data = try JSONSerialization.data(withJSONObject: ["server_scoring": [
            "schema_version": 2, "user_id": ownerA, "day": day, "algorithm_version": "per_feature",
            "features": ["sleep": ["status": "available", "device_id": "device",
                "algorithm_version": "frwhoop-server-1", "processing_status": "done",
                "input_revision": 8, "required_revision": 8]],
            "daily": [:], "nights": [], "stale": false
        ]])
        let cache = try ServerScoreCacheCodec.parseSnapshot(data, day: day, ownerId: ownerA)
        let repo = ServerScoreRepository(dependencies: dependencies(auth) { _, _ in cache })
        repo.selectDevice(localDeviceId: "strap-a")
        await repo.refreshVisibleDays(todayKey: day)
        XCTAssertEqual(repo.state.days[day]?.phase, .noData)
        XCTAssertFalse(repo.state.days[day]?.pending ?? true)
        XCTAssertNil(repo.state.scalar(.sleepTotal, day: day))
    }

    func testUnqualifiedV2ResultCannotBlankExistingDashboardFields() async throws {
        let auth = Auth(ownerA)
        let data = try JSONSerialization.data(withJSONObject: ["server_scoring": [
            "schema_version": 2, "user_id": ownerA, "day": day, "algorithm_version": "per_feature",
            "features": [
                "hrv": ["status": "available", "device_id": "device",
                    "algorithm_version": "frwhoop-physiology-2", "processing_status": "done"],
                "sleep": ["status": "available", "device_id": "device",
                    "algorithm_version": "frwhoop-physiology-2", "processing_status": "done"]
            ],
            "daily": ["sleep_total_min": 480, "strain": 12.5], "nights": [], "stale": false
        ]])
        let cache = try ServerScoreCacheCodec.parseSnapshot(data, day: day, ownerId: ownerA)
        let repo = ServerScoreRepository(dependencies: dependencies(auth) { _, _ in cache })
        repo.selectDevice(localDeviceId: "strap-a")
        await repo.refreshVisibleDays(todayKey: day)

        XCTAssertFalse(repo.state.hasServerOwnership)
        XCTAssertFalse(repo.state.owns(.sleepTotal))
        XCTAssertFalse(repo.state.owns(.strain))
        XCTAssertEqual(repo.state.value(.sleepTotal, day: day, local: 321), 321)
        XCTAssertTrue(repo.state.enrollmentValues.isEmpty)
        XCTAssertFalse(CloudScoreIdentity.overlayLive)
    }

    func testEnrollmentPendingAndFailedStatesAreNotFlattenedIntoSuccess() async throws {
        for (processing, expected) in [("running", ServerScoreDayState.Phase.pending), ("exhausted", .failed)] {
            let auth = Auth(ownerA)
            var cache = try snapshot(ownerA)
            cache.features["sleep"]?.processingStatus = processing
            let result = cache
            let repo = ServerScoreRepository(dependencies: dependencies(auth) { _, _ in result })
            repo.selectDevice(localDeviceId: "strap-a")
            await repo.refreshVisibleDays(todayKey: day)
            XCTAssertEqual(repo.state.days[day]?.phase, expected)
            XCTAssertEqual(repo.state.days[day]?.pending, processing == "running")
        }
    }
    private final class Auth {
        var owner: String?
        var conditionalClears = 0
        init(_ owner: String?) { self.owner = owner }
    }
    private func dependencies(_ auth: Auth,
        fetch: @escaping (String, String) async throws -> ServerScoreDayCache) -> ServerScoreRepository.Dependencies {
        .init(ownerId: { auth.owner }, clearSession: { auth.owner = nil },
            clearIfCurrent: { _, owner in
                auth.conditionalClears += 1
                guard auth.owner == owner else { return false }
                auth.owner = nil
                return true
            }, signIn: { owner, _ in auth.owner = owner }, fetch: { day, owner, _ in try await fetch(day, owner) },
            enabled: { true }, ready: { true }, automaticPolling: false,
            canonicalDeviceId: { _, _ in "device" })
    }
    private func snapshot(_ owner: String, revision: Int = 1, device: String = "device") throws -> ServerScoreDayCache {
        let data = try JSONSerialization.data(withJSONObject: ["server_scoring": [
            "schema_version": 2, "user_id": owner, "day": day, "algorithm_version": "per_feature",
            "features": ["sleep": ["status": "available", "device_id": device, "algorithm_version": "frwhoop-server-1",
                "input_revision": revision, "required_revision": revision]],
            "daily": ["sleep_total_min": 480], "nights": [], "stale": false
        ]])
        return try ServerScoreCacheCodec.parseSnapshot(data, day: day, ownerId: owner,
            fetchedAt: Date(timeIntervalSince1970: Double(revision)))
    }

    func testLateSuccessAfterSignOutCannotDisplayOrPersist() async throws {
        let auth = Auth(ownerA), gate = Gate()
        let response = try snapshot(ownerA)
        let entered = expectation(description: "fetch started")
        let repo = ServerScoreRepository(dependencies: dependencies(auth) { _, _ in
            entered.fulfill(); await gate.wait(); return response
        })
        let store = try await WhoopStore.inMemory(); repo.selectDevice(localDeviceId: "strap-a"); repo.wire(store: store)
        let pending = Task { await repo.refreshVisibleDays(todayKey: day) }
        await fulfillment(of: [entered], timeout: 2)
        repo.signOut()
        await gate.open(); await pending.value
        XCTAssertFalse(repo.signedIn); XCTAssertNil(repo.overlay(for: day)); XCTAssertNil(repo.lastFetchedAt)
        XCTAssertNil(try ServerScoreCacheStore(db: store.registryWriter).load(ownerId: ownerA, day: day))
        XCTAssertNil(UserDefaults.standard.string(forKey: ownerKey))
        XCTAssertFalse(CloudScoreIdentity.overlayLive)
    }

    func testDelayedSuccessCannotReplaceNextAccountIngestIdentity() async throws {
        let auth = Auth(ownerA), gate = Gate()
        let old = try snapshot(ownerA), next = try snapshot(ownerB)
        let entered = expectation(description: "old account fetch started")
        let repo = ServerScoreRepository(dependencies: dependencies(auth) { _, owner in
            if owner == self.ownerA {
                entered.fulfill(); await gate.wait(); return old
            }
            return next
        })
        let store = try await WhoopStore.inMemory(); repo.selectDevice(localDeviceId: "strap-a"); repo.wire(store: store)
        let pending = Task { await repo.refreshVisibleDays(todayKey: day) }
        await fulfillment(of: [entered], timeout: 2)
        await repo.signIn(email: ownerB, password: "unused")
        XCTAssertEqual(UserDefaults.standard.string(forKey: ownerKey), ownerB)
        await gate.open(); await pending.value
        XCTAssertEqual(UserDefaults.standard.string(forKey: ownerKey), ownerB)
        XCTAssertEqual(repo.overlay(for: day)?.ownerId, ownerB)
        XCTAssertNil(try ServerScoreCacheStore(db: store.registryWriter).load(ownerId: ownerA, day: day))
    }

    func testDelayedUnauthorizedCannotClearTheNextAccount() async throws {
        let auth = Auth(ownerA), gate = Gate()
        let next = try snapshot(ownerB)
        let entered = expectation(description: "old account fetch started")
        let repo = ServerScoreRepository(dependencies: dependencies(auth) { _, owner in
            if owner == self.ownerA {
                entered.fulfill(); await gate.wait()
                throw ServerScoreClient.FetchError.unauthorized(accessToken: "old-token")
            }
            return next
        })
        let store = try await WhoopStore.inMemory(); repo.selectDevice(localDeviceId: "strap-a"); repo.wire(store: store)
        let pending = Task { await repo.refreshVisibleDays(todayKey: day) }
        await fulfillment(of: [entered], timeout: 2)
        await repo.signIn(email: ownerB, password: "unused")
        XCTAssertEqual(repo.overlay(for: day)?.ownerId, ownerB)
        await gate.open(); await pending.value
        XCTAssertTrue(repo.signedIn); XCTAssertEqual(auth.owner, ownerB)
        XCTAssertEqual(repo.overlay(for: day)?.ownerId, ownerB); XCTAssertNil(repo.lastError)
        XCTAssertEqual(auth.conditionalClears, 0)
    }

    func testOlderOverlappingFetchCannotOverwriteNewerMemoryOrDisk() async throws {
        let auth = Auth(ownerA), gate = Gate()
        let old = try snapshot(ownerA, revision: 1), newest = try snapshot(ownerA, revision: 2)
        let entered = expectation(description: "first fetch started")
        var requests = 0
        let repo = ServerScoreRepository(dependencies: dependencies(auth) { _, _ in
            requests += 1
            if requests == 1 { entered.fulfill(); await gate.wait(); return old }
            return newest
        })
        let store = try await WhoopStore.inMemory(); repo.selectDevice(localDeviceId: "strap-a"); repo.wire(store: store)
        let pending = Task { await repo.refreshVisibleDays(todayKey: day) }
        await fulfillment(of: [entered], timeout: 2)
        await repo.refreshVisibleDays(todayKey: day)
        await gate.open(); await pending.value
        XCTAssertEqual(repo.overlay(for: day)?.features["sleep"]?.inputRevision, 2)
        XCTAssertEqual(try ServerScoreCacheStore(db: store.registryWriter).load(ownerId: ownerA, day: day)?.features["sleep"]?.inputRevision, 2)
    }

    func testOfflineSignInRefreshDoesNotRestorePriorOwnerCache() async throws {
        let auth = Auth(ownerA)
        let prior = try snapshot(ownerA)
        var offline = false
        let repo = ServerScoreRepository(dependencies: dependencies(auth) { _, _ in
            if offline { throw URLError(.notConnectedToInternet) }
            return prior
        })
        let store = try await WhoopStore.inMemory(); repo.selectDevice(localDeviceId: "strap-a"); repo.wire(store: store)
        await repo.refreshVisibleDays(todayKey: day)
        XCTAssertEqual(repo.overlay(for: day)?.ownerId, ownerA)
        offline = true
        await repo.signIn(email: ownerB, password: "unused")
        XCTAssertTrue(repo.signedIn); XCTAssertNil(repo.overlay(for: day))
        XCTAssertEqual(repo.lastError, "Server scores unavailable")
        XCTAssertNotNil(try ServerScoreCacheStore(db: store.registryWriter).load(ownerId: ownerA, day: day))
        XCTAssertNil(try ServerScoreCacheStore(db: store.registryWriter).load(ownerId: ownerB, day: day))
    }

    func testDeviceSwitchFencesDelayedResponseAndRequiresFreshDeviceResult() async throws {
        let auth = Auth(ownerA), gate = Gate()
        let response = try snapshot(ownerA)
        let entered = expectation(description: "old device fetch started")
        var arguments: [String] = []
        var dependencies = dependencies(auth) { _, _ in response }
        dependencies.canonicalDeviceId = { _, _ in nil }
        dependencies.fetch = { _, _, device in
            arguments.append(device)
            if device == "strap-a" { entered.fulfill(); await gate.wait() }
            return response
        }
        let repo = ServerScoreRepository(dependencies: dependencies)
        let store = try await WhoopStore.inMemory()
        repo.selectDevice(localDeviceId: "strap-a"); repo.wire(store: store)
        let pending = Task { await repo.refreshVisibleDays(todayKey: day) }
        await fulfillment(of: [entered], timeout: 2)
        repo.selectDevice(localDeviceId: "strap-b")
        XCTAssertNil(repo.overlay(for: day)); XCTAssertFalse(repo.deviceLinked)
        await gate.open(); await pending.value
        XCTAssertNil(repo.overlay(for: day)); XCTAssertFalse(repo.deviceLinked)
        XCTAssertNil(try ServerScoreCacheStore(db: store.registryWriter).load(ownerId: ownerA, day: day))
        await repo.refreshVisibleDays(todayKey: day)
        XCTAssertEqual(arguments, ["strap-a", "strap-b"])
        XCTAssertNotNil(repo.overlay(for: day)); XCTAssertTrue(repo.deviceLinked)
    }

    func testCachedDifferentDeviceIsNotShownAfterSelection() async throws {
        let auth = Auth(ownerA)
        var dependencies = dependencies(auth) { _, _ in throw URLError(.notConnectedToInternet) }
        dependencies.canonicalDeviceId = { _, local in local == "strap-a" ? "device" : "different-device" }
        let repo = ServerScoreRepository(dependencies: dependencies)
        let store = try await WhoopStore.inMemory()
        try ServerScoreCacheStore(db: store.registryWriter).upsert(snapshot(ownerA))
        repo.selectDevice(localDeviceId: "strap-b"); repo.wire(store: store)
        await repo.refreshVisibleDays(todayKey: day)
        XCTAssertNil(repo.overlay(for: day))
        XCTAssertNotNil(try ServerScoreCacheStore(db: store.registryWriter).load(ownerId: ownerA, day: day))
    }

    func testOfflineSwitchBackRestoresSelectedStrapDespiteNewerOtherStrapCache() async throws {
        let auth = Auth(ownerA)
        let first = try snapshot(ownerA, revision: 1, device: "device-a")
        let second = try snapshot(ownerA, revision: 2, device: "device-b")
        var offline = false
        var dependencies = dependencies(auth) { _, _ in first }
        dependencies.canonicalDeviceId = { _, local in local == "strap-a" ? "device-a" : "device-b" }
        dependencies.fetch = { _, _, local in
            if offline { throw URLError(.notConnectedToInternet) }
            return local == "strap-a" ? first : second
        }
        let repo = ServerScoreRepository(dependencies: dependencies)
        let store = try await WhoopStore.inMemory()
        repo.selectDevice(localDeviceId: "strap-a"); repo.wire(store: store)
        await repo.refreshVisibleDays(todayKey: day)
        XCTAssertEqual(repo.overlay(for: day)?.features["sleep"]?.deviceId, "device-a")
        repo.selectDevice(localDeviceId: "strap-b")
        await repo.refreshVisibleDays(todayKey: day)
        XCTAssertEqual(repo.overlay(for: day)?.features["sleep"]?.deviceId, "device-b")

        offline = true
        repo.selectDevice(localDeviceId: "strap-a")
        await repo.refreshVisibleDays(todayKey: day)
        XCTAssertEqual(repo.overlay(for: day), first)
        XCTAssertEqual(repo.lastError, "Server scores unavailable")
        XCTAssertEqual(try ServerScoreCacheStore(db: store.registryWriter)
            .load(ownerId: ownerA, day: day)?.features["sleep"]?.deviceId, "device-b")
    }

    func testPersistedRegistrationReceiptKeepsSameStrapLinkedOfflineWithoutScores() async throws {
        let auth = Auth(ownerA)
        var dependencies = dependencies(auth) { _, _ in throw URLError(.notConnectedToInternet) }
        dependencies.canonicalDeviceId = { owner, local in
            owner == self.ownerA && local == "strap-a" ? "device-a" : nil
        }
        let repo = ServerScoreRepository(dependencies: dependencies)
        let store = try await WhoopStore.inMemory()
        repo.selectDevice(localDeviceId: "strap-a"); repo.wire(store: store)
        XCTAssertTrue(repo.deviceLinked)
        await repo.refreshVisibleDays(todayKey: day)
        XCTAssertTrue(repo.deviceLinked)
        XCTAssertNil(repo.overlay(for: day))
        repo.selectDevice(localDeviceId: "strap-b")
        XCTAssertFalse(repo.deviceLinked)
        repo.selectDevice(localDeviceId: "strap-a")
        XCTAssertTrue(repo.deviceLinked)
        auth.owner = ownerB
        repo.enrollmentChanged()
        XCTAssertFalse(repo.deviceLinked)
    }

    func testRegistrationAcknowledgedBeforeFailedScoreFetchStillLinksDevice() async throws {
        let auth = Auth(ownerA)
        var registered = false
        var dependencies = dependencies(auth) { _, _ in
            registered = true
            throw URLError(.notConnectedToInternet)
        }
        dependencies.canonicalDeviceId = { _, _ in registered ? "device-a" : nil }
        let repo = ServerScoreRepository(dependencies: dependencies)
        repo.selectDevice(localDeviceId: "strap-a")
        XCTAssertFalse(repo.deviceLinked)
        await repo.refreshVisibleDays(todayKey: day)
        XCTAssertTrue(repo.deviceLinked)
        XCTAssertEqual(repo.lastError, "Server scores unavailable")
    }

    func testConfirmedDeviceLinkRequiresBothTheOwnerAndSelectedStrap() {
        let mapping: (String, String) -> String? = { owner, strap in
            owner == self.ownerA && strap == "strap-a" ? "device-a" : nil
        }
        XCTAssertTrue(ServerScoreRepository.hasConfirmedDeviceLink(
            ownerId: ownerA, localDeviceId: "strap-a", canonicalDeviceId: mapping))
        XCTAssertFalse(ServerScoreRepository.hasConfirmedDeviceLink(
            ownerId: ownerA, localDeviceId: "strap-b", canonicalDeviceId: mapping))
        XCTAssertFalse(ServerScoreRepository.hasConfirmedDeviceLink(
            ownerId: nil, localDeviceId: "strap-a", canonicalDeviceId: mapping))
    }
}
