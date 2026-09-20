package com.frwhoop.scoring

import com.frwhoop.scoring.db.*
import com.frwhoop.scoring.scoring.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.sql.SQLException
import java.util.UUID

class VendorImportIntegrationTest:PgIntegrationBase() {
    private val units=linkedMapOf("miband_max_hr_bpm" to "bpm","miband_vitality_points" to "vendor_points",
        "miband_sleep_deep_min" to "min","miband_sleep_rem_min" to "min","miband_sleep_light_min" to "min",
        "miband_sleep_awake_min" to "min","miband_intensity_min" to "min",
        "miband_sleep_score_0_100" to "vendor_score_0_100","miband_stress_score_0_100" to "vendor_score_0_100")
    private fun body()=JSONObject().put("schemaVersion",1).put("day",day).put("timezone","UTC")
        .put("consent",JSONObject().put("purpose","imported_metrics").put("policyVersion",1).put("decisionId",UUID.randomUUID()))
        .put("source",JSONObject().put("kind","miband_import").put("externalDeviceId","xiaomi-band:fixture").put("method","mi_fitness_export_daily"))
        .put("values",JSONObject(units.mapValues { (_,unit) -> JSONObject().put("value",50).put("unit",unit) }))
    private fun put(payload:JSONObject,expected:Long=0,deleted:Boolean=false,owner:UUID=u)=pg.connection().use { c ->
        c.createStatement().use { it.execute("set role authenticated");it.execute("set request.jwt.claim.sub='$owner'") }
        c.prepareStatement("select put_scoring_history_input_v3(?,?,?,?::date,?::jsonb,?,?,?,?,?)::text").use { s ->
            s.setObject(1,device);s.setString(2,"imported_daily");s.setString(3,"import:miband:$day");s.setString(4,day)
            s.setString(5,payload.toString());s.setLong(6,expected);s.setBoolean(7,deleted)
            s.setObject(8,UUID.randomUUID());s.setObject(9,UUID.randomUUID());s.setLong(10,1)
            s.executeQuery().use { it.next();JSONObject(it.getString(1)).getLong("revision") }
        }
    }
    private fun score():ServerScoreBundle {
        val i=SignalSampleReader(pg.db).loadHistoricalDay(u,day,device)!!
        return DayScorer().score(i,"frwhoop-server-2-history",HistoricalStateMachine.prepare(i,HistoryCheckpointReader.Seed(null,emptyList())))
    }
    @Test fun strictVendorSourceUnitsRangesUnknownsAndExistingConsentAreRequired() {
        fun reject(p:JSONObject)=assertEquals("22023",assertThrows(SQLException::class.java) { put(p) }.sqlState)
        reject(body().apply { remove("consent") })
        reject(body().apply { getJSONObject("consent").put("purpose","journal_context") })
        assertThrows(SQLException::class.java) { put(body(),owner=other) }
        for((key,unit) in units) {
            fun one(value:Any,u:String=unit)=body().put("values",JSONObject().put(key,JSONObject().put("value",value).put("unit",u)))
            for(value in listOf<Any>(true,"50",-1)) reject(one(value))
            reject(one(50,"wrong_unit"))
            reject(one(50).apply { getJSONObject("source").put("kind","oura_import") })
            if(unit=="min") reject(one(1441)) else {
                reject(one(0));reject(one(1.5))
                reject(one(if(unit=="vendor_score_0_100") 101 else 1000001))
            }
        }
        val valid=body().apply { getJSONObject("values").getJSONObject("miband_vitality_points").put("value",250) }
        val first=put(valid)
        val unknown=body().put("values",JSONObject(units.mapValues { (_,unit) -> JSONObject().put("value",JSONObject.NULL).put("unit",unit) }))
        put(unknown,first)
        assertEquals("2",scalar("select count(*) from scoring_history_inputs_v3"))
        assertFalse(score().derived!!.metrics.keySet().any { it.startsWith("imported_miband_") })
    }

    @Test fun allNineVendorValuesPublishSeparatelyWithoutStressRestVitalityOrStageFabrication() {
        val revision=put(body())
        val scored=score();val d=scored.derived!!
        for((key,unit) in units) {
            val out="imported_$key";val reading=d.metrics.getJSONObject(out)
            assertEquals(50.0,reading.getDouble("value"),0.0)
            assertEquals(unit,reading.getString("unit"));assertTrue(d.capabilities.contains(out))
            val provenance=d.details.getJSONObject("imported_provenance").getJSONObject(out)
            assertEquals(revision,provenance.getLong("inputRevision"))
            assertEquals("miband_import",provenance.getJSONObject("source").getString("kind"))
        }
        for(key in listOf("stress","sleep_performance","vitality","body_age","sleep_deep_min","max_hr"))
            assertTrue(key,d.metrics.getJSONObject(key).isNull("value"))
        assertTrue(scored.result.sleepSessions.isEmpty())
        assertTrue(scored.hasNonRawObservations)
        assertTrue(scored.historyCommit!!.state.getJSONObject("observation").getJSONObject("baselineObservations").isNull("hrv"))
    }

    @Test fun sameCountCorrectionFromAnotherConnectionFencesClaimAndTombstoneRemovesVendorOutput() {
        val first=put(body());val q=ScoringWorkQueue(pg.db,"frwhoop-server-2-history")
        q.maintain(1000);q.dirtyWorkItem(u,device,day);q.maintain(1000)
        val item=q.claim()!!
        val i=SignalSampleReader(pg.db).loadHistoricalDay(u,item.day,device)!!
        val stale=DayScorer().score(i,q.algorithmVersion,HistoricalStateMachine.prepare(i,HistoryCheckpointReader(pg.db).load(item)))
        val changed=body().apply { getJSONObject("values").getJSONObject("miband_stress_score_0_100").put("value",75) }
        val second=put(changed,first)
        assertNull(EngineIngestWriter(q).write(item,stale,1))
        assertEquals(75.0,score().derived!!.metrics.getJSONObject("imported_miband_stress_score_0_100").getDouble("value"),0.0)
        put(JSONObject(),second,deleted=true)
        assertFalse(score().derived!!.metrics.keySet().any { it.startsWith("imported_miband_") })
    }
}
