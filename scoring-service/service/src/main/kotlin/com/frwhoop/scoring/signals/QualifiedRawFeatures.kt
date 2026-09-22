package com.frwhoop.scoring.signals

import com.frwhoop.scoring.b2.B2ObjectStore
import com.noop.protocol.PpgHr
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import kotlin.math.abs
import kotlin.math.sqrt

/** Deterministic extraction only after independent capture metadata and actual object bytes agree. */
class QualifiedRawFeatures(private val objects: B2ObjectStore.GetClient) {
    data class Features(val values: Map<String, Double>, val samples: Int, val observedFraction: Double,
                        val maximumGap: Double, val evidenceHash: String, val quality: JSONObject, val observedThrough: Double)
    fun extract(proof: SensorAcquisitionProof.Verified, manifests: List<VerifiedRawObjectReader.Manifest>,
                user: UUID, device: UUID): Features {
        val kind = proof.receipt.kind
        require(kind in setOf("ppg", "imu")) { "unsupported_source" }
        val j = proof.json
        val channels = j.getJSONArray("channels")
        val rate = SensorAcquisitionProof.finite(j, "sample_rate_hz")
        require(j.getString("decoder_version") == VerifiedRawObjectReader.VERSION) { "decoder_mismatch" }
        if (kind == "ppg") {
            require(channels.toList() == listOf("ppg") && rate == 24.0 && j.getString("unit") == "adc_count" &&
                SensorAcquisitionProof.finite(j,"wavelength_nm") in 300.0..1500.0) { "channel_semantics_unverified" }
            require(j.getString("motion_status") == "aligned_quiet" &&
                j.getString("motion_evidence_sha256").matches(Regex("[a-f0-9]{64}"))) { "motion_alignment_unverified" }
        } else {
            require(channels.toList() == listOf("ax","ay","az","gx","gy","gz") && rate == 100.0 &&
                j.getString("accelerometer_unit") == "m_s2" && j.getString("gyroscope_unit") == "rad_s" &&
                j.getString("layout") == "axis_major_100") { "channel_semantics_unverified" }
            require(SensorAcquisitionProof.finite(j,"accelerometer_scale") > 0 &&
                SensorAcquisitionProof.finite(j,"gyroscope_scale") > 0) { "axis_units_unverified" }
        }
        val mappings = j.getJSONArray("records")
        require(mappings.length() in 1..300) { "raw_sample_budget_exceeded" }
        val ids = (0 until mappings.length()).map { UUID.fromString(mappings.getJSONObject(it).getString("object_id")) }.toSet()
        require(ids.size in 1..8) { "raw_object_budget_exceeded" }
        val selected = ids.map { id -> manifests.singleOrNull { it.id == id } ?: error("archive_pending") }
        require(selected.all { it.sourceId?.toString() == j.getJSONObject("cohort").getString("source_id") }) { "capture_source_mismatch" }
        require(selected.sumOf { it.uncompressedBytes.toLong() } <= 8 * 1024 * 1024 &&
            selected.sumOf { it.compressedBytes.toLong() } <= 8 * 1024 * 1024) { "raw_byte_budget_exceeded" }
        val decoded = selected.associate { manifest ->
            interrupted()
            manifest.id to VerifiedRawObjectReader(objects).read(manifest,user,device)
        }
        val byObject = decoded.mapValues { (_,value) -> value.records.associateBy { it.rowId } }
        val physical = mutableMapOf<Pair<Long, Long?>, Pair<Double, List<Int>>>()
        val records = (0 until mappings.length()).mapNotNull { index ->
            interrupted()
            val m = mappings.getJSONObject(index)
            val id = UUID.fromString(m.getString("object_id"))
            val source = decoded.getValue(id)
            require(source.digest == m.getString("object_sha256") && source.kind ==
                if(kind == "ppg") "ppg_i16_unqualified" else "imu_6axis_i16_unqualified") { "raw_identity_mismatch" }
            val row = byObject.getValue(id)[m.getLong("row_id")] ?: error("raw_record_missing")
            require(row.timestamp == m.getLong("sensor_second")) { "raw_record_identity_mismatch" }
            if (kind == "ppg") require(row.recordIndex != null && row.recordIndex == m.getLong("record_index")) { "raw_record_identity_mismatch" }
            val start = SensorAcquisitionProof.finite(m,"start_s")
            require(start >= proof.receipt.start && start + 1 <= proof.receipt.end && start % 1.0 == 0.0 &&
                row.columns.size == if(kind == "ppg") 24 else 600) { "sample_clock_mapping_unsupported" }
            val previous = physical.putIfAbsent(row.timestamp to row.recordIndex, start to row.columns)
            require(previous == null || previous == start to row.columns) { "conflicting_physical_record" }
            if (previous != null) null else start to row.columns
        }.sortedBy { it.first }
        require(records.zipWithNext().none { (a,b) -> a.first + 1 > b.first }) { "raw_time_overlap" }
        val coverage = records.size / 300.0
        var through = proof.receipt.start.toDouble(); var gap = 0.0
        records.forEach { (start,_) -> gap = maxOf(gap,start-through); through = start+1 }
        gap = maxOf(gap,proof.receipt.end-through)
        require(coverage >= .90 && gap <= 30) { "insufficient_observed_time" }
        val values = linkedMapOf<String,Double>()
        val quality = JSONObject().put("task",if(kind=="ppg") "heart_rate" else "motion")
        if (kind == "ppg") {
            val samples = records.flatMap { it.second }
            val clipped = samples.count { it == Short.MIN_VALUE.toInt() || it == Short.MAX_VALUE.toInt() }.toDouble()/samples.size
            quality.put("clipped_fraction",clipped).put("motion_status","aligned_quiet")
            require(clipped <= .01 && samples.maxOrNull()!! - samples.minOrNull()!! > 2) { "optical_clipping_or_flatline" }
            val sqi = JSONArray()
            val estimates = mutableListOf<PpgHr.Estimate>()
            for (start in proof.receipt.start until proof.receipt.end step 30) {
                interrupted()
                val epoch = records.filter { it.first >= start && it.first < start+30 }
                val candidates = PpgHr.estimate(epoch.flatMap { (ts,counts) -> counts.map { PpgHr.Sample(ts.toLong(),it) } })
                sqi.put(JSONObject().put("start",start).put("end",start+30).put("observed_seconds",epoch.size)
                    .put("accepted_estimates",candidates.size).put("reason",if(candidates.isEmpty()) "optical_quality_rejected" else JSONObject.NULL))
                estimates.addAll(candidates)
            }
            require(estimates.size >= 240) { "optical_quality_rejected" }
            values["heart_rate_bpm"] = median(estimates.map { it.bpm.toDouble() })
            quality.put("sqi_30s",sqi).put("accepted_estimates",estimates.size)
        } else {
            val scaleA = j.getDouble("accelerometer_scale"); val scaleG = j.getDouble("gyroscope_scale")
            val acceleration = records.flatMap { (_,row) -> (0 until 100).map { i -> sqrt((0..2).sumOf { a -> (row[a*100+i]*scaleA)*(row[a*100+i]*scaleA) }) } }
            val gyro = records.flatMap { (_,row) -> (0 until 100).map { i -> (3..5).sumOf { a -> (row[a*100+i]*scaleG)*(row[a*100+i]*scaleG) } } }
            values["acceleration_magnitude_m_s2"] = median(acceleration)
            values["acceleration_mad_m_s2"] = median(acceleration.map { abs(it-values.getValue("acceleration_magnitude_m_s2")) })
            values["gyroscope_rms_rad_s"] = sqrt(gyro.average())
        }
        require(values.values.all { it.isFinite() }) { "nonfinite_result" }
        return Features(values,records.size*rate.toInt(),coverage,gap,proof.receipt.digest,quality,through)
    }
    companion object {
        const val VERSION = "qualified-raw-features-1"
        fun median(values: List<Double>): Double = values.sorted().let { (it[(it.size-1)/2]+it[it.size/2])/2 }
        private fun interrupted() { if(Thread.currentThread().isInterrupted) throw InterruptedException("raw_task_cancelled") }
    }
}
