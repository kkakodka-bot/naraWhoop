package com.noop.analytics

import com.noop.data.RrInterval
import com.noop.protocol.ParsedFrame

/** Evidence shared by measurement and state models. State never decides signal validity. */
object PhysiologyQuality {
    /** Production receipts are CRC/digest checked again; word indices never follow zero compaction. */
    fun checkedPackets(packets: List<com.noop.protocol.RrPacketProvenance>, deviceId: String,
                       userId: String = "local", deviceFirmware: String? = null): List<IntervalObservation> =
        packets.flatMap { packet -> packet.words().map { word ->
            IntervalObservation(originalId = "${packet.packetId}:interval:${word.index}", userId = userId,
                deviceId = deviceId, deviceFirmware = deviceFirmware, source = "whoop5_history",
                eventTime = packet.ts.toDouble(), originalRRMs = word.rrMs.toDouble(),
                startBeatId = "${packet.packetId}:beat:${word.index}", endBeatId = "${packet.packetId}:beat:${word.index + 1}",
                continuityGroup = packet.packetId, timestampPrecisionSeconds = packet.timestampPrecisionSeconds,
                decoderVersion = packet.decoderVersion, clockVersion = packet.clockVersion,
                packetId = packet.packetId, ordinal = word.index, originalAccepted = word.rawTicks != 0,
                startBeatAccepted = word.rawTicks != 0, endBeatAccepted = word.rawTicks != 0,
                qualityReason = if (word.rawTicks == 0) "zero_original_word" else null)
        } }
    /** Keep separate source candidates; unmatched historical rows stay continuity-unverified. */
    fun packetOrLegacy(packets: List<com.noop.protocol.RrPacketProvenance>, rows: List<RrInterval>,
                       deviceId: String, userId: String = "local"): List<IntervalObservation>? {
        val observed = checkedPackets(packets, deviceId, userId)
        if (observed.none { it.originalRRMs > 0 }) return null
        val packetTimes = observed.map { it.eventTime.toLong() }.toSet()
        val unknown = legacy(rows.filter { it.srcChannel == 7 || (it.srcChannel == 5 && it.ts !in packetTimes) }, deviceId)
            .map { it.copy(userId = userId, source = if (it.source == "channel:5") "whoop5_history" else it.source) }
        return observed + unknown
    }
    data class Span(val start: Double, val end: Double)
    data class Correction(val id: String, val pass: String, val kind: String)
    data class IntervalObservation(
        val originalId: String,
        val userId: String = "local",
        val deviceId: String,
        val deviceFirmware: String? = null,
        val source: String,
        val modality: String = "ppg_ibi",
        val eventTime: Double,
        val originalRRMs: Double,
        val startBeatId: String? = null,
        val endBeatId: String? = null,
        val continuityGroup: String? = null,
        val verifiedSpan: Span? = null,
        val timestampPrecisionSeconds: Double = 1.0,
        val decoderVersion: String = "unknown",
        val clockVersion: String = "unknown",
        val packetId: String? = null,
        val ordinal: Int? = null,
        val originalAccepted: Boolean = true,
        val startBeatAccepted: Boolean = true,
        val endBeatAccepted: Boolean = true,
        val rhythmAmbiguous: Boolean = false,
        val qualityReason: String? = null,
        val corrections: List<Correction> = emptyList(),
        val correctedRRMs: Double? = null,
        /** Null denotes unavailable evidence, not a clean signal. */
        val motionContaminated: Boolean? = null,
        val contactAccepted: Boolean? = null,
        val opticalQualityAccepted: Boolean? = null,
        val detectorAgreementFraction: Double? = null,
    )
    data class ContextEpoch(val start: Double, val end: Double, val state: String, val qualified: Boolean, val availableAt: Double? = null)

    fun signalRejectionReason(row: IntervalObservation): String? = when {
        row.motionContaminated == true -> "motion_contamination"
        row.contactAccepted == false -> "contact_rejected"
        row.opticalQualityAccepted == false -> "optical_quality_rejected"
        row.detectorAgreementFraction?.let { !it.isFinite() || it !in 0.0..1.0 } == true -> "invalid_detector_evidence"
        row.detectorAgreementFraction?.let { it < 0.90 } == true -> "detector_disagreement"
        else -> null
    }

    /** Rejected original beats retain that status across event-time window boundaries. */
    fun propagatingEndpointRejections(observations: List<IntervalObservation>): List<IntervalObservation> {
        val rejected = mutableSetOf<List<String>>()
        for (row in observations) {
            if (row.startBeatId != null && !row.startBeatAccepted) rejected.add(listOf(row.userId, row.deviceId, row.source, row.startBeatId))
            if (row.endBeatId != null && !row.endBeatAccepted) rejected.add(listOf(row.userId, row.deviceId, row.source, row.endBeatId))
        }
        if (rejected.isEmpty()) return observations
        val conflicts = observations.groupBy { listOf(it.userId, it.deviceId, it.source, it.originalId) }
            .filterValues { rows -> rows.any { it != rows.first() } }.keys
        return observations.map { row -> if (listOf(row.userId, row.deviceId, row.source, row.originalId) in conflicts) row else row.copy(
            startBeatAccepted = row.startBeatAccepted && listOf(row.userId, row.deviceId, row.source, row.startBeatId ?: "") !in rejected,
            endBeatAccepted = row.endBeatAccepted && listOf(row.userId, row.deviceId, row.source, row.endBeatId ?: "") !in rejected) }
    }

    /** Engineering ambiguity screen, not a rhythm diagnosis or an upper HRV bound. */
    fun hasAmbiguousAlternation(observations: List<IntervalObservation>): Boolean {
        val rows = observations.sortedBy { it.verifiedSpan?.start ?: it.eventTime }
        fun usable(row: IntervalObservation): Boolean {
            val span = row.verifiedSpan ?: return false
            return row.originalAccepted && row.startBeatAccepted && row.endBeatAccepted &&
                row.originalRRMs.isFinite() && row.originalRRMs in 250.0..2500.0 &&
                span.start.isFinite() && span.end.isFinite() && span.end > span.start &&
                kotlin.math.abs(span.end - span.start - row.originalRRMs / 1000) <= 0.002001 &&
                row.timestampPrecisionSeconds.isFinite() && row.timestampPrecisionSeconds > 0 && row.timestampPrecisionSeconds <= 0.020
        }
        fun adjacent(a: IntervalObservation, b: IntervalObservation): Boolean =
            usable(a) && usable(b) && a.userId == b.userId && a.deviceId == b.deviceId && a.source == b.source &&
                a.deviceFirmware == b.deviceFirmware && a.clockVersion == b.clockVersion && a.decoderVersion == b.decoderVersion &&
                a.continuityGroup != null && a.continuityGroup == b.continuityGroup && a.endBeatId != null &&
                a.endBeatId == b.startBeatId && a.startBeatId != b.endBeatId &&
                kotlin.math.abs(a.verifiedSpan!!.end - b.verifiedSpan!!.start) <= 0.000001
        var run = 0
        for (i in 2 until rows.size) {
            val a = rows[i - 2]; val b = rows[i - 1]; val c = rows[i]
            val x = b.originalRRMs - a.originalRRMs; val y = c.originalRRMs - b.originalRRMs
            val scale = (a.originalRRMs + b.originalRRMs + c.originalRRMs) / 3
            if (adjacent(a, b) && adjacent(b, c) && x * y < 0 && minOf(kotlin.math.abs(x), kotlin.math.abs(y)) > maxOf(250.0, 0.35 * scale)) {
                run++
                if (run >= 20) return true
            } else run = 0
        }
        return false
    }

    fun legacy(rows: List<RrInterval>, deviceId: String): List<IntervalObservation> = rows.map {
        IntervalObservation(originalId = "legacy:${it.ts}:${it.rrMs}:${it.seq}", deviceId = deviceId,
            source = "channel:${it.srcChannel ?: -1}", eventTime = it.ts.toDouble(),
            originalRRMs = it.rrMs.toDouble(), ordinal = it.ord)
    }

    /** Final binary state, not a deep/light eligibility rule. Shadow inference is not PSG truth. */
    fun contextFromSleep(stages: List<StageSegment>, start: Long, end: Long, episodeType: String? = null): List<ContextEpoch> =
        SleepStageSemantics.normalized(stages, start, end).map { segment ->
            val state = when {
                SleepStageSemantics.isSleep(segment) -> if (episodeType == "nap") "nap" else "sleep"
                segment.state == "off_body" -> "off_body"
                SleepStageSemantics.isKnownState(segment) -> "awake"
                else -> "unknown"
            }
            ContextEpoch(segment.start.toDouble(), segment.end.toDouble(), state, state != "unknown",
                if (segment.computationMode == "causal") segment.end.toDouble() else null)
        }

    /** Packet-local identity never implies measured duration or continuity into a later packet. */
    fun historicalPacket(frame: ParsedFrame, packetId: String, deviceId: String,
                         userId: String = "local"): List<IntervalObservation> {
        if (!frame.ok || frame.crcOk != true || frame.typeName != "HISTORICAL_DATA" ||
            frame.parsed["rr_source_channel"] != 5 || packetId.isEmpty()) return emptyList()
        val timestamp = (frame.parsed["unix"] as? Number)?.toDouble() ?: return emptyList()
        val values = frame.parsed["rr_intervals"] as? List<*> ?: return emptyList()
        val count = frame.parsed["rr_count"] as? Int ?: return emptyList()
        if (frame.parsed["hist_version"] != 18 || count !in 1..4 || count != values.size ||
            (frame.parsed["rr_raw_ticks"] as? List<*>)?.size != count) return emptyList()
        if (values.any { it !is Int }) return emptyList()
        return values.mapIndexed { index, value ->
            IntervalObservation(originalId = "$packetId:interval:$index", userId = userId,
                deviceId = deviceId, source = "whoop5_history", eventTime = timestamp,
                originalRRMs = (value as Int).toDouble(), startBeatId = "$packetId:beat:$index",
                endBeatId = "$packetId:beat:${index + 1}", continuityGroup = packetId,
                decoderVersion = "whoop5-ticks-1024-v1", clockVersion = "sensor-second-unmapped",
                packetId = packetId, ordinal = index)
        }
    }

    internal fun union(spans: List<Span>, start: Double, end: Double): List<Span> {
        val clipped = spans.filter { it.start.isFinite() && it.end.isFinite() && it.end > it.start }
            .map { Span(maxOf(start, it.start), minOf(end, it.end)) }.filter { it.end > it.start }
            .sortedWith(compareBy<Span> { it.start }.thenBy { it.end })
        val result = mutableListOf<Span>()
        for (span in clipped) {
            val last = result.lastOrNull()
            if (last != null && span.start <= last.end) result[result.lastIndex] = Span(last.start, maxOf(last.end, span.end))
            else result.add(span)
        }
        return result
    }
}
