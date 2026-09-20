import XCTest
@testable import WhoopStore

final class ServerSleepOverrideTests: XCTestCase {
    let owner = "11111111-1111-1111-1111-111111111111"
    let device = "22222222-2222-2222-2222-222222222222"
    let editId = "33333333-3333-3333-3333-333333333333"
    func snapshot(existing: Bool = true, capability: Bool = true, tombstone: Bool = false) throws -> ServerScoreDayCache {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "server_physiology_snapshot", withExtension: "json"))
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var overlay = root["server_scoring"] as! [String: Any]
        var features = overlay["features"] as! [String: [String: Any]]
        features["sleep"]?["supports_boundary_overrides"] = capability
        overlay["features"] = features
        overlay["sleep_overrides"] = existing ? [["id": editId, "device_id": device, "original_start": 1789570200,
            "original_end": 1789571100, "start": 1789570800, "end": 1789570890, "tombstone": tombstone, "revision": 4]] : []
        root["server_scoring"] = overlay
        return try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: root), day: "2026-09-16", ownerId: owner)
    }
    func testCorrectionPreservesOriginalIdentityBoundsAndOptimisticRevision() throws {
        let target = try ServerSleepEditTarget.prepare(cache: snapshot(), nightId: "episode-1")
        XCTAssertEqual(target.id, editId); XCTAssertEqual(target.expectedRevision, 4)
        XCTAssertEqual(target.originalStart, 1789570200); XCTAssertEqual(target.originalEnd, 1789571100)
        let args = try target.rpcArguments(start: target.start + 30, end: target.end + 30, tombstone: false)
        XCTAssertEqual(args["p_id"] as? String, editId)
        XCTAssertEqual(args["p_expected_revision"] as? Int64, 4)
        XCTAssertEqual(args["p_original_start"] as? String, "2026-09-16T14:50:00Z")
        XCTAssertEqual(args["p_start"] as? String, "2026-09-16T15:00:30Z")
        XCTAssertNil(args["p_user"], "The authenticated server derives owner identity from the JWT")
    }
    func testFirstOverrideUsesStableDraftIdAndTombstoneRestoreKeepsRevision() throws {
        let fresh = try ServerSleepEditTarget.prepare(cache: snapshot(existing: false), nightId: "episode-1", newId: editId)
        XCTAssertEqual(fresh.id, editId); XCTAssertEqual(fresh.expectedRevision, 0)
        XCTAssertEqual(try fresh.rpcArguments(start: fresh.start, end: fresh.end, tombstone: true)["p_tombstone"] as? Bool, true)
        let cache = try snapshot(tombstone: true)
        let restore = try ServerSleepEditTarget.prepare(cache: cache, existing: XCTUnwrap(cache.sleepOverrides.first))
        XCTAssertEqual(restore.id, editId); XCTAssertEqual(restore.expectedRevision, 4)
        XCTAssertEqual(try restore.rpcArguments(start: restore.start, end: restore.end, tombstone: false)["p_tombstone"] as? Bool, false)
    }
    func testUnsupportedSelectedModelAndInvalidBoundsAreRejected() throws {
        XCTAssertThrowsError(try ServerSleepEditTarget.prepare(cache: snapshot(capability: false), nightId: "episode-1"))
        let target = try ServerSleepEditTarget.prepare(cache: snapshot(), nightId: "episode-1")
        XCTAssertThrowsError(try target.rpcArguments(start: target.end, end: target.start, tombstone: false))
        XCTAssertThrowsError(try target.rpcArguments(start: target.start, end: target.start + 48 * 3600 + 1, tombstone: false))
        var cache = try snapshot(); cache.features["sleep"] = nil
        XCTAssertThrowsError(try ServerSleepEditTarget.prepare(cache: cache, nightId: "episode-1"))
    }
    func testOwnerScopedCacheRoundTripRetainsImmediateOverrideRevision() async throws {
        let store = try await WhoopStore.inMemory(); let cacheStore = ServerScoreCacheStore(db: store.registryWriter)
        let cache = try snapshot(); try cacheStore.upsert(cache)
        let loaded = try XCTUnwrap(cacheStore.load(ownerId: owner, day: cache.day))
        XCTAssertEqual(loaded.sleepOverrides, cache.sleepOverrides)
        XCTAssertEqual(loaded.features["sleep"]?.supportsBoundaryOverrides, true)
        XCTAssertEqual(try ServerSleepEditTarget.prepare(cache: loaded, nightId: "episode-1").expectedRevision, 4)
    }

    func legacySnapshot(token: String? = String(repeating: "a", count: 64), revision: Int = 0) throws -> ServerScoreDayCache {
        let cache = try snapshot()
        var root = try JSONSerialization.jsonObject(with: Data(cache.rawSnapshotJSON!.utf8)) as! [String: Any]
        var overlay = root["server_scoring"] as! [String: Any]
        var rows = overlay["sleep_overrides"] as! [[String: Any]]
        rows[0]["revision"] = revision
        rows[0]["source"] = revision == 0 ? "legacy_user_boundary" : "physiology_override"
        rows[0]["legacy_revision"] = token
        rows[0]["original_start_at"] = "2026-09-16T14:50:00.123456Z"
        rows[0]["original_end_at"] = "2026-09-16T15:05:00.654321Z"
        overlay["sleep_overrides"] = rows
        var nights = overlay["nights"] as! [[String: Any]]
        nights[0]["boundary_provenance"] = "user_boundary:legacy_user_boundary:\(editId)"
        overlay["nights"] = nights; root["server_scoring"] = overlay
        return try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: root), day: cache.day, ownerId: owner)
    }
    func testLegacyContinuationCarriesSourceTokenAndExactOriginalBounds() async throws {
        let cache = try legacySnapshot()
        let store = try await WhoopStore.inMemory(); let cacheStore = ServerScoreCacheStore(db: store.registryWriter)
        try cacheStore.upsert(cache)
        let loaded = try XCTUnwrap(cacheStore.load(ownerId: owner, day: cache.day))
        let target = try ServerSleepEditTarget.prepare(cache: loaded, nightId: "episode-1")
        XCTAssertEqual(target.rpcName, "continue_legacy_physiology_sleep_override")
        XCTAssertEqual(target.id, editId); XCTAssertEqual(target.expectedRevision, 0)
        let args = try target.rpcArguments(start: target.start, end: target.end, tombstone: true)
        XCTAssertEqual(args["p_legacy_revision"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual(args["p_original_start"] as? String, "2026-09-16T14:50:00.123456Z")
        XCTAssertEqual(args["p_original_end"] as? String, "2026-09-16T15:05:00.654321Z")
        let converted = try ServerSleepEditTarget.prepare(cache: legacySnapshot(token: nil, revision: 1), nightId: "episode-1")
        XCTAssertEqual(converted.rpcName, "set_physiology_sleep_override")
        XCTAssertEqual(try converted.rpcArguments(start: converted.start, end: converted.end, tombstone: false)["p_original_start"] as? String,
                       "2026-09-16T14:50:00.123456Z")
    }
    func testLegacyWithoutValidSourceTokenCannotBecomeANewUnfencedOverride() throws {
        for token in [nil, "", "unreviewed", String(repeating: "g", count: 64)] as [String?] {
            let cache = try legacySnapshot(token: token)
            XCTAssertTrue(cache.sleepOverrides.isEmpty)
            XCTAssertThrowsError(try ServerSleepEditTarget.prepare(cache: cache, nightId: "episode-1"))
        }
    }
    func testAuthoritativeProvenanceCannotSelectAnotherRowWithTheSameBounds() throws {
        let cache = try legacySnapshot()
        var root = try JSONSerialization.jsonObject(with: Data(cache.rawSnapshotJSON!.utf8)) as! [String: Any]
        var overlay = root["server_scoring"] as! [String: Any]
        let actual = (overlay["sleep_overrides"] as! [[String: Any]])[0]
        var decoy = actual; decoy["id"] = "44444444-4444-4444-4444-444444444444"
        overlay["sleep_overrides"] = [decoy, actual]; root["server_scoring"] = overlay
        let duplicateBounds = try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: root), day: cache.day, ownerId: owner)
        XCTAssertEqual(try ServerSleepEditTarget.prepare(cache: duplicateBounds, nightId: "episode-1").id, editId)
        overlay["sleep_overrides"] = [decoy]; root["server_scoring"] = overlay
        let missingIdentity = try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: root), day: cache.day, ownerId: owner)
        XCTAssertThrowsError(try ServerSleepEditTarget.prepare(cache: missingIdentity, nightId: "episode-1"))
    }
}
