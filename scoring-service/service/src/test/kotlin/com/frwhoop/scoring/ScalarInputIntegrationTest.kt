package com.frwhoop.scoring

import com.frwhoop.scoring.db.*
import com.frwhoop.scoring.scoring.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class ScalarInputIntegrationTest:PgIntegrationBase() {
    private val ts=Instant.parse("2026-09-15T12:00:00Z").epochSecond
    private fun ppg(at:Long,bpm:Int=90,conf:String="null",d:String=device.toString())=sql("""
        insert into noop_ppg_hr_samples(user_id,device_id,source_id,ts,bpm,conf,batch_id)
        values('$u','$d',gen_random_uuid(),$at,$bpm,$conf,gen_random_uuid())
    """)
    @Test fun derivedPpgIsSourceLocalAndNeverEntersMeasuredHrOrRrHrv() {
        ppg(ts);ppg(ts+1,95,"0.8");ppg(ts+86400,200);ppg(ts+2,210,d=device2.toString())
        sql("insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id) values('$u','$device',gen_random_uuid(),$ts,60,gen_random_uuid())")
        val i=SignalSampleReader(pg.db).loadHistoricalDay(u,day,device)!!
        assertEquals(listOf(60),i.hr.map { it.bpm });assertTrue(i.rr.isEmpty())
        assertEquals(listOf(90,95),i.scalarInputs!!.ppgHr.map { it.bpm })
        assertNull(i.scalarInputs!!.ppgHr.first().confidence)
        assertEquals(listOf(95),i.scalarInputs!!.derivedWithoutMeasuredOverlap(i.hr).map { it.bpm })
        val scored=DayScorer().score(i,"frwhoop-server-2-history",HistoricalStateMachine.prepare(i,HistoryCheckpointReader.Seed(null,emptyList())))
        assertNull(scored.result.daily.avgHrv)
        assertEquals(1,scored.derived!!.details.getJSONObject("derived_ppg_hr").getInt("samplesAfterMeasuredOverlap"))
        assertEquals(95,scored.derived!!.charts.getJSONArray("derived_ppg_hr").getJSONObject(0).getInt("value"))
        assertTrue(scored.coverageGaps.contains("ppgHrSample_provenance_unknown"))
    }

    @Test fun optionalProvenanceColumnRetainsKnownMetadataAndRefusesFutureOrInvalidRows() {
        // Reader-side shape fixture only, not a claim that Rawls's future 070 validation was run.
        sql("alter table noop_ppg_hr_samples add column if not exists provenance jsonb")
        ppg(ts);ppg(ts+1);ppg(ts+2);ppg(ts+3,0)
        val valid=JSONObject().put("v",1).put("origin","whoop-v26-ppg-derived").put("algorithm","ppg-acf-v1")
            .put("sampleRateHz",64).put("windowSettingSeconds",8).put("inputStartTs",ts).put("inputEndTs",ts+1)
            .put("inputSHA256","b".repeat(64))
        val future=JSONObject(valid.toString()).put("inputEndTs",ts+86400)
        sql("""update noop_ppg_hr_samples set provenance='$valid' where ts=$ts""")
        sql("""update noop_ppg_hr_samples set provenance='$future' where ts=${ts+1}""")
        sql("""update noop_ppg_hr_samples set provenance='{"v":1,"origin":"whoop-v18","recordIndex":false}' where ts=${ts+2}""")
        val i=SignalSampleReader(pg.db).loadHistoricalDay(u,day,device)!!
        assertEquals(listOf(ts),i.scalarInputs!!.ppgHr.map { it.ts })
        assertEquals("ppg-acf-v1",i.scalarInputs!!.ppgHr.single().provenance!!.getString("algorithm"))
        assertTrue(i.scalarInputs!!.gaps.contains("ppgHrSample_provenance_invalid"))
        assertTrue(i.scalarInputs!!.gaps.contains("ppgHrSample_measurement_invalid"))
        assertEquals("4",scalar("select count(*) from noop_ppg_hr_samples"))
    }

    @Test fun counterPredecessorAndRawBandStateAreValidatedWithoutChanging050Schema() {
        val lo=Instant.parse("2026-09-15T00:00:00Z").epochSecond-30*3600
        sql("""insert into noop_step_samples(user_id,device_id,source_id,ts,counter,activity_class,batch_id)
            values('$u','$device',gen_random_uuid(),$lo-1,65535,1,gen_random_uuid()),
              ('$u','$device',gen_random_uuid(),$lo,1,1,gen_random_uuid()),
              ('$u','$device',gen_random_uuid(),$lo+1,65536,1,gen_random_uuid());
            insert into noop_sleep_state_samples(user_id,device_id,source_id,ts,state,raw_byte,batch_id)
            values('$u','$device',gen_random_uuid(),$ts,3,48,gen_random_uuid()),
              ('$u','$device',gen_random_uuid(),$ts+1,2,16,gen_random_uuid())""")
        val i=SignalSampleReader(pg.db).loadHistoricalDay(u,day,device)!!
        assertEquals(listOf(65535,1),i.steps.map { it.counter })
        assertEquals(listOf(ts to 3),i.bandSleepState)
        assertTrue(i.scalarInputs!!.gaps.containsAll(setOf("stepSample_measurement_invalid","sleepStateSample_measurement_invalid")))
        assertEquals("3",scalar("select count(*) from noop_step_samples"))
        assertEquals("2",scalar("select count(*) from noop_sleep_state_samples"))
    }

    @Test fun admittedStepProvenanceSurvivesThePlainKernelDtoWithoutTouchingRoom() {
        sql("alter table noop_step_samples add column if not exists provenance jsonb")
        sql("""insert into noop_step_samples(user_id,device_id,source_id,ts,counter,activity_class,batch_id,provenance)
            values('$u','$device',gen_random_uuid(),$ts,12,1,gen_random_uuid(),'{"v":1,"origin":"whoop-v18","recordIndex":4294967295}')""")
        val i=SignalSampleReader(pg.db).loadHistoricalDay(u,day,device)!!
        val metadata=JSONObject(i.steps.single().provenanceJSON!!)
        assertEquals(0xffff_ffffL,metadata.getLong("recordIndex"))
        assertTrue(metadata.similar(i.scalarInputs!!.provenance.getValue("stepSample").getValue(ts)))
    }
}
