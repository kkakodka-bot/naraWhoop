package com.frwhoop.scoring.db

import com.frwhoop.scoring.signals.SignalCapabilityRegistry
import org.json.JSONArray
import org.json.JSONObject
import java.sql.Connection
import java.time.Instant
import java.time.LocalDate
import java.util.UUID

/** Read-only, event-time scoped acquisition inventory. Event bins never assert waveform continuity. */
class SignalInventoryReader(private val db: PostgresClient) {
    fun report(user: UUID, device: UUID, day: String, window: Pair<Long, Long>? = null,
               capturedAt: Instant = Instant.now()): JSONObject = db.withConnection { connection ->
        LocalDate.parse(day)
        connection.isReadOnly = true
        connection.transactionIsolation = Connection.TRANSACTION_REPEATABLE_READ
        connection.autoCommit = false
        try {
            connection.createStatement().use { it.execute("set local statement_timeout='15s'") }
            val readOnly = connection.createStatement().use { query -> query.executeQuery("show transaction_read_only").use { rows ->
                rows.next(); rows.getString(1) == "on"
            } }
            check(readOnly) { "inventory_transaction_must_be_read_only" }
            val deviceCatalogue = connection.prepareStatement("select device_family,firmware from public.devices where user_id=? and id=?").use { query ->
                query.setObject(1, user); query.setObject(2, device)
                query.executeQuery().use { rows ->
                    require(rows.next()) { "inventory_device_not_owned" }
                    JSONObject().put("device_family", rows.getString("device_family") ?: SignalCapabilityRegistry.UNKNOWN)
                        .put("firmware", rows.getString("firmware") ?: SignalCapabilityRegistry.UNKNOWN)
                        .put("catalogue_as_of", capturedAt.toString())
                }
            }
            val calendar = CalendarOwnershipReader.load(connection, user, day)
            val result = JSONObject().put("schema_version", 2).put("tool_version", SignalCapabilityRegistry.VERSION)
                .put("user_id", user.toString()).put("device_id", device.toString()).put("day", day)
                .put("captured_at", capturedAt.toString()).put("read_only", true)
                .put("timezone_ids", JSONArray(calendar.timezoneIds))
                .put("day_intervals", JSONArray(calendar.dayIntervals.map { listOf(it.first, it.second) }))
                .put("period_kind", if (window == null) "calendar_day_and_preceding_context" else "operator_selected_owned_window")
                .put("signal_values_exported", false).put("waveform_activation_allowed", false)
            val unavailable = calendar.unavailableReason
            if (unavailable != null) return@withConnection result.put("status", "unavailable").put("reason", unavailable)
            val intervals = if (window == null) calendar.contextIntervals else {
                require(window.second > window.first && window.second - window.first <= CalendarOwnershipReader.MAX_CONTEXT_SECONDS) {
                    "inventory_window_out_of_bounds"
                }
                val overlap = calendar.contextIntervals.map { maxOf(it.first, window.first) to minOf(it.second, window.second) }
                    .filter { it.second > it.first }
                require(overlap.sumOf { it.second - it.first } == window.second - window.first) { "inventory_window_not_owned_by_context" }
                overlap
            }
            require(intervals.isNotEmpty()) { "inventory_period_empty" }
            val duration = intervals.sumOf { it.second - it.first }
            result.put("status", "available").put("period_intervals", JSONArray(intervals.map { listOf(it.first, it.second) }))
                .put("period_seconds", duration)
            val tables = linkedMapOf("heart_rate" to "noop_hr_samples", "rr_intervals" to "noop_rr_intervals",
                "rr_packet_receipts" to "noop_rr_packet_provenance", "standard_hr_receipts" to "noop_standard_hr_receipts",
                "skin_temperature" to "noop_skin_temp_samples", "gravity" to "noop_gravity_samples",
                "steps" to "noop_step_samples", "respiration_auxiliary" to "noop_resp_samples",
                "events" to "noop_events", "band_sleep_state" to "noop_sleep_state_samples")
            val signals = JSONObject()
            val cohorts = linkedMapOf<String?, JSONObject>()
            fun cohort(source: String?): JSONObject = cohorts.getOrPut(source) {
                require(cohorts.size < MAX_SOURCES) { "inventory_source_limit_exceeded_narrow_the_window" }
                val catalogue = JSONObject(deviceCatalogue.toString())
                if (source != null) connection.prepareStatement("select platform,app_version from public.noop_app_installations where user_id=? and source_id=?").use { query ->
                    query.setObject(1, user); query.setObject(2, UUID.fromString(source))
                    query.executeQuery().use { rows -> if (rows.next()) {
                        catalogue.put("phone_platform", rows.getString("platform"))
                            .put("app_version", rows.getString("app_version"))
                    } }
                }
                SignalCapabilityRegistry.captureCohort(device.toString(), source, catalogue).put("signals", JSONObject())
            }
            for ((signal, table) in tables) {
                val bins = sortedMapOf<Long, Long>()
                val bySource = linkedMapOf<String?, MutableMap<Long, Long>>()
                val predicate = intervals.joinToString(" or ") { "(ts>=? and ts<?)" }
                connection.prepareStatement("select source_id,ts,count(*) as n from public.$table where user_id=? and device_id=? and ($predicate) group by source_id,ts order by ts,source_id limit ${MAX_EVENT_BINS + 1}").use { query ->
                    query.setObject(1, user); query.setObject(2, device)
                    intervals.forEachIndexed { i, range -> query.setLong(3 + i * 2, range.first); query.setLong(4 + i * 2, range.second) }
                    query.fetchSize = 4096
                    query.executeQuery().use { rows ->
                        var read = 0
                        while (rows.next()) {
                            require(++read <= MAX_EVENT_BINS) { "inventory_event_bin_limit_exceeded_narrow_the_window" }
                            val source = rows.getString("source_id")
                            cohort(source)
                            val second = rows.getLong("ts"); val count = rows.getLong("n")
                            bins[second] = (bins[second] ?: 0L) + count
                            bySource.getOrPut(source) { sortedMapOf() }[second] = count
                        }
                    }
                }
                fun describe(counts: Map<Long, Long>) = SignalCapabilityRegistry.summarizeEvents(intervals, counts)
                    .put("channel_semantics", when (signal) {
                        "respiration_auxiliary" -> "unverified_not_respiratory_reference"
                        "skin_temperature" -> "skin_not_core_temperature_sensor_mapping_requires_qualification"
                        "standard_hr_receipts" -> "raw_notifications_host_receipt_time_not_beat_clock"
                        else -> "named_projection_not_waveform_channel"
                    })
                signals.put(signal, describe(bins))
                bySource.forEach { (source, counts) -> cohort(source).getJSONObject("signals").put(signal, describe(counts)) }
            }
            result.put("signals", signals)
            val predicate = intervals.joinToString(" or ") { "(ts>=? and ts<?)" }
            val sources = JSONArray()
            connection.prepareStatement("select \"srcChannel\", \"tsSuspect\", count(*) as n from public.noop_rr_intervals where user_id=? and device_id=? and ($predicate) group by 1,2 order by 1,2").use { query ->
                query.setObject(1, user); query.setObject(2, device)
                intervals.forEachIndexed { i, range -> query.setLong(3 + i * 2, range.first); query.setLong(4 + i * 2, range.second) }
                query.executeQuery().use { rows -> while (rows.next()) sources.put(JSONObject()
                    .put("source_channel", rows.getObject("srcChannel") ?: JSONObject.NULL)
                    .put("timestamp_suspect", rows.getObject("tsSuspect") ?: JSONObject.NULL).put("row_count", rows.getLong("n"))) }
            }
            result.put("rr_source_counts", sources)
            val clocks = JSONArray()
            connection.prepareStatement("select \"clockVersion\", \"timestampPrecisionSeconds\", count(*) as n from public.noop_rr_packet_provenance where user_id=? and device_id=? and ($predicate) group by 1,2 order by 1,2").use { query ->
                query.setObject(1, user); query.setObject(2, device)
                intervals.forEachIndexed { i, range -> query.setLong(3 + i * 2, range.first); query.setLong(4 + i * 2, range.second) }
                query.executeQuery().use { rows -> while (rows.next()) clocks.put(JSONObject()
                    .put("clock_version", rows.getString("clockVersion")).put("timestamp_precision_seconds", rows.getDouble("timestampPrecisionSeconds"))
                    .put("receipt_count", rows.getLong("n"))) }
            }
            result.put("rr_receipt_clocks", clocks).put("rr_beat_clock_status", "unverified_no_subsecond_span_or_cross_packet_continuity")
            val raw = rawObjects(connection, user, device, intervals)
            for (index in 0 until raw.length()) cohort(raw.getJSONObject(index).optString("source_id", null))
            if (cohorts.isEmpty()) cohort(null)
            result.put("raw_objects", raw)
                .put("capability_registry", SignalCapabilityRegistry.build(signals, JSONArray(cohorts.values), raw))
            result.put("retention", JSONObject().put("local_pruning_guarantee", "not_established")
                .put("archive_claims_are_not_current_byte_verification", true)
                .put("next_step", "fetch_hash_decode_requested_objects_then_qualify_clock_channels_alignment_and_actual_coverage"))
            result
        } finally {
            connection.rollback()
        }
    }

    private fun rawObjects(connection: Connection, user: UUID, device: UUID, intervals: List<Pair<Long, Long>>): JSONArray {
        val predicate = intervals.joinToString(" or ") { "(w.start_ts<? and w.end_ts>?)" }
        val output = JSONArray()
        connection.prepareStatement("""
            select w.stream,w.object_id,w.start_ts,w.end_ts,w.received_records,w.missing_records,w.interpolated_records,
                w.coverage,m.status,m.sha256,m.sha256_source,m.verified_at,m.decode_verified_at,m.decoder_version,
                m.compressed_bytes,m.uncompressed_bytes,m.sample_count,m.compression,m.format,m.source_id,
                m.object_kind,(to_jsonb(m)->>'sample_rate_hz')::numeric as catalogue_sample_rate_hz
            from public.noop_signal_windows w join public.object_manifests m on m.id=w.object_id
            where w.user_id=? and w.device_id=? and m.user_id=w.user_id and m.device_id=w.device_id
              and m.object_key=w.object_key and m.object_class in ('raw','waveform') and ($predicate)
            order by w.start_ts,w.stream,w.object_id limit 10001
        """.trimIndent()).use { query ->
            query.setObject(1, user); query.setObject(2, device)
            intervals.forEachIndexed { i, range -> query.setLong(3 + i * 2, range.second); query.setLong(4 + i * 2, range.first) }
            query.executeQuery().use { rows -> while (rows.next()) {
                require(output.length() < 10000) { "inventory_raw_object_limit_exceeded_narrow_the_window" }
                val item = JSONObject()
                for (key in listOf("stream", "object_id", "start_ts", "end_ts", "received_records", "missing_records",
                    "interpolated_records", "coverage", "status", "sha256", "sha256_source", "verified_at", "decode_verified_at",
                    "decoder_version", "compressed_bytes", "uncompressed_bytes", "sample_count", "compression", "format",
                    "source_id", "object_kind", "catalogue_sample_rate_hz")) {
                    item.put(key, rows.getObject(key) ?: JSONObject.NULL)
                }
                item.put("proof_scope", "catalogue_only_not_refetched_by_inventory")
                    .put("catalogue_reported_coverage", item.remove("coverage"))
                    .put("sample_rate_hz", JSONObject.NULL).put("channel_identity", "unqualified")
                    .put("observed_time_fraction", JSONObject.NULL).put("timing_uncertainty_seconds", JSONObject.NULL)
                output.put(item)
            } }
        }
        return output
    }

    companion object {
        const val MAX_SOURCES = 64
        const val MAX_EVENT_BINS = 1_000_000
    }
}
