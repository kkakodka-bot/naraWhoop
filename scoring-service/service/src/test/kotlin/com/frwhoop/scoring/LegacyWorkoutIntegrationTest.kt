package com.frwhoop.scoring

import com.frwhoop.scoring.db.*
import com.frwhoop.scoring.scoring.*
import com.noop.analytics.*
import com.noop.data.DailyMetric
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.util.UUID

class LegacyWorkoutIntegrationTest:PgIntegrationBase() {
    private val start=Instant.parse("2026-09-15T12:00:00Z").epochSecond
    private fun insert(id:UUID=UUID.randomUUID(),d:UUID=device,t:Long=start,version:String="0.1.0",owner:UUID=u):UUID {
        sql("""insert into sessions(id,user_id,device_id,kind,source,start_at,end_at,algorithm_version,summary)
            values('$id','$owner','$d','workout','apple_health',to_timestamp($t),to_timestamp($t+3600),'$version',
            '{"sport":"running","calories_kcal":321,"distance_m":5000,"steps":6000,"avg_hr":240,"strain":99,"notes":"PRIVATE_FIXTURE","route_polyline":"PRIVATE_ROUTE"}')""")
        return id
    }
    @Test fun sourceLocalAsOfBoundsExcludeFutureOtherOwnerAndServerFeedback() {
        val id=insert();insert(d=device2);insert(t=start+86400);insert(version="frwhoop-server-1")
        val foreign=UUID.randomUUID()
        sql("insert into devices(id,user_id,source_kind) values('$foreign','$other','noop_push')")
        insert(d=foreign,owner=other)
        val input=SignalSampleReader(pg.db).loadHistoricalDay(u,day,device)!!
        assertEquals(listOf(id.toString()),input.legacyWorkouts.map { it.id })
        val result=DayResult(DailyMetric(device.toString(),day),emptyList(),emptyList(),null,null)
        val out=WorkoutResultOrchestrator.evaluate(input,result)
        assertEquals(1,out.count)
        val w=out.sessions.getJSONObject(0)
        assertEquals("legacy_uploaded_workout",w.getString("inputKind"))
        assertEquals("imported:apple_health",w.getString("energyMethod"))
        assertEquals(321,w.getInt("energyKcal"))
        assertTrue(w.isNull("avgHr"));assertTrue(w.isNull("strain"));assertTrue(w.isNull("heartRateRecovery"))
        assertFalse(w.toString().contains("PRIVATE"))
        assertTrue(out.gaps.contains("uploaded_workout_raw_physiology_unavailable"))
    }

    @Test fun realRawPhysiologyReplacesUploadedScoresAndJournalDismissalReplacesNaturalKey() {
        val id=insert()
        sql("""insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id)
            select '$u','$device',gen_random_uuid(),$start+n,100,gen_random_uuid() from generate_series(0,3540,60) n""")
        val input=SignalSampleReader(pg.db).loadHistoricalDay(u,day,device)!!
        val result=DayResult(DailyMetric(device.toString(),day,restingHr=60),emptyList(),emptyList(),null,null)
        val out=WorkoutResultOrchestrator.evaluate(input,result).sessions.getJSONObject(0)
        assertEquals(100.0,out.getDouble("avgHr"),0.0)
        assertNotEquals(99.0,out.getDouble("strain"),0.0)
        val dismiss=HistoryInputReader.Input("manual_workout","workout:$id",7,false,JSONObject()
            .put("originalStart",start).put("originalSport","running").put("start",start).put("end",start+3600)
            .put("sport","running").put("dismissed",true))
        val edited=input.copy(history=HistoryInputReader.Day(listOf(dismiss)))
        assertEquals(0,WorkoutResultOrchestrator.evaluate(edited,result).sessions.length())
        val tombstone=edited.copy(history=HistoryInputReader.Day(listOf(dismiss.copy(deleted=true,payload=JSONObject()))))
        assertEquals(1,WorkoutResultOrchestrator.evaluate(tombstone,result).sessions.length())
    }
    @Test fun pastUploadedWorkoutCorrectionFencesClaimedHistoryFromSecondConnection() {
        val id=insert()
        val q=ScoringWorkQueue(pg.db,"frwhoop-server-2-history")
        q.maintain(1000)
        q.dirtyWorkItem(u,device,day);q.maintain(1000)
        val item=q.claim()!!
        val input=SignalSampleReader(pg.db).loadHistoricalDay(u,item.day,device)!!
        val scored=DayScorer().score(input,q.algorithmVersion,HistoricalStateMachine.prepare(input,HistoryCheckpointReader(pg.db).load(item)))
        pg.connection().use { c -> c.createStatement().use { it.execute("update sessions set end_at=end_at+interval '60 seconds' where id='$id'") } }
        assertNull(EngineIngestWriter(q).write(item,scored,1))
        assertEquals("0",scalar("select count(*) from scoring_history_checkpoints_v3"))
    }
}
