package com.frwhoop.scoring

import com.frwhoop.scoring.db.SignalSampleReader
import com.frwhoop.scoring.scoring.CanonicalScorePayload
import com.frwhoop.scoring.scoring.DayScorer
import com.frwhoop.scoring.scoring.UserDayBounds
import com.noop.analytics.PhysiologyQuality
import com.noop.analytics.UserProfile
import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.protocol.DeviceFamily
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset
import java.util.UUID
import java.io.File
import kotlin.math.PI
import kotlin.math.sin

/** Synthetic wiring controls only, not a WHOOP/reference accuracy result. */
class DayScorerPhysiologyIntegrationTest {
    @Test fun exhaustedShadowBudgetKeepsCompletedHeartRateAndSleepOutputsPublishable() {
        val lo=bounds.dayLo
        val hr=(lo until lo+600).map { HrSample(device.toString(),it,60) }
        val gravity=hr.map { GravitySample(device.toString(),it.ts,0.0,0.0,1.0,dynAccel=.01) }
        val base=input(false).copy(hr=hr,gravity=gravity,rr=emptyList(),hrvObservations=emptyList(),events=emptyList())
        val now=Instant.ofEpochSecond(lo+459)
        val normal=DayScorer().score(base,CanonicalScorePayload.ALGORITHM_VERSION,"budget",now)
        var budgetReads=0
        val bounded=DayScorer().score(base,CanonicalScorePayload.ALGORITHM_VERSION,"budget",now,
            shadowBudget={budgetReads++;java.time.Duration.ZERO})
        assertEquals(1,budgetReads)
        assertEquals(normal.heartRateWindows,bounded.heartRateWindows)
        assertEquals(normal.result.sleepSessions,bounded.result.sleepSessions)
        assertEquals(normal.result.hrvMeasurements,bounded.result.hrvMeasurements)
        assertEquals(60.0,bounded.heartRateWindows.single().meanBpm!!,0.0)
        assertEquals(listOf("shadow_publication_budget_exhausted"),bounded.physiologyShadow!!.rawReasons)
        assertTrue(CanonicalScorePayload.build(bounded).getJSONObject("daily").getJSONArray("heart_rate_windows").length()>0)
    }
    @Test fun awakeRestRespirationRunsDuringTheDayWithoutBecomingTheOvernightStatistic() {
        val lo = bounds.dayLo + 14 * 3600
        val hi = lo + 600
        val hr = (lo until hi).map { HrSample(device.toString(), it, 60) }
        val gravity = hr.map { GravitySample(device.toString(), it.ts, 0.0, 0.0, 1.0, dynAccel = .01) }
        var time = lo.toDouble()
        var index = 0
        val rows = buildList {
            while (time < hi) {
                val duration = .8 + .04 * sin(2 * PI * .2 * (time - lo))
                add(PhysiologyQuality.IntervalObservation("awake:$index", user.toString(), device.toString(),
                    source = "synthetic_not_reference", eventTime = time, originalRRMs = duration * 1000,
                    startBeatId = "awake-beat:$index", endBeatId = "awake-beat:${index + 1}", continuityGroup = "awake",
                    verifiedSpan = PhysiologyQuality.Span(time, time + duration), timestampPrecisionSeconds = .001,
                    decoderVersion = "synthetic-fixture", clockVersion = "synthetic-fixture"))
                time += duration; index++
            }
        }
        val annotation = com.noop.analytics.SleepContextSpan(lo, hi, "awake", "fixture", availableAt = lo)
        val base = input(false).copy(hr = hr, gravity = gravity, rr = emptyList(), hrvObservations = rows,
            events = emptyList(), sleepContext = listOf(annotation))
        val now = Instant.ofEpochSecond(hi)
        val score = DayScorer().score(base, CanonicalScorePayload.ALGORITHM_VERSION, "awake", now)
        assertTrue(score.result.sleepSessions.isEmpty())
        assertNull(score.respirationSummary)
        assertNull(score.result.daily.respRateBpm)
        val summary = score.physiologyShadow!!.summaries.single().summary
        assertEquals("qualified_awake_rest", summary.context)
        assertEquals(12.0, summary.median!!, .5)
        assertTrue(score.physiologyShadow.windows.all { it.end <= hi })
        for (unqualified in listOf(base.copy(sleepContext = emptyList()),
            base.copy(sleepContext = listOf(annotation.copy(availableAt = hi + 1))))) {
            val result = DayScorer().score(unqualified, CanonicalScorePayload.ALGORITHM_VERSION, "unknown", now)
            assertTrue(result.physiologyShadow!!.summaries.none { it.summary.context == "qualified_awake_rest" })
        }
        val unverified = DayScorer().score(base.copy(hrvObservations = rows.map { it.copy(verifiedSpan = null) }),
            CanonicalScorePayload.ALGORITHM_VERSION, "no-clock", now)
        assertTrue(unverified.physiologyShadow!!.windows.all { it.breathsPerMinute == null && it.reason == "timing_unverified" })
    }

    @Test fun completedHeartRateWindowsHonorAcquisitionCutoffAndExplicitOffBodyContext() {
        val lo=bounds.dayLo
        val hr=(lo until lo+600).map { HrSample(device.toString(),it,if(it<lo+300) 60 else 120) }
        val gravity=hr.map { GravitySample(device.toString(),it.ts,0.0,0.0,1.0,dynAccel=.01) }
        val base=input(false).copy(hr=hr,gravity=gravity,rr=emptyList(),hrvObservations=emptyList(),events=emptyList())
        val now=Instant.ofEpochSecond(lo+459)
        val score=DayScorer().score(base,CanonicalScorePayload.ALGORITHM_VERSION,"7",now)
        val window=score.heartRateWindows.single()
        assertEquals(lo,window.start); assertEquals(lo+300,window.end)
        assertEquals(60.0,window.meanBpm!!,0.0); assertEquals(60.0,window.lowMotionBpm!!,0.0)
        val payload=CanonicalScorePayload.build(score)
        assertTrue(payload.getJSONObject("daily").isNull("resting_hr_bpm"))
        val published=payload.getJSONObject("daily").getJSONArray("heart_rate_windows").getJSONObject(0)
        assertEquals(device.toString(),published.getString("device_id"))
        assertEquals(user.toString(),published.getString("user_id"))
        val offBody=base.copy(sleepContext=listOf(com.noop.analytics.SleepContextSpan(lo,lo+300,"off_body","fixture",availableAt=lo)))
        val excluded=DayScorer().score(offBody,CanonicalScorePayload.ALGORITHM_VERSION,"8",now).heartRateWindows.single()
        assertNull(excluded.meanBpm); assertNull(excluded.lowMotionBpm)
        assertEquals("off_body_evidence",excluded.lowMotionReason)
    }
    private val user=UUID.fromString("11111111-1111-1111-1111-111111111111")
    private val device=UUID.fromString("22222222-2222-2222-2222-222222222222")
    private val bounds=UserDayBounds.forDay("2026-09-17",ZoneOffset.UTC)
    private val start=bounds.dayLo+3600
    private val nap=bounds.dayLo+15*3600
    private fun input(verified: Boolean): SignalSampleReader.DayInputs {
        val sleep=listOf(start until start+7200,nap until nap+1200)
        val hr=(bounds.dayLo..bounds.dayHi step 5).map { t ->
            HrSample(device.toString(),t,if(sleep.any { t in it }) 60 else 80)
        }
        val gravity=hr.map { GravitySample(device.toString(),it.ts,0.0,0.0,1.0) }
        val rows=sleep.flatMapIndexed { run,range ->
            val result=mutableListOf<PhysiologyQuality.IntervalObservation>(); var time=range.first.toDouble(); var index=0
            while(time<range.last+1) {
                val duration=0.8+0.04*sin(2*PI*0.2*(time-range.first)); val end=time+duration
                result+=PhysiologyQuality.IntervalObservation("run:$run:interval:$index",user.toString(),device.toString(),
                    source="synthetic_wiring_not_reference",eventTime=time,originalRRMs=duration*1000,
                    startBeatId="run:$run:beat:$index",endBeatId="run:$run:beat:${index+1}",continuityGroup="run:$run",
                    verifiedSpan=if(verified) PhysiologyQuality.Span(time,end) else null,
                    timestampPrecisionSeconds=if(verified) 0.001 else 1.0,decoderVersion="fixture",clockVersion="fixture")
                time=end; index++
            }
            result
        }
        return SignalSampleReader.DayInputs(user,"2026-09-17",device.toString(),0,bounds.dayLo,bounds.dayHi,UserProfile(),
            bounds.nightLo,bounds.nightHi,hr,emptyList(),emptyList(),gravity,emptyList(),DeviceFamily.WHOOP5,
            hrvObservations=rows)
    }

    @Test fun detectorMeasurementSummaryAndPublicationKeepNapOwnershipAndActualRespirationMethod() {
        val score=DayScorer().score(input(true),CanonicalScorePayload.ALGORITHM_VERSION,"42",Instant.parse("2026-09-18T00:00:00Z"))
        val payload=CanonicalScorePayload.build(score)
        val episodes=payload.getJSONArray("nights")
        assertEquals(2,episodes.length())
        assertEquals("main_sleep",episodes.getJSONObject(0).getString("episode_type"))
        assertEquals("nap",episodes.getJSONObject(1).getString("episode_type"))
        assertEquals(nap,episodes.getJSONObject(1).getLong("start"))
        assertEquals(12.0,payload.getJSONObject("daily").getDouble("resp_rate_bpm"),0.5)
        val summary=payload.getJSONObject("daily").getJSONObject("respiration_summary")
        assertTrue(summary.getDouble("coverage")>0.9)
        assertEquals("resp-spectrum-acf-1",summary.getString("method_version"))
        val main=score.result.sleepSessions.filter { it.episodeType=="main_sleep" }
        val lo=main.minOf { it.start }; val hi=main.maxOf { it.end }
        assertEquals(score.physiologyShadow!!.windows.count { it.start>=lo && it.end<=hi },summary.getInt("total_windows"))
        assertTrue(payload.getBoolean("period_closed"))
        assertEquals("provisional",payload.getString("publication_status"))
        assertFalse(payload.getJSONObject("shadow").getBoolean("canonical_outputs_allowed"))
    }

    @Test fun actualScorerSerializationMatchesBothClientFixtures() {
        val score=DayScorer().score(input(true),CanonicalScorePayload.ALGORITHM_VERSION,"42",Instant.parse("2026-09-18T00:00:00Z"))
        val payload=CanonicalScorePayload.build(score)
        // The read RPC preserves these generated fields and attaches per-feature selection
        // metadata. This fixture is a synthetic read envelope, not an activation/promotion.
        val features=JSONObject()
        for (feature in listOf("sleep","hrv","respiration")) features.put(feature,JSONObject()
            .put("status","available").put("device_id",score.deviceId)
            .put("algorithm_version",score.algorithmVersion).put("input_revision",42).put("required_revision",42))
        val envelope=JSONObject().put("server_scoring",JSONObject()
            .put("schema_version",2).put("user_id",score.userId.toString()).put("day",score.day)
            .put("algorithm_version",score.algorithmVersion).put("computed_at",score.computedAt.toString())
            .put("stale",false).put("features",features).put("daily",payload.getJSONObject("daily"))
            .put("nights",payload.getJSONArray("nights")).put("measurements",payload.getJSONArray("measurements")))
        val repository=generateSequence(File(System.getProperty("user.dir"))) { it.parentFile }
            .first { File(it,"android/app/src/test/resources").isDirectory }
        val files=listOf(File(repository,"android/app/src/test/resources/server_scored_sleep_snapshot.json"),
            File(repository,"Packages/WhoopStore/Tests/WhoopStoreTests/Resources/server_scored_sleep_snapshot.json"))
        if (System.getenv("UPDATE_SCORED_CLIENT_FIXTURE")=="1") {
            for(file in files) file.writeText(CanonicalScorePayload.encode(envelope)+"\n")
        }
        for(file in files) assertEquals(file.path,CanonicalScorePayload.encode(envelope),file.readText().trim())
        assertEquals(files[0].readText(),files[1].readText())
        assertEquals("main_sleep",envelope.getJSONObject("server_scoring").getJSONObject("daily")
            .getJSONObject("respiration_summary").getString("context"))
    }

    @Test fun preservedBeatIdentitiesWithoutClockProofCannotPublishRespirationOrQualifiedHrv() {
        val score=DayScorer().score(input(false),CanonicalScorePayload.ALGORITHM_VERSION,"43")
        val payload=CanonicalScorePayload.build(score)
        assertTrue(payload.getJSONObject("daily").isNull("resp_rate_bpm"))
        assertTrue(payload.getJSONObject("daily").isNull("hrv_rmssd_ms"))
        assertTrue(score.physiologyShadow!!.windows.all { it.breathsPerMinute==null && it.reason=="timing_unverified" })
        assertTrue(score.result.hrvMeasurements.none { it.measurementValid })
    }
    @Test fun deletingAllSleepCannotKeepRestingHrFromDeletedEpisodes() {
        val original=input(false)
        val before=DayScorer().score(original,CanonicalScorePayload.ALGORITHM_VERSION,"44")
        assertNotNull(before.result.daily.restingHr)
        val overrides=before.result.sleepSessions.mapIndexed { i,session ->
            com.frwhoop.scoring.scoring.SleepBoundaryOverride("delete-$i",session.start,session.end,
                session.start,session.end,true,1,"user_annotation")
        }
        val after=DayScorer().score(original.copy(sleepOverrides=overrides),CanonicalScorePayload.ALGORITHM_VERSION,"45")
        assertTrue(after.result.sleepSessions.isEmpty())
        val daily=CanonicalScorePayload.build(after).getJSONObject("daily")
        assertTrue(daily.isNull("resting_hr_bpm"));assertTrue(daily.isNull("overnight_hr_bpm"))
    }

    @Test fun snapshotExcludesFutureSignalsAndUnfinishedMeasurementWindowsWithoutChangingMode() {
        val original=input(true)
        val at=Instant.ofEpochSecond(start+600+285)
        val crossing=original.hrvObservations!!.first { row -> row.verifiedSpan!!.let { it.start<=at.epochSecond && it.end>at.epochSecond } }
        val expected=original.copy(hr=original.hr.filter { it.ts<=at.epochSecond },
            gravity=original.gravity.filter { it.ts<=at.epochSecond },
            hrvObservations=original.hrvObservations.filter { it.eventTime<=at.epochSecond && it.verifiedSpan!!.end<=at.epochSecond })
        val actual=DayScorer().score(original,CanonicalScorePayload.ALGORITHM_VERSION,"as-of",at)
        val control=DayScorer().score(expected,CanonicalScorePayload.ALGORITHM_VERSION,"as-of",at)
        assertEquals(control.result,actual.result)
        assertTrue(actual.result.hrvMeasurements.any { it.measurementValid })
        assertTrue(actual.result.hrvMeasurements.all { it.end<=at.epochSecond && it.computationMode=="retrospective" })
        assertTrue(actual.result.hrvMeasurements.none { crossing.originalId in it.originalIds })
        assertTrue(actual.result.sleepSessions.all { it.end<=at.epochSecond })
        assertTrue(actual.observedThrough!!<=at)
        assertTrue(actual.physiologyShadow!!.windows.all { it.end<=at.epochSecond })
    }

    @Test fun receiptOnlySnapshotReportsItsObservedTimeButFutureReceiptCannotMoveIt() {
        val base=input(false)
        val at=Instant.ofEpochSecond(start+600)
        val receipt=base.hrvObservations!!.first().copy(eventTime=(start+100).toDouble())
        val rows=listOf(receipt,receipt.copy(originalId="future",eventTime=(start+1200).toDouble()))
        val score=DayScorer().score(base.copy(hr=emptyList(),gravity=emptyList(),hrvObservations=rows),
            CanonicalScorePayload.ALGORITHM_VERSION,"receipt-only",at)
        assertEquals(Instant.ofEpochSecond(start+100),score.observedThrough)
        assertTrue(score.result.hrvMeasurements.none { it.measurementValid })
        assertTrue(score.result.hrvMeasurements.none { "future" in it.originalIds })
    }
    @Test fun groupedInterruptionsReachCanonicalEpochsAndNeverQualifyForSleepPhysiology() {
        val gapStart=start+2700; val gapEnd=gapStart+1800
        for(kind in listOf("reading","off_body","missing")) {
            val original=input(true)
            val context=if(kind=="missing") emptyList() else listOf(com.noop.analytics.SleepContextSpan(
                gapStart,gapEnd,kind,"independent_annotation"))
            val prepared=original.copy(sleepContext=context,
                gravity=original.gravity.filter { kind!="missing" || it.ts !in gapStart until gapEnd })
            val score=DayScorer().score(prepared,CanonicalScorePayload.ALGORITHM_VERSION,"gap-$kind",
                Instant.parse("2026-09-18T00:00:00Z"))
            val payload=CanonicalScorePayload.build(score)
            val first=payload.getJSONArray("nights").getJSONObject(0)
            val daily=payload.getJSONObject("daily")
            val expected=when(kind) { "reading"->"awake";"off_body"->"off_body";else->"state_unknown" }
            val gapEpochs=first.getJSONArray("stages").let { rows -> (0 until rows.length()).map(rows::getJSONObject) }
                .filter { it.getLong("start")>=gapStart && it.getLong("end")<=gapEnd }
            assertEquals(1800L,gapEpochs.sumOf { it.getLong("end")-it.getLong("start") })
            assertTrue(gapEpochs.all { it.getString("state")==expected })
            assertEquals(90.0,daily.getDouble("sleep_total_min"),0.0)
            assertEquals(120.0,daily.getDouble("sleep_in_bed_min"),0.0)
            assertEquals(if(kind=="reading") 30.0 else 0.0,daily.getDouble("sleep_awake_min"),0.0)
            assertEquals(if(kind=="off_body") 30.0 else 0.0,daily.getDouble("off_body_min"),0.0)
            assertEquals(if(kind=="missing") 30.0 else 0.0,daily.getDouble("state_unknown_min"),0.0)
            assertEquals(Instant.ofEpochSecond(gapStart).toString(),first.getString("final_known_sleep_at"))
            assertEquals(gapEnd,first.getLong("end"))
            assertTrue(score.result.hrvMeasurements.filter { it.start>=gapStart && it.end<=gapEnd }.none { it.context=="sleep" })
            assertTrue(score.physiologyShadow!!.windows.none { it.start<gapEnd && it.end>gapStart })

            // Explicit correction bounds are applied after opportunity assembly, and are never extended.
            val session=score.result.sleepSessions.first()
            val edit=com.frwhoop.scoring.scoring.SleepBoundaryOverride("gap-edit",session.start,session.end,
                session.start+300,gapStart+900,false,1,"user_annotation")
            val edited=DayScorer().score(prepared.copy(sleepOverrides=listOf(edit)),CanonicalScorePayload.ALGORITHM_VERSION,"edit")
            val manual=edited.result.sleepSessions.first { it.boundaryProvenance?.startsWith("user_boundary:")==true }
            assertEquals(edit.start,manual.start);assertEquals(edit.end,manual.end)
            val tombstone=edit.copy(tombstone=true,revision=2)
            for(late in listOf(prepared,original)) {
                val deleted=DayScorer().score(late.copy(sleepOverrides=listOf(tombstone)),CanonicalScorePayload.ALGORITHM_VERSION,"deleted")
                assertTrue(deleted.result.sleepSessions.none { it.start<edit.originalEnd && it.end>edit.originalStart })
            }
        }
    }
}
