package com.frwhoop.scoring.db

import com.noop.data.HrSample
import com.noop.data.StepSample
import org.json.JSONArray
import org.json.JSONObject
import java.sql.Connection
import java.util.UUID

/** Projection admission only. Provenance absence is not proof of a producing algorithm. */
object ScalarInputReader {
    data class PpgHr(val ts:Long,val bpm:Int,val confidence:Double?,val provenance:JSONObject?)
    data class Result(val steps:List<StepSample>,val bandState:List<Pair<Long,Int>>,val ppgHr:List<PpgHr>,
                      val provenance:Map<String,Map<Long,JSONObject?>>,val gaps:Set<String>) {
        fun diagnostics(lo:Long,hi:Long):JSONObject=JSONObject().put("schemaVersion",1).put("streams",JSONObject(provenance.mapValues { (_,rows) ->
            val selected=rows.filterKeys { it in lo..hi }.values
            JSONObject().put("samples",selected.size).put("known",selected.count { it!=null })
                .put("unknown",selected.count { it==null })
                .put("origins",JSONArray(selected.mapNotNull { it?.getString("origin") }.distinct().sorted()))
                .put("algorithms",JSONArray(selected.mapNotNull { it?.optString("algorithm")?.takeIf(String::isNotEmpty) }.distinct().sorted()))
        }))
        fun derivedWithoutMeasuredOverlap(measured:List<HrSample>):List<PpgHr> {
            val timestamps=measured.filter { it.bpm>0 }.map { it.ts }.toHashSet()
            return ppgHr.filter { it.ts !in timestamps }
        }
    }

    internal fun provenance(raw:String?,hi:Long):JSONObject? {
        if(raw==null || raw=="null") return null
        require(raw.toByteArray(Charsets.UTF_8).size<=4096) { "scalar_provenance_size" }
        val j=JSONObject(raw)
        require(j.toString().toByteArray(Charsets.UTF_8).size<=1024) { "scalar_provenance_size" }
        val allowed=setOf("v","origin","recordIndex","frameSHA256","algorithm","sampleRateHz","windowSettingSeconds","inputStartTs","inputEndTs","inputSHA256","inputSelection")
        require(j.keySet().all { it in allowed }) { "scalar_provenance_field" }
        val safeInteger=9_007_199_254_740_991L
        fun integer(key:String,min:Long,max:Long):Long {
            val number=j.opt(key) as? Number ?: error("scalar_provenance_number")
            val decimal=number.toString().toBigDecimalOrNull() ?: error("scalar_provenance_number")
            val value=decimal.longValueExact()
            require(value in min..max) { "scalar_provenance_number" }
            return value
        }
        require(integer("v",1,1)==1L && j.opt("origin") is String && j.getString("origin") in
            setOf("whoop-v18","whoop-v26-ppg-derived","legacy-unknown")) { "scalar_provenance_version_origin" }
        val directKeys=setOf("recordIndex","frameSHA256")
        val derivedKeys=setOf("algorithm","sampleRateHz","windowSettingSeconds","inputStartTs","inputEndTs","inputSHA256")
        val keys=j.keySet()
        val validShape=when(j.getString("origin")) {
            "whoop-v18" -> keys.intersect(derivedKeys+"inputSelection").isEmpty()
            "whoop-v26-ppg-derived" -> keys.containsAll(derivedKeys) && keys.intersect(directKeys).isEmpty()
            else -> keys.intersect(directKeys+derivedKeys+"inputSelection").isEmpty()
        }
        require(validShape) { "scalar_provenance_origin_shape" }
        if(j.has("inputSelection")) require(
            j.opt("inputSelection") is String && j.getString("inputSelection") in
            setOf("concat-records-per-second-v1","last-record-per-second-v1")) { "scalar_provenance_input_selection" }
        if(j.has("recordIndex")) integer("recordIndex",0,0xffff_ffffL)
        for(key in listOf("sampleRateHz","windowSettingSeconds")) if(j.has(key)) integer(key,1,safeInteger)
        for(key in listOf("inputStartTs","inputEndTs")) if(j.has(key)) integer(key,-safeInteger,safeInteger)
        // inputEndTs is exclusive and now JSON-safe: subtracting one cannot overflow, unlike hi+1.
        if(j.has("inputEndTs")) require(j.getLong("inputEndTs")-1<=hi) { "scalar_provenance_future_window" }
        if(j.has("inputStartTs") && j.has("inputEndTs")) require(j.getLong("inputStartTs")<j.getLong("inputEndTs")) { "scalar_provenance_window" }
        for(key in listOf("frameSHA256","inputSHA256")) if(j.has(key)) require(j.opt(key) is String &&
            Regex("[0-9a-f]{64}").matches(j.getString(key))) { "scalar_provenance_digest" }
        if(j.has("algorithm")) require(j.opt("algorithm") is String && j.getString("algorithm") in
            setOf("ppg-acf-v1","ppg-acf-sublag-v1")) { "scalar_provenance_algorithm" }
        return j
    }

    fun load(c:Connection,owner:UUID,device:UUID,lo:Long,hi:Long,predecessor:Boolean):Result {
        val steps=mutableListOf<StepSample>();val band=mutableListOf<Pair<Long,Int>>();val ppg=mutableListOf<PpgHr>()
        val metadata=linkedMapOf<String,MutableMap<Long,JSONObject?>>()
        val gaps=linkedSetOf<String>()
        fun read(table:String,stream:String,fields:String,from:Long,to:Long,lastOnly:Boolean=false,consume:(java.sql.ResultSet,JSONObject?)->Unit) {
            // Table/column identifiers are fixed literals below, never client input. to_jsonb keeps this
            // compatible with 060 before 070 adds provenance; no fabricated legacy provenance column.
            val ordering=if(lastOnly) "desc limit 1" else "asc limit 300001"
            c.prepareStatement("select ts,$fields,(to_jsonb(t)->'provenance')::text from $table t where user_id=? and device_id=? and ts between ? and ? order by ts $ordering").use { s ->
                s.setObject(1,owner);s.setObject(2,device);s.setLong(3,from);s.setLong(4,to)
                s.executeQuery().use { r ->
                    var count=0
                    while(r.next()) {
                        check(++count<=300000) { "scalar_input_window_limit" }
                        val parsed=runCatching { provenance(r.getString(r.metaData.columnCount),hi) }
                        if(parsed.isFailure) { gaps+="${stream}_provenance_invalid";continue }
                        val value=parsed.getOrNull()
                        val admitted=runCatching { consume(r,value) }
                        if(admitted.isFailure) { gaps+="${stream}_measurement_invalid";continue }
                        metadata.getOrPut(stream) { linkedMapOf() }[r.getLong(1)]=value
                        if(value==null) gaps+="${stream}_provenance_unknown"
                    }
                }
            }
        }
        val step:(java.sql.ResultSet,JSONObject?)->Unit={ r,p ->
            val counter=r.getInt(2);val activity=r.getInt(3).let { if(r.wasNull()) null else it }
            require(counter in 0..65535 && (activity==null || activity in 0..2))
            steps+=StepSample(device.toString(),r.getLong(1),counter,activity,provenanceJSON=p?.toString())
        }
        if(predecessor) read("noop_step_samples","stepSample","counter,activity_class",Long.MIN_VALUE,lo-1,true,step)
        read("noop_step_samples","stepSample","counter,activity_class",lo,hi,consume=step)
        read("noop_sleep_state_samples","sleepStateSample","state,raw_byte",lo,hi) { r,_ ->
            val state=r.getInt(2);val raw=r.getInt(3).let { if(r.wasNull()) null else it }
            require(state in 0..3 && (raw==null || raw in 0..255 && (raw shr 4 and 3)==state))
            band+=r.getLong(1) to state
        }
        read("noop_ppg_hr_samples","ppgHrSample","bpm,conf",lo,hi) { r,p ->
            val bpm=r.getInt(2);val conf=r.getDouble(3).let { if(r.wasNull()) null else it }
            require(bpm>0 && (conf==null || conf.isFinite() && conf in 0.0..1.0))
            ppg+=PpgHr(r.getLong(1),bpm,conf,p)
        }
        return Result(steps,band,ppg,metadata,gaps)
    }
}
