package com.frwhoop.scoring

import com.frwhoop.scoring.db.*
import com.frwhoop.scoring.scoring.*
import com.noop.analytics.*
import org.json.JSONArray
import org.json.JSONObject
import java.time.ZoneId
import java.util.UUID

/** Runs synthetic fixtures through the real PG reader, then the common kernel or full server lane. */
internal class WholeDaySwiftRunner {
    companion object {
        /** Index only fixture identities; expected results never participate in source selection. */
        internal fun selectedRowIds(raw: JSONArray, stream: String, user: String, device: String,
                                    keys: List<List<Any?>>): JSONArray {
            val fields = when (stream) {
                "rr" -> listOf("ts", "rrMs", "seq")
                "events" -> listOf("ts", "kind")
                else -> listOf("ts")
            }
            fun normalized(value: Any?): Any = if (value is Number) value.toLong() else value ?: JSONObject.NULL
            val absentField = Any()
            // A null map value marks an ambiguous identity. Do not silently choose the first row.
            val byKey = HashMap<List<Any>, String?>()
            for (index in 0 until raw.length()) {
                val row = raw.getJSONObject(index)
                if (row.getString("userId") != user || row.getString("deviceId") != device) continue
                val key = fields.map { field -> row.opt(field)?.let(::normalized) ?: absentField }
                byKey[key] = if (byKey.containsKey(key)) null else row.getString("id")
            }
            return JSONArray(keys.map { key ->
                require(key.size == fields.size) { "Invalid selected identity shape: $stream" }
                checkNotNull(byKey[key.map(::normalized)]) { "Missing or ambiguous selected identity: $stream" }
            })
        }
    }
    private val pg get()=DisposablePostgres
    private val completed=mutableMapOf<String,HistoricalStateMachine.Commit>()
    private fun j(vararg pairs:Pair<String,Any?>)=JSONObject(pairs.toMap().mapValues { it.value ?: JSONObject.NULL })
    private fun rows(a:JSONArray)=(0 until a.length()).map(a::getJSONObject)
    private fun number(j:JSONObject,key:String)=if(j.isNull(key)) null else j.getDouble(key)

    fun run(c:WholeDaySwiftCorpus.Case):JSONObject {
        val input=c.input;load(input)
        val owner=UUID.fromString(input.getString("userId"));val device=UUID.fromString(input.getString("deviceId"))
        val reader=SignalSampleReader(pg.db)
        // The frozen kernel_calendar producer uses bounded ordinary Store reads. Historical
        // predecessor/thermal loading belongs only to the separately declared server_day lane.
        val i=when(c.mode) {
            "kernel_calendar" -> reader.loadDay(owner,input.getString("day"),device)
            "server_day" -> reader.loadHistoricalDay(owner,input.getString("day"),device)
            else -> error("Unsupported whole-day mode: ${c.mode}")
        }!!
        WholeDaySwiftCorpus.compareEffectiveProfile(i.profile,input.getJSONObject("profile"),"${c.id}.effectiveProfile")
        WholeDaySwiftCorpus.compare(i.history.configuration,input.getJSONObject("config"),"${c.id}.effectiveConfig")
        require(i.timezone==input.getString("timezone")) { "${c.id}: eligible profile journal does not select input.timezone" }
        val history=input.getJSONArray("history").toList().map { completed[it] ?: error("history case must run first: $it") }
        val p=HistoricalStateMachine.prepare(i,HistoryCheckpointReader.Seed(history.lastOrNull()?.state,history.map { it.state.getJSONObject("observation") }))
        val bundle=if(c.mode=="server_day") DayScorer().score(i,"frwhoop-server-2-history",p) else null
        val result=bundle?.result ?: kernel(i,p)
        val commit=bundle?.historyCommit ?: HistoricalStateMachine.finish(i,result,p,emptyMap())
        completed[c.id]=requireNotNull(commit)
        val actual=j("selection" to selection(input.getJSONObject("raw"),i,result,p,bundle),"result" to encode(result,i.deviceId))
        if(c.mode=="server_day") {
            val debt=commit.sleepDebt
            actual.put("history",j("baselinesBefore" to HistoricalStateMachine.encodeBaselines(p.baselines),
                "baselinesAfter" to commit.state.getJSONObject("baselinesAfter"),"needHours" to p.needHours,
                "habitualMidsleepSec" to p.habitualMidsleep,"sleepDebt" to j("needMin" to debt.needMin,"balanceMin" to debt.balanceMin,
                    "magnitudeMin" to debt.magnitudeMin,"nightCount" to debt.nightCount,
                    "nights" to JSONArray(debt.nights.map { j("day" to it.day,"sleptMin" to it.sleptMin,"deltaMin" to it.deltaMin) }))))
            val snapshot=EngineIngestWriter.buildSnapshot(requireNotNull(bundle))
            val normalized=JSONObject()
            for(key in listOf("metrics","details","charts","chartMetadata","capabilities","sleep")) normalized.put(key,snapshot.get(key))
            normalized.put("dependency",j("stateSchemaVersion" to 1,"profileRevision" to commit.profileRevision,
                "configurationRevision" to commit.configurationRevision,"sourceEra" to p.sourceEra))
            actual.put("snapshot",normalized)
        }
        return actual
    }
    private fun kernel(i:SignalSampleReader.DayInputs,p:HistoricalStateMachine.Prepared):DayResult {
        val config=i.history.configuration
        return AnalyticsEngine.analyzeDay(day=i.day,hr=i.hr,rr=i.rr,resp=i.scoringResp,vendorResp=i.vendorResp,
            gravity=i.gravity,steps=i.steps,skinTemp=i.skinTemp,spo2=i.spo2,bandSleepState=i.bandSleepState,
            dayHr=i.hr.filter { it.ts in i.dayLo..i.dayHi },daySteps=i.steps.filter { it.ts in i.dayLo..i.dayHi },
            dayGravity=i.gravity.filter { it.ts in i.dayLo..i.dayHi },profile=i.profile,baselines=p.profileBaselines,
            skinTempFamily=i.deviceFamily,skinTempAnchorRaw=p.skinTempAnchorRaw,
            skinTempWornToleranceSec=if(i.isOura) AnalyticsEngine.DEFAULT_OURA_WORN_TOLERANCE_SEC else 0,
            tzOffsetSeconds=i.tzOffsetSeconds,wristOff=AnalyticsEngine.offWristIntervals(i.events,i.nightHi),
            maxHROverride=number(config,"maxHR"),sleepNeedHours=p.needHours,sleepConsistency=p.consistency,
            habitualMidsleepSec=p.habitualMidsleep,useSleepStagerV2=config.optBoolean("useSleepStagerV2",true),
            useMotionAwareWake=config.optBoolean("useMotionAwareWake",i.deviceFamily!=com.noop.protocol.DeviceFamily.WHOOP4),
            deepHrvWindow=config.optBoolean("deepHrvWindow",false),effortMethod=StrainScorer.Method.valueOf(config.optString("effortMethod","EDWARDS")),
            providedSleep=if(i.gravity.isEmpty()) SleepStager.hrOnlySessions(i.hr,i.rr,i.scoringResp) else emptyList())
    }
    private fun selection(raw:JSONObject,i:SignalSampleReader.DayInputs,r:DayResult,p:HistoricalStateMachine.Prepared,b:ServerScoreBundle?):JSONObject {
        fun ids(stream:String,keys:List<List<Any?>>):JSONArray {
            return selectedRowIds(raw.getJSONArray(stream), stream, i.userId.toString(), i.deviceId, keys)
        }
        fun ts(stream:String,values:List<Long>)=ids(stream,values.map { listOf(it) })
        val streams=j("hr" to ts("hr",i.hr.map { it.ts }),"rr" to ids("rr",i.rr.map { listOf(it.ts,it.rrMs,it.seq) }),
            "resp" to ts("resp",i.resp.map { it.ts }),"gravity" to ts("gravity",i.gravity.map { it.ts }),
            "events" to ids("events",i.events.map { listOf(it.ts,it.kind) }),"steps" to ts("steps",i.steps.map { it.ts }),
            "skinTemp" to ts("skinTemp",i.skinTemp.map { it.ts }),"spo2" to ts("spo2",i.spo2.map { it.ts }),
            "bandState" to ts("bandState",i.bandSleepState.map { it.first }),"ppgHr" to ts("ppgHr",i.scalarInputs!!.ppgHr.map { it.ts }))
        val candidates=r.sleepSessions.withIndex().filter { b?.sleepNapOverrides?.get(SleepBounds(it.value.start,it.value.end))!=true }
        val main=SleepStageTotals.mainNightGroupIndices(candidates.map { SleepStageTotals.NightBlock(it.value.start,it.value.end) },
            i.tzOffsetSeconds,p.habitualMidsleep,if(b==null) null else ZoneId.of(i.timezone))?.map { candidates[it].index } ?: emptyList()
        val physiology=r.sleepSessions.indices.filter { !r.sleepSessions[it].hrOnly }.ifEmpty { r.sleepSessions.indices.toList() }
        val windows=physiology.flatMap { index -> val s=r.sleepSessions[index]
            SleepStager.sessionHrvWindows(s.start,s.end,i.rr,s.stages).map { w ->
                j("sessionStart" to s.start,"start" to w.startTs,"stage" to w.stage,"cleanBeats" to w.cleanBeats,"rmssd" to w.rmssd) } }
        return j("bounds" to j("dayLo" to i.dayLo,"dayHi" to i.dayHi,"nightLo" to i.nightLo,"nightHi" to i.nightHi,"tzOffsetSeconds" to i.tzOffsetSeconds),
            "streams" to streams,"dayHr" to ts("hr",i.hr.filter { it.ts in i.dayLo..i.dayHi }.map { it.ts }),
            "daySteps" to ts("steps",i.steps.filter { it.ts in i.dayLo..i.dayHi }.map { it.ts }),
            "dayGravity" to ts("gravity",i.gravity.filter { it.ts in i.dayLo..i.dayHi }.map { it.ts }),
            "vendorResp" to ts("resp",i.vendorResp.map { it.ts }),"scoringResp" to ts("resp",i.scoringResp.map { it.ts }),
            "wristOff" to JSONArray(AnalyticsEngine.offWristIntervals(i.events,i.nightHi).map { j("start" to it.first,"end" to it.second) }),
            "profileRevision" to (i.history.profile?.revision ?: 0),"configurationRevision" to (i.history.config?.revision ?: 0),
            "sleepEditEntities" to JSONArray(i.history.sleepEdits.filterNot { it.deleted }.sortedByDescending { it.revision }.map { it.entity }),
            "mainNightIndices" to JSONArray(main),"physiologySessionIndices" to JSONArray(physiology),"hrvWindows" to JSONArray(windows))
    }
    private fun encode(r:DayResult,source:String):JSONObject = j(
        "daily" to DailyMetricJson.encode(r.daily.copy(deviceId=source)),
        "sleep" to JSONArray(r.sleepSessions.map { s -> j("start" to s.start,"end" to s.end,"efficiency" to s.efficiency,
            "restingHR" to s.restingHR,"avgHRV" to s.avgHRV,"hrOnly" to s.hrOnly,
            "stages" to JSONArray(s.stages.map { j("start" to it.start,"end" to it.end,"stage" to it.stage) })) }),
        "workouts" to JSONArray(r.workouts.map { w -> j("start" to w.start,"end" to w.end,"avgHR" to w.avgHR,"peakHR" to w.peakHR,
            "strain" to w.strain,"durationS" to w.durationS,"zoneTimePct" to JSONObject(w.zoneTimePct.mapKeys { it.key.toString() }),
            "avgHRRPct" to w.avgHRRPct,"hrmax" to w.hrmax,"hrmaxSource" to w.hrmaxSource,"caloriesKcal" to w.caloriesKcal,
            "caloriesKJ" to w.caloriesKJ,"hrCoveragePct" to w.hrCoveragePct) }),
        "scores" to j("recovery" to r.recovery,"strain" to r.strain,"rest" to r.rest,"nightlySkinTempC" to r.nightlySkinTempC,
            "chargeConfidence" to r.chargeConfidence.name.lowercase(),"effortConfidence" to r.effortConfidence.name.lowercase(),"restConfidence" to r.restConfidence.name.lowercase()),
        "sessionMotionByStart" to JSONObject(r.sessionMotionByStart.mapKeys { it.key.toString() }),
        "sessionSleepStateByStart" to JSONObject(r.sessionSleepStateByStart.mapKeys { it.key.toString() }),
        "detectionFunnel" to r.detectionFunnel?.let { f -> j("hrSamples" to f.hrSamples,"motionSamples" to f.motionSamples,
            "restingHR" to f.restingHR,"hrFloor" to f.hrFloor,"motionPassed" to f.motionPassed,"hrMissing" to f.hrMissing,
            "hrTooLow" to f.hrTooLow,"active" to f.active,"runs" to f.runs,"bridged" to f.bridged,"longestRunS" to f.longestRunS,
            "meanRunS" to f.meanRunS,"droppedShort" to f.droppedShort,"droppedNoHR" to f.droppedNoHR,"droppedLowIntensity" to f.droppedLowIntensity,"kept" to f.kept) })

    private fun load(i:JSONObject) {
        pg.sql("truncate auth.users cascade; delete from scoring_algorithms_v2 where algorithm_version<>'frwhoop-server-1'")
        val owner=i.getString("userId");val device=i.getString("deviceId");val raw=i.getJSONObject("raw")
        val devices=mutableMapOf(device to owner)
        for(stream in WholeDaySwiftCorpus.streamFields.keys) for(row in rows(raw.getJSONArray(stream))) {
            val d=row.getString("deviceId");val u=row.getString("userId")
            require(devices[d]==null || devices[d]==u) { "fixture assigns one device to two owners" };devices[d]=u
        }
        pg.connection().use { c ->
            for(u in devices.values.distinct()) c.prepareStatement("insert into auth.users(id) values(?::uuid)").use { it.setString(1,u);it.executeUpdate() }
            for((d,u) in devices) c.prepareStatement("insert into devices(id,user_id,source_kind,device_family,external_device_id) values(?::uuid,?::uuid,'noop_push',?,?)").use {
                it.setString(1,d);it.setString(2,u);it.setString(3,i.getString("deviceFamily"));it.setString(4,if(d==device) i.getString("externalDeviceId") else d);it.executeUpdate()
            }
            for(row in rows(i.getJSONArray("journal"))) {
                WholeDaySwiftCorpus.keys(row,"kind entity revision effectiveDay deleted payload","journal")
                c.prepareStatement("select validate_scoring_history_input_v3(?,?::jsonb,?)").use {
                    it.setString(1,row.getString("kind"));it.setString(2,row.getJSONObject("payload").toString());it.setBoolean(3,row.getBoolean("deleted"));it.execute()
                }
                c.prepareStatement("""insert into scoring_history_inputs_v3(revision,user_id,device_id,kind,entity,effective_day,payload,deleted,
                    expected_revision,client_id,client_mutation_id,client_revision,invalidated_from) overriding system value
                    values(?,?::uuid,?::uuid,?,?,?::date,?::jsonb,?,0,gen_random_uuid(),gen_random_uuid(),1,?::date)""").use {
                    it.setLong(1,WholeDaySwiftCorpus.integer(row.get("revision"),"journal.revision"));it.setString(2,owner);it.setString(3,device)
                    it.setString(4,row.getString("kind"));it.setString(5,row.getString("entity"));it.setString(6,row.getString("effectiveDay"))
                    it.setString(7,row.getJSONObject("payload").toString());it.setBoolean(8,row.getBoolean("deleted"));it.setString(9,row.getString("effectiveDay"));it.executeUpdate()
                }
            }
            // Optional provenance columns are a reader fixture, not a substitute for Rawls's070 gate.
            c.createStatement().use { s -> listOf("noop_step_samples","noop_sleep_state_samples","noop_ppg_hr_samples").forEach {
                s.execute("alter table $it add column if not exists provenance jsonb")
            } }
            val tables=mapOf("hr" to "noop_hr_samples","rr" to "noop_rr_intervals","resp" to "noop_resp_samples","gravity" to "noop_gravity_samples",
                "events" to "noop_events","steps" to "noop_step_samples","skinTemp" to "noop_skin_temp_samples","spo2" to "noop_spo2_samples",
                "bandState" to "noop_sleep_state_samples","ppgHr" to "noop_ppg_hr_samples")
            for((stream,fieldsText) in WholeDaySwiftCorpus.streamFields) {
                val fields=fieldsText.split(' ')
                fun column(f:String)=when(f) { "activityClass" -> "activity_class";"rawByte" -> "raw_byte";else -> f }
                val columns=fields.joinToString(",") { "\"${column(it)}\"" }
                val expressions=fields.joinToString(",") { f ->
                    if(f=="provenance") "nullif(j->'$f','null'::jsonb)" else "(j->>'$f')::"+when(f) {
                        "kind","payloadJSON" -> "text";"ts" -> "bigint";"x","y","z","conf" -> "double precision";else -> "integer"
                    }
                }
                c.prepareStatement("insert into ${tables.getValue(stream)}(user_id,device_id,source_id,batch_id,$columns) select (j->>'userId')::uuid,(j->>'deviceId')::uuid,gen_random_uuid(),gen_random_uuid(),$expressions from jsonb_array_elements(?::jsonb) j").use {
                    it.setString(1,raw.getJSONArray(stream).toString());it.executeUpdate()
                }
            }
        }
    }
}
