package com.frwhoop.scoring

import com.frwhoop.scoring.db.SignalSampleReader
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class HistoricalThermalInputIntegrationTest : PgIntegrationBase() {
    @Test fun windowMedianUsesOnlySameDeviceAtOrBeforeDayAndPastCorrectionIsVisible() {
        val start=Instant.parse("2026-09-15T00:00:00Z").epochSecond
        sql("update devices set device_family='whoop4' where id='$device'")
        fun insert(ts:Long,raw:Int,source:String=device.toString())=sql("""
            insert into noop_skin_temp_samples(user_id,device_id,source_id,ts,raw,batch_id)
            select '$u','$source',gen_random_uuid(),$ts+n,$raw,gen_random_uuid() from generate_series(0,299) n
        """.trimIndent())
        insert(start,1100);insert(start,1800,device2.toString())
        val reader=SignalSampleReader(pg.db)
        assertEquals(1100.0,reader.loadHistoricalDay(u,day,device)!!.skinTempAnchorRaw!!,0.0)
        insert(start+86400,1500)
        assertEquals(1100.0,reader.loadHistoricalDay(u,day,device)!!.skinTempAnchorRaw!!,0.0)
        assertEquals(1300.0,reader.loadHistoricalDay(u,"2026-09-16",device)!!.skinTempAnchorRaw!!,0.0)
        sql("update noop_skin_temp_samples set raw=1200 where user_id='$u' and device_id='$device' and ts<$start+86400")
        assertEquals(1200.0,reader.loadHistoricalDay(u,day,device)!!.skinTempAnchorRaw!!,0.0)
    }

    @Test fun canonicalDeviceRetainsOriginalOuraProvenanceForRespirationShape() {
        sql("update devices set external_device_id='oura-fixture-ring' where id='$device'")
        val input=SignalSampleReader(pg.db).loadHistoricalDay(u,day,device)!!
        assertTrue(input.isOura)
        assertEquals(device.toString(),input.deviceId)
        val rows=listOf(com.noop.data.RespSample(input.deviceId,input.dayLo,14375))
        assertTrue(input.copy(resp=rows).scoringResp.isEmpty())
        assertEquals(rows,input.copy(resp=rows).vendorResp)
    }
}
