package com.noop.push

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ServerScoreClientTest {
    private val owner = "11111111-1111-1111-1111-111111111111"
    private val day = "2026-09-16"
    private fun snapshot(device: String? = null): ServerScoreDayCache {
        var body = javaClass.getResource("/server_physiology_snapshot.json")!!.readText()
        if (device != null) body = body.replace("22222222-2222-2222-2222-222222222222", device)
        return ServerScoreClient.parseSnapshot(body, day, owner, 1000)
    }

    @Test fun roundTripPreservesEpochMetadataAndHistoricalAvailability() {
        val prefs = SelfHostedPushSettingsTest.FakePushPrefs()
        val store = ServerScoreCacheStore(prefs)
        val cache = snapshot()
        store.upsert(cache)
        val loaded = store.load(owner, day)!!
        assertEquals(cache, loaded)
        assertEquals(0.0, loaded.daily!!.hrvRmssdMs!!, 0.0)
        assertEquals(listOf("state_unknown", "sleep_unstaged", "off_body"), loaded.nights[0].stages.map { it.state })
        assertEquals(0.9, loaded.nights[0].stages[1].sleepProbability!!, 0.0)
        assertNull(loaded.nights[0].stages[1].pLight)
        assertEquals(301L, loaded.features["sleep"]!!.inputRevision)
        assertEquals("fixture-manifest", loaded.features["sleep"]!!.manifestHash)
        assertEquals("manual_boundary", loaded.nights[0].boundaryProvenance)
        assertFalse(loaded.stale)
        assertTrue(loaded.measurementsJSON!!.contains("preserve-me"))
    }

    @Test fun ownerDeviceVersionScopesAndLegacyRowsAreIsolated() {
        val prefs = SelfHostedPushSettingsTest.FakePushPrefs()
        val store = ServerScoreCacheStore(prefs)
        val first = snapshot()
        val second = snapshot("33333333-3333-3333-3333-333333333333")
        store.upsert(first); store.upsert(second)
        assertNotEquals(first.scopeKey, second.scopeKey)
        assertEquals(first, store.load(owner, day, first.scopeKey))
        assertEquals(second, store.load(owner, day, second.scopeKey))
        assertNull(store.load("another-owner", day))
        prefs.edit().putString(day, first.rawSnapshotJSON).apply()
        assertNull(ServerScoreCacheStore(SelfHostedPushSettingsTest.FakePushPrefs().apply {
            edit().putString(day, first.rawSnapshotJSON).apply()
        }).load(owner, day))
    }

    @Test fun strictOwnerDayAndSchemaReadback() {
        val body = snapshot().rawSnapshotJSON!!
        assertTrue(runCatching { ServerScoreClient.parseSnapshot(body, day, "another-owner") }.isFailure)
        assertTrue(runCatching { ServerScoreClient.parseSnapshot(body, "2026-09-17", owner) }.isFailure)
        assertTrue(runCatching { ServerScoreClient.parseSnapshot("""{"server_scoring":{"algorithm_version":"frwhoop-server-1","daily":{}}}""", day, owner) }.isFailure)
    }

    @Test fun delayedResponseCannotCrossSignOutOrAccountSwitch() {
        val cache = snapshot()
        val state = ServerScoreSessionState()
        state.activate(owner)
        val pending = state.generation()
        assertTrue(state.accept(cache, pending, owner))
        state.activate(null)
        assertNull(state.overlay(day, null))
        assertFalse(state.accept(cache, pending, owner))
        val other = "44444444-4444-4444-4444-444444444444"
        state.activate(other)
        assertNull(state.overlay(day, other))
        assertFalse(state.accept(cache, pending, other))
        state.activate(owner)
        assertFalse(state.accept(cache, pending, owner))
        assertTrue(state.accept(cache, state.generation(), owner))
        assertNull(state.overlay(day, other))
    }

    @Test fun allUnknownRemainsUnavailable() {
        val root = JSONObject(snapshot().rawSnapshotJSON!!)
        root.getJSONObject("server_scoring").put("daily", JSONObject()
            .put("sleep_total_min", JSONObject.NULL).put("state_unknown_min", 1.5))
        val parsed = ServerScoreClient.parseSnapshot(root.toString(), day, owner)
        assertNull(parsed.daily?.sleepTotalMin)
        assertEquals(1.5, parsed.daily!!.stateUnknownMin!!, 0.0)
    }

    @Test fun laterRequestAndHigherRevisionWin() {
        val cache = snapshot(); val state = ServerScoreSessionState(); state.activate(owner)
        val oldRequest = state.beginRequest(day); val newRequest = state.beginRequest(day)
        assertTrue(state.accept(cache, state.generation(), owner, newRequest))
        assertFalse(state.isCurrentRequest(day, state.generation(), owner, oldRequest))
        assertTrue(state.isCurrentRequest(day, state.generation(), owner, newRequest))
        // Both unauthorized handling and disk fallback use the same request fence.
        assertFalse(state.accept(cache, state.generation(), owner, oldRequest))
        val older = ServerScoreClient.parseSnapshot(cache.rawSnapshotJSON!!.replace("301", "300"), day, owner)
        assertFalse(state.accept(older, state.generation(), owner))
    }
}
