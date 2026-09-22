package com.frwhoop.scoring

import com.frwhoop.scoring.b2.B2ObjectStore
import com.noop.analytics.UserProfile
import org.json.JSONArray
import org.json.JSONObject
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

/** Actual-Swift fixtures are externally owned. Absence, stale hashes and sparse assertions fail closed. */
internal object WholeDaySwiftCorpus {
    data class Case(val id:String,val mode:String,val input:JSONObject,val expected:JSONObject)
    val streamFields=linkedMapOf(
        "hr" to "ts bpm", "rr" to "ts rrMs seq ord srcChannel tsSuspect", "resp" to "ts raw",
        "gravity" to "ts x y z", "events" to "ts kind payloadJSON", "steps" to "ts counter activityClass provenance",
        "skinTemp" to "ts raw aux1Raw aux2Raw", "spo2" to "ts red ir",
        "bandState" to "ts state rawByte provenance", "ppgHr" to "ts bpm conf provenance")
    val dailyFields="deviceId day totalSleepMin efficiency deepMin remMin lightMin disturbances restingHr avgHrv recovery strain exerciseCount spo2Pct skinTempDevC respRateBpm steps activeKcalEst spo2Red spo2Ir avgSdnn skinTempC sleepHrOnly"
    private val digest=Regex("[0-9a-f]{64}")
    private val modes=setOf("kernel_calendar","server_day")
    fun keys(j:JSONObject,names:String,path:String) = require(j.keySet()==names.split(' ').toSet()) { "$path keys: expected $names, actual ${j.keySet()}" }
    fun integer(value:Any,path:String):Long {
        require(value is Number) { "$path must be an integer, not ${value.javaClass.simpleName}" }
        return value.toString().toBigDecimal().longValueExact()
    }
    private fun uuid(j:JSONObject,key:String) { require(j.opt(key) is String && UUID.fromString(j.getString(key)).toString()==j.getString(key)) { "invalid $key" } }
    private fun readFile(root:Path,file:String,limit:Long):ByteArray {
        require(Regex("[A-Za-z0-9][A-Za-z0-9_.-]*\\.json").matches(file)) { "invalid fixture basename: $file" }
        val path=root.resolve(file)
        require(Files.isRegularFile(path,NOFOLLOW_LINKS) && Files.size(path) in 1..limit) { "missing/oversized fixture: $path" }
        return Files.readAllBytes(path)
    }
    fun read(directory:Path,repository:Path):List<Case> {
        require(Files.isDirectory(directory,NOFOLLOW_LINKS)) { "Swift corpus missing: $directory" }
        val manifest=JSONObject(readFile(directory,"manifest.json",1024*1024).toString(Charsets.UTF_8))
        keys(manifest,"schemaVersion producer recipe sourceRevision sourceHashes cases","manifest")
        require(integer(manifest.get("schemaVersion"),"schemaVersion")==1L && manifest.get("producer")=="actual-swift" &&
            manifest.get("recipe")=="w4-whole-day-v1") { "unsupported Swift corpus" }
        require(Regex("[0-9a-f]{40}").matches(manifest.getString("sourceRevision"))) { "invalid sourceRevision" }
        val hashes=manifest.getJSONObject("sourceHashes")
        require(hashes.has("Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift")) { "missing Swift engine hash" }
        for(name in hashes.keySet()) {
            require(name.endsWith(".swift") && !name.contains("..") && !Path.of(name).isAbsolute &&
                listOf("Packages/StrandAnalytics/","Packages/WhoopStore/","Packages/WhoopProtocol/","Strand/","StrandTests/").any(name::startsWith)) { "invalid source hash path" }
            val path=repository.resolve(name)
            require(Files.isRegularFile(path,NOFOLLOW_LINKS) && Files.size(path)<=4*1024*1024 && digest.matches(hashes.getString(name)) &&
                B2ObjectStore.sha256Hex(Files.readAllBytes(path))==hashes.getString(name)) { "stale Swift source hash: $name" }
        }
        val entries=manifest.getJSONArray("cases")
        require(entries.length() in 1..512) { "empty/oversized Swift corpus" }
        val seen=mutableSetOf<String>();val files=mutableSetOf<String>();var bytes=0L
        val cases=(0 until entries.length()).map { n ->
            val entry=entries.getJSONObject(n);keys(entry,"id file sha256 mode","manifest.case[$n]")
            val id=entry.getString("id");val file=entry.getString("file");val mode=entry.getString("mode")
            require(id.isNotBlank() && seen.add(id) && files.add(file) && mode in modes && digest.matches(entry.getString("sha256")))
            val raw=readFile(directory,file,32L*1024*1024);bytes+=raw.size
            require(bytes<=512L*1024*1024 && B2ObjectStore.sha256Hex(raw)==entry.getString("sha256")) { "fixture digest/size: $id" }
            val c=JSONObject(raw.toString(Charsets.UTF_8));keys(c,"schemaVersion id mode input expected",id)
            require(integer(c.get("schemaVersion"),"$id.schemaVersion")==1L && c.get("id")==id && c.get("mode")==mode)
            validate(Case(id,mode,c.getJSONObject("input"),c.getJSONObject("expected")))
        }
        val byId=cases.associateBy { it.id }
        for(c in cases) {
            val history=c.input.getJSONArray("history").toList().map { require(it is String);byId[it] ?: error("missing history case: $it") }
            require(history.map { it.id }.distinct().size==history.size)
            require(history.all { it.input.getString("day")<c.input.getString("day") && it.input.get("deviceId")==c.input.get("deviceId") && it.input.get("userId")==c.input.get("userId") }) { "future/foreign history: ${c.id}" }
            require(history.map { it.input.getString("day") }.zipWithNext().all { (a,b) -> a<b }) { "unordered history: ${c.id}" }
            history.forEachIndexed { index, prior ->
                require(prior.mode==c.mode && prior.input.getJSONArray("history").toList()==history.take(index).map { it.id }) {
                    "history checkpoint ancestry differs from declared inputs: ${c.id}/${prior.id}"
                }
            }
        }
        return cases
    }
    fun validate(c:Case):Case {
        require(c.mode in modes) { "unsupported mode: ${c.mode}" }
        val i=c.input
        keys(i,"userId deviceId externalDeviceId deviceFamily day timezone profile config bounds raw history journal","${c.id}.input")
        uuid(i,"userId");uuid(i,"deviceId");require(i.get("externalDeviceId") is String && i.get("deviceFamily") in setOf("whoop4","whoop5"))
        LocalDate.parse(i.getString("day"));ZoneId.of(i.getString("timezone"))
        keys(i.getJSONObject("profile"),"age sex weightKg heightCm waistCm stepTicksPerStep","profile")
        val p=i.getJSONObject("profile");require(p.get("sex") in setOf("male","female","nonbinary"))
        for(key in p.keySet()-"sex") require(key=="waistCm" && p.get(key)===JSONObject.NULL ||
            p.get(key) is Number && p.getDouble(key).isFinite()) { "profile.$key" }
        i.getJSONObject("config");i.getJSONArray("history")
        val revisions=mutableSetOf<Long>()
        objects(i.getJSONArray("journal")).forEach { row ->
            keys(row,"kind entity revision effectiveDay deleted payload","journal")
            require(row.getString("kind") in setOf("profile","config","sleep_edit","context","period","imported_daily","manual_workout"))
            require(row.getString("entity").isNotBlank() && row.get("deleted") is Boolean)
            val revision=integer(row.get("revision"),"journal.revision")
            require(revision>0 && revisions.add(revision))
            LocalDate.parse(row.getString("effectiveDay"));row.getJSONObject("payload")
        }
        bounds(i.getJSONObject("bounds"))
        val raw=i.getJSONObject("raw");require(raw.keySet()==streamFields.keys)
        for((stream,fields) in streamFields) {
            val ids=mutableSetOf<String>();val a=raw.getJSONArray(stream)
            require(a.length()<=300000) { "oversized stream: $stream" }
            for(n in 0 until a.length()) {
                val row=a.getJSONObject(n);keys(row,"id userId deviceId $fields","$stream[$n]")
                require(row.get("id") is String && row.getString("id").isNotBlank() && ids.add(row.getString("id")))
                uuid(row,"userId");uuid(row,"deviceId")
                for(key in fields.split(' ')) {
                    val v=row.get(key)
                    when(key) {
                        "kind","payloadJSON" -> require(v is String)
                        "provenance" -> require(v===JSONObject.NULL || v is JSONObject)
                        "x","y","z","conf" -> require((key=="conf" && v===JSONObject.NULL) || v is Number && v.toDouble().isFinite())
                        "ord","srcChannel","tsSuspect","activityClass","aux1Raw","aux2Raw","rawByte" -> if(v!==JSONObject.NULL) integer(v,"$stream.$key")
                        else -> integer(v,"$stream.$key")
                    }
                }
            }
        }
        val expected=c.expected
        keys(expected,if(c.mode=="kernel_calendar") "selection result" else "selection result history snapshot","${c.id}.expected")
        val selection=expected.getJSONObject("selection")
        keys(selection,"bounds streams dayHr daySteps dayGravity vendorResp scoringResp wristOff profileRevision configurationRevision sleepEditEntities mainNightIndices physiologySessionIndices hrvWindows","selection")
        bounds(selection.getJSONObject("bounds"));compare(selection.getJSONObject("bounds"),i.getJSONObject("bounds"),"${c.id}.selection.bounds")
        require(selection.getJSONObject("streams").keySet()==streamFields.keys)
        fun ids(a:JSONArray,stream:String) {
            val known=objects(raw.getJSONArray(stream)).map { it.getString("id") }.toSet()
            require(a.toList().all { it is String && it in known } && a.toList().distinct().size==a.length()) { "invalid selected $stream identities" }
        }
        streamFields.keys.forEach { ids(selection.getJSONObject("streams").getJSONArray(it),it) }
        mapOf("dayHr" to "hr","daySteps" to "steps","dayGravity" to "gravity","vendorResp" to "resp","scoringResp" to "resp")
            .forEach { (key,stream) -> ids(selection.getJSONArray(key),stream) }
        listOf("profileRevision","configurationRevision").forEach { require(integer(selection.get(it),it)>=0) }
        require(selection.getJSONArray("sleepEditEntities").toList().all { it is String })
        objects(selection.getJSONArray("wristOff")).forEach { keys(it,"start end","wristOff");interval(it) }
        objects(selection.getJSONArray("hrvWindows")).forEach {
            keys(it,"sessionStart start stage cleanBeats rmssd","hrvWindow")
            listOf("sessionStart","start","cleanBeats").forEach { key -> integer(it.get(key),key) }
            require(it.getString("stage") in setOf("wake","light","deep","rem","?"));numeric(it,"rmssd")
        }
        val r=expected.getJSONObject("result")
        keys(r,"daily sleep workouts scores sessionMotionByStart sessionSleepStateByStart detectionFunnel","result")
        val daily=r.getJSONObject("daily");keys(daily,dailyFields,"daily")
        for(key in daily.keySet()) when(key) {
            "deviceId","day" -> require(daily.get(key) is String)
            "sleepHrOnly" -> require(daily.isNull(key) || daily.get(key) is Boolean)
            "disturbances","restingHr","exerciseCount","steps","spo2Red","spo2Ir" -> if(!daily.isNull(key)) integer(daily.get(key),key)
            else -> numeric(daily,key)
        }
        val sleeps=objects(r.getJSONArray("sleep"))
        sleeps.forEach { s ->
            keys(s,"start end efficiency restingHR avgHRV hrOnly stages","sleep");interval(s)
            require(s.get("hrOnly") is Boolean)
            listOf("efficiency","restingHR","avgHRV").forEach { numeric(s,it) }
            objects(s.getJSONArray("stages")).forEach { stage ->
                keys(stage,"start end stage","stage");interval(stage)
                require(stage.getString("stage") in setOf("wake","light","deep","rem"))
            }
        }
        listOf("mainNightIndices","physiologySessionIndices").forEach { key ->
            val indices=selection.getJSONArray(key).toList().map { integer(it,key) }
            require(indices.distinct()==indices && indices.all { it>=0 && it<sleeps.size })
        }
        objects(r.getJSONArray("workouts")).forEach { w ->
            keys(w,"start end avgHR peakHR strain durationS zoneTimePct avgHRRPct hrmax hrmaxSource caloriesKcal caloriesKJ hrCoveragePct","workout")
            interval(w);integer(w.get("durationS"),"durationS")
            require(w.isNull("hrmaxSource") || w.get("hrmaxSource") is String)
            w.getJSONObject("zoneTimePct").let { zones -> zones.keySet().forEach {
                require(it in setOf("0","1","2","3","4","5")) { "${c.id}.workout.zoneTimePct unknown zone: $it" }
                numeric(zones,it)
            } }
            listOf("avgHR","peakHR","strain","avgHRRPct","hrmax","caloriesKcal","caloriesKJ","hrCoveragePct").forEach { numeric(w,it) }
        }
        val scores=r.getJSONObject("scores")
        keys(scores,"recovery strain rest nightlySkinTempC chargeConfidence effortConfidence restConfidence","scores")
        scores.keySet().forEach { if(it.endsWith("Confidence")) require(scores.get(it) is String) else numeric(scores,it) }
        r.getJSONObject("sessionMotionByStart");r.getJSONObject("sessionSleepStateByStart")
        if(!r.isNull("detectionFunnel")) keys(r.getJSONObject("detectionFunnel"),
            "hrSamples motionSamples restingHR hrFloor motionPassed hrMissing hrTooLow active runs bridged longestRunS meanRunS droppedShort droppedNoHR droppedLowIntensity kept","funnel")
        if(c.mode=="server_day") {
            keys(expected.getJSONObject("history"),"baselinesBefore baselinesAfter needHours habitualMidsleepSec sleepDebt","history")
            keys(expected.getJSONObject("snapshot"),"metrics details charts chartMetadata capabilities sleep dependency","snapshot")
        }
        return c
    }
    private fun objects(a:JSONArray)=(0 until a.length()).map(a::getJSONObject)
    private fun numeric(j:JSONObject,key:String) { require(j.isNull(key) || j.get(key) is Number && j.getDouble(key).isFinite()) { "invalid numeric $key" } }
    private fun interval(j:JSONObject) { require(integer(j.get("start"),"start")<=integer(j.get("end"),"end")) }
    private fun bounds(j:JSONObject) { keys(j,"dayLo dayHi nightLo nightHi tzOffsetSeconds","bounds");j.keySet().forEach { integer(j.get(it),"bounds.$it") } }

    fun compareEffectiveProfile(actual:UserProfile,expected:JSONObject,path:String) {
        // Swift UserProfile has no waist field. Its explicit null is Kotlin's documented UNSET
        // sentinel, not a zero-centimetre measurement. A resolved nonzero waist must still mismatch.
        val waist:Any=if(expected.get("waistCm")===JSONObject.NULL && actual.waistCm==0.0) JSONObject.NULL else actual.waistCm
        compare(JSONObject().put("age",actual.age).put("sex",actual.sex).put("weightKg",actual.weightKg)
            .put("heightCm",actual.heightCm).put("waistCm",waist).put("stepTicksPerStep",actual.stepTicksPerStep),expected,path)
    }

    fun compare(actual:Any,expected:Any,path:String) {
        fun fail():Nothing=throw AssertionError("$path: expected=$expected actual=$actual")
        when {
            actual is JSONObject && expected is JSONObject -> {
                if(actual.keySet()!=expected.keySet()) throw AssertionError("$path keys: expected=${expected.keySet()} actual=${actual.keySet()}")
                expected.keySet().sorted().forEach { compare(actual.get(it),expected.get(it),"$path.$it") }
            }
            actual is JSONArray && expected is JSONArray -> {
                if(actual.length()!=expected.length()) fail()
                for(n in 0 until expected.length()) compare(actual.get(n),expected.get(n),"$path[$n]")
            }
            actual is Number && expected is Number -> {
                val a=actual.toDouble();val e=expected.toDouble()
                if(!a.isFinite() || !e.isFinite()) fail()
                // Swift JSON may spell a floating result as 75 instead of 75.0. Integer
                // identities remain exact regardless of either serializer's number spelling.
                val integralActual=actual is Int || actual is Long || actual is java.math.BigInteger
                val integralExpected=expected is Int || expected is Long || expected is java.math.BigInteger
                if(integerPath(path) || integralActual && integralExpected) {
                    if(actual.toString().toBigDecimal().compareTo(expected.toString().toBigDecimal())!=0) fail()
                } else if(kotlin.math.abs(a-e)>maxOf(1e-8,kotlin.math.abs(e)*1e-9)) fail()
            }
            actual!=expected -> fail()
        }
    }

    private fun integerPath(path:String):Boolean = path.substringAfterLast('.') in setOf(
        "dayLo","dayHi","nightLo","nightHi","tzOffsetSeconds","start","end","sessionStart",
        "profileRevision","configurationRevision","stateSchemaVersion","disturbances","restingHr",
        "exerciseCount","steps","spo2Red","spo2Ir","cleanBeats","durationS","nValid","nightsSinceUpdate",
        "nightCount","hrSamples","motionSamples","motionPassed","hrMissing","hrTooLow","active","runs",
        "bridged","longestRunS","droppedShort","droppedNoHR","droppedLowIntensity","kept") ||
        Regex(".*\\.(mainNightIndices|physiologySessionIndices)\\[[0-9]+]$").matches(path) ||
        Regex(".*\\.sessionSleepStateByStart\\.[0-9]+\\[[0-9]+]$").matches(path)
}
