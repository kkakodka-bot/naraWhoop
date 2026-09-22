package com.noop.push

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ServerSignalWindowCacheTest {
    private val owner = "11111111-1111-4111-8111-111111111111"
    private val device = "22222222-2222-4222-8222-222222222222"
    private val day = "2026-09-21"
    private fun window(kind: String = "hrv"): JSONObject {
        val duration = if (kind == "spo2") 900 else 300
        return JSONObject().put("schema_version", 1).put("algorithm_version", "sensor-windows-1")
            .put("user_id", owner).put("device_id", device).put("window_id", "33333333-3333-4333-8333-333333333333")
            .put("kind", kind).put("start", 1800).put("end", 1800 + duration)
            .put("duration_seconds", duration).put("stride_seconds", duration)
            .put("input_revision", "7").put("result_revision", "7").put("required_revision", 7)
            .put("publication_status", "shadow").put("measurement_status", if (kind == "spo2") "blocked" else "unavailable")
            .put("reason", "capture_metadata_unqualified").put("freshness_status", "snapshot")
            .put("modality", if (kind in setOf("hrv", "spo2")) "unknown" else kind)
            .put("unit", mapOf("hrv" to "ms", "ppg" to "bpm", "imu" to "m_s2_and_rad_s", "temperature" to "degC_skin", "spo2" to "percent")[kind])
            .put("values", JSONObject.NULL).put("quality", JSONObject().put("unavailable_signals", JSONArray().put("motion")))
            .put("observed_fraction", JSONObject.NULL).put("maximum_gap_seconds", JSONObject.NULL)
            .put("observed_through", JSONObject.NULL).put("source", JSONObject.NULL)
            .put("computed_at", "2026-09-21T00:05:00Z").put("published_at", "2026-09-21T00:05:01Z")
            .put("computation_mode", "retrospective").put("provenance", "vps_estimate")
            .put("calibration_status", "not_reference_validated").put("quality_policy_version", "engineering-sensor-quality-1")
            .put("preprocess_version", "qualified-raw-features-1")
    }
    private fun decode(value: JSONObject) = ServerSignalWindowCache.decode(value, owner, device)
    private fun body(rows: JSONArray = JSONArray().put(window())): JSONObject = JSONObject().put("server_scoring", JSONObject()
        .put("schema_version", 2).put("algorithm_version", "frwhoop-physiology-2").put("user_id", owner).put("day", day)
        .put("features", JSONObject().put("hrv", JSONObject().put("status", "unavailable").put("device_id", device)
            .put("algorithm_version", "frwhoop-physiology-2").put("publication_status", "shadow")))
        .put("daily", JSONObject().put("hrv_rmssd_ms", 99)).put("nights", JSONArray())
        .put("signal_windows_device_id", device).put("signal_windows", rows))

    @Test fun supportedModalitiesPreserveExplicitMissingnessAndMeasuredZeroCoverage() {
        for (kind in listOf("hrv", "ppg", "imu", "temperature", "spo2")) {
            val absent = decode(window(kind))!!
            assertNull(absent.observedFraction)
            val zero = decode(window(kind).put("observed_fraction", 0).put("maximum_gap_seconds", 300))!!
            assertEquals(0.0, zero.observedFraction!!, 0.0)
        }
        for (modality in listOf("ppg_ibi", "ecg_nn")) assertEquals(modality, decode(window().put("modality", modality))!!.modality)
        assertNull(decode(window("ppg").put("modality", "ecg_nn")))
    }

    @Test fun ownerDeviceAndShadowAuthorizationAreMandatory() {
        for ((key, value) in listOf("user_id" to "another-owner", "device_id" to "another-device",
            "algorithm_version" to "another-algorithm", "schema_version" to 2, "schema_version" to true,
            "publication_status" to "canonical", "measurement_status" to "available", "window_id" to "not-a-uuid",
            "provenance" to "device_reported", "unit" to "bpm", "calibration_status" to "validated")) {
            assertNull("$key=$value", decode(window().put(key, value)))
        }
        assertNull(ServerSignalWindowCache.decode(window().put("user_id", ""), "", device))
        assertNull(decode(window("spo2").put("measurement_status", "unqualified")))
    }

    @Test fun numericalValuesCannotEnterThroughShadowDiagnostics() {
        for (value in listOf<Any>(JSONObject().put("observed_rmssd_ms", 44), JSONArray(), 0, "null", false)) {
            assertNull(decode(window().put("values", value)))
        }
        val absent = window(); absent.remove("values"); assertNull(decode(absent))
    }

    @Test fun timingRequiresExactIntegralAlignedBoundedWindows() {
        for ((key, value) in listOf("start" to -300, "start" to 1801, "start" to 1800.5,
            "start" to "1800", "start" to true, "end" to 2099, "end" to 4102444801L,
            "end" to Long.MIN_VALUE, "duration_seconds" to 900, "duration_seconds" to "300", "stride_seconds" to 60)) {
            assertNull("$key=$value", decode(window().put(key, value)))
        }
        val start = Long.MAX_VALUE / 300 * 300
        assertNull(decode(window().put("start", start).put("end", start + 300)))
        assertNull(decode(window("spo2").put("start", 2100).put("end", 3000)))
    }

    @Test fun revisionIdentityAndFreshnessAreExactWithoutIntegerCoercion() {
        for (revision in listOf<Any>("0", "-1", "+7", "07", "7.0", " 7", "9223372036854775808", 7, true)) {
            assertNull(revision.toString(), decode(window().put("input_revision", revision).put("result_revision", revision)))
        }
        assertNull(decode(window().put("result_revision", "8")))
        assertNull(decode(window().put("result_revision", "07")))
        assertNull(decode(window().put("required_revision", "7")))
        assertNull(decode(window().put("required_revision", 0)))
        assertNull(decode(window().put("required_revision", 8)))
        assertEquals("stale", decode(window().put("required_revision", 8).put("freshness_status", "stale"))!!.freshnessStatus)
        assertNotNull(decode(window().put("required_revision", JSONObject.NULL)))
        assertEquals(Long.MAX_VALUE, decode(window().put("input_revision", Long.MAX_VALUE.toString())
            .put("result_revision", Long.MAX_VALUE.toString()).put("required_revision", Long.MAX_VALUE))!!.inputRevision)
    }

    @Test fun missingRequiredFieldsAndMalformedMissingnessAreRejected() {
        for (key in listOf("observed_fraction", "maximum_gap_seconds", "observed_through", "source", "published_at",
            "reason", "required_revision", "quality", "computed_at", "quality_policy_version", "preprocess_version", "stride_seconds")) {
            val absent = window(); absent.remove(key); assertNull(key, decode(absent))
        }
        for ((key, value) in listOf("observed_fraction" to "0.5", "observed_fraction" to true, "observed_fraction" to 1.01,
            "observed_fraction" to -0.01, "maximum_gap_seconds" to 301, "observed_through" to 2101,
            "observed_through" to 1799, "source" to 0, "reason" to JSONObject.NULL, "reason" to "",
            "reason" to "not a reason", "reason" to "unqualified\n", "quality" to JSONArray(), "computed_at" to " ")) {
            assertNull("$key=$value", decode(window().put(key, value)))
        }
    }

    @Test fun cachedRawSnapshotRoundTripKeepsDiagnosticsButCannotActivateCanonicalHrv() {
        val row = window().put("analysis_status", "available").put("measurement_status", "unqualified")
            .put("reason", "not_reference_validated").put("acquisition_contract_sha256", "a".repeat(64))
        val first = ServerScoreCacheCodec.parseSnapshot(body(JSONArray().put(row)).toString(), day, owner)
        val restored = ServerScoreCacheCodec.parseSnapshot(first.rawSnapshotJSON!!, day, owner)
        assertEquals(first.signalWindows, restored.signalWindows)
        assertEquals(1, restored.signalWindows.size)
        val retained = JSONObject(restored.rawSnapshotJSON!!).getJSONObject("server_scoring").getJSONArray("signal_windows").getJSONObject(0)
        assertEquals(row.toString(), retained.toString())
        assertFalse(restored.features.getValue("hrv").isCanonicalAvailable)
        assertNull(ServerVitalSelection.resolve(ServerVitalSelection.Metric.HRV, true, day, restored, null).value)
        val unsafe = ServerScoreCacheCodec.parseSnapshot(body(JSONArray().put(row.put("values", JSONObject().put("heart_rate_bpm", 99)))).toString(), day, owner)
        assertTrue(unsafe.signalWindows.isEmpty())
    }

    @Test fun cachedEnvelopeScopeAndWindowCountAreBounded() {
        val cache = ServerScoreCacheCodec.parseSnapshot(body().toString(), day, owner)
        assertTrue(cache.copy(ownerId = "another-owner").signalWindows.isEmpty())
        assertTrue(cache.copy(day = "2026-09-22").signalWindows.isEmpty())
        val nonStringDevice = body(JSONArray().put(window().put("device_id", "123")))
        nonStringDevice.getJSONObject("server_scoring").put("signal_windows_device_id", 123)
        assertTrue(ServerScoreCacheCodec.parseSnapshot(nonStringDevice.toString(), day, owner).signalWindows.isEmpty())
        val mixed = JSONArray().put(window()).put(window().put("device_id", "other"))
        assertEquals(1, ServerScoreCacheCodec.parseSnapshot(body(mixed).toString(), day, owner).signalWindows.size)
        assertEquals(2600, ServerScoreCacheCodec.parseSnapshot(body(JSONArray(List(2600) { window() })).toString(), day, owner).signalWindows.size)
        assertTrue(ServerScoreCacheCodec.parseSnapshot(body(JSONArray(List(4097) { window() })).toString(), day, owner).signalWindows.isEmpty())
    }
}
