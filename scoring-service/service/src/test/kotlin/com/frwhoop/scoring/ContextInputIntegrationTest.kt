package com.frwhoop.scoring

import org.json.JSONObject
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import java.sql.SQLException
import java.util.UUID

class ContextInputIntegrationTest : PgIntegrationBase() {
    private fun consent(purpose: String) = JSONObject().put("purpose",purpose).put("policyVersion",1)
        .put("decisionId","50000000-0000-4000-8000-000000000001")
    private fun base(purpose: String) = JSONObject().put("schemaVersion",1).put("day",day)
        .put("timezone","UTC").put("consent",consent(purpose))
    private fun put(kind: String, entity: String, payload: JSONObject, expected: Long=0, deleted: Boolean=false,
                    effective: String=day): Long = pg.connection().use { c ->
        c.createStatement().use { it.execute("set role authenticated"); it.execute("set request.jwt.claim.sub='$u'") }
        c.prepareStatement("select put_scoring_history_input_v3(?,?,?,?::date,?::jsonb,?,?,?,?,?)::text").use { s ->
            s.setObject(1,device); s.setString(2,kind); s.setString(3,entity); s.setString(4,effective)
            s.setString(5,payload.toString()); s.setLong(6,expected); s.setBoolean(7,deleted)
            s.setObject(8,UUID.randomUUID()); s.setObject(9,UUID.randomUUID()); s.setLong(10,1)
            s.executeQuery().use { it.next(); JSONObject(it.getString(1)).getLong("revision") }
        }
    }
    private fun rejected(block: () -> Unit) {
        assertEquals("22023",assertThrows(SQLException::class.java,block).sqlState)
    }
    private fun context() = base("journal_context").put("flags",JSONObject()
        .put("alcohol",false).put("stress",JSONObject.NULL).put("sauna",JSONObject.NULL)
        .put("hardOrLateWorkout",true).put("travelPhaseJump",JSONObject.NULL).put("alreadyUnwell",false))

    @Test fun dailyContextRetainsUnknownFlagsAndRequiresAffirmativeChoiceProvenance() {
        val body = context()
        rejected { put("context","context:$day",JSONObject(body.toString()).apply { remove("consent") }) }
        rejected { put("context","context:$day",JSONObject(body.toString()).put("notes","private note")) }
        rejected { put("context","context:$day",JSONObject(body.toString()).put("consent",consent("cycle_context"))) }
        rejected { put("context","context:$day",JSONObject(body.toString()).put("flags",JSONObject().put("alcohol",false))) }
        rejected { put("context","context:2026-09-16",body) }
        put("context","context:$day",body)
        assertEquals("null",scalar("select payload->'flags'->'stress' from scoring_history_inputs_v3"))
        assertEquals("false",scalar("select payload->'flags'->'alcohol' from scoring_history_inputs_v3"))
    }

    @Test fun periodStartCannotSilentlyChangeDateAndDeletionIsAnImmutableTombstone() {
        val key = "period:40000000-0000-4000-8000-000000000001"
        val body = base("cycle_context").put("event","period_start")
        rejected { put("period",key,JSONObject(body.toString()).put("event","prediction")) }
        val first = put("period",key,body)
        rejected { put("period",key,JSONObject(body.toString()).put("day","2026-09-16"),first,effective="2026-09-16") }
        put("period",key,JSONObject(),first,deleted=true)
        assertEquals("2",scalar("select count(*) from scoring_history_inputs_v3"))
        assertEquals("t",scalar("select deleted from scoring_history_inputs_v3 order by revision desc limit 1"))
    }

    @Test fun importedValuesPreserveUnitsAndSourceIdentityAndRefuseServerFeedback() {
        val source = JSONObject().put("kind","apple_health").put("externalDeviceId","apple-health").put("method","healthkit_daily_aggregate")
        val values = JSONObject().put("hrv_sdnn_ms",JSONObject().put("value",55.0).put("unit","ms"))
            .put("sleep_debt_min",JSONObject().put("value",30).put("unit","min"))
            .put("vo2max_ml_kg_min",JSONObject().put("value",JSONObject.NULL).put("unit","mL/kg/min"))
        val body = base("imported_metrics").put("source",source).put("values",values)
        rejected { put("imported_daily","import:apple:$day",JSONObject(body.toString()).put("source",JSONObject(source.toString()).put("kind","server"))) }
        rejected { put("imported_daily","import:apple:$day",JSONObject(body.toString()).put("values",JSONObject().put("hrv_sdnn_ms",JSONObject().put("value",55).put("unit","bpm")))) }
        val first = put("imported_daily","import:apple:$day",body)
        rejected { put("imported_daily","import:apple:$day",JSONObject(body.toString()).put("source",JSONObject(source.toString()).put("method","different")),first) }
        assertEquals(55.0,scalar("select payload->'values'->'hrv_sdnn_ms'->>'value' from scoring_history_inputs_v3")!!.toDouble(),0.0)
    }

    @Test fun manualWorkoutKeepsNaturalKeyAndRejectsDerivedAndPrivateFields() {
        val key = "workout:40000000-0000-4000-8000-000000000001"
        val body = base("manual_workouts").apply { remove("day") }.put("originalStart",1789440000)
            .put("originalSport","strength").put("start",1789440000).put("end",1789443600)
            .put("sport","strength").put("dismissed",false).put("energyKcal",JSONObject.NULL)
            .put("distanceM",JSONObject.NULL).put("steps",JSONObject.NULL)
        for (field in listOf("strain","avgHr","notes","routePolyline"))
            rejected { put("manual_workout",key,JSONObject(body.toString()).put(field,1)) }
        val first = put("manual_workout",key,body)
        rejected { put("manual_workout",key,JSONObject(body.toString()).put("originalSport","run"),first) }
        put("manual_workout",key,JSONObject(body.toString()).put("end",1789447200),first)
        assertEquals("2",scalar("select count(*) from scoring_history_inputs_v3"))
    }

    @Test fun importedSleepFiguresKeepStrictUnitsRangesAndNullableUnknowns() {
        val source=JSONObject().put("kind","whoop_import").put("externalDeviceId","export").put("method","vendor_daily")
        fun payload(key:String,value:Any,unit:String)=base("imported_metrics").put("source",source)
            .put("values",JSONObject().put(key,JSONObject().put("value",value).put("unit",unit)))
        for(key in listOf("sleep_performance_pct","sleep_consistency_pct")) {
            for(value in listOf<Any>(-1,101,true,"90")) rejected { put("imported_daily","import:sleep:$day",payload(key,value,"%")) }
            rejected { put("imported_daily","import:sleep:$day",payload(key,90,"min")) }
        }
        rejected { put("imported_daily","import:sleep:$day",payload("sleep_need_min",1441,"min")) }
        val first=put("imported_daily","import:sleep:$day",payload("sleep_need_min",480,"min"))
        put("imported_daily","import:sleep:$day",payload("sleep_need_min",JSONObject.NULL,"min"),first)
        assertEquals("null",scalar("select payload->'values'->'sleep_need_min'->'value' from scoring_history_inputs_v3 order by revision desc limit 1"))
    }

    @Test fun configGatesAreBooleanAndNoObservationCanBeBackdatedAheadOfItsOwnDay() {
        rejected { put("config","primary",JSONObject().put("schemaVersion",1).put("journalContextEnabled","yes")) }
        put("config","primary",JSONObject().put("schemaVersion",1).put("journalContextEnabled",true).put("cycleAwarenessEnabled",false))
        rejected { put("context","context:2026-09-14",context(),effective="2026-09-14") }
        rejected { put("period","period:40000000-0000-4000-8000-000000000001",base("cycle_context").put("event","period_start").put("day","2026-02-30"),effective="2026-02-28") }
    }

    @Test fun dayCycleAndEffortMethodsAreStrictEnumsAndNullableEpochsUseNoReset() {
        fun body(key:String,value:Any)=JSONObject().put("schemaVersion",1).put(key,value)
        for(value in listOf(JSONObject.NULL,1,true,"calendar","SLEEP_ONSET"))
            rejected { put("config","primary",body("dayCycleMode",value)) }
        for(value in listOf(JSONObject.NULL,1,true,"edwards"))
            rejected { put("config","primary",body("effortMethod",value)) }
        val first=put("config","primary",body("dayCycleMode","midnight"))
        put("config","primary",body("dayCycleMode","sleep_onset").put("hrvBaselineEpoch",JSONObject.NULL)
            .put("recoveryBaselineEpoch",JSONObject.NULL),first)
        val input=com.frwhoop.scoring.db.SignalSampleReader(pg.db).loadHistoricalDay(u,day,device)!!
        val p=com.frwhoop.scoring.scoring.HistoricalStateMachine.prepare(input,com.frwhoop.scoring.db.HistoryCheckpointReader.Seed(null,emptyList()))
        assertEquals(0.0,p.hrvEpoch,0.0)
        assertEquals(0.0,p.recoveryEpoch,0.0)
    }

    @Test fun customZoneStepAndCandidatePreferencesRejectWrongTypesAndInvalidRanges() {
        fun body(key:String,value:Any)=JSONObject().put("schemaVersion",1).put(key,value)
        for(value in listOf<Any>("yes",1,JSONObject.NULL)) rejected {
            put("config","primary",body("spo2CandidateDisplayEnabled",value))
        }
        for(value in listOf<Any>("50",-1,1000001)) rejected {
            put("config","primary",body("stepsManualCoefficient",value))
        }
        for(value in listOf<Any>("90,110,130,150,170",JSONArray(listOf(90,110,130,150)),
            JSONArray(listOf(90,110,110,150,170)),JSONArray(listOf(29,110,130,150,170)),
            JSONArray(listOf(90,110,130,150,251)),JSONArray(listOf(90,110,130,150,"170")))) rejected {
            put("config","primary",body("customHRZoneLowerBounds",value))
        }
        for(value in listOf<Any>(JSONObject.NULL,JSONObject(),"",1,"a".repeat(129))) rejected {
            put("config","primary",body("sourceEra",value))
        }
        val first=put("config","primary",JSONObject().put("schemaVersion",1)
            .put("customHRZoneLowerBounds",JSONArray(listOf(90,110,130,150,170)))
            .put("stepsManualCoefficient",42.5).put("spo2CandidateDisplayEnabled",false))
        put("config","primary",JSONObject().put("schemaVersion",1).put("customHRZoneLowerBounds",JSONObject.NULL)
            .put("stepsManualCoefficient",0).put("spo2CandidateDisplayEnabled",true),first)
        assertEquals("2",scalar("select count(*) from scoring_history_inputs_v3"))
    }
}
