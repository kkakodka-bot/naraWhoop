import Foundation
import XCTest
import NoopPush
import WhoopStore

private actor RefreshFeed {
    private(set) var days: [String] = []
    var revision: Int = 1
    var value: Int = 42
    var pending = false
    var failure: Failure?
    var suspended = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    enum Failure { case offline, authentication }
    func configure(revision: Int = 1, value: Int = 42, pending: Bool = false, failure: Failure? = nil) {
        self.revision = revision; self.value = value; self.pending = pending; self.failure = failure
    }
    func suspend() { suspended = true }
    func release() {
        suspended = false
        let held = continuations; continuations.removeAll()
        held.forEach { $0.resume() }
    }
    func fetch(day: String, context: AccountSessionContext) async throws -> ServerScoreResponse {
        days.append(day)
        let failure = failure
        let object: [String: Any] = ["schemaVersion": 2, "day": day, "status": "partial",
            "userId": context.scope.userID, "sourceDeviceId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "timezone": TimeZone.current.identifier, "algorithmVersion": "synthetic-v2",
            "inputRevision": revision, "resultRevision": revision, "computedAt": "2026-09-18T15:00:00Z",
            "coverage": [:], "daily": ["hrv_rmssd_ms": value], "sleep": [], "pending": pending]
        let response = try ServerScoreResponse.decode(JSONSerialization.data(withJSONObject: object), requestedDay: day)
        if suspended { await withCheckedContinuation { continuations.append($0) } }
        switch failure {
        case .offline: throw URLError(.notConnectedToInternet)
        case .authentication: throw ServerScoreClient.FetchError.unauthorized
        case nil: return response
        }
    }
    func waitForCall() async {
        for _ in 0..<10_000 {
            if !days.isEmpty && (!suspended || !continuations.isEmpty) { return }
            await Task.yield()
        }
    }
}

@MainActor
private final class RefreshClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ interval: TimeInterval) { date = date.addingTimeInterval(interval) }
}

private actor CacheRestoreProbe {
    private(set) var calls = 0
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend() { held = true }
    func restore(_ row: ServerScoreCachedSnapshot) async throws -> ServerScoreSnapshot {
        calls += 1
        if held { await withCheckedContinuation { continuation = $0 } }
        return try await ServerScoreDecodeWorker.shared.restore(row)
    }
    func release() { held = false; continuation?.resume(); continuation = nil }
    func waitForCall() async {
        for _ in 0..<10_000 {
            if calls > 0 && (!held || continuation != nil) { return }
            await Task.yield()
        }
    }
}

@MainActor
final class ServerScoreRefreshNativeTests: XCTestCase {
    private func identity() throws -> AccountSessionContext {
        let context = AccountSessionContext(scope: try AccountScope(projectURL: "https://refresh-fixture.invalid",
            userID: UUID().uuidString), generation: UUID())
        CloudAuthClient.context = context
        CloudAuthClient.failSignOut = false
        CloudAuthClient.lastPersistenceError = nil
        return context
    }
    private func repository(_ feed: RefreshFeed, clock: RefreshClock) -> ServerScoreRepository {
        ServerScoreRepository(fetch: { try await feed.fetch(day: $0, context: $1) }, now: { clock.date })
    }

    private func cachedStore(context: AccountSessionContext, clock: RefreshClock) async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        let cache = ServerScoreSnapshotCache(db: store.registryWriter)
        let owner = ServerScoreCacheOwner(projectURL: context.scope.projectURL, userID: context.scope.userID)
        let session = ServerScoreCacheSession(owner: owner, generation: context.generation)
        await cache.activate(session)
        let response = try await RefreshFeed().fetch(day: ServerScoreDate.day(clock.date, timeZone: .current), context: context)
        let snapshot = try XCTUnwrap(response.snapshot)
        let row = try await ServerScoreDecodeWorker.shared.prepare(snapshot, owner: owner, now: clock.date)
        try await cache.store(row, session: session)
        return store
    }

    func testColdCacheHydratesBeforeAnyNetworkAndIsNotReloadedOnForeground() async throws {
        let context = try identity()
        ServerScoringSettings.activated[context.scope] = [.hrv]
        let feed = RefreshFeed(), clock = RefreshClock(), restores = CacheRestoreProbe()
        let store = try await cachedStore(context: context, clock: clock)
        let repo = ServerScoreRepository(fetch: { try await feed.fetch(day: $0, context: $1) },
            now: { clock.date }, restore: { try await restores.restore($0) })
        defer { repo.invalidate() }
        await repo.wireAndHydrate(store: store)
        let initialRequests = await feed.days.count
        XCTAssertEqual(initialRequests, 0)
        XCTAssertTrue(repo.state.hasServerOwnership)
        XCTAssertEqual(repo.state.days[repo.currentDay]?.snapshot?.daily?[.hrv], 42)
        XCTAssertEqual(repo.state.days[repo.currentDay]?.cached, true)
        for _ in 0..<3 {
            repo.setForeground(false)
            repo.setForeground(true)
            for _ in 0..<30 { await Task.yield() }
        }
        let restoreCount = await restores.calls
        XCTAssertEqual(restoreCount, 1)
    }

    func testCacheDecodeCannotEraseNewerOfflineStatus() async throws {
        let context = try identity()
        let feed = RefreshFeed(), clock = RefreshClock(), restores = CacheRestoreProbe()
        let store = try await cachedStore(context: context, clock: clock)
        await restores.suspend()
        let repo = ServerScoreRepository(fetch: { try await feed.fetch(day: $0, context: $1) },
            now: { clock.date }, restore: { try await restores.restore($0) })
        defer { repo.invalidate() }
        let hydration = Task { await repo.wireAndHydrate(store: store) }
        await restores.waitForCall()
        await feed.configure(failure: .offline)
        await repo.refreshVisibleDays()
        XCTAssertEqual(repo.state.days[repo.currentDay]?.phase, .offline)
        await restores.release()
        await hydration.value
        XCTAssertEqual(repo.state.days[repo.currentDay]?.phase, .offline)
        XCTAssertEqual(repo.state.days[repo.currentDay]?.snapshot?.daily?[.hrv], 42)
        XCTAssertEqual(repo.state.days[repo.currentDay]?.cached, true)
    }

    func testForegroundDuringColdHydrationJoinsTheSameCacheRead() async throws {
        let context = try identity()
        let feed = RefreshFeed(), clock = RefreshClock(), restores = CacheRestoreProbe()
        let store = try await cachedStore(context: context, clock: clock)
        await restores.suspend()
        let repo = ServerScoreRepository(fetch: { try await feed.fetch(day: $0, context: $1) },
            now: { clock.date }, restore: { try await restores.restore($0) })
        defer { repo.invalidate() }
        let hydration = Task { await repo.wireAndHydrate(store: store) }
        await restores.waitForCall()
        repo.setForeground(true)
        for _ in 0..<50 { await Task.yield() }
        let restoreCount = await restores.calls
        let networkCount = await feed.days.count
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(networkCount, 0)
        await restores.release()
        await hydration.value
    }

    func testAccountChangeDuringCacheDecodeCannotPublishPriorOwner() async throws {
        let context = try identity()
        let feed = RefreshFeed(), clock = RefreshClock(), restores = CacheRestoreProbe()
        let store = try await cachedStore(context: context, clock: clock)
        await restores.suspend()
        let repo = ServerScoreRepository(fetch: { try await feed.fetch(day: $0, context: $1) },
            now: { clock.date }, restore: { try await restores.restore($0) })
        defer { repo.invalidate() }
        let hydration = Task { await repo.wireAndHydrate(store: store) }
        await restores.waitForCall()
        let replacement = try identity()
        await repo.refreshVisibleDays()
        await restores.release()
        await hydration.value
        XCTAssertEqual(repo.state.generation, replacement.generation)
        XCTAssertEqual(repo.state.days[repo.currentDay]?.snapshot?.userId, replacement.scope.userID)
    }

    func testFreshRepeatedRequestsCoalesceButExplicitRefreshBypassesFreshness() async throws {
        _ = try identity()
        let feed = RefreshFeed(), clock = RefreshClock(), repo = repository(feed, clock: clock)
        defer { repo.invalidate() }
        await repo.refreshVisibleDays()
        let revision = repo.state.revision
        for _ in 0..<10 { await repo.refreshVisibleDays() }
        let before = await feed.days.count
        XCTAssertEqual(before, 1)
        XCTAssertEqual(repo.state.revision, revision)
        await repo.refreshVisibleDays(reason: .userInitiated)
        let after = await feed.days.count
        XCTAssertEqual(after, 2)
        XCTAssertEqual(repo.state.revision, revision)
    }

    func testSelectedHistoricalDayIsRequestedBeforeCurrentDay() async throws {
        _ = try identity()
        let feed = RefreshFeed(), clock = RefreshClock(), repo = repository(feed, clock: clock)
        defer { repo.invalidate() }
        let selected = ServerScoreDate.offsetDay(repo.currentDay, by: -3, timeZone: .current)
        await repo.refreshVisibleDays(todayKey: selected)
        let days = await feed.days
        XCTAssertEqual(days, [selected, repo.currentDay])
    }

    func testSelectionDuringInactiveCacheBootstrapIsRetainedWithoutHTTP() async throws {
        _ = try identity()
        let feed = RefreshFeed(), clock = RefreshClock(), repo = repository(feed, clock: clock)
        defer { repo.invalidate() }
        let selected = ServerScoreDate.offsetDay(repo.currentDay, by: -3, timeZone: .current)
        repo.setForeground(false)
        await repo.refreshVisibleDays(todayKey: selected)
        let inactiveCount = await feed.days.count
        XCTAssertEqual(inactiveCount, 0)
        repo.setForeground(true)
        await repo.refreshVisibleDays()
        let days = await feed.days
        XCTAssertEqual(days, [selected, repo.currentDay])
    }

    func testRecentHistoryRemainsFreshWhenCurrentDayExpires() async throws {
        _ = try identity()
        let feed = RefreshFeed(), clock = RefreshClock(), repo = repository(feed, clock: clock)
        defer { repo.invalidate() }
        await repo.refreshRecentDays(limit: 3)
        await repo.refreshRecentDays(limit: 3)
        let freshCount = await feed.days.count
        XCTAssertEqual(freshCount, 3)
        clock.advance(46)
        await repo.refreshRecentDays(limit: 3, reason: .poll)
        let refreshed = await feed.days
        XCTAssertEqual(refreshed.count, 4)
        XCTAssertEqual(refreshed.last, repo.currentDay)
        clock.advance(300)
        await repo.refreshRecentDays(limit: 3)
        let expiredCount = await feed.days.count
        XCTAssertEqual(expiredCount, 7)
    }

    func testInvalidationsDuringOneRequestProduceOnlyOneTrailingRead() async throws {
        _ = try identity()
        let feed = RefreshFeed(), clock = RefreshClock(), repo = repository(feed, clock: clock)
        defer { repo.invalidate() }
        await feed.suspend()
        let initial = Task { await repo.refreshVisibleDays() }
        await feed.waitForCall()
        let invalidations = (0..<8).map { _ in Task { await repo.refreshVisibleDays(reason: .invalidation) } }
        for _ in 0..<30 { await Task.yield() }
        let heldCount = await feed.days.count
        XCTAssertEqual(heldCount, 1)
        await feed.release()
        await initial.value
        for task in invalidations { await task.value }
        let completedCount = await feed.days.count
        XCTAssertEqual(completedCount, 2)
    }

    func testTransientFailuresBackOffAndKeepCachedContent() async throws {
        _ = try identity()
        let feed = RefreshFeed(), clock = RefreshClock(), repo = repository(feed, clock: clock)
        defer { repo.invalidate() }
        await repo.refreshVisibleDays()
        let revision = repo.state.revision
        await feed.configure(failure: .offline)
        await repo.refreshVisibleDays(reason: .userInitiated)
        XCTAssertEqual(repo.state.days[repo.currentDay]?.phase, .offline)
        XCTAssertEqual(repo.state.days[repo.currentDay]?.snapshot?.daily?[.hrv], 42)
        XCTAssertEqual(repo.state.revision, revision)
        await repo.refreshVisibleDays(reason: .invalidation)
        clock.advance(14)
        await repo.refreshVisibleDays(reason: .poll)
        let heldCount = await feed.days.count
        XCTAssertEqual(heldCount, 2)
        clock.advance(1)
        await repo.refreshVisibleDays(reason: .poll)
        let retryCount = await feed.days.count
        XCTAssertEqual(retryCount, 3)
        clock.advance(29)
        await repo.refreshVisibleDays()
        let secondHeldCount = await feed.days.count
        XCTAssertEqual(secondHeldCount, 3)
        clock.advance(1)
        await feed.configure()
        await repo.refreshVisibleDays()
        XCTAssertEqual(repo.state.days[repo.currentDay]?.phase, .partial)
        XCTAssertEqual(repo.state.revision, revision)
    }

    func testPendingAuthenticationAndRecoveryRemainObservableWithoutContentRevisionChurn() async throws {
        _ = try identity()
        let feed = RefreshFeed(), clock = RefreshClock(), repo = repository(feed, clock: clock)
        defer { repo.invalidate() }
        await repo.refreshVisibleDays()
        let revision = repo.state.revision
        await feed.configure(pending: true)
        await repo.refreshVisibleDays(reason: .userInitiated)
        XCTAssertEqual(repo.state.days[repo.currentDay]?.pending, true)
        XCTAssertEqual(repo.state.revision, revision)
        await feed.configure(failure: .authentication)
        await repo.refreshVisibleDays(reason: .userInitiated)
        XCTAssertEqual(repo.state.days[repo.currentDay]?.phase, .authenticationRequired)
        XCTAssertEqual(repo.state.revision, revision)
        await feed.configure(revision: 2, value: 43)
        await repo.refreshVisibleDays(reason: .userInitiated)
        XCTAssertGreaterThan(repo.state.revision, revision)
        XCTAssertEqual(repo.state.days[repo.currentDay]?.snapshot?.daily?[.hrv], 43)
    }

    func testSameRevisionMutationStillFailsClosed() async throws {
        _ = try identity()
        let feed = RefreshFeed(), clock = RefreshClock(), repo = repository(feed, clock: clock)
        defer { repo.invalidate() }
        await repo.refreshVisibleDays()
        let revision = repo.state.revision
        await feed.configure(value: 99)
        await repo.refreshVisibleDays(reason: .userInitiated)
        XCTAssertEqual(repo.state.days[repo.currentDay]?.phase, .failed)
        XCTAssertEqual(repo.state.days[repo.currentDay]?.snapshot?.daily?[.hrv], 42)
        XCTAssertEqual(repo.state.revision, revision)
    }

    func testAccountChangeClearsFreshnessAndRejectsOldDelayedReply() async throws {
        _ = try identity()
        let feed = RefreshFeed(), clock = RefreshClock(), repo = repository(feed, clock: clock)
        defer { repo.invalidate() }
        await feed.suspend()
        let old = Task { await repo.refreshVisibleDays() }
        await feed.waitForCall()
        let replacement = try identity()
        await feed.release()
        await repo.refreshVisibleDays()
        await old.value
        XCTAssertEqual(repo.state.generation, replacement.generation)
        XCTAssertEqual(repo.state.days[repo.currentDay]?.snapshot?.userId, replacement.scope.userID)
        let count = await feed.days.count
        XCTAssertEqual(count, 2)
    }

    func testRepeatedForegroundTransitionsDoNotRefetchFreshSnapshot() async throws {
        _ = try identity()
        let feed = RefreshFeed(), clock = RefreshClock(), repo = repository(feed, clock: clock)
        defer { repo.invalidate() }
        await repo.refreshVisibleDays()
        for _ in 0..<3 {
            repo.setForeground(false)
            repo.setForeground(true)
            for _ in 0..<20 { await Task.yield() }
        }
        let count = await feed.days.count
        XCTAssertEqual(count, 1)
    }

    func testBackgroundInvalidationIsRetainedUntilForegroundWithoutBackgroundHTTP() async throws {
        _ = try identity()
        let feed = RefreshFeed(), clock = RefreshClock(), repo = repository(feed, clock: clock)
        defer { repo.invalidate() }
        await repo.refreshVisibleDays()
        repo.setForeground(false)
        await feed.configure(revision: 2, value: 43)
        NotificationCenter.default.post(name: ServerScoreRepository.refreshRequested, object: nil)
        for _ in 0..<50 { await Task.yield() }
        let backgroundCount = await feed.days.count
        XCTAssertEqual(backgroundCount, 1)
        repo.setForeground(true)
        await repo.refreshVisibleDays()
        for _ in 0..<50 { await Task.yield() }
        let foregroundCount = await feed.days.count
        XCTAssertEqual(foregroundCount, 2)
        XCTAssertEqual(repo.state.days[repo.currentDay]?.snapshot?.daily?[.hrv], 43)
    }

    func testClockRollbackDoesNotCreateAnUnboundedFailurePause() async throws {
        _ = try identity()
        let feed = RefreshFeed(), clock = RefreshClock(), repo = repository(feed, clock: clock)
        defer { repo.invalidate() }
        await feed.configure(failure: .offline)
        await repo.refreshVisibleDays()
        clock.advance(-3600)
        await feed.configure()
        await repo.refreshVisibleDays()
        let count = await feed.days.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(repo.state.days[repo.currentDay]?.phase, .partial)
    }
}

final class ServerScoreReadSessionOwnerTests: XCTestCase {
    func testSessionReusedOnlyWithinCapturedGenerationAndOldRetirementCannotCancelReplacement() throws {
        let scope = try AccountScope(projectURL: "https://session-fixture.invalid", userID: UUID().uuidString)
        let first = AccountSessionContext(scope: scope, generation: UUID())
        let replacement = AccountSessionContext(scope: scope, generation: UUID())
        let owner = ServerScoreReadSessionOwner()
        let a = try owner.session(context: first, isCurrent: { $0 == first })
        let b = try owner.session(context: first, isCurrent: { $0 == first })
        XCTAssertTrue(a === b)
        let c = try owner.session(context: replacement, isCurrent: { $0 == replacement })
        XCTAssertFalse(a === c)
        owner.retire(context: first)
        let d = try owner.session(context: replacement, isCurrent: { $0 == replacement })
        XCTAssertTrue(c === d)
        owner.retire(context: replacement)
    }

    func testRetiredOwnerCannotReplaceLiveSession() throws {
        let scope = try AccountScope(projectURL: "https://session-fixture.invalid", userID: UUID().uuidString)
        let first = AccountSessionContext(scope: scope, generation: UUID())
        let replacement = AccountSessionContext(scope: scope, generation: UUID())
        let owner = ServerScoreReadSessionOwner()
        let live = try owner.session(context: replacement, isCurrent: { $0 == replacement })
        XCTAssertThrowsError(try owner.session(context: first, isCurrent: { $0 == replacement }))
        let retained = try owner.session(context: replacement, isCurrent: { $0 == replacement })
        XCTAssertTrue(live === retained)
        owner.retire(context: replacement)
    }
}
