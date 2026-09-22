package com.frwhoop.scoring.signals

import org.json.JSONArray
import org.json.JSONObject

/** Inventory evidence cannot grant a decoder, model or metric permission to publish. */
object SignalCapabilityRegistry {
    const val VERSION = "sensor-capability-inventory-1"
    const val UNKNOWN = "unknown"

    fun summarizeEvents(intervals: List<Pair<Long, Long>>, counts: Map<Long, Long>): JSONObject {
        require(intervals.isNotEmpty() && intervals.all { it.second > it.first })
        require(intervals.zipWithNext().all { (a, b) -> a.second <= b.first })
        require(counts.all { (second, count) -> count > 0 && intervals.any { second >= it.first && second < it.second } })
        val duration = intervals.sumOf { it.second - it.first }
        val seconds = counts.keys.sorted()
        var maximumGap = 0L
        for ((start, end) in intervals) {
            var cursor = start
            for (second in seconds) if (second >= start && second < end) {
                maximumGap = maxOf(maximumGap, second - cursor)
                cursor = second + 1
            }
            maximumGap = maxOf(maximumGap, end - cursor)
        }
        val rows = counts.values.sum()
        return JSONObject().put("row_count", rows).put("occupied_seconds", seconds.size)
            .put("occupied_second_fraction", seconds.size.toDouble() / duration)
            .put("maximum_empty_second_run", maximumGap)
            .put("first_event_second", seconds.firstOrNull() ?: JSONObject.NULL)
            .put("last_event_second", seconds.lastOrNull() ?: JSONObject.NULL)
            .put("rows_per_requested_second", rows.toDouble() / duration)
            .put("observed_sample_count", JSONObject.NULL)
            .put("observed_time_fraction", JSONObject.NULL).put("sample_rate_hz", JSONObject.NULL)
            .put("verified_sample_rate_hz", JSONObject.NULL).put("verified_maximum_gap_seconds", JSONObject.NULL)
            .put("coverage_interpretation", "occupied_whole_second_event_bins_not_continuous_acquisition")
            .put("timing_uncertainty_seconds", JSONObject.NULL).put("stored_timestamp_resolution_seconds", 1)
    }

    fun captureCohort(device: String, source: String?, catalogue: JSONObject = JSONObject()): JSONObject = JSONObject()
        .put("device_id", device).put("source_installation_id", source ?: JSONObject.NULL)
        .put("device_family_at_capture", UNKNOWN).put("hardware_revision_at_capture", UNKNOWN)
        .put("firmware_at_capture", UNKNOWN).put("phone_platform_at_capture", UNKNOWN)
        .put("phone_os_version_at_capture", UNKNOWN).put("app_version_at_capture", UNKNOWN)
        .put("app_build_at_capture", UNKNOWN).put("capture_mode", UNKNOWN)
        .put("capture_metadata_status", "not_retained_in_catalogue")
        .put("current_catalogue_advisory", catalogue)
        .put("current_catalogue_is_capture_evidence", false)

    fun build(signals: JSONObject, scalarCohorts: JSONArray, rawObjects: JSONArray,
              evidenceKind: String = "owned_database_catalogue"): JSONObject {
        require(evidenceKind in setOf("owned_database_catalogue", "synthetic_fixture"))
        val capabilities = JSONArray()
        fun capability(name: String, projection: String?, rawStream: String?, modality: String,
                       declaredUnits: String, reason: String, channels: List<String>) {
            val projections = if (name == "five_minute_pulse_interval_variability")
                listOf("rr_intervals", "rr_packet_receipts", "standard_hr_receipts") else listOfNotNull(projection)
            val projectionCounts = JSONObject()
            projections.forEach { projectionCounts.put(it, signals.optJSONObject(it)?.optLong("row_count") ?: 0L) }
            val scalarRows = projections.sumOf { projectionCounts.getLong(it) }
            val objects = (0 until rawObjects.length()).map { rawObjects.getJSONObject(it) }
                .filter { it.optString("stream") == rawStream }
            val observed = scalarRows > 0 || objects.isNotEmpty()
            capabilities.put(JSONObject().put("capability", name).put("modality", modality)
                .put("qualification_status", if (name == "spo2") "blocked" else if (observed) "unqualified" else "not_observed")
                .put("reason", if (observed || name == "spo2") reason else "no_catalogue_observations")
                .put("observed_scalar_rows", scalarRows).put("projection_row_counts", projectionCounts)
                .put("projection_rows_are_not_unique_physical_observations", true)
                .put("catalogue_object_count", objects.size)
                .put("observed_sample_count", JSONObject.NULL).put("verified_sample_rate_hz", JSONObject.NULL)
                .put("observed_time_fraction", JSONObject.NULL).put("verified_maximum_gap_seconds", JSONObject.NULL)
                .put("declared_encoding_units", declaredUnits).put("qualified_physical_units", JSONObject.NULL)
                .put("candidate_channels", JSONArray(channels)).put("qualified_channels", JSONArray())
                .put("cohort_evidence", "capture_metadata_and_server_acquisition_proof_required")
                .put("eligible_for_scoring_from_inventory", false))
        }
        capability("five_minute_pulse_interval_variability", "rr_packet_receipts", null, "ppg_pulse_intervals",
            "decoder_specific_interval_units", "timing_coverage_unverified",
            listOf("whoop4_historical_milliseconds", "whoop5_historical_original_words", "standard_ble_rr"))
        capability("ppg_waveform_and_server_heart_rate", null, "ppgWaveformSample", "optical",
            "signed_i16_counts", "timing_channel_units_and_reference_unverified", listOf("wavelength_unknown"))
        capability("continuous_imu", null, "imuRawSample", "inertial",
            "signed_i16_counts", "timing_axis_units_and_orientation_unverified", listOf("accel_x", "accel_y", "accel_z", "gyro_x", "gyro_y", "gyro_z"))
        capability("skin_temperature", "skin_temperature", null, "skin_temperature",
            "raw_integer_scalar", "capture_mapping_wear_and_reference_unverified", listOf("skin_temperature_not_core"))
        capability("spo2", null, null, "oxygen_saturation", "unsupported",
            "unsupported_source_requires_calibrated_source_or_qualified_optical_method", emptyList())
        return JSONObject().put("version", VERSION).put("evidence_kind", evidenceKind)
            .put("qualification_authority", "none_inventory_is_read_only")
            .put("cohorts", scalarCohorts).put("raw_stream_catalogue", rawStreamCatalogue(rawObjects))
            .put("capabilities", capabilities)
            .put("cadences", JSONObject()
                .put("hardware_acquisition", "observed_native_clock_requires_capture_proof")
                .put("ble_delivery", "receipt_time_not_sample_time")
                .put("cloud_delivery", "durable_receipts_best_effort_no_phone_background_sla")
                .put("analysis", "bounded_changed_input_revisions_with_utc_300_second_attempts")
                .put("result", "revisioned_available_or_reason_after_window_and_inputs_are_eligible"))
            .put("metric_separation", JSONArray(listOf("ppg_pulse_interval_variability_is_not_ecg_nn_variability",
                "five_minute_sdnn_is_not_imported_daily_sdnn", "skin_temperature_is_not_core_temperature")))
    }

    private fun rawStreamCatalogue(objects: JSONArray): JSONArray {
        val groups = (0 until objects.length()).map { objects.getJSONObject(it) }.groupBy {
            it.getString("stream") to it.optString("source_id", UNKNOWN)
        }
        return JSONArray(groups.entries.sortedWith(compareBy({ it.key.first }, { it.key.second })).map { (key, entries) ->
            JSONObject().put("stream", key.first).put("source_installation_id", key.second)
                .put("object_count", entries.size)
                .put("catalogue_reported_record_count", entries.sumOf { it.optLong("received_records") })
                .put("catalogue_reported_compressed_bytes", entries.filterNot { it.isNull("compressed_bytes") }.sumOf { it.optLong("compressed_bytes") })
                .put("objects_missing_byte_counts", entries.count { it.isNull("compressed_bytes") })
                .put("record_counts_may_overlap", true).put("capture_mode", UNKNOWN)
                .put("observed_sample_count", JSONObject.NULL).put("sample_rate_hz", JSONObject.NULL)
                .put("observed_time_fraction", JSONObject.NULL).put("proof_scope", "catalogue_only_not_refetched_by_inventory")
        })
    }

    /** No person, installation, strap or reference measurement is represented by this fixture. */
    fun fixtureReport(): JSONObject {
        val intervals = listOf(0L to 300L)
        val signals = JSONObject()
            .put("heart_rate", summarizeEvents(intervals, mapOf(0L to 1L, 60L to 1L)))
            .put("rr_packet_receipts", summarizeEvents(intervals, mapOf(0L to 1L, 299L to 1L)))
            .put("skin_temperature", summarizeEvents(intervals, mapOf(30L to 1L, 270L to 1L)))
        val cohorts = JSONArray()
        for (platform in listOf("ios", "android")) for (family in listOf("whoop4", "whoop5_mg")) {
            cohorts.put(captureCohort("fixture-$family-$platform", "fixture-source-$platform-$family",
                JSONObject().put("device_family", family).put("firmware", "fixture-current-only")
                    .put("phone_platform", platform).put("app_version", "fixture-current-only")))
        }
        val raw = JSONArray()
        for (stream in listOf("ppgWaveformSample", "imuRawSample")) raw.put(JSONObject()
            .put("stream", stream).put("source_id", "fixture-source-android-whoop5_mg")
            .put("received_records", if (stream == "ppgWaveformSample") 2 else 300)
            .put("sample_count", if (stream == "ppgWaveformSample") 2 else 300)
            .put("catalogue_sample_rate_hz", if (stream == "ppgWaveformSample") 24 else 100)
            .put("compressed_bytes", JSONObject.NULL).put("catalogue_reported_coverage", 1.0)
            .put("proof_scope", "synthetic_catalogue_claim_only"))
        return JSONObject().put("schema_version", 2).put("tool_version", VERSION)
            .put("evidence_kind", "synthetic_fixture").put("hardware_measurements", false)
            .put("signal_values_exported", false).put("read_only", true).put("waveform_activation_allowed", false)
            .put("period_seconds", 300).put("period_intervals", JSONArray(listOf(listOf(0L, 300L))))
            .put("signals", signals).put("raw_objects", raw)
            .put("capability_registry", build(signals, cohorts, raw, "synthetic_fixture"))
            .put("hardware_soak", "NOT_MEASURED").put("reference_validation", "NOT_MEASURED")
            .put("target_vps_capacity", "NOT_MEASURED")
    }
}
