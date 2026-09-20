package com.frwhoop.scoring

import com.frwhoop.scoring.db.*
import com.frwhoop.scoring.scoring.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.time.Instant
import java.util.UUID

/** Decoder fixture from the actual input RPC -> scorer -> fenced SQL publication, all synthetic. */
class HistoricalSnapshotFixtureIntegrationTest:PgIntegrationBase() {
    private fun put(kind:String,entity:String,body:JSONObject) = pg.connection().use { c ->
        c.createStatement().use { it.execute("set role authenticated");it.execute("set request.jwt.claim.sub='$u'") }
        c.prepareStatement("select put_scoring_history_input_v3(?,?,?,?::date,?::jsonb,0,false,?,?,1)").use { s ->
            s.setObject(1,device);s.setString(2,kind);s.setString(3,entity);s.setString(4,day);s.setString(5,body.toString())
            s.setObject(6,UUID.randomUUID());s.setObject(7,UUID.randomUUID());s.execute()
        }
    }
    @Test fun immutableOutputFixtureHasRealLeaseCheckpointAndServerRestagedSleep() {
        val start=Instant.parse("${day}T00:00:00Z").epochSecond
        sql("""insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id)
            select '$u','$device',gen_random_uuid(),$start+n,58,gen_random_uuid() from generate_series(0,25170,30) n""")
        put("profile","primary",JSONObject().put("schemaVersion",1).put("age",40).put("sex","female")
            .put("weightKg",65).put("heightCm",170).put("timezone","UTC"))
        put("config","primary",JSONObject().put("schemaVersion",1).put("dayCycleMode","sleep_onset")
            .put("customHRZoneLowerBounds",org.json.JSONArray(listOf(90,110,130,150,170))).put("stepsManualCoefficient",42.5))
        put("sleep_edit","sleep:40000000-0000-4000-8000-000000000001",JSONObject().put("schemaVersion",1)
            .put("originalStart",start).put("originalEnd",start+7*3600).put("start",start).put("end",start+7*3600)
            .put("isNap",false).put("dismissed",false))
        val q=ScoringWorkQueue(pg.db,"frwhoop-server-2-history")
        q.maintain(1000);q.dirtyWorkItem(u,device,day);q.maintain(1000)
        var count=0
        while(true) {
            val item=q.claim() ?: break
            check(++count<32)
            val i=SignalSampleReader(pg.db).loadHistoricalDay(u,item.day,device)!!
            val p=HistoricalStateMachine.prepare(i,HistoryCheckpointReader(pg.db).load(item))
            assertNotNull(EngineIngestWriter(q).write(item,DayScorer().score(i,q.algorithmVersion,p),1))
        }
        val payload=JSONObject(scalar("select payload::text from scoring_snapshots_v2 where day='$day' and algorithm_version='${q.algorithmVersion}' order by result_revision desc limit 1")!!)
        assertEquals(2,payload.getInt("schemaVersion"));assertEquals(device.toString(),payload.getString("sourceDeviceId"))
        assertTrue(payload.getLong("resultRevision")>0)
        assertEquals("sleep_onset",payload.getJSONObject("details").getJSONObject("day_cycle").getString("mode"))
        val sleep=payload.getJSONArray("sleep").getJSONObject(0)
        assertEquals(start,sleep.getLong("originalStart"));assertTrue(sleep.getJSONArray("stages").length()>0)
        assertTrue(payload.getJSONObject("charts").has("sleep_hr:${sleep.getString("id")}"))
        val bytes=payload.toString(2).toByteArray(Charsets.UTF_8)
        assertTrue(bytes.size<512*1024)
        // Explicit evidence destination only; normal test runs do not write outside build artifacts.
        System.getenv("W3_TEST_ARTIFACTS")?.let { directory ->
            Files.write(Files.createDirectories(Path.of(directory)).resolve("W4-SNAPSHOT-V2-NATIVE-FIXTURE.json"),bytes)
        }
    }
}
