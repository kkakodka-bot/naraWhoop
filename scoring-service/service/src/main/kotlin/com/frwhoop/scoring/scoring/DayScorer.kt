package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.db.SignalSampleReader
import com.noop.analytics.AnalyticsEngine
import com.noop.analytics.DayResult
import com.noop.analytics.HrvSeries
import com.noop.analytics.PhysiologyQuality
import com.noop.analytics.SleepStageSemantics
import com.noop.analytics.RespirationEstimator
import com.noop.protocol.DeviceFamily
import com.frwhoop.scoring.signals.PhysiologyShadowRunner

/**
 * Runs the scoped server kernel (HRV/RR + sleep + Charge/Effort) via the extracted Kotlin twin.
 * Charge and Effort are published on the physiology-2 daily payload so phones can read them
 * from the hosted overlay rather than rescoring locally.
 */
class DayScorer(private val physiology: PhysiologyShadowRunner = PhysiologyShadowRunner()) {
    fun score(inputs: SignalSampleReader.DayInputs, algorithmVersion: String, inputRevision: String = "unversioned",
              computedAt: java.time.Instant = java.time.Instant.now(),
              shadowBudget: (() -> java.time.Duration)? = null): ServerScoreBundle {
        val cutoff=computedAt.epochSecond
        val exactCutoff=cutoff+computedAt.nano/1_000_000_000.0
        // A retrospective method may inspect later evidence only within this acquisition snapshot.
        // A beat spanning the cutoff is omitted intact, never truncated into invented timing proof.
        val snapshot=inputs.copy(
            hr=inputs.hr.filter { it.ts<=cutoff && com.noop.analytics.SleepSignalValidity.heartRate(it) },
            rr=inputs.rr.filter { it.ts<=cutoff },
            resp=inputs.resp.filter { it.ts<=cutoff },
            gravity=inputs.gravity.filter { it.ts<=cutoff && com.noop.analytics.SleepSignalValidity.gravity(it) },
            skinTemp=inputs.skinTemp.filter { it.ts<=cutoff },
            steps=inputs.steps.filter { it.ts<=cutoff }, events=inputs.events.filter { it.ts<=cutoff },
            bandSleepState=inputs.bandSleepState.filter { it.first<=cutoff },
            hrvObservations=inputs.hrvObservations?.filter { row ->
                row.eventTime.isFinite() && row.eventTime<=exactCutoff &&
                    (row.verifiedSpan?.let { it.start.isFinite() && it.end.isFinite() && it.end<=exactCutoff } ?: true)
            },
            hrvHistory=inputs.hrvHistory.filter { it.end<=cutoff },
            sleepContext=inputs.sleepContext.mapNotNull { span ->
                if(span.start>=cutoff || (span.availableAt?.let { it>cutoff } ?: false)) null
                else span.copy(end=minOf(span.end,cutoff)).takeIf { it.end>it.start }
            })
        return scoreSnapshot(snapshot,algorithmVersion,inputRevision,computedAt,shadowBudget)
    }

    private fun scoreSnapshot(inputs: SignalSampleReader.DayInputs, algorithmVersion: String, inputRevision: String,
                              computedAt: java.time.Instant, shadowBudget: (() -> java.time.Duration)?): ServerScoreBundle {
        require(algorithmVersion==CanonicalScorePayload.ALGORITHM_VERSION) { "This scorer cannot impersonate another algorithm version" }
        val ownership=inputs.calendarOwnership
        if(ownership?.unavailableReason!=null) {
            return ServerScoreBundle(inputs.userId,inputs.day,inputs.deviceId,algorithmVersion,
                DayResult(com.noop.data.DailyMetric(deviceId=inputs.deviceId,day=inputs.day),emptyList(),emptyList(),null,null),
                computedAt=computedAt,calendarOwnership=ownership,inputUnavailableReason=ownership.unavailableReason)
        }
        // Local-day bounds (from the user's profile timezone via UserDayBounds) — the SAME local-day
        // semantics queue discovery uses. UTC-midnight bounds would shift the scored window for any
        // non-UTC user (Phase 3 gate failure: "DayScorer currently uses a UTC day boundary").
        val dayLo = inputs.dayLo
        val dayHi = inputs.dayHi
        fun owns(timestamp:Long)=ownership?.dayIntervals?.any { timestamp>=it.first && timestamp<it.second } ?: (timestamp in dayLo..dayHi)
        val dayHr = (AnalyticsEngine.daySliceFromNight(
            inputs.hr, inputs.nightLo, inputs.nightHi, dayLo, dayHi,
        ) { it.ts } ?: inputs.hr.filter { it.ts in dayLo..dayHi }).filter { owns(it.ts) }
        val dayGravity = (AnalyticsEngine.daySliceFromNight(
            inputs.gravity, inputs.nightLo, inputs.nightHi, dayLo, dayHi,
        ) { it.ts } ?: inputs.gravity.filter { it.ts in dayLo..dayHi }).filter { owns(it.ts) }

        val wristOff = AnalyticsEngine.offWristIntervals(inputs.events, inputs.nightHi+1)
        val observations = inputs.hrvObservations ?: PhysiologyQuality.legacy(inputs.rr,inputs.deviceId)
            .map { it.copy(userId=inputs.userId.toString(),deviceFirmware=inputs.deviceFirmware) }
        require(observations.all { it.userId==inputs.userId.toString() && it.deviceId==inputs.deviceId })

        val observedThrough = (inputs.hr.map { it.ts } + inputs.rr.map { it.ts } + inputs.resp.map { it.ts } +
            inputs.gravity.map { it.ts } + inputs.steps.map { it.ts } + observations.map { it.eventTime.toLong() })
            .filter { it<=computedAt.epochSecond }.maxOrNull()
        val nowSeconds=computedAt.epochSecond
        val sleepContextThrough=(inputs.sleepContext.filter { it.end<=nowSeconds }.map { it.end } +
            listOfNotNull(observedThrough?.plus(1)?.coerceAtMost(nowSeconds))).maxOrNull()
        val analyzed = AnalyticsEngine.analyzeDay(
            day = inputs.day,
            hr = inputs.hr,
            rr = inputs.rr,
            hrvObservations = observations,
            hrvHistory = inputs.hrvHistory,
            inputRevision = inputRevision,
            resp = inputs.resp,
            gravity = inputs.gravity,
            dayHr = dayHr,
            dayGravity = dayGravity,
            steps = inputs.steps,
            daySteps = inputs.steps.filter { owns(it.ts) },
            profile = inputs.profile,
            tzOffsetSeconds = inputs.tzOffsetSeconds,
            wristOff = wristOff,
            skinTemp = inputs.skinTemp,
            skinTempFamily = inputs.deviceFamily,
            useSleepStagerV2 = true,
            useMotionAwareWake = inputs.deviceFamily != DeviceFamily.WHOOP4,
            localDayStart = dayLo,
            localDayEndExclusive = dayHi + 1,
            sleepContext = inputs.sleepContext,
            bandSleepState = inputs.bandSleepState,
            sleepObservedThrough = sleepContextThrough,
            useFullDaySleepOpportunities = true,
            localDayOwnership = ownership?.dayIntervals,
            measurementObservedThrough = nowSeconds,
        )
        val contexts = inputs.sleepContext + wristOff.map { com.noop.analytics.SleepContextSpan(
            it.first,it.second,"off_body","wrist_event",availableAt=it.first) }
        var result = analyzed.copy(sleepSessions = SleepBoundaryOverrides.apply(analyzed.sleepSessions,inputs.sleepOverrides)
            .filter { owns(it.end) }.map { session ->
                val stages = com.noop.analytics.SleepStageSemantics.applyingContext(session.stages,
                    session.start,session.end,contexts,observedThrough=sleepContextThrough)
                session.copy(stages=stages,efficiency=com.noop.analytics.SleepStager.efficiency(session.start,session.end,stages))
            })
        if(inputs.sleepOverrides.isNotEmpty()) {
            val group=com.noop.analytics.SleepOpportunityDetector.mainSleepGroupIndices(
                result.sleepSessions,inputs.tzOffsetSeconds).toSet()
            val episodes=result.sleepSessions.mapIndexed { index,s -> s.copy(
                episodeType=if(!s.hasKnownState) "uncertain" else if(index in group) "main_sleep" else "nap") }
            val context=episodes.flatMap { PhysiologyQuality.contextFromSleep(it.stages,it.start,it.end,it.episodeType) }
            val from=minOf(dayLo,episodes.minOfOrNull { it.start }?:dayLo).toInt()
            val windows=HrvSeries.windows(from,minOf(dayHi+1,nowSeconds).toInt(),observations,context,inputRevision=inputRevision).filter { window ->
                window.end<=nowSeconds && (ownership==null || ownership.dayIntervals.any { window.start>=it.first && window.end<=it.second } ||
                    episodes.any { window.start<it.end && window.end>it.start })
            }
            val main=episodes.filterIndexed { index,_ -> index in group }
            val summary=if(main.isEmpty()) null else HrvSeries.summarize(windows,
                main.minOf { it.start }.toInt(),main.maxOf { it.end }.toInt())
            val sdnn=if(summary?.representative==true) windows.filter {
                it.start>=main.minOf { s -> s.start } && it.end<=main.maxOf { s -> s.end } &&
                    it.baselineEligible && it.context=="sleep"
            }.mapNotNull { it.sdnn }.takeIf { it.isNotEmpty() }?.average() else null
            result=result.copy(
                daily=result.daily.copy(avgHrv=summary?.meanRMSSD,avgSdnn=sdnn),
                sleepSessions=episodes.map { s -> s.copy(avgHRV=HrvSeries.summarize(windows,s.start.toInt(),s.end.toInt(),
                    context=if(s.episodeType=="nap") "nap" else "sleep").meanRMSSD) },
                hrvMeasurements=windows,hrvBaselines=windows.map { HrvSeries.baseline(it,inputs.hrvHistory+windows) },
                hrvNightSummary=summary)
        }
        // Final edit/context ownership controls physiology, including after a tombstone or moved boundary.
        val finalEpisodes=result.sleepSessions.map { session ->
            val eligibleHr=inputs.hr.filter { sample -> session.stages.any {
                SleepStageSemantics.isSleep(it) && sample.ts>=it.start && sample.ts<it.end
            } }
            session.copy(restingHR=com.noop.analytics.SleepStager.sessionRestingHR(session.start,session.end,eligibleHr))
        }
        result=result.copy(sleepSessions=finalEpisodes,daily=result.daily.copy(restingHr=finalEpisodes.mapNotNull { it.restingHR }.minOrNull()))
        val sleepEpochs=result.sleepSessions.filter { it.episodeType=="main_sleep" }.flatMap { it.stages }
            .filter(SleepStageSemantics::isSleep)
        val sleepingHr=inputs.hr.filter { sample -> sample.bpm>0 && sleepEpochs.any { sample.ts>=it.start && sample.ts<it.end } }
        val heartRateWindows = com.noop.analytics.HeartRateWindows.windows(dayLo,
            minOf(dayHi+1, nowSeconds), dayHr, dayGravity,
            wristOff + inputs.sleepContext.filter { it.kind == "off_body" }.map { it.start to it.end }).filter { window ->
            ownership == null || ownership.dayIntervals.any { window.start >= it.first && window.end <= it.second }
        }

        // Binary sleep evidence defines context; a deep-stage label is neither necessary nor sufficient.
        // Merge only touching observed sleep spans. Wake, unknown and off-body gaps remain excluded.
        val sleepSpans=mutableListOf<PhysiologyShadowRunner.Context>()
        for (epoch in result.sleepSessions.flatMap { it.stages }.filter(SleepStageSemantics::isSleep).sortedBy { it.start }) {
            val previous=sleepSpans.lastOrNull()
            if(previous!=null && epoch.start.toDouble()<=previous.end) {
                sleepSpans[sleepSpans.lastIndex]=previous.copy(end=maxOf(previous.end,epoch.end.toDouble()))
            } else sleepSpans.add(PhysiologyShadowRunner.Context(epoch.start.toDouble(),epoch.end.toDouble(),"qualified_sleep"))
        }
        val respiratoryContexts = RespirationContexts.withAwakeRest(sleepSpans, heartRateWindows,
            result.sleepSessions.flatMap { it.stages }, contexts)
        val shadow=physiology.evaluate(PhysiologyShadowRunner.Request(inputs.userId,java.util.UUID.fromString(inputs.deviceId),
            inputRevision,inputs.nightLo,inputs.nightHi+1,observations,respiratoryContexts),shadowBudget?.invoke())
        val mainEpisodes=result.sleepSessions.filter { it.episodeType=="main_sleep" }
        // Awake-rest results are retained separately and never enter the overnight statistic.
        val sleepRespiration = shadow.windows.filter { window -> sleepSpans.any {
            window.start >= it.start && window.end <= it.end
        } }
        val respirationSummary=if(mainEpisodes.isEmpty()) null else RespirationEstimator.summarize(sleepRespiration,
            mainEpisodes.minOf { it.start }.toDouble(),mainEpisodes.maxOf { it.end }.toDouble(),"qualified_sleep")
        // This v2 shadow snapshot must never relabel the older peak-counting heuristic as the repaired estimator.
        result=result.copy(daily=result.daily.copy(respRateBpm=respirationSummary?.median))

        return ServerScoreBundle(
            userId = inputs.userId,
            day = inputs.day,
            deviceId = inputs.deviceId,
            algorithmVersion = algorithmVersion,
            result = result,
            tzOffsetSeconds = inputs.tzOffsetSeconds,
            observedThrough = observedThrough?.let { java.time.Instant.ofEpochSecond(it) },
            sleepOverrides = inputs.sleepOverrides,
            computedAt = computedAt,
            overnightMeanHr = sleepingHr.takeIf { it.isNotEmpty() }?.map { it.bpm }?.average(),
            physiologyShadow = shadow,
            respirationSummary = respirationSummary,
            localDayEndExclusive = inputs.dayHi+1,
            calendarOwnership = ownership,
            heartRateWindows = heartRateWindows,
        )
    }
}

data class ServerScoreBundle(
    val userId: java.util.UUID,
    val day: String,
    val deviceId: String,
    val algorithmVersion: String,
    val result: DayResult,
    val tzOffsetSeconds: Long = 0,
    val computedAt: java.time.Instant = java.time.Instant.now(),
    val observedThrough: java.time.Instant? = null,
    val overnightMeanHr: Double? = null,
    val sleepOverrides: List<SleepBoundaryOverride> = emptyList(),
    val physiologyShadow: PhysiologyShadowRunner.Result? = null,
    val respirationSummary: RespirationEstimator.Summary? = null,
    val localDayEndExclusive: Long? = null,
    val calendarOwnership: com.frwhoop.scoring.db.CalendarOwnershipReader.Ownership? = null,
    val inputUnavailableReason: String? = null,
    val heartRateWindows: List<com.noop.analytics.HeartRateWindows.Measurement> = emptyList(),
)
