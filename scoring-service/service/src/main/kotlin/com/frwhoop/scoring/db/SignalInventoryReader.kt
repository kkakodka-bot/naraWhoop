package com.frwhoop.scoring.db

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
            val owned = connection.prepareStatement("select 1 from public.devices where user_id=? and id=?").use { query ->
                query.setObject(1, user); query.setObject(2, device)
                query.executeQuery().use { it.next() }
            }
            require(owned) { "inventory_device_not_owned" }
            val calendar = CalendarOwnershipReader.load(connection, user, day)
            val result = JSONObject().put("schema_version", 1).put("tool_version", "physiology-signal-inventory-1")
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
                "rr_packet_receipts" to "noop_rr_packet_provenance", "gravity" to "noop_gravity_samples",
                "steps" to "noop_step_samples", "respiration_auxiliary" to "noop_resp_samples",
                "events" to "noop_events", "band_sleep_state" to "noop_sleep_state_samples")
            val signals = JSONObject()
            for ((signal, table) in tables) {
                val bins = mutableListOf<Long>()
                var count = 0L
                val predicate = intervals.joinToString(" or ") { "(ts>=? and ts<?)" }
                connection.prepareStatement("select ts,count(*) as n from public.$table where user_id=? and device_id=? and ($predicate) group by ts order by ts").use { query ->
                    query.setObject(1, user); query.setObject(2, device)
                    intervals.forEachIndexed { i, range -> query.setLong(3 + i * 2, range.first); query.setLong(4 + i * 2, range.second) }
                    query.executeQuery().use { rows -> while (rows.next()) { bins += rows.getLong("ts"); count += rows.getLong("n") } }
                }
                val gaps = intervals.map { (start, end) ->
                    var cursor = start
                    var longest = 0L
                    for (timestamp in bins) if (timestamp >= start && timestamp < end) {
                        longest = maxOf(longest, timestamp - cursor); cursor = timestamp + 1
                    }
                    maxOf(longest, end - cursor)
                }
                signals.put(signal, JSONObject().put("row_count", count).put("occupied_seconds", bins.size)
                    .put("occupied_second_fraction", bins.size.toDouble() / duration)
                    .put("maximum_empty_second_run", gaps.maxOrNull() ?: duration)
                    .put("first_event_second", bins.firstOrNull() ?: JSONObject.NULL)
                    .put("last_event_second", bins.lastOrNull() ?: JSONObject.NULL)
                    .put("rows_per_requested_second", count.toDouble() / duration)
                    .put("observed_time_fraction", JSONObject.NULL).put("sample_rate_hz", JSONObject.NULL)
                    .put("coverage_interpretation", "occupied_whole_second_event_bins_not_continuous_acquisition")
                    .put("timing_uncertainty_seconds", JSONObject.NULL)
                    .put("stored_timestamp_resolution_seconds", 1)
                    .put("channel_semantics", if (signal == "respiration_auxiliary") "unverified_not_respiratory_reference" else "named_projection_not_waveform_channel"))
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
            result.put("raw_objects", rawObjects(connection, user, device, intervals))
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
                m.compressed_bytes,m.uncompressed_bytes,m.sample_count,m.compression,m.format
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
                    "decoder_version", "compressed_bytes", "uncompressed_bytes", "sample_count", "compression", "format")) {
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
}
