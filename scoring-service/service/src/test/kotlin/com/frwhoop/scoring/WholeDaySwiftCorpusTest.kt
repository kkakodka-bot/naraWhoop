package com.frwhoop.scoring

import com.frwhoop.scoring.b2.B2ObjectStore
import com.frwhoop.scoring.scoring.DailyMetricJson
import com.noop.data.DailyMetric
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.nio.file.Files
import java.nio.file.Path
import java.time.LocalDate
import java.time.ZoneId

/** Synthetic parser controls, not a producer of actual-Swift expected values. */
class WholeDaySwiftCorpusTest {
    @get:Rule val temporary=TemporaryFolder()

    @Test fun exactShapesAndFloatToleranceDoNotDependOnJsonNumberSpelling() {
        WholeDaySwiftCorpus.compare(JSONObject("""{"score":75.00000001,"missing":null,"flag":false}"""),
            JSONObject("""{"score":75,"missing":null,"flag":false}"""),"case")
        assertThrows(AssertionError::class.java) { WholeDaySwiftCorpus.compare(JSONObject("""{"score":75.001}"""),JSONObject("""{"score":75}"""),"case") }
        for(wrong in listOf<Any>(0,"null",false)) assertThrows(AssertionError::class.java) {
            WholeDaySwiftCorpus.compare(wrong,JSONObject.NULL,"case.missing")
        }
        assertThrows(AssertionError::class.java) { WholeDaySwiftCorpus.compare(JSONObject(),JSONObject().put("missing",JSONObject.NULL),"case") }
    }

    @Test fun equalCountsChangedIdentityStageOrderAndIntegerPrecisionFail() {
        val e=JSONArray().put("rr-1").put("rr-2")
        assertThrows(AssertionError::class.java) { WholeDaySwiftCorpus.compare(JSONArray().put("rr-1").put("rr-3"),e,"case.selection.streams.rr") }
        assertThrows(AssertionError::class.java) { WholeDaySwiftCorpus.compare(JSONArray().put("rr-2").put("rr-1"),e,"case.selection.streams.rr") }
        assertThrows(AssertionError::class.java) { WholeDaySwiftCorpus.compare(9007199254740992L,9007199254740993L,"case.revision") }
        assertThrows(AssertionError::class.java) { WholeDaySwiftCorpus.compare(1789420000.1,1789420000L,"case.stage.start") }
        assertThrows(AssertionError::class.java) { WholeDaySwiftCorpus.compare("light","deep","case.stage.stage") }
        WholeDaySwiftCorpus.compare(1789420000.0,1789420000L,"case.stage.start")
    }

    @Test fun sparseResultsBadModesAndContradictoryBoundsAreRejected() {
        WholeDaySwiftCorpus.validate(syntheticCase())
        val sparse=syntheticCase();sparse.expected.getJSONObject("result").getJSONObject("daily").remove("avgSdnn")
        assertThrows(IllegalArgumentException::class.java) { WholeDaySwiftCorpus.validate(sparse) }
        assertThrows(IllegalArgumentException::class.java) { WholeDaySwiftCorpus.validate(syntheticCase().copy(mode="unknown")) }
        val bounds=syntheticCase();bounds.expected.getJSONObject("selection").getJSONObject("bounds").put("dayHi",42)
        assertThrows(AssertionError::class.java) { WholeDaySwiftCorpus.validate(bounds) }
    }

    @Test fun absentCorpusFailsWithoutDatabaseOrAssumptionSkip() {
        val root=temporary.newFolder().toPath()
        val error=assertThrows(IllegalArgumentException::class.java) { WholeDaySwiftCorpus.read(root.resolve("absent"),root) }
        assertTrue(error.message!!.contains("Swift corpus missing"))
    }

    @Test fun explicitNullWaistIsAllowedButMissingOrMalformedProfileFieldsAreNot() {
        val nullable=syntheticCase();nullable.input.getJSONObject("profile").put("waistCm",JSONObject.NULL)
        WholeDaySwiftCorpus.validate(nullable)
        val missing=syntheticCase();missing.input.getJSONObject("profile").remove("waistCm")
        assertThrows(IllegalArgumentException::class.java) { WholeDaySwiftCorpus.validate(missing) }
        for(value in listOf<Any>("unknown",false,JSONObject())) {
            val invalid=syntheticCase();invalid.input.getJSONObject("profile").put("waistCm",value)
            assertThrows(IllegalArgumentException::class.java) { WholeDaySwiftCorpus.validate(invalid) }
        }
        for(key in listOf("age","heightCm","weightKg","stepTicksPerStep")) {
            val invalid=syntheticCase();invalid.input.getJSONObject("profile").put(key,JSONObject.NULL)
            assertThrows(IllegalArgumentException::class.java) { WholeDaySwiftCorpus.validate(invalid) }
        }
    }

    @Test fun workoutZoneZeroIsAnExistingEngineOutputButUnknownZonesAreRejected() {
        val c=syntheticCase()
        val workout=JSONObject()
        "avgHR peakHR strain avgHRRPct hrmax hrmaxSource caloriesKcal caloriesKJ hrCoveragePct".split(' ').forEach {
            workout.put(it,JSONObject.NULL)
        }
        workout.put("start",1).put("end",2).put("durationS",1)
            .put("zoneTimePct",JSONObject((0..5).associate { it.toString() to if(it==0) 100 else 0 }))
        c.expected.getJSONObject("result").getJSONArray("workouts").put(workout)
        WholeDaySwiftCorpus.validate(c)
        for(key in listOf("-1","6","0.0","unknown")) {
            workout.put("zoneTimePct",JSONObject().put(key,0))
            assertThrows(IllegalArgumentException::class.java) { WholeDaySwiftCorpus.validate(c) }
        }
    }

    @Test fun exactHashesAndAllCasesAreReadButChangedBytesAreRejected() {
        val (dir,repo)=corpus(listOf(syntheticCase()))
        assertEquals(listOf("synthetic-empty"),WholeDaySwiftCorpus.read(dir,repo).map { it.id })
        Files.writeString(dir.resolve("case-0.json"),Files.readString(dir.resolve("case-0.json"))+" ")
        assertTrue(assertThrows(IllegalArgumentException::class.java) { WholeDaySwiftCorpus.read(dir,repo) }.message!!.contains("digest"))
    }

    @Test fun sourceDriftTraversalAndSymlinkAreRejected() {
        val (dir,repo)=corpus(listOf(syntheticCase()))
        Files.writeString(repo.resolve(enginePath),"changed synthetic source")
        assertTrue(assertThrows(IllegalArgumentException::class.java) { WholeDaySwiftCorpus.read(dir,repo) }.message!!.contains("stale Swift"))
        val (dir2,repo2)=corpus(listOf(syntheticCase()))
        val manifest=JSONObject(Files.readString(dir2.resolve("manifest.json")))
        manifest.getJSONArray("cases").getJSONObject(0).put("file","../case-0.json")
        Files.writeString(dir2.resolve("manifest.json"),manifest.toString())
        assertThrows(IllegalArgumentException::class.java) { WholeDaySwiftCorpus.read(dir2,repo2) }
        val (dir3,repo3)=corpus(listOf(syntheticCase()))
        Files.move(dir3.resolve("case-0.json"),dir3.resolve("target.json"))
        Files.createSymbolicLink(dir3.resolve("case-0.json"),Path.of("target.json"))
        assertThrows(IllegalArgumentException::class.java) { WholeDaySwiftCorpus.read(dir3,repo3) }
    }

    @Test fun futureForeignAndUnorderedHistoryCannotBecomeCheckpointInputs() {
        val current=syntheticCase()
        val future=syntheticCase("future","2026-09-16")
        current.input.getJSONArray("history").put("future")
        val (dir,repo)=corpus(listOf(current,future))
        assertThrows(IllegalArgumentException::class.java) { WholeDaySwiftCorpus.read(dir,repo) }
        val previous=syntheticCase("previous","2026-09-14")
        previous.input.put("userId","10000000-0000-4000-8000-000000000002")
        val second=syntheticCase();second.input.getJSONArray("history").put("previous")
        val (dir2,repo2)=corpus(listOf(previous,second))
        assertThrows(IllegalArgumentException::class.java) { WholeDaySwiftCorpus.read(dir2,repo2) }
    }

    private fun corpus(cases:List<WholeDaySwiftCorpus.Case>):Pair<Path,Path> {
        val dir=temporary.newFolder().toPath();val repo=temporary.newFolder().toPath()
        Files.createDirectories(repo.resolve(enginePath).parent)
        val source="// SYNTHETIC parser control, never actual-Swift evidence."
        Files.writeString(repo.resolve(enginePath),source)
        val entries=JSONArray()
        cases.forEachIndexed { index,c ->
            val bytes=JSONObject().put("schemaVersion",1).put("id",c.id).put("mode",c.mode).put("input",c.input).put("expected",c.expected).toString().toByteArray()
            Files.write(dir.resolve("case-$index.json"),bytes)
            entries.put(JSONObject().put("id",c.id).put("file","case-$index.json").put("sha256",B2ObjectStore.sha256Hex(bytes)).put("mode",c.mode))
        }
        Files.writeString(dir.resolve("manifest.json"),JSONObject().put("schemaVersion",1).put("producer","actual-swift")
            .put("recipe","w4-whole-day-v1").put("sourceRevision","0".repeat(40))
            .put("sourceHashes",JSONObject().put(enginePath,B2ObjectStore.sha256Hex(source.toByteArray()))).put("cases",entries).toString())
        return dir to repo
    }

    companion object {
        private const val enginePath="Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift"
        internal fun syntheticCase(id:String="synthetic-empty",day:String="2026-09-15",timezone:String="UTC"):WholeDaySwiftCorpus.Case {
            val user="10000000-0000-4000-8000-000000000001";val device="20000000-0000-4000-8000-000000000001"
            val date=LocalDate.parse(day);val zone=ZoneId.of(timezone);val start=date.atStartOfDay(zone)
            val bounds=JSONObject().put("dayLo",start.toEpochSecond()).put("dayHi",date.plusDays(1).atStartOfDay(zone).toEpochSecond()-1)
                .put("nightLo",start.toEpochSecond()-30*3600).put("nightHi",date.plusDays(1).atStartOfDay(zone).toEpochSecond()-1)
                .put("tzOffsetSeconds",start.offset.totalSeconds)
            val profile=JSONObject().put("age",30).put("sex","nonbinary").put("weightKg",70).put("heightCm",170).put("waistCm",0).put("stepTicksPerStep",1)
            val config=JSONObject().put("schemaVersion",1).put("useSleepStagerV2",true).put("useMotionAwareWake",true)
                .put("deepHrvWindow",false).put("effortMethod","EDWARDS").put("dayCycleMode","midnight")
            val journal=JSONArray().put(JSONObject().put("kind","profile").put("entity","primary").put("revision",1)
                .put("effectiveDay",day).put("deleted",false).put("payload",JSONObject(profile.toString()).put("waistCm",JSONObject.NULL).put("schemaVersion",1).put("timezone",timezone)))
                .put(JSONObject().put("kind","config").put("entity","primary").put("revision",2).put("effectiveDay",day).put("deleted",false).put("payload",config))
            val input=JSONObject().put("userId",user).put("deviceId",device).put("externalDeviceId",device).put("deviceFamily","whoop5")
                .put("day",day).put("timezone",timezone).put("profile",profile).put("config",config).put("bounds",bounds)
                .put("raw",JSONObject(WholeDaySwiftCorpus.streamFields.keys.associateWith { JSONArray() })).put("history",JSONArray()).put("journal",journal)
            val selection=JSONObject().put("bounds",JSONObject(bounds.toString()))
                .put("streams",JSONObject(WholeDaySwiftCorpus.streamFields.keys.associateWith { JSONArray() }))
                .put("profileRevision",1).put("configurationRevision",2)
            listOf("dayHr","daySteps","dayGravity","vendorResp","scoringResp","wristOff","sleepEditEntities","mainNightIndices","physiologySessionIndices","hrvWindows").forEach { selection.put(it,JSONArray()) }
            val scores=JSONObject().put("recovery",JSONObject.NULL).put("strain",JSONObject.NULL).put("rest",JSONObject.NULL).put("nightlySkinTempC",JSONObject.NULL)
                .put("chargeConfidence","unavailable").put("effortConfidence","unavailable").put("restConfidence","unavailable")
            val result=JSONObject().put("daily",DailyMetricJson.encode(DailyMetric(deviceId=device,day=day))).put("sleep",JSONArray()).put("workouts",JSONArray())
                .put("scores",scores).put("sessionMotionByStart",JSONObject()).put("sessionSleepStateByStart",JSONObject()).put("detectionFunnel",JSONObject.NULL)
            return WholeDaySwiftCorpus.Case(id,"kernel_calendar",input,JSONObject().put("selection",selection).put("result",result))
        }
    }
}
