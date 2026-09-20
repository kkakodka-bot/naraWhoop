package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.b2.B2ObjectStore
import com.noop.analytics.DetectedSleep
import com.noop.analytics.SleepStageTotals
import com.noop.analytics.StageSegment
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.UUID

/** The single mapping used by publication, readback and the immutable derived archive. */
object CanonicalScorePayload {
    const val SCHEMA_VERSION = 2
    const val ALGORITHM_VERSION = "frwhoop-physiology-2"

    fun build(bundle: ServerScoreBundle, computedAt: Instant = bundle.computedAt): JSONObject {
        val sessions = bundle.result.sleepSessions.sortedWith(compareBy({ it.start }, { it.end }))
        require(sessions.all { it.end > it.start && it.end - it.start <= 172800 }) { "invalid sleep bounds" }
        require(sessions.zipWithNext().all { (a,b) -> a.end <= b.start }) { "overlapping sleep episodes" }
        for (stage in sessions.flatMap { it.stages }) {
            require(stage.end>stage.start) { "invalid stage bounds" }
            val probabilities=listOf(stage.pWake,stage.pLight,stage.pDeep,stage.pRem)
            require((probabilities.all { it==null } || probabilities.all { it!=null } &&
                kotlin.math.abs(probabilities.filterNotNull().sum()-1.0)<=1e-6) &&
                (probabilities+listOf(stage.sleepProbability,stage.evidenceCoverage)).filterNotNull().all { it.isFinite() && it in 0.0..1.0 }) {
                "invalid stage probability or coverage contract"
            }
            require(stage.probabilitiesCalibrated!=true || probabilities.all { it!=null }) { "calibration requires probability vector" }
        }
        val candidates = sessions.indices.filter { sessions[it].hasKnownState }.ifEmpty { sessions.indices.toList() }
        val explicitMain=sessions.indices.filter { sessions[it].episodeType=="main_sleep" }.toSet()
        val mainIndices = if(sessions.any { it.episodeType!=null }) explicitMain else SleepStageTotals.mainNightGroupIndices(
            candidates.map { SleepStageTotals.NightBlock(sessions[it].start, sessions[it].end) }, bundle.tzOffsetSeconds,
        ).orEmpty().map { candidates[it] }.toSet()
        val groupId = if (mainIndices.isEmpty()) null else stableId(bundle, "main:${bundle.day}")
        val nights = JSONArray()
        val main = mutableListOf<JSONObject>()
        for ((index, session) in sessions.withIndex()) {
            val item = session(session, bundle, index in mainIndices, groupId, computedAt)
            nights.put(item)
            if (index in mainIndices) main.add(item)
        }
        val daily = JSONObject()
            .put("day", bundle.day)
            .put("source_device_id", bundle.deviceId)
            .put("computed_at", computedAt.toString())
            .putNullable("hrv_rmssd_ms", bundle.result.daily.avgHrv)
            .putNullable("hrv_sdnn_ms", bundle.result.daily.avgSdnn)
            .putNullable("resting_hr_bpm", bundle.result.daily.restingHr)
            .putNullable("overnight_hr_bpm", bundle.overnightMeanHr)
            .put("heart_rate_windows", JSONArray(bundle.heartRateWindows.map { window -> JSONObject()
                .put("start",window.start).put("end",window.end)
                .put("device_id",bundle.deviceId).put("user_id",bundle.userId.toString())
                .put("method_version",com.noop.analytics.HeartRateWindows.VERSION)
                .put("calibration_status","not_reference_validated")
                .put("statistic","sampled_hr_and_low_motion_mean_not_daily_resting_baseline")
                .putNullable("mean_bpm",window.meanBpm).putNullable("low_motion_bpm",window.lowMotionBpm)
                .put("sample_fraction",window.sampleFraction).put("low_motion_sample_fraction",window.lowMotionSampleFraction)
                .put("moving_seconds",window.movingSeconds)
                .put("motion_observed_fraction",window.motionObservedSeconds / 300.0)
                .putNullable("reason",window.reason).putNullable("low_motion_reason",window.lowMotionReason) }))
            .putNullable("recovery", bundle.result.daily.recovery ?: bundle.result.recovery)
            .putNullable("strain", bundle.result.daily.strain ?: bundle.result.strain)
            .putNullable("spo2_pct", bundle.result.daily.spo2Pct)
            .putNullable("skin_temp_c", bundle.result.daily.skinTempC)
            .putNullable("skin_temp_dev_c", bundle.result.daily.skinTempDevC)
            .putNullable("resp_rate_bpm", bundle.respirationSummary?.median)
            .putNullable("respiration_summary", bundle.respirationSummary?.let { summary -> JSONObject()
                .putNullable("median_bpm",summary.median).putNullable("mean_bpm",summary.mean)
                .put("distribution_bpm",JSONArray(summary.distributionBpm))
                .put("distribution_kind","sorted_accepted_window_estimates")
                .put("accepted_seconds",summary.acceptedSeconds).put("coverage",summary.coverage)
                .put("accepted_windows",summary.acceptedWindows).put("total_windows",summary.totalWindows)
                .put("context",if (summary.context == "qualified_sleep") "main_sleep" else summary.context)
                .put("measurement_context",summary.context).put("context_provenance","estimated_binary_sleep")
                .put("method_version",com.noop.analytics.RespirationEstimator.VERSION)
                .put("preprocess_version",com.noop.analytics.RespirationEstimator.PREPROCESS_VERSION)
                .put("calibration_status","not_reference_validated") })
            .putNullable("respiration_unavailable_reason",if(bundle.respirationSummary?.median!=null) null else
                if(bundle.respirationSummary==null) "sleep_context_unavailable" else "no_quality_eligible_windows")
            .putNullable("hrv_summary",bundle.result.hrvNightSummary?.let(HrvPayloadCodec::summary))
            .putNullable("main_sleep_group_id", groupId)
            .put("opportunity_kind", "estimated_sleep_opportunity")
        val keys = listOf("asleep_min", "awake_min", "light_min", "deep_min", "rem_min",
            "sleep_unstaged_min", "state_unknown_min", "off_body_min", "in_bed_min")
        for (key in keys) {
            val outputKey = when (key) {
                "asleep_min" -> "sleep_total_min"
                "sleep_unstaged_min", "state_unknown_min", "off_body_min" -> key
                else -> "sleep_$key"
            }
            daily.putNullable(outputKey, if (main.isEmpty()) null else main.sumOf { it.optDouble(key,0.0) })
        }
        // Evidence-bearing grouped interruptions are already explicit epochs inside opportunity
        // fragments. Only remaining unrepresented gaps have no established state.
        val lo = main.minOfOrNull { it.getLong("start") }
        val hi = main.maxOfOrNull { it.getLong("end") }
        val fragmentMinutes = main.sumOf { it.getDouble("in_bed_min") }
        val opportunityMinutes = if (lo != null && hi != null) (hi - lo) / 60.0 else null
        if (opportunityMinutes != null) {
            daily.put("sleep_in_bed_min", opportunityMinutes)
            daily.put("state_unknown_min", main.sumOf { it.getDouble("state_unknown_min") } +
                (opportunityMinutes - fragmentMinutes).coerceAtLeast(0.0))
        }
        daily.putNullable("sleep_efficiency", opportunityMinutes?.takeIf { it > 0 }?.let {
            main.sumOf { n -> n.optDouble("asleep_min",0.0) } / it
        })
        if (main.none { it.getBoolean("measurement_available") }) {
            for (key in listOf("sleep_total_min","sleep_awake_min","sleep_light_min","sleep_deep_min",
                "sleep_rem_min","sleep_unstaged_min","sleep_efficiency")) daily.put(key,JSONObject.NULL)
        }
        daily.putNullable("sleep_onset_at", lo?.let { Instant.ofEpochSecond(it).toString() })
        daily.putNullable("wake_onset_at", hi?.let { Instant.ofEpochSecond(it).toString() })
        daily.put("provenance", JSONObject()
            .put("scorer", "frwhoop-scoring-service")
            .put("scope", "hrv_sleep_respiration")
            .put("computation_mode", "retrospective")
            .put("calibration_status", "not_reference_validated"))
        daily.put("input_context",JSONObject().put("habitual_timing_status","unavailable_no_frozen_personal_timing_model")
            .put("sleep_opportunity_detector",com.noop.analytics.SleepOpportunityDetector.VERSION)
            .put("sleep_policy_status","engineering_shadow_not_reference_validated")
            .put("respiration_auxiliary_channel_status","semantics_unverified_not_used_as_reference_waveform"))
        return JSONObject()
            .put("schema_version", SCHEMA_VERSION)
            .put("algorithm_version", bundle.algorithmVersion)
            .put("user_id", bundle.userId.toString())
            .put("device_id", bundle.deviceId)
            .put("day", bundle.day)
            .put("computed_at", computedAt.toString())
            .putNullable("observed_through", bundle.observedThrough?.toString())
            .put("computation_mode", "retrospective")
            .put("publication_status", "provisional")
            .put("publication_status_reason", "acquisition_completeness_not_attested")
            .put("period_closed", bundle.localDayEndExclusive?.let { computedAt.epochSecond>=it } ?: false)
            .putNullable("unavailable_reason",bundle.inputUnavailableReason)
            .putNullable("calendar_ownership",bundle.calendarOwnership?.let { calendar -> JSONObject()
                .put("timezone_ids",JSONArray(calendar.timezoneIds))
                .put("day_intervals",JSONArray(calendar.dayIntervals.map { listOf(it.first,it.second) }))
                .put("context_intervals",JSONArray(calendar.contextIntervals.map { listOf(it.first,it.second) }))
                .putNullable("unavailable_reason",calendar.unavailableReason) })
            .put("archive_status", "pending")
            .put("daily", daily)
            .put("nights", nights)
            .putNullable("shadow",bundle.physiologyShadow?.json())
            .put("sleep_overrides",JSONArray(bundle.sleepOverrides.map { edit -> JSONObject()
                .put("id",edit.id).put("device_id",bundle.deviceId).put("revision",edit.revision)
                .put("original_start",edit.originalStart).put("original_end",edit.originalEnd)
                .put("start",edit.start).put("end",edit.end).put("tombstone",edit.tombstone)
                .put("boundary_provenance",edit.provenance) }))
            .put("measurements", JSONArray(bundle.result.hrvMeasurements.mapIndexed { index,window ->
                HrvPayloadCodec.encode(window,bundle.userId.toString(),bundle.deviceId,bundle.result.hrvBaselines.getOrNull(index))
            }))
    }

    private fun session(
        session: DetectedSleep, bundle: ServerScoreBundle, isMain: Boolean,
        groupId: String?, computedAt: Instant,
    ): JSONObject {
        val stages = JSONArray()
        val duration = mutableMapOf<String, Long>()
        var estimatedSleepOnset: Long? = null
        var finalKnownSleep: Long? = null
        val epochBounds = generateSequence(Math.floorDiv(session.start,30)*30+30) { it+30 }
            .takeWhile { it<session.end }.toList()
        val boundaries = (session.stages.flatMap { listOf(it.start, it.end) } + epochBounds +
            listOf(session.start, session.end)).filter { it in session.start..session.end }.distinct().sorted()
        for ((start, end) in boundaries.zipWithNext()) {
            val covering = session.stages.filter { it.start <= start && it.end >= end }
            val names = covering.map { normalizeStage(it) }.distinct()
            val state = if (names.size == 1) names.single() else "state_unknown"
            if(state in listOf("light","deep","rem","sleep_unstaged")) {
                if(estimatedSleepOnset==null) estimatedSleepOnset=start
                finalKnownSleep=end
            }
            val metadata = covering.singleOrNull()
            val reason = when {
                covering.isEmpty() -> "missing_features"
                names.size > 1 -> "conflicting_segments"
                state == "state_unknown" -> metadata?.abstentionReason ?: "state_unavailable"
                state == "sleep_unstaged" -> "stage_unavailable"
                else -> null
            }
            duration[state] = (duration[state] ?: 0) + end - start
            stages.put(JSONObject().put("start", start).put("end", end)
                .put("stage", if (state in listOf("state_unknown", "sleep_unstaged", "off_body")) "unknown" else state)
                .put("state",when(state) {
                    "light","deep","rem" -> "sleep"
                    "wake" -> "awake"
                    else -> state
                }).putNullable("reason", reason)
                .put("calibration_status", if (metadata?.probabilitiesCalibrated == true) "calibrated" else "uncalibrated")
                .putNullable("p_sleep",metadata?.sleepProbability)
                .putNullable("evidence_coverage",metadata?.evidenceCoverage)
                .putNullable("p_wake",metadata?.pWake).putNullable("p_light",metadata?.pLight)
                .putNullable("p_deep",metadata?.pDeep).putNullable("p_rem",metadata?.pRem)
                .putNullable("algorithm_version",metadata?.algorithmVersion)
                .put("computation_mode",metadata?.computationMode ?: "retrospective"))
        }
        fun minutes(state: String) = (duration[state] ?: 0) / 60.0
        val asleep = listOf("light", "deep", "rem", "sleep_unstaged").sumOf { minutes(it) }
        val span = (session.end - session.start) / 60.0
        val available = (asleep+minutes("wake"))>0
        val episodeType = when {
            asleep == 0.0 -> "uncertain"
            isMain -> "main_sleep"
            session.episodeType in listOf("nap", "other_sleep") -> session.episodeType!!
            span <= 180.0 -> "nap"
            else -> "other_sleep"
        }
        return JSONObject()
            .put("id", stableId(bundle, "episode:${session.start}:${session.end}"))
            .put("period_day", bundle.day).put("device_id", bundle.deviceId)
            .put("start", session.start).put("end", session.end)
            .put("start_at", Instant.ofEpochSecond(session.start).toString())
            .put("end_at", Instant.ofEpochSecond(session.end).toString())
            .putNullable("start_timezone_id",bundle.calendarOwnership?.timezoneAt(session.start))
            .putNullable("end_timezone_id",bundle.calendarOwnership?.timezoneAt(session.end,closingBound=true))
            .put("timezone_policy","event_time_half_open_bounds")
            .put("episode_type", episodeType).put("is_nap", episodeType == "nap")
            .putNullable("main_sleep_group_id", if (isMain) groupId else null)
            .put("boundary_provenance", session.boundaryProvenance ?: "algorithm_estimated")
            .putNullable("estimated_sleep_onset_at",estimatedSleepOnset?.let { Instant.ofEpochSecond(it).toString() })
            .putNullable("final_known_sleep_at",finalKnownSleep?.let { Instant.ofEpochSecond(it).toString() })
            .put("opportunity_kind", session.denominatorKind ?: "estimated_sleep_opportunity")
            .put("manual_edit", session.boundaryProvenance?.startsWith("user_") == true).put("tombstone", false)
            .put("measurement_available",available)
            .put("in_bed_min", span).putNullable("asleep_min",if(available) asleep else null)
            .put("awake_min", minutes("wake")).put("light_min", minutes("light"))
            .put("deep_min", minutes("deep")).put("rem_min", minutes("rem"))
            .put("sleep_unstaged_min", minutes("sleep_unstaged"))
            .put("state_unknown_min", minutes("state_unknown"))
            .put("off_body_min", minutes("off_body"))
            .putNullable("efficiency",if(available) asleep / span else null)
            .put("state_coverage", 1.0 - (minutes("state_unknown") + minutes("off_body")) / span)
            .putNullable("resting_hr_bpm", session.restingHR)
            .putNullable("overnight_hr_bpm", null)
            .putNullable("hrv_rmssd_ms", session.avgHRV)
            .put("stages", stages).put("hypnogram", stages)
            .put("computed_at", computedAt.toString())
    }

    private fun normalizeStage(segment: StageSegment): String {
        if (segment.state in listOf("state_unknown","off_body")) return segment.state!!
        if (segment.state=="sleep_unstaged") return "sleep_unstaged"
        if (segment.state=="awake") return "wake"
        return when (segment.stage) {
        "awake" -> "wake"
        "wake", "light", "deep", "rem", "sleep_unstaged" -> segment.stage
        else -> "state_unknown"
        }
    }

    private fun stableId(bundle: ServerScoreBundle, key: String): String =
        UUID.nameUUIDFromBytes("${bundle.userId}/${bundle.deviceId}/${bundle.algorithmVersion}/$key"
            .toByteArray(Charsets.UTF_8)).toString()

    private fun JSONObject.putNullable(key: String, value: Any?): JSONObject = put(key, value ?: JSONObject.NULL)

    /** Sorted object keys make payload hashing independent of JSONObject's iteration order. */
    fun encode(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keySet().sorted().joinToString(",", "{", "}") { key ->
            JSONObject.quote(key) + ":" + encode(value.get(key))
        }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { encode(value.get(it)) }
        is String -> JSONObject.quote(value)
        is Number -> JSONObject.numberToString(value)
        is Boolean -> value.toString()
        else -> error("unsupported canonical JSON type")
    }

    fun hash(payload: JSONObject): String = B2ObjectStore.sha256Hex(encode(payload).toByteArray(Charsets.UTF_8))
}
