package com.frwhoop.scoring

import com.frwhoop.scoring.signals.SignalCapabilityRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SignalCapabilityRegistryTest {
    @Test fun eventDensityIsIndependentOfSampleTimingAndIncludesBothWindowEdges() {
        val report = SignalCapabilityRegistry.summarizeEvents(listOf(0L to 300L), mapOf(10L to 24L, 11L to 24L, 260L to 24L))
        assertEquals(72L, report.getLong("row_count"))
        assertEquals(3, report.getInt("occupied_seconds"))
        assertEquals(0.24, report.getDouble("rows_per_requested_second"), 0.0)
        assertEquals(248L, report.getLong("maximum_empty_second_run"))
        for (field in listOf("observed_sample_count", "observed_time_fraction", "sample_rate_hz", "verified_sample_rate_hz",
            "timing_uncertainty_seconds", "verified_maximum_gap_seconds")) assertTrue(field, report.isNull(field))
    }

    @Test fun disjointCalendarIntervalsDoNotInventGapOutsideOwnedTime() {
        val report = SignalCapabilityRegistry.summarizeEvents(listOf(0L to 10L, 100L to 110L), mapOf(0L to 1L, 109L to 1L))
        assertEquals(9, report.getInt("maximum_empty_second_run"))
        assertEquals(0.1, report.getDouble("occupied_second_fraction"), 0.0)
        assertThrows(IllegalArgumentException::class.java) {
            SignalCapabilityRegistry.summarizeEvents(listOf(0L to 10L), mapOf(10L to 1L))
        }
        assertThrows(IllegalArgumentException::class.java) {
            SignalCapabilityRegistry.summarizeEvents(listOf(0L to 10L, 9L to 11L), emptyMap())
        }
    }

    @Test fun catalogueFirmwareAndOsAreNeverCaptureCohortEvidence() {
        val cohort = SignalCapabilityRegistry.captureCohort("fixture-device", "fixture-source", JSONObject()
            .put("device_family", "whoop5_mg").put("firmware", "50.41.1.0").put("phone_platform", "ios").put("app_version", "1.2"))
        for (field in listOf("device_family_at_capture", "hardware_revision_at_capture", "firmware_at_capture",
            "phone_platform_at_capture", "phone_os_version_at_capture", "app_version_at_capture", "app_build_at_capture", "capture_mode")) {
            assertEquals(field, "unknown", cohort.getString(field))
        }
        assertEquals("50.41.1.0", cohort.getJSONObject("current_catalogue_advisory").getString("firmware"))
        assertFalse(cohort.getBoolean("current_catalogue_is_capture_evidence"))
    }

    @Test fun rawRateClaimsAndOverlappingObjectsDoNotQualifySampleRateOrCoverage() {
        val raw = JSONArray()
        repeat(2) { raw.put(JSONObject().put("stream", "ppgWaveformSample").put("source_id", "fixture-source")
            .put("received_records", 600).put("sample_count", 600).put("catalogue_sample_rate_hz", 24)
            .put("compressed_bytes", JSONObject.NULL).put("catalogue_reported_coverage", 1.0)) }
        val registry = SignalCapabilityRegistry.build(JSONObject(), JSONArray(), raw)
        val stream = registry.getJSONArray("raw_stream_catalogue").getJSONObject(0)
        assertEquals(2, stream.getInt("object_count"))
        assertEquals(1200, stream.getInt("catalogue_reported_record_count"))
        assertTrue(stream.getBoolean("record_counts_may_overlap"))
        assertEquals(2, stream.getInt("objects_missing_byte_counts"))
        assertTrue(stream.isNull("sample_rate_hz"))
        assertTrue(stream.isNull("observed_time_fraction"))
        val ppg = registry.getJSONArray("capabilities").getJSONObject(1)
        assertEquals("unqualified", ppg.getString("qualification_status"))
        assertEquals(0, ppg.getJSONArray("qualified_channels").length())
        assertFalse(ppg.getBoolean("eligible_for_scoring_from_inventory"))
    }

    @Test fun syntheticReportCoversCohortsWithoutInventingHardwareOrOxygenation() {
        val report = SignalCapabilityRegistry.fixtureReport()
        val registry = report.getJSONObject("capability_registry")
        assertEquals("synthetic_fixture", registry.getString("evidence_kind"))
        assertEquals(4, registry.getJSONArray("cohorts").length())
        assertFalse(report.getBoolean("hardware_measurements"))
        assertEquals("NOT_MEASURED", report.getString("target_vps_capacity"))
        assertEquals(2, report.getJSONObject("signals").getJSONObject("skin_temperature").getInt("row_count"))
        val capabilities = registry.getJSONArray("capabilities")
        val spo2 = capabilities.getJSONObject(capabilities.length() - 1)
        assertEquals("spo2", spo2.getString("capability"))
        assertEquals("blocked", spo2.getString("qualification_status"))
        assertTrue(spo2.isNull("qualified_physical_units"))
        assertFalse(report.has("user_id"))
    }
}
