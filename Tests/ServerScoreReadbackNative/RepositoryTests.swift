import Foundation
import XCTest
import NoopPush

private actor ReadbackFeed {
    private(set) var days: [String] = []
    var delayed = false
    private var replies: [(CheckedContinuation<ServerScoreResponse, Never>, ServerScoreResponse)] = []
    func setDelayed() { delayed = true }
    func fetch(day: String, context: AccountSessionContext) async throws -> ServerScoreResponse {
        days.append(day)
        let object: [String: Any] = ["schemaVersion": 2, "day": day, "status": "partial",
            "userId": context.scope.userID, "sourceDeviceId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "timezone": "America/Los_Angeles", "algorithmVersion": "test-v2",
            "inputRevision": 1, "resultRevision": 1, "computedAt": "2026-09-18T15:00:00Z",
            "coverage": [:], "daily": ["hrv_rmssd_ms": 42], "sleep": []]
        let response = try ServerScoreResponse.decode(JSONSerialization.data(withJSONObject: object), requestedDay: day)
        if !delayed { return response }
        return await withCheckedContinuation { replies.append(($0, response)) }
    }
    func release() { let saved = replies; replies = []; for (reply, value) in saved { reply.resume(returning: value) } }
    func waitForCalls(_ count: Int) async {
        for _ in 0..<10000 {
            if days.count >= count && (!delayed || replies.count >= count) { return }
            await Task.yield()
        }
    }
}

@MainActor
final class ServerScoreRepositoryNativeTests: XCTestCase {
    private func identity() throws -> AccountSessionContext {
        let context = AccountSessionContext(scope: try AccountScope(projectURL: "https://w4-fixture.invalid", userID: UUID().uuidString), generation: UUID())
        CloudAuthClient.context = context
        CloudAuthClient.failSignOut = false
        CloudAuthClient.lastPersistenceError = nil
        return context
    }
    private func repository(_ feed: ReadbackFeed, now: @escaping () -> Date = { ServerScoreDate.parse("2026-09-18T15:00:00Z")! }) -> ServerScoreRepository {
        let repo = ServerScoreRepository(fetch: { try await feed.fetch(day: $0, context: $1) }, now: now)
        repo.configure(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        return repo
    }
    func testImmediateReadWithoutLocalRepositoryAndEqualCountPublication() async throws {
        _ = try identity()
        let feed = ReadbackFeed()
        let repo = repository(feed)
        defer { repo.invalidate() }
        await repo.refreshVisibleDays()
        let revision = repo.state.revision
        XCTAssertEqual(repo.state.days["2026-09-18"]?.snapshot?.daily?[.hrv], 42)
        await repo.refreshVisibleDays()
        XCTAssertEqual(repo.state.revision, revision, "an unchanged result must not invalidate content projections")
        XCTAssertEqual(repo.state.days.count, 1)
        let count = await feed.days.count
        XCTAssertEqual(count, 1, "a fresh repeated screen request should not call the receiver")
    }
    func testMidnightRefreshUsesNewCalendarDay() async throws {
        _ = try identity()
        var date = ServerScoreDate.parse("2026-09-18T06:59:59Z")!
        let feed = ReadbackFeed()
        let repo = repository(feed, now: { date })
        defer { repo.invalidate() }
        await repo.refreshVisibleDays()
        date = date.addingTimeInterval(1)
        await repo.refreshVisibleDays()
        let days = await feed.days
        XCTAssertTrue(days.contains("2026-09-17"))
        XCTAssertTrue(days.contains("2026-09-18"))
        XCTAssertEqual(repo.state.currentDay, "2026-09-18")
    }
    func testConcurrentSameDayReadsAreSingleFlight() async throws {
        _ = try identity()
        let feed = ReadbackFeed()
        await feed.setDelayed()
        let repo = repository(feed)
        defer { repo.invalidate() }
        let first = Task { await repo.refreshVisibleDays() }
        let second = Task { await repo.refreshVisibleDays() }
        await feed.waitForCalls(1)
        for _ in 0..<20 { await Task.yield() }
        let calls = await feed.days.count
        XCTAssertEqual(calls, 1)
        await feed.release()
        await first.value
        await second.value
    }
    func testRetiredGenerationRejectsDelayedReply() async throws {
        _ = try identity()
        let feed = ReadbackFeed()
        await feed.setDelayed()
        let repo = repository(feed)
        let task = Task { await repo.refreshVisibleDays() }
        await feed.waitForCalls(1)
        _ = try identity()
        repo.invalidate()
        await feed.release()
        await task.value
        XCTAssertEqual(repo.state, .empty)
        XCTAssertFalse(repo.signedIn)
    }
    func testBackgroundRefreshNotificationDoesNotFetch() async throws {
        _ = try identity()
        let feed = ReadbackFeed()
        let repo = repository(feed)
        defer { repo.invalidate() }
        repo.setForeground(false)
        for _ in 0..<20 { await Task.yield() }
        let before = await feed.days.count
        NotificationCenter.default.post(name: ServerScoreRepository.refreshRequested, object: nil)
        for _ in 0..<30 { await Task.yield() }
        await repo.refreshVisibleDays()
        let after = await feed.days.count
        XCTAssertEqual(before, after)
    }
    func testFailedSignOutSurvivesReplacementAndExplicitRetry() throws {
        _ = try identity()
        let repo = repository(ReadbackFeed())
        CloudAuthClient.failSignOut = true
        repo.signOut()
        XCTAssertTrue(repo.signOutNeedsRetry)
        XCTAssertNotNil(repo.lastError)
        XCTAssertFalse(repo.signedIn)
        repo.invalidate()
        let replacement = repository(ReadbackFeed())
        defer { replacement.invalidate() }
        XCTAssertTrue(replacement.signOutNeedsRetry)
        CloudAuthClient.failSignOut = false
        replacement.signOut()
        XCTAssertFalse(replacement.signOutNeedsRetry)
        XCTAssertNil(replacement.lastError)
    }
}
