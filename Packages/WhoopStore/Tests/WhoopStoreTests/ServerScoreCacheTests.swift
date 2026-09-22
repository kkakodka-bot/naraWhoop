import XCTest
@testable import WhoopStore

final class ServerScoreCacheTests: XCTestCase {
    func testRoundTripDailyAndNights() async throws {
        let store = try await WhoopStore.inMemory()
        let cacheStore = ServerScoreCacheStore(db: store.registryWriter)
        let daily = ServerScoreDailyCache(
            hrvRmssdMs: 44.2,
            restingHrBpm: 51,
            sleepTotalMin: 410,
            computedAt: "2026-09-16T08:00:00Z"
        )
        let nights = [
            ServerScoreNightCache(
                id: "n1",
                startAt: "2026-09-15T23:00:00Z",
                endAt: "2026-09-16T07:00:00Z",
                isNap: false,
                asleepMin: 410,
                inBedMin: 450,
                lightMin: 200,
                deepMin: 90,
                remMin: 120,
                awakeMin: 40,
                efficiency: 91,
                hrvRmssdMs: 44.2,
                restingHrBpm: 51
            ),
        ]
        try cacheStore.upsert(day: "2026-09-16", daily: daily, nights: nights, computedAt: daily.computedAt, stale: false)
        let loaded = try cacheStore.load(day: "2026-09-16")
        XCTAssertEqual(loaded?.daily?.hrvRmssdMs, 44.2)
        XCTAssertEqual(loaded?.nights.count, 1)
        XCTAssertEqual(loaded?.stale, false)
    }
}
