package com.frwhoop.scoring.scoring

import com.noop.analytics.HrvSeries
import com.noop.analytics.HrvWindow
import com.noop.analytics.PhysiologyQuality
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Versioned scalar-window contract shared by result archives, readback and baseline history. */
object HrvPayloadCodec {
    fun encode(w: HrvWindow.Result,owner: String,device: String,baseline: HrvSeries.Baseline? = null): JSONObject {
        require(w.userId==null || w.userId==owner) { "HRV owner mismatch" }
        require(w.deviceId==null || w.deviceId==device) { "HRV device mismatch" }
        val identity="$owner/$device/${w.source}/${w.modality}/${w.algorithmVersion}/${w.qualityVersion}/${w.start}/${w.end}"
        return obj(
            "measurement_schema_version" to 1,"feature" to "hrv",
            "window_id" to UUID.nameUUIDFromBytes(identity.toByteArray(Charsets.UTF_8)).toString(),
            "user_id" to owner,"device_id" to device,"device_firmware" to w.deviceFirmware,
            "start" to w.start,"end" to w.end,"duration_seconds" to w.end-w.start,
            "source" to w.source,"modality" to w.modality,"metric" to w.metric,"unit" to w.unit,
            "input_revision" to w.inputRevision,"computation_mode" to w.computationMode,
            "algorithm_version" to w.algorithmVersion,"quality_version" to w.qualityVersion,
            "preprocess_version" to "original-beat-continuity-v2","checkpoint_hash" to null,
            "decoder_versions" to JSONArray(w.decoderVersions),"clock_versions" to JSONArray(w.clockVersions),
            "observed_rmssd_ms" to w.observedRMSSD,"corrected_rmssd_ms" to w.correctedRMSSD,
            "sdnn_ms" to w.sdnn,"research_observed_rmssd_ms" to w.researchObservedRMSSD,
            "original_ids" to JSONArray(w.originalIds),"pair_mask" to JSONArray(w.pairMask),
            "corrected_pair_mask" to JSONArray(w.correctedPairMask),"pair_reasons" to JSONArray(w.pairReasons),
            "observed_time_fraction" to w.observedTimeFraction,
            "observed_spans" to JSONArray(w.observedSpans.map { obj("start" to it.start,"end" to it.end) }),
            "accepted_duration_seconds" to w.acceptedDurationSeconds,"valid_interval_fraction" to w.validIntervalFraction,
            "valid_pair_count" to w.validPairCount,"corrected_pair_count" to w.correctedPairCount,
            "corrected_method_version" to w.correctedMethodVersion,"correction_passes" to JSONArray(w.correctionPasses),
            "maximum_gap_seconds" to w.maximumGapSeconds,"correction_fraction" to w.correctionFraction,
            "correction_event_count" to w.correctionEventCount,"inserted_event_count" to w.insertedEventCount,
            "deleted_event_count" to w.deletedEventCount,"measurement_valid" to w.measurementValid,
            "reason" to w.reason,"context" to w.context,"baseline_eligible" to w.baselineEligible,
            "baseline_reason" to w.baselineReason,"timing_precision_seconds" to w.timingPrecisionSeconds,
            "calibration_status" to "engineering_shadow",
            "baseline" to baseline?.let { obj("version" to it.version,"window_days" to it.windowDays,
                "effective_sample_count" to it.effectiveSampleCount,"excluded_zero_count" to it.excludedZeroCount,
                "log_median" to it.logMedian,"log_mad" to it.logMAD,"log_deviation" to it.logDeviation,
                "robust_z" to it.robustZ,"reason" to it.reason) })
    }

    fun summary(s: HrvSeries.Summary): JSONObject = obj("context" to s.context,"mean_rmssd_ms" to s.meanRMSSD,
        "median_rmssd_ms" to s.medianRMSSD,"duration_weighted_mean_rmssd_ms" to s.durationWeightedMeanRMSSD,
        "distribution_ms" to JSONArray(s.distribution),"eligible_window_count" to s.eligibleWindowCount,
        "excluded_window_count" to s.excludedWindowCount,"accepted_duration_seconds" to s.acceptedDurationSeconds,
        "opportunity_seconds" to s.opportunitySeconds,"sampling_coverage" to s.samplingCoverage,
        "segment_coverage" to JSONArray(s.segmentCoverage),"representative" to s.representative,
        "reason" to s.reason,"version" to s.version)

    /** Unknown/old schemas never become a fabricated valid baseline. Strict fields are intentional. */
    fun decode(o: JSONObject): HrvWindow.Result {
        require(o.getInt("measurement_schema_version")==1 && o.getString("feature")=="hrv")
        fun s(k:String)=if(o.isNull(k)) null else o.getString(k)
        fun d(k:String)=if(o.isNull(k)) null else o.getDouble(k).also { require(it.isFinite()) }
        fun strings(k:String)=o.getJSONArray(k).let { a -> (0 until a.length()).map { a.getString(it) } }
        fun bools(k:String)=o.getJSONArray(k).let { a -> (0 until a.length()).map { a.getBoolean(it) } }
        val spans=o.getJSONArray("observed_spans").let { a -> (0 until a.length()).map { i ->
            a.getJSONObject(i).let { PhysiologyQuality.Span(it.getDouble("start"),it.getDouble("end")) } } }
        val w=HrvWindow.Result(
            start=o.getInt("start"),end=o.getInt("end"),userId=s("user_id"),deviceId=s("device_id"),
            deviceFirmware=s("device_firmware"),source=s("source"),modality=s("modality"),
            inputRevision=o.getString("input_revision"),computationMode=o.getString("computation_mode"),
            algorithmVersion=o.getString("algorithm_version"),qualityVersion=o.getString("quality_version"),
            metric=o.getString("metric"),unit=o.getString("unit"),observedRMSSD=d("observed_rmssd_ms"),
            correctedRMSSD=d("corrected_rmssd_ms"),sdnn=d("sdnn_ms"),researchObservedRMSSD=d("research_observed_rmssd_ms"),
            originalIds=strings("original_ids"),pairMask=bools("pair_mask"),correctedPairMask=bools("corrected_pair_mask"),
            pairReasons=o.getJSONArray("pair_reasons").let { a -> (0 until a.length()).map { if(a.isNull(it)) null else a.getString(it) } },
            observedTimeFraction=o.getDouble("observed_time_fraction"),observedSpans=spans,
            acceptedDurationSeconds=o.getDouble("accepted_duration_seconds"),validIntervalFraction=o.getDouble("valid_interval_fraction"),
            validPairCount=o.getInt("valid_pair_count"),correctedPairCount=o.getInt("corrected_pair_count"),
            correctedMethodVersion=s("corrected_method_version"),correctionPasses=strings("correction_passes"),
            maximumGapSeconds=o.getDouble("maximum_gap_seconds"),correctionFraction=o.getDouble("correction_fraction"),
            correctionEventCount=o.getInt("correction_event_count"),insertedEventCount=o.getInt("inserted_event_count"),
            deletedEventCount=o.getInt("deleted_event_count"),measurementValid=o.getBoolean("measurement_valid"),
            reason=s("reason"),context=o.getString("context"),baselineEligible=o.getBoolean("baseline_eligible"),
            baselineReason=s("baseline_reason"),timingPrecisionSeconds=d("timing_precision_seconds"),
            decoderVersions=strings("decoder_versions"),clockVersions=strings("clock_versions"))
        require(w.end.toLong()-w.start==300L && HrvWindow.alignedStart(w.start)==w.start)
        require(w.observedTimeFraction in 0.0..1.0 && w.validIntervalFraction in 0.0..1.0 && w.correctionFraction in 0.0..1.0)
        require(w.acceptedDurationSeconds in 0.0..300.0 && w.maximumGapSeconds in 0.0..300.0)
        require(listOf(w.pairMask.size,w.correctedPairMask.size,w.pairReasons.size).all { it==w.originalIds.size })
        require(!w.measurementValid || (w.reason==null && w.observedRMSSD?.let { it>=0 }==true))
        require(!w.baselineEligible || w.measurementValid)
        return w
    }

    private fun obj(vararg fields: Pair<String,Any?>)=JSONObject().apply {
        fields.forEach { (k,v) -> put(k,v?:JSONObject.NULL) }
    }
}
