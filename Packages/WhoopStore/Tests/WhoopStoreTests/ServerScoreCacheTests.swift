import XCTest
@testable import WhoopStore

final class ServerScoreCacheTests: XCTestCase {
    private let owner = "11111111-1111-1111-1111-111111111111"
    private let day = "2026-09-16"
    private func snapshot(ownerId: String? = nil, device: String? = nil) throws -> ServerScoreDayCache {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "server_physiology_snapshot", withExtension: "json"))
        var body = try String(contentsOf: url)
        if let ownerId { body = body.replacingOccurrences(of: owner, with: ownerId) }
        if let device { body = body.replacingOccurrences(of: "22222222-2222-2222-2222-222222222222", with: device) }
        return try ServerScoreCacheCodec.parseSnapshot(Data(body.utf8), day: day, ownerId: ownerId ?? owner,
                                                       fetchedAt: Date(timeIntervalSince1970: 1))
    }

    func testRoundTripPreservesEpochMetadataAndHistoricalAvailability() async throws {
        let store = try await WhoopStore.inMemory()
        let cacheStore = ServerScoreCacheStore(db: store.registryWriter)
        let cache = try snapshot()
        try cacheStore.upsert(cache)
        let loaded = try XCTUnwrap(cacheStore.load(ownerId: owner, day: day))
        XCTAssertEqual(loaded, cache)
        XCTAssertEqual(loaded.daily?.hrvRmssdMs, 0)
        XCTAssertEqual(loaded.nights[0].stages.map(\.state), ["state_unknown", "sleep_unstaged", "off_body"])
        XCTAssertEqual(loaded.nights[0].stages[1].sleepProbability, 0.9)
        XCTAssertNil(loaded.nights[0].stages[1].pLight)
        XCTAssertEqual(loaded.features["sleep"]?.inputRevision, 301)
        XCTAssertEqual(loaded.features["sleep"]?.manifestHash, "fixture-manifest")
        XCTAssertEqual(loaded.nights[0].boundaryProvenance, "manual_boundary")
        XCTAssertFalse(loaded.stale, "Historical data does not expire solely because it is older than six hours")
        XCTAssertTrue(loaded.measurementsJSON?.contains("preserve-me") == true)
    }

    func testOwnerDeviceVersionScopesAndLegacyRowsAreIsolated() async throws {
        let store = try await WhoopStore.inMemory()
        let cacheStore = ServerScoreCacheStore(db: store.registryWriter)
        let first = try snapshot()
        let second = try snapshot(device: "33333333-3333-3333-3333-333333333333")
        try cacheStore.upsert(first); try cacheStore.upsert(second)
        XCTAssertNotEqual(first.scopeKey, second.scopeKey)
        XCTAssertEqual(try cacheStore.load(ownerId: owner, day: day, scopeKey: first.scopeKey), first)
        XCTAssertEqual(try cacheStore.load(ownerId: owner, day: day, scopeKey: second.scopeKey), second)
        XCTAssertNil(try cacheStore.load(ownerId: "another-owner", day: day))
        try cacheStore.upsert(day: day, daily: first.daily, nights: first.nights, computedAt: first.computedAt, stale: false)
        XCTAssertNil(try cacheStore.load(day: day), "Ownerless pre-v2 records are never displayed")
    }

    func testStrictOwnerDayAndSchemaReadback() throws {
        let cache = try snapshot()
        let data = Data(try XCTUnwrap(cache.rawSnapshotJSON).utf8)
        XCTAssertThrowsError(try ServerScoreCacheCodec.parseSnapshot(data, day: day, ownerId: "another-owner"))
        XCTAssertThrowsError(try ServerScoreCacheCodec.parseSnapshot(data, day: "2026-09-17", ownerId: owner))
        let legacy = Data(#"{"server_scoring":{"algorithm_version":"frwhoop-server-1","daily":{}}}"#.utf8)
        XCTAssertThrowsError(try ServerScoreCacheCodec.parseSnapshot(legacy, day: day, ownerId: owner))
    }

    func testSelectedDeviceLoadsItsOlderSnapshotWithoutCrossingOwner() async throws {
        let store = try await WhoopStore.inMemory()
        let persistence = ServerScoreCacheStore(db: store.registryWriter)
        let deviceA = "22222222-2222-2222-2222-222222222222"
        let deviceB = "33333333-3333-3333-3333-333333333333"
        let first = try snapshot()
        let secondFixture = try snapshot(device: deviceB)
        let second = try ServerScoreCacheCodec.parseSnapshot(
            Data(try XCTUnwrap(secondFixture.rawSnapshotJSON).utf8), day: day, ownerId: owner,
            fetchedAt: Date(timeIntervalSince1970: 2))
        try persistence.upsert(first)
        try persistence.upsert(second)
        XCTAssertEqual(try persistence.load(ownerId: owner, day: day), second)
        XCTAssertEqual(try persistence.load(ownerId: owner, day: day, deviceId: deviceA), first)
        XCTAssertEqual(try persistence.load(ownerId: owner, day: day, deviceId: deviceB), second)
        XCTAssertNil(try persistence.load(ownerId: owner, day: day, deviceId: "missing-device"))
        XCTAssertNil(try persistence.load(ownerId: "another-owner", day: day, deviceId: deviceA))
    }

    func testDelayedResponseCannotCrossSignOutOrAccountSwitch() throws {
        let cache = try snapshot()
        var state = ServerScoreSessionState()
        state.activate(ownerId: owner)
        let pending = state.generation
        XCTAssertTrue(state.accept(cache, generation: pending, currentOwnerId: owner))
        state.activate(ownerId: nil)
        XCTAssertNil(state.overlay(day: day, currentOwnerId: nil))
        XCTAssertFalse(state.accept(cache, generation: pending, currentOwnerId: owner))
        let other = "44444444-4444-4444-4444-444444444444"
        state.activate(ownerId: other)
        XCTAssertNil(state.overlay(day: day, currentOwnerId: other))
        XCTAssertFalse(state.accept(cache, generation: pending, currentOwnerId: other))
        state.activate(ownerId: owner)
        XCTAssertFalse(state.accept(cache, generation: pending, currentOwnerId: owner))
        XCTAssertTrue(state.accept(cache, generation: state.generation, currentOwnerId: owner))
        XCTAssertNil(state.overlay(day: day, currentOwnerId: other), "External authentication changes also hide old data")
    }

    func testAllUnknownRemainsUnavailable() throws {
        let cache = try snapshot()
        var root = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(cache.rawSnapshotJSON).utf8)) as! [String: Any]
        var overlay = root["server_scoring"] as! [String: Any]
        overlay["daily"] = ["sleep_total_min": NSNull(), "state_unknown_min": 1.5]
        root["server_scoring"] = overlay
        let parsed = try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: root), day: day, ownerId: owner)
        XCTAssertNil(parsed.daily?.sleepTotalMin)
        XCTAssertEqual(parsed.daily?.stateUnknownMin, 1.5)
    }

    func testLaterRequestAndHigherRevisionWin() throws {
        let cache = try snapshot()
        var state = ServerScoreSessionState(); state.activate(ownerId: owner)
        let oldRequest = state.beginRequest(day: day)
        let newRequest = state.beginRequest(day: day)
        XCTAssertTrue(state.accept(cache, generation: state.generation, currentOwnerId: owner, request: newRequest))
        XCTAssertFalse(state.isCurrentRequest(day: day, generation: state.generation, currentOwnerId: owner, request: oldRequest))
        XCTAssertTrue(state.isCurrentRequest(day: day, generation: state.generation, currentOwnerId: owner, request: newRequest))
        // The same fence is used before unauthorized handling and disk fallback on failure.
        XCTAssertFalse(state.accept(cache, generation: state.generation, currentOwnerId: owner, request: oldRequest))
        let older = try ServerScoreCacheCodec.parseSnapshot(Data(cache.rawSnapshotJSON!.replacingOccurrences(of: "301", with: "300").utf8), day: day, ownerId: owner)
        XCTAssertFalse(state.accept(older, generation: state.generation, currentOwnerId: owner))
    }

    func testLegacySelectedRowsKeepTotalsWithoutClaimingV2Quality() async throws {
        let body = """
        {"server_scoring":{"schema_version":2,"user_id":"\(owner)","day":"\(day)","algorithm_version":"per_feature",
        "features":{"sleep":{"status":"fresh","device_id":"device","algorithm_version":"frwhoop-server-1",
        "computed_at":"2026-09-16T10:00:00Z","required_revision":4,"processing_status":"pending","timezone_id":"UTC","timezone_ids":["UTC","America/Los_Angeles"]}},
        "nights":[{"id":"night","device_id":"device","algorithm_version":"frwhoop-server-1",
        "start_at":"2026-09-16T00:00:00Z","end_at":"2026-09-16T00:02:00Z","is_nap":false,"asleep_min":1.5,"in_bed_min":2,
        "stages":[{"start":1789516800,"end":1789516830,"stage":"wake"},
        {"start":1789516830,"end":1789516860,"stage":"light"},
        {"start":1789516860,"end":1789516890,"stage":"deep"},
        {"start":1789516890,"end":1789516920,"stage":"rem"}]}]}}
        """
        let cache = try ServerScoreCacheCodec.parseSnapshot(Data(body.utf8), day: day, ownerId: owner, fetchedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(cache.nights[0].stages.map(\.state), ["awake", "sleep", "sleep", "sleep"])
        XCTAssertEqual(cache.nights[0].measurementAvailable, true)
        XCTAssertEqual(cache.nights[0].asleepMin, 1.5)
        XCTAssertNil(cache.nights[0].stateCoverage)
        XCTAssertTrue(cache.nights[0].stages.allSatisfy { $0.evidenceCoverage == nil && $0.sleepProbability == nil && $0.algorithmVersion == "frwhoop-server-1" && $0.reason == "legacy_quality_unavailable" })
        XCTAssertTrue(cache.sleepMetadataLines.contains("Legacy baseline · quality and evidence coverage unavailable"))
        XCTAssertTrue(cache.sleepMetadataLines.contains("Observed through: unavailable"))
        XCTAssertTrue(cache.sleepMetadataLines.contains("Fetched: 1970-01-01T00:00:01Z"))
        XCTAssertTrue(cache.sleepMetadataLines.contains("Processing: pending · archive: unavailable"))
        XCTAssertTrue(cache.sleepMetadataLines.contains("Time zones: UTC · America/Los_Angeles"))
        XCTAssertEqual(cache.nights[0].stateCoverageDescription, "State coverage: unavailable")
        let store = try await WhoopStore.inMemory(); let persistence = ServerScoreCacheStore(db: store.registryWriter)
        try persistence.upsert(cache)
        XCTAssertEqual(try persistence.load(ownerId: owner, day: day), cache)
        let v2 = try ServerScoreCacheCodec.parseSnapshot(Data(body.replacingOccurrences(of: "frwhoop-server-1", with: "frwhoop-physiology-2").utf8), day: day, ownerId: owner)
        XCTAssertNil(v2.nights[0].measurementAvailable)
        XCTAssertTrue(v2.nights[0].stages.allSatisfy { $0.state == "state_unknown" && $0.reason == nil })
        let explicitUnknown = body.replacingOccurrences(of: "\"stage\":\"light\"", with: "\"stage\":\"light\",\"state\":\"state_unknown\"")
            .replacingOccurrences(of: "\"asleep_min\":1.5", with: "\"asleep_min\":1.5,\"measurement_available\":false")
        let abstained = try ServerScoreCacheCodec.parseSnapshot(Data(explicitUnknown.utf8), day: day, ownerId: owner)
        XCTAssertEqual(abstained.nights[0].stages[1].state, "state_unknown")
        XCTAssertEqual(abstained.nights[0].measurementAvailable, false)
    }
}
