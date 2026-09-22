package com.frwhoop.scoring.signals

import com.frwhoop.scoring.db.SignalSampleReader
import com.noop.analytics.HrvWindow
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.UUID
import kotlin.math.abs

object SensorWindows {
    const val VERSION = "sensor-windows-1"
    fun build(inputs: SignalSampleReader.DayInputs, revision: String, computed: Instant,
              hrv: List<HrvWindow.Result>, raw: Map<String,BoundedRawFeatureLane.Outcome>): List<JSONObject> {
        val end = minOf(inputs.dayHi+1,computed.epochSecond)
        val first = Math.floorDiv(inputs.dayLo+299,300)*300
        require(end-first <= 76*3600) { "sensor_window_budget_exceeded" }
        val output = mutableListOf<JSONObject>()
        val offBody=com.noop.analytics.AnalyticsEngine.offWristIntervals(inputs.events,inputs.nightHi+1) +
            inputs.sleepContext.filter { it.kind=="off_body" }.map { it.start to it.end }
        val byStart = hrv.associateBy { it.start.toLong() }
        val proofs = inputs.acquisitionEvidence.receipts.groupBy { it.start to it.kind }
        for(start in first until end step 300) {
            if(start+300>end) break
            if(inputs.calendarOwnership?.dayIntervals?.none { start>=it.first && start+300<=it.second } == true) continue
            val h = byStart[start] ?: HrvWindow.measure(start.toInt(),inputs.hrvObservations.orEmpty(),inputRevision=revision)
            val timingProofs = proofs[start to "beat_timing"].orEmpty().mapNotNull { receipt ->
                runCatching { SensorAcquisitionProof.verify(receipt,inputs.userId,UUID.fromString(inputs.deviceId)) }
                    .getOrNull()?.takeIf { h.source == "whoop5_history:${it.source}" }
            }
            val hr = base(inputs,revision,computed,start,"hrv",h.modality ?: "unknown","ms")
                .put("values",JSONObject().put("observed_rmssd_ms",h.observedRMSSD ?: JSONObject.NULL)
                    .put("corrected_rmssd_ms",h.correctedRMSSD ?: JSONObject.NULL).put("sdnn_5m_ms",h.sdnn ?: JSONObject.NULL))
                .put("quality",JSONObject().put("accepted_pairs",h.validPairCount).put("correction_fraction",h.correctionFraction)
                    .put("quality_version",h.qualityVersion).put("unavailable_signals",JSONArray(h.unavailableQualitySignals)))
                .put("source",h.source ?: JSONObject.NULL).put("maximum_gap_seconds",h.maximumGapSeconds)
                .put("observed_fraction",if(h.timingPrecisionSeconds == null) JSONObject.NULL else h.observedTimeFraction)
                .put("accepted_duration_seconds",h.acceptedDurationSeconds)
                .put("decoder_versions",JSONArray(h.decoderVersions)).put("clock_versions",JSONArray(h.clockVersions))
                .put("quality_policy_version",h.qualityVersion)
                .put("acquisition_contract_sha256s",JSONArray(timingProofs.map { it.receipt.digest }))
                .put("capture_cohorts",JSONArray(timingProofs.map { it.json.getJSONObject("cohort") }))
                .put("observed_through",h.observedSpans.maxOfOrNull { it.end } ?: JSONObject.NULL)
            outcome(hr,h.measurementValid,h.reason ?: inputs.acquisitionEvidence.reason); output += hr
            for(kind in listOf("ppg","imu","temperature")) {
                val candidates = proofs[start to kind].orEmpty()
                val receipt = candidates.singleOrNull()
                val unit = when(kind) { "ppg"->"bpm"; "temperature"->"degC_skin"; else->"m_s2_and_rad_s" }
                val item = base(inputs,revision,computed,start,kind,kind,unit)
                var reason = inputs.acquisitionEvidence.reason ?: if(candidates.size>1) "conflicting_acquisition_proofs" else "capture_metadata_unqualified"
                if(receipt != null) {
                    item.put("acquisition_contract_sha256",receipt.digest)
                    try {
                        val proof = SensorAcquisitionProof.verify(receipt,inputs.userId,UUID.fromString(inputs.deviceId))
                        item.put("source",proof.source).put("capture_cohort",proof.json.getJSONObject("cohort"))
                            .put("clock_uncertainty_seconds",proof.uncertainty)
                        if(kind in setOf("ppg", "temperature")) {
                            require(offBody.none { it.first<start+300 && it.second>start }) { "off_body" }
                        }
                        if(kind=="temperature") {
                            val rows = inputs.skinTemp.filter { it.ts>=start && it.ts<start+300 }
                            item.put("observed_sample_count",rows.size)
                            require(proof.json.getString("unit") == "celsius_centi" && proof.json.getString("wear_status") == "on_body" &&
                                proof.json.getJSONObject("cohort").getString("hardware") in setOf("WHOOP5","WHOOP_MG")) { "temperature_source_unqualified" }
                            val identity = rows.joinToString(";") { "${it.ts}:${it.raw}:${it.aux1Raw}:${it.aux2Raw}" }
                            require(rows.all { inputs.temperatureSources[it.ts] == proof.json.getJSONObject("cohort").getString("source_id") }) { "capture_source_mismatch" }
                            require(SensorAcquisitionProof.sha256(identity.toByteArray()) == proof.json.getString("scalar_sha256")) { "temperature_input_mismatch" }
                            require(rows.isNotEmpty() && rows.map { it.ts }.distinct().size==rows.size) { "temperature_missing_or_conflicting" }
                            val samples=rows.map { it.raw/100.0 }; require(samples.all { it in 10.0..50.0 }) { "temperature_quality_rejected" }
                            val median=QualifiedRawFeatures.median(samples)
                            item.put("values",JSONObject().put("median_skin_c",median).put("mad_skin_c",QualifiedRawFeatures.median(samples.map { abs(it-median) })))
                                .put("quality",JSONObject().put("coverage_kind","point_observations_not_continuous_duration"))
                                .put("observed_through",rows.maxOf { it.ts })
                            reason=""
                        } else {
                            val value=raw[receipt.digest]
                            if(value?.features!=null) {
                                item.put("values",JSONObject(value.features.values)).put("quality",value.features.quality)
                                    .put("observed_fraction",value.features.observedFraction).put("maximum_gap_seconds",value.features.maximumGap)
                                    .put("observed_sample_count",value.features.samples)
                                    .put("observed_through",value.features.observedThrough).put("decoder_version",VerifiedRawObjectReader.VERSION)
                                reason=""
                            } else reason=value?.reason ?: "archive_pending"
                        }
                    } catch(e: Exception) { reason=BoundedRawFeatureLane.safeReason(e) }
                }
                outcome(item,reason.isEmpty(),reason.takeIf { it.isNotEmpty() }); output+=item
            }
            if(start%900L==0L && start+900<=end && inputs.calendarOwnership?.dayIntervals?.none {
                start>=it.first && start+900<=it.second } != true) output+=base(inputs,revision,computed,start,"spo2","unknown","percent",900)
                .put("measurement_status","blocked").put("reason","supported_calibrated_source_not_validated")
        }
        return output
    }
    private fun base(i: SignalSampleReader.DayInputs,r: String,c: Instant,s: Long,kind: String,modality: String,unit: String,duration: Long=300) = JSONObject()
        .put("schema_version",1).put("algorithm_version",VERSION).put("user_id",i.userId.toString()).put("device_id",i.deviceId)
        .put("window_id",UUID.nameUUIDFromBytes("${i.userId}/${i.deviceId}/$kind/$s/$duration/$VERSION".toByteArray()).toString())
        .put("kind",kind).put("start",s).put("end",s+duration).put("duration_seconds",duration).put("stride_seconds",duration)
        .put("input_revision",r).put("result_revision",r).put("computed_at",c.toString()).put("publication_status","shadow")
        .put("computation_mode","retrospective").put("provenance","vps_estimate").put("modality",modality).put("unit",unit)
        .put("values",JSONObject.NULL).put("observed_fraction",JSONObject.NULL).put("maximum_gap_seconds",JSONObject.NULL)
        .put("quality",JSONObject()).put("calibration_status","not_reference_validated")
        .put("freshness_status","snapshot").put("source",JSONObject.NULL)
        .put("observed_through",JSONObject.NULL).put("published_at",JSONObject.NULL)
        .put("quality_policy_version","engineering-sensor-quality-1").put("preprocess_version",QualifiedRawFeatures.VERSION)
        .put("acquisition_reason",i.acquisitionEvidence.reason ?: JSONObject.NULL)
    private fun outcome(j: JSONObject,available: Boolean,reason: String?) {
        j.put("measurement_status",if(available) "available" else "unavailable").put("reason",reason ?: JSONObject.NULL)
    }
}
