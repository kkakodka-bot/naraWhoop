package com.noop.push

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ServerSleepOverrideTest {
    private val owner="11111111-1111-1111-1111-111111111111"
    private val device="22222222-2222-2222-2222-222222222222"
    private val editId="33333333-3333-3333-3333-333333333333"
    private fun snapshot(existing: Boolean=true,capability: Boolean=true,tombstone: Boolean=false): ServerScoreDayCache {
        val root=JSONObject(javaClass.getResource("/server_physiology_snapshot.json")!!.readText())
        val overlay=root.getJSONObject("server_scoring")
        overlay.getJSONObject("features").getJSONObject("sleep").put("supports_boundary_overrides",capability)
        overlay.put("sleep_overrides",JSONArray().apply { if(existing) put(JSONObject().put("id",editId).put("device_id",device)
            .put("original_start",1789570200L).put("original_end",1789571100L).put("start",1789570800L).put("end",1789570890L)
            .put("tombstone",tombstone).put("revision",4)) })
        return ServerScoreClient.parseSnapshot(root.toString(),"2026-09-16",owner)
    }
    @Test fun correctionPreservesOriginalIdentityBoundsAndOptimisticRevision() {
        val target=ServerSleepEditTarget.prepare(snapshot(),"episode-1")
        assertEquals(editId,target.id); assertEquals(4L,target.expectedRevision)
        assertEquals(1789570200L,target.originalStart); assertEquals(1789571100L,target.originalEnd)
        val args=target.rpcArguments(target.start+30,target.end+30,false)
        assertEquals(editId,args.getString("p_id")); assertEquals(4L,args.getLong("p_expected_revision"))
        assertEquals("2026-09-16T14:50:00Z",args.getString("p_original_start"))
        assertEquals("2026-09-16T15:00:30Z",args.getString("p_start"))
        assertFalse(args.has("p_user"))
    }
    @Test fun firstOverrideUsesStableDraftIdAndTombstoneRestoreKeepsRevision() {
        val fresh=ServerSleepEditTarget.prepare(snapshot(existing=false),"episode-1",editId)
        assertEquals(editId,fresh.id); assertEquals(0L,fresh.expectedRevision)
        assertTrue(fresh.rpcArguments(fresh.start,fresh.end,true).getBoolean("p_tombstone"))
        val cache=snapshot(tombstone=true); val restore=ServerSleepEditTarget.prepare(cache,cache.sleepOverrides.single())
        assertEquals(editId,restore.id); assertEquals(4L,restore.expectedRevision)
        assertFalse(restore.rpcArguments(restore.start,restore.end,false).getBoolean("p_tombstone"))
    }
    @Test fun unsupportedSelectedModelAndInvalidBoundsAreRejected() {
        assertThrows(IllegalArgumentException::class.java) { ServerSleepEditTarget.prepare(snapshot(capability=false),"episode-1") }
        val target=ServerSleepEditTarget.prepare(snapshot(),"episode-1")
        assertThrows(IllegalArgumentException::class.java) { target.rpcArguments(target.end,target.start,false) }
        assertThrows(IllegalArgumentException::class.java) { target.rpcArguments(target.start,target.start+48*3600+1,false) }
        assertThrows(IllegalArgumentException::class.java) { ServerSleepEditTarget.prepare(snapshot().copy(features=emptyMap()),"episode-1") }
    }
    @Test fun ownerScopedCacheRetainsImmediateOverrideRevision() {
        val cache=snapshot(); val store=ServerScoreCacheStore(SelfHostedPushSettingsTest.FakePushPrefs())
        store.upsert(cache); val loaded=store.load(owner,cache.day)!!
        assertEquals(cache.sleepOverrides,loaded.sleepOverrides)
        assertEquals(true,loaded.features["sleep"]?.supportsBoundaryOverrides)
        assertEquals(4L,ServerSleepEditTarget.prepare(loaded,"episode-1").expectedRevision)
    }
    private fun legacySnapshot(token: String?="a".repeat(64),revision: Long=0): ServerScoreDayCache {
        val cache=snapshot(); val root=JSONObject(cache.rawSnapshotJSON!!); val overlay=root.getJSONObject("server_scoring")
        overlay.getJSONArray("sleep_overrides").getJSONObject(0).put("revision",revision)
            .put("source",if(revision==0L) "legacy_user_boundary" else "physiology_override")
            .put("legacy_revision",token).put("original_start_at","2026-09-16T14:50:00.123456Z")
            .put("original_end_at","2026-09-16T15:05:00.654321Z")
        overlay.getJSONArray("nights").getJSONObject(0).put("boundary_provenance","user_boundary:legacy_user_boundary:$editId")
        return ServerScoreClient.parseSnapshot(root.toString(),cache.day,owner)
    }
    @Test fun legacyContinuationCarriesSourceTokenAndExactOriginalBounds() {
        val cache=legacySnapshot(); val store=ServerScoreCacheStore(SelfHostedPushSettingsTest.FakePushPrefs())
        store.upsert(cache); val target=ServerSleepEditTarget.prepare(store.load(owner,cache.day)!!,"episode-1")
        assertEquals("continue_legacy_physiology_sleep_override",target.rpcName)
        assertEquals(editId,target.id); assertEquals(0L,target.expectedRevision)
        val args=target.rpcArguments(target.start,target.end,true)
        assertEquals("a".repeat(64),args.getString("p_legacy_revision"))
        assertEquals("2026-09-16T14:50:00.123456Z",args.getString("p_original_start"))
        assertEquals("2026-09-16T15:05:00.654321Z",args.getString("p_original_end"))
        val converted=ServerSleepEditTarget.prepare(legacySnapshot(token=null,revision=1),"episode-1")
        assertEquals("set_physiology_sleep_override",converted.rpcName)
        assertEquals("2026-09-16T14:50:00.123456Z",converted.rpcArguments(converted.start,converted.end,false).getString("p_original_start"))
    }
    @Test fun legacyWithoutValidSourceTokenCannotBecomeANewUnfencedOverride() {
        for(token in listOf(null,"","unreviewed","g".repeat(64))) {
            val cache=legacySnapshot(token)
            assertTrue(cache.sleepOverrides.isEmpty())
            assertThrows(IllegalArgumentException::class.java) { ServerSleepEditTarget.prepare(cache,"episode-1") }
        }
    }
    @Test fun authoritativeProvenanceCannotSelectAnotherRowWithTheSameBounds() {
        val cache=legacySnapshot(); val root=JSONObject(cache.rawSnapshotJSON!!); val overlay=root.getJSONObject("server_scoring")
        val actual=overlay.getJSONArray("sleep_overrides").getJSONObject(0)
        val decoy=JSONObject(actual.toString()).put("id","44444444-4444-4444-4444-444444444444")
        overlay.put("sleep_overrides",JSONArray().put(decoy).put(actual))
        val duplicateBounds=ServerScoreClient.parseSnapshot(root.toString(),cache.day,owner)
        assertEquals(editId,ServerSleepEditTarget.prepare(duplicateBounds,"episode-1").id)
        overlay.put("sleep_overrides",JSONArray().put(decoy))
        val missingIdentity=ServerScoreClient.parseSnapshot(root.toString(),cache.day,owner)
        assertThrows(IllegalArgumentException::class.java) { ServerSleepEditTarget.prepare(missingIdentity,"episode-1") }
    }
}
