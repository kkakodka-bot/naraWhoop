package com.frwhoop.scoring

import com.frwhoop.scoring.db.EngineIngestWriter
import com.frwhoop.scoring.db.SignalSampleReader
import com.frwhoop.scoring.scoring.DayScorer
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.util.UUID

class SleepEditScoringIntegrationTest : PgIntegrationBase() {
    private val entity = "sleep:40000000-0000-4000-8000-000000000001"
    private val originalStart = Instant.parse("${day}T18:00:00Z").epochSecond
    private fun edit(shift: Long = 0, dismissed: Boolean = false) = JSONObject()
        .put("schemaVersion",1).put("originalStart",originalStart).put("originalEnd",originalStart+3600)
        .put("start",originalStart+shift).put("end",originalStart+shift+3600)
        .put("isNap",true).put("dismissed",dismissed)

    private fun put(body: JSONObject, expected: Long = 0, kind: String = "sleep_edit", key: String = entity,
                    effective: String = day): Long = pg.connection().use { c ->
        c.createStatement().use { it.execute("set role authenticated"); it.execute("set request.jwt.claim.sub='$u'") }
        c.prepareStatement("select put_scoring_history_input_v3(?,?,?,?::date,?::jsonb,?,false,?,?,?)::text").use { s ->
            s.setObject(1,device); s.setString(2,kind); s.setString(3,key); s.setString(4,effective)
            s.setString(5,body.toString()); s.setLong(6,expected); s.setObject(7,UUID.randomUUID())
            s.setObject(8,UUID.randomUUID()); s.setLong(9,1)
            s.executeQuery().use { it.next(); JSONObject(it.getString(1)).getLong("revision") }
        }
    }

    private fun drain() {
        queue.maintain(128)
        var count = 0
        while (true) {
            val item = queue.claim() ?: break
            check(count++ < 32)
            val inputs = SignalSampleReader(pg.db).loadDay(item.userId,item.day,item.deviceId)!!
            assertNotNull(EngineIngestWriter(queue).write(item,DayScorer().score(inputs,item.algorithmVersion),1))
        }
    }
    private fun snapshot(date: String = day) = JSONObject(scalar("select payload::text from scoring_snapshots_v2 where day='$date' order by result_revision desc limit 1")!!)

    @Test fun unmatchedManualNapIsPublishedWithoutInventingStagesOrMeasuredPhysiology() {
        put(edit()); drain()
        val result = snapshot()
        assertEquals("partial",result.getString("status"))
        assertTrue(result.isNull("dataThrough"))
        val sleep = result.getJSONArray("sleep").getJSONObject(0)
        assertTrue(sleep.getBoolean("is_nap"))
        assertEquals(entity,sleep.getString("editEntity"))
        assertEquals(entity.removePrefix("sleep:"),sleep.getString("id"))
        assertEquals(originalStart,sleep.getLong("originalStart"))
        assertEquals(0,sleep.getJSONArray("stages").length())
        for (field in listOf("asleep_min","awake_min","light_min","deep_min","rem_min","efficiency","resting_hr_bpm","hrv_rmssd_ms"))
            assertTrue(field,sleep.isNull(field))
        assertTrue(result.getJSONObject("daily").isNull("sleep_total_min"))
        assertTrue(result.getJSONObject("coverage").getJSONArray("gaps").toList().contains("edited_sleep_raw_staging_unavailable"))
    }

    @Test fun dismissAndUndoRoundTripSameManualEntityWithNoLocalRecompute() {
        val first = put(edit()); drain()
        val id = snapshot().getJSONArray("sleep").getJSONObject(0).getString("id")
        val dismissed = put(edit(dismissed=true),first); drain()
        assertEquals(0,snapshot().getJSONArray("sleep").length())
        put(edit(),dismissed); drain()
        assertEquals(id,snapshot().getJSONArray("sleep").getJSONObject(0).getString("id"))
        assertEquals("3",scalar("select count(*) from scoring_history_inputs_v3"))
    }

    @Test fun movedWakeDayRemovesOldDayAndPreservesAnchorsOnNewDay() {
        val first = put(edit()); drain()
        put(edit(shift=8*3600),first); drain()
        assertEquals(0,snapshot().getJSONArray("sleep").length())
        val moved = snapshot("2026-09-16").getJSONArray("sleep").getJSONObject(0)
        assertEquals(entity,moved.getString("editEntity"))
        assertEquals(originalStart,moved.getLong("originalStart"))
        assertEquals(originalStart+3600,moved.getLong("originalEnd"))
        assertEquals(Instant.ofEpochSecond(originalStart+8*3600).toString(),moved.getString("start_at"))
    }

    @Test fun asOfReaderUsesProfileAndConfigRevisionsNotFutureMutableDefaults() {
        val earlier = JSONObject().put("schemaVersion",1).put("age",31).put("timezone","UTC")
        val first = put(earlier,kind="profile",key="primary",effective="2026-09-01")
        put(JSONObject().put("schemaVersion",1).put("age",70).put("timezone","Pacific/Auckland"),
            first,kind="profile",key="primary",effective="2026-10-01")
        val config = put(JSONObject().put("schemaVersion",1).put("effortMethod","EDWARDS"),kind="config",key="primary")
        put(JSONObject().put("schemaVersion",1).put("effortMethod","BANISTER"),config,kind="config",key="primary",effective="2026-10-01")
        val reader = SignalSampleReader(pg.db)
        val current = reader.loadDay(u,day,device)!!
        assertEquals(31.0,current.profile.age,0.0); assertEquals("UTC",current.timezone)
        assertEquals(first,current.history.profile!!.revision)
        assertEquals("EDWARDS",current.history.configuration.getString("effortMethod"))
        assertEquals(70.0,reader.loadDay(u,"2026-10-01",device)!!.profile.age,0.0)
        val unknown = reader.loadDay(u,"2026-08-31",device)!!
        assertNull(unknown.history.profile); assertEquals("UTC",unknown.timezone)
        assertEquals(30.0,unknown.profile.age,0.0)
    }

    @Test fun newEditFencesAlreadyClaimedWorkerBeforeRangeExpansion() {
        queue.dirtyWorkItem(u,device,day)
        val stale = queue.claim()!!
        val staleBundle = DayScorer().score(SignalSampleReader(pg.db).loadDay(u,day,device)!!,stale.algorithmVersion)
        put(edit())
        assertNull(EngineIngestWriter(queue).write(stale,staleBundle,1))
        assertEquals("0",scalar("select count(*) from scoring_snapshots_v2"))
        assertTrue(queue.markFailed(stale,"superseded"))
        drain()
        assertEquals(entity,snapshot().getJSONArray("sleep").getJSONObject(0).getString("editEntity"))
    }

    private fun hr(from:Long,to:Long) = sql("""insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id)
        select '$u','$device','$device',ts,58,'50000000-0000-4000-8000-000000000001' from generate_series($from,$to,30) ts""")

    @Test fun rawBackedManualNapIsRestagedByServerAndKeepsObservedGapEmpty() {
        hr(originalStart,originalStart+870)
        hr(originalStart+1800,originalStart+2670)
        put(edit()); drain()
        val stages=snapshot().getJSONArray("sleep").getJSONObject(0).getJSONArray("stages")
        assertTrue(stages.length()>0)
        val segments=(0 until stages.length()).map { stages.getJSONObject(it) }
        assertTrue(segments.all { it.getLong("end")<=originalStart+900 || it.getLong("start")>=originalStart+1800 })
        assertTrue(segments.all { it.getLong("end")<=originalStart+2700 })
        assertEquals(1800L,segments.sumOf { it.getLong("end")-it.getLong("start") })
        assertFalse(snapshot().getJSONObject("coverage").getJSONArray("gaps").toList().contains("edited_sleep_raw_staging_unavailable"))
    }

    @Test fun dstFallBackEditUsesRealEpochBoundsAndNoClientStages() {
        val date="2026-11-01"
        put(JSONObject().put("schemaVersion",1).put("timezone","America/New_York"),kind="profile",key="primary",effective=date)
        val start=Instant.parse("2026-11-01T05:30:00Z").epochSecond
        val end=Instant.parse("2026-11-01T07:30:00Z").epochSecond
        hr(start,end-30)
        val body=edit().put("originalStart",start).put("originalEnd",end).put("start",start).put("end",end)
        assertFalse(body.has("stages"))
        put(body,effective=date); drain()
        val input=SignalSampleReader(pg.db).loadDay(u,date,device)!!
        assertEquals(25*3600L,input.dayHi-input.dayLo+1)
        val sleep=snapshot(date).getJSONArray("sleep").getJSONObject(0)
        assertEquals(120.0,sleep.getDouble("in_bed_min"),0.0)
        val stages=sleep.getJSONArray("stages")
        assertEquals(7200L,(0 until stages.length()).sumOf { stages.getJSONObject(it).let { s -> s.getLong("end")-s.getLong("start") } })
        assertEquals(start,sleep.getLong("originalStart")); assertEquals(entity,sleep.getString("editEntity"))
    }

    @Test fun boundaryCorrectionRestagesFreshRawButNeverChangesOriginalIdentity() {
        hr(originalStart,originalStart+7170)
        val first=put(edit()); drain()
        val before=snapshot().getJSONArray("sleep").getJSONObject(0)
        put(edit(shift=3600),first); drain()
        val after=snapshot().getJSONArray("sleep").getJSONObject(0)
        assertEquals(before.getString("id"),after.getString("id"))
        assertEquals(originalStart,after.getLong("originalStart"))
        val segments=after.getJSONArray("stages")
        assertTrue(segments.length()>0)
        assertTrue((0 until segments.length()).all { segments.getJSONObject(it).getLong("start")>=originalStart+3600 })
    }
}
