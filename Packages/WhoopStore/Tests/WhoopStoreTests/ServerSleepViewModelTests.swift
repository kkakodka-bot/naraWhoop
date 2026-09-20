import XCTest
@testable import WhoopStore

final class ServerSleepViewModelTests: XCTestCase {
    private func cache(stages: String, available: Bool = true, type: String = "nap", opportunityKind: String? = nil) throws -> ServerScoreDayCache {
        let opportunity = opportunityKind.map { "\"\($0)\"" } ?? "null"
        let data = Data("""
        {"server_scoring":{"schema_version":2,"user_id":"owner","day":"2026-09-18","algorithm_version":"frwhoop-physiology-2",
        "features":{"sleep":{"status":"fresh","device_id":"device","algorithm_version":"sleep-v2"}},
        "nights":[{"id":"night","device_id":"device","start_at":"2026-09-18T14:00:00Z","end_at":"2026-09-18T14:01:30Z","is_nap":true,
        "episode_type":"\(type)","main_sleep_group_id":"canonical-group","measurement_available":\(available),"asleep_min":0,"opportunity_kind":\(opportunity),
        "stages":\(stages)}]}}
        """.utf8)
        return try ServerScoreCacheCodec.parseSnapshot(data, day: "2026-09-18", ownerId: "owner")
    }
    func testCanonicalStatesDoNotBecomeLightSleep() {
        XCTAssertEqual(ServerSleepEpisode.canonicalState(stage: "light", state: "state_unknown"), "unknown")
        XCTAssertEqual(ServerSleepEpisode.canonicalState(stage: "unknown", state: "sleep_unstaged"), "sleep_unstaged")
        XCTAssertEqual(ServerSleepEpisode.canonicalState(stage: "light", state: "off_body"), "off_body")
        XCTAssertEqual(ServerSleepEpisode.canonicalState(stage: "deep", state: "sleep"), "deep")
    }
    func testEventTimeZonesSurviveCodecAndDoNotUseTheCurrentPhoneZone() throws {
        let base = try cache(stages: "[]")
        let raw = try XCTUnwrap(base.rawSnapshotJSON).replacingOccurrences(of: "\"is_nap\":true",
            with: "\"is_nap\":true,\"start_timezone_id\":\"America/Los_Angeles\",\"end_timezone_id\":\"America/New_York\"")
        let parsed = try ServerScoreCacheCodec.parseSnapshot(Data(raw.utf8), day: base.day, ownerId: base.ownerId)
        let stored = try JSONDecoder().decode(ServerScoreDayCache.self, from: JSONEncoder().encode(parsed))
        let episode = try XCTUnwrap(ServerSleepEpisode.episodes(stored, day: base.day).first)
        XCTAssertEqual(episode.startTimezoneId, "America/Los_Angeles")
        XCTAssertEqual(episode.endTimezoneId, "America/New_York")
        XCTAssertTrue(episode.clockLabel.contains("07:00 -07:00 (America/Los_Angeles)"))
        XCTAssertTrue(episode.clockLabel.contains("10:01 -04:00 (America/New_York)"))
        XCTAssertTrue(ServerSleepEpisode.eventClock(episode.start, timezoneId: nil).contains("UTC; event zone unavailable"))
        XCTAssertTrue(ServerSleepEpisode.eventClock(episode.start, timezoneId: "invalid-zone").contains("UTC; event zone unavailable"))
    }
    func testMissingEpochsNeverCreateTimelineAndCanonicalNapSurvives() throws {
        let value = try cache(stages: "[]")
        let episode = try XCTUnwrap(ServerSleepEpisode.episodes(value, day: value.day).first)
        XCTAssertTrue(episode.bands.isEmpty)
        XCTAssertEqual(episode.episodeType, "nap")
        XCTAssertEqual(episode.groupId, "canonical-group")
        XCTAssertEqual(episode.reason, "No server epochs available")
        XCTAssertEqual(episode.asleepMin, 0)
        XCTAssertTrue(ServerSleepEpisode.episodes(value, day: "2026-09-17").isEmpty)
    }
    func testUnavailableIsNotZeroAndAfternoonMainRemainsMain() throws {
        let value = try cache(stages: "[]", available: false, type: "main_sleep")
        let episode = try XCTUnwrap(ServerSleepEpisode.episodes(value, day: value.day).first)
        XCTAssertNil(episode.asleepMin)
        XCTAssertEqual(episode.episodeType, "main_sleep")
    }
    func testOpportunityLabelsNeverClaimUnconfirmedBedOccupancy() throws {
        for kind in [nil, "estimated_sleep_opportunity", "user_reported_sleep_opportunity", "unrecognized"] as [String?] {
            let value = try cache(stages: "[]", opportunityKind: kind)
            let episode = try XCTUnwrap(ServerSleepEpisode.episodes(value, day: value.day).first)
            XCTAssertEqual(episode.opportunityKind, kind)
            XCTAssertEqual(episode.opportunityLabel, kind == "user_reported_sleep_opportunity" ?
                "Reported sleep opportunity" : "Estimated sleep opportunity")
            XCTAssertFalse(episode.opportunityLabel.lowercased().contains("in bed"))
        }
    }
    func testEpochTimesAndMissingGapRemainUnmodified() throws {
        let start = Int(try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-18T14:00:00Z")).timeIntervalSince1970)
        let value = try cache(stages: """
        [{"start":\(start),"end":\(start + 30),"stage":"unknown","state":"sleep_unstaged"},
        {"start":\(start + 60),"end":\(start + 90),"stage":"unknown","state":"off_body"}]
        """)
        let episode = try XCTUnwrap(ServerSleepEpisode.episodes(value, day: value.day).first)
        XCTAssertEqual(episode.bands.map(\.state), ["sleep_unstaged", "off_body"])
        XCTAssertEqual(episode.bands.map(\.start), [start, start + 60])
        XCTAssertEqual(episode.bands.reduce(0) { $0 + $1.end - $1.start }, 60)
        XCTAssertEqual(episode.end - episode.start, 90)
    }

    func testLegacyDatabaseRowThroughCodecPreservesBaselineStagesAndTotals() throws {
        let start = Int(try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-18T14:00:00Z")).timeIntervalSince1970)
        let body = """
        {"server_scoring":{"schema_version":2,"user_id":"owner","day":"2026-09-18","algorithm_version":"per_feature",
        "features":{"sleep":{"status":"fresh","device_id":"device","algorithm_version":"frwhoop-server-1"}},
        "nights":[{"id":"night","device_id":"device","algorithm_version":"frwhoop-server-1","start_at":"2026-09-18T14:00:00Z",
        "end_at":"2026-09-18T14:01:30Z","is_nap":true,"asleep_min":1,"in_bed_min":1.5,
        "stages":[{"start":\(start),"end":\(start+30),"stage":"wake"},{"start":\(start+30),"end":\(start+60),"stage":"deep"},
        {"start":\(start+60),"end":\(start+90),"stage":"rem"}]}]}}
        """
        let value = try ServerScoreCacheCodec.parseSnapshot(Data(body.utf8), day: "2026-09-18", ownerId: "owner")
        let episode = try XCTUnwrap(ServerSleepEpisode.episodes(value, day: value.day).first)
        XCTAssertEqual(episode.bands.map(\.state), ["wake", "deep", "rem"])
        XCTAssertEqual(episode.asleepMin, 1)
        XCTAssertEqual(episode.episodeType, "nap")
        XCTAssertEqual(value.nights[0].stateCoverageDescription, "State coverage: unavailable")
        let v2 = try ServerScoreCacheCodec.parseSnapshot(Data(body.replacingOccurrences(of: "frwhoop-server-1", with: "frwhoop-physiology-2").utf8), day: value.day, ownerId: "owner")
        let unknown = try XCTUnwrap(ServerSleepEpisode.episodes(v2, day: v2.day).first)
        XCTAssertNil(unknown.asleepMin)
        XCTAssertEqual(unknown.bands.map(\.state), ["unknown", "unknown", "unknown"])
    }
}
