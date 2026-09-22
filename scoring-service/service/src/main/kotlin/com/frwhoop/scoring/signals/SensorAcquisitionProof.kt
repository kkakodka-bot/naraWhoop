package com.frwhoop.scoring.signals

import com.frwhoop.scoring.db.RrPacketObservationBridge
import com.noop.analytics.PhysiologyQuality
import com.noop.protocol.RrPacketProvenance
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID
import kotlin.math.abs

/** Operator-reviewed capture evidence. A digest authenticates bytes, not physiological accuracy. */
object SensorAcquisitionProof {
    const val VERSION = "capture-evidence-1"
    const val MAX_BYTES = 2 * 1024 * 1024
    data class Receipt(val kind: String, val start: Long, val end: Long, val digest: String, val bytes: ByteArray)
    data class Verified(val receipt: Receipt, val json: JSONObject, val source: String, val firmware: String,
                        val clock: String, val uncertainty: Double)

    fun verify(receipt: Receipt, user: UUID, device: UUID): Verified {
        require(receipt.bytes.size in 1..MAX_BYTES && sha256(receipt.bytes) == receipt.digest) { "capture_digest_mismatch" }
        require(receipt.start % 300L == 0L && receipt.end - receipt.start == 300L) { "capture_window_invalid" }
        val j = JSONObject(receipt.bytes.toString(Charsets.UTF_8))
        require(j.getInt("schema_version") == 1 && j.getString("qualification") == "verified_capture_metadata") { "capture_unqualified" }
        require(j.getString("user_id") == user.toString() && j.getString("device_id") == device.toString() &&
            j.getString("kind") == receipt.kind && j.getLong("start") == receipt.start && j.getLong("end") == receipt.end) { "capture_scope_mismatch" }
        for (key in listOf("capture_evidence_sha256", "independent_clock_evidence_sha256", "reference_capture_sha256"))
            require(j.getString(key).matches(Regex("[a-f0-9]{64}"))) { "capture_reference_missing" }
        val cohort = j.getJSONObject("cohort")
        for (key in listOf("hardware", "firmware", "os", "os_version", "app_build", "capture_mode", "source_id", "session_id"))
            require(cohort.getString(key).isNotBlank() && cohort.getString(key) != "unknown") { "capture_cohort_unknown" }
        UUID.fromString(cohort.getString("source_id"))
        require(j.getString("clock_id").isNotBlank() && j.getString("clock_method") == "independent_capture_reference") { "clock_uncertain" }
        val uncertainty = finite(j, "clock_uncertainty_seconds")
        require(uncertainty > 0 && uncertainty <= 0.002) { "clock_uncertain" }
        return Verified(receipt, j, cohort.getString("source_id") + ":" + cohort.getString("session_id"),
            cohort.getString("firmware"), j.getString("clock_id"), uncertainty)
    }

    /** Endpoints are independently supplied observations; no receipt timestamp or mean HR becomes a beat clock. */
    fun beats(proof: Verified, packets: List<RrPacketProvenance>, user: UUID, device: UUID,
              packetSources: Map<String,String>): List<PhysiologyQuality.IntervalObservation> {
        require(proof.receipt.kind == "beat_timing" && proof.json.getJSONObject("cohort").getString("hardware") in setOf("WHOOP5", "WHOOP_MG")) { "unsupported_source" }
        require(proof.json.getString("modality") == "ppg_ibi") { "unsupported_modality" }
        val byId = packets.mapNotNull(RrPacketObservationBridge::verified).associateBy { it.packetId }
        val rows = proof.json.getJSONArray("intervals")
        require(rows.length() in 1..2000) { "capture_interval_limit" }
        val seen = mutableSetOf<Pair<String, Int>>()
        val endpoints = mutableMapOf<String, Double>()
        val result = (0 until rows.length()).map { index ->
            val row = rows.getJSONObject(index)
            val packet = byId[row.getString("packet_id")] ?: error("capture_packet_missing")
            require(packetSources[packet.packetId] == proof.json.getJSONObject("cohort").getString("source_id")) { "capture_source_mismatch" }
            val ordinal = row.getInt("word_index")
            val word = packet.words().singleOrNull { it.index == ordinal } ?: error("capture_word_missing")
            require(seen.add(packet.packetId to ordinal)) { "capture_duplicate_word" }
            require(proof.json.getString("decoder_version") == packet.decoderVersion && packet.clockOffsetSeconds == 0L) { "capture_decoder_or_clock_mismatch" }
            val original = PhysiologyQuality.checkedPackets(listOf(packet), device.toString(), user.toString(), proof.firmware)[ordinal]
            val first = row.getString("start_beat_id"); val last = row.getString("end_beat_id")
            val group = row.getString("continuity_id")
            require(first.isNotBlank() && last.isNotBlank() && first != last && group.isNotBlank()) { "capture_continuity_missing" }
            if (word.rawTicks == 0) {
                require(row.isNull("start_s") && row.isNull("end_s")) { "zero_word_has_no_beat_span" }
                // Keep rejected endpoint identities even across an all-zero packet. They
                // propagate rejection into adjacent packets without manufacturing a span.
                original.copy(source = "whoop5_history:${proof.source}",
                    startBeatId = "${proof.source}:$group:$first", endBeatId = "${proof.source}:$group:$last",
                    continuityGroup = "${proof.source}:$group")
            } else {
                val lo = finite(row, "start_s"); val hi = finite(row, "end_s")
                require(lo >= proof.receipt.start - 2.5 && hi <= proof.receipt.end + 2.5 && hi > lo &&
                    abs(hi - lo - word.rrMs / 1000.0) <= 0.002001) { "capture_interval_mismatch" }
                for ((id, time) in listOf(first to lo, last to hi)) {
                    val key = "${proof.source}:$group:$id"
                    require(endpoints.putIfAbsent(key, time)?.let { abs(it - time) < 0.000001 } != false) { "capture_endpoint_conflict" }
                }
                original.copy(source = "whoop5_history:${proof.source}", eventTime = (lo + hi) / 2,
                    startBeatId = "${proof.source}:$group:$first", endBeatId = "${proof.source}:$group:$last",
                    continuityGroup = "${proof.source}:$group", verifiedSpan = PhysiologyQuality.Span(lo, hi),
                    timestampPrecisionSeconds = proof.uncertainty, clockVersion = "${VERSION}:${proof.clock}",
                    startBeatAccepted = packet.words().getOrNull(ordinal-1)?.rawTicks != 0,
                    endBeatAccepted = packet.words().getOrNull(ordinal+1)?.rawTicks != 0)
            }
        }
        // Missing/zero words remain part of the evidence. A partial packet cannot silently erase a gap.
        for (id in seen.map { it.first }.distinct()) require(byId.getValue(id).words().all { id to it.index in seen }) { "capture_incomplete_packet" }
        val timed = result.filter { it.verifiedSpan != null }.sortedBy { it.verifiedSpan!!.start }
        require(timed.zipWithNext().none { (a, b) -> a.verifiedSpan!!.end > b.verifiedSpan!!.start + 0.000001 }) { "capture_overlapping_beats" }
        return result
    }

    fun finite(j: JSONObject, key: String) = j.getDouble(key).also { require(it.isFinite()) { "capture_nonfinite" } }
    fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
