import com.noop.push.LegacyBeatReadEligibility
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CanonicalEvidenceTest {
    // Synthetic retained-v1 result. The exclusion marker permits heuristic sleep,
    // never qualifies beat timing or constitutes a physical phone observation.
    private fun fixture(): JSONObject = JSONObject("""{
      "owner":"server","metrics":["sleep_total_min","sleep_in_bed_min","sleep_sessions"],
      "status":"available","reason":null,"result_revision":"sha256:${"a".repeat(64)}",
      "input_revision":4,"algorithm_version":"frwhoop-server-1","configuration_version":"legacy-1",
      "canonical_qualification":"retained_legacy","manifest_hash":"${"b".repeat(64)}",
      "project":"https://fixture.invalid","owner_id":"00000000-0000-4000-8000-000000000001",
      "source_id":"00000000-0000-4000-8000-000000000002","device_id":"00000000-0000-4000-8000-000000000003",
      "window":"2026-09-21","timezone_id":"UTC","computed_at":"2026-09-22T06:00:00Z","freshness":"current",
      "values":{"sleep_total_min":360,"sleep_in_bed_min":480,"sleep_sessions":[
        {"start_at":"2026-09-21T00:00:00Z","asleep_min":360,"in_bed_min":480,"resting_hr_bpm":53,"hrv_rmssd_ms":null}]},
      "details":{"input_eligibility":{"policy_version":"legacy-rr-excluded-1","rr_input":"excluded"},
        "source_receipt":{"object_id":"00000000-0000-4000-8000-000000000004","sha256":"${"c".repeat(64)}"},
        "nights":[{"start_at":"2026-09-21T00:00:00Z","asleep_min":360,"in_bed_min":480,"resting_hr_bpm":53,"hrv_rmssd_ms":null}]}}
    """)
    private fun normalized(value: JSONObject): JSONObject = JSONObject(value.toString()).also(LegacyBeatReadEligibility::family)

    @Test fun normalizedPersistenceMatchesCompletePublicContractWithoutMutatingOriginal() {
        val original = fixture()
        val before = original.toString()
        val restored = normalized(original)
        assertFalse("Reproduces distinct private backing normalization", original.similar(restored))
        assertEquals(360, restored.getJSONObject("values").getInt("sleep_total_min"))
        assertTrue(canonicalFamilyContractMatches(original, restored))
        assertEquals("Comparator must preserve original wire payload", before, original.toString())
    }

    @Test fun everyIdentityRevisionAndEvidenceFieldRemainsCompared() {
        val original = fixture()
        val mutations = mapOf<String, Any>("owner" to "client", "metrics" to JSONArray("[\"sleep_total_min\"]"),
            "status" to "revoked", "reason" to "qualification_revoked", "result_revision" to "compute:99",
            "input_revision" to 5, "algorithm_version" to "other", "configuration_version" to "other",
            "model_version" to "other", "preprocessing_version" to "other", "quality_version" to "other",
            "manifest_hash" to "d".repeat(64), "feature_manifest_hash" to "e".repeat(64),
            "canonical_qualification" to "other", "project" to "https://other.invalid", "owner_id" to "other",
            "source_id" to "other", "device_id" to "other", "window" to "2026-09-20", "timezone_id" to "Europe/London",
            "computed_at" to "2026-09-22T07:00:00Z", "observed_through" to "2026-09-22T07:00:00Z",
            "freshness" to "stale", "expires_at" to "2026-09-23T07:00:00Z", "decision_id" to "other")
        for ((key, value) in mutations) {
            assertFalse(key, canonicalFamilyContractMatches(original, normalized(original).put(key, value)))
        }
    }

    @Test fun independentNumbersNestedValuesReceiptsAndMarkerCannotMutate() {
        val original = fixture()
        for (key in listOf("sleep_total_min", "sleep_in_bed_min")) {
            val changed = normalized(original)
            changed.getJSONObject("values").put(key, 1)
            assertFalse(key, canonicalFamilyContractMatches(original, changed))
        }
        for ((container, key) in listOf("values" to "sleep_sessions", "details" to "nights")) {
            val changed = normalized(original)
            changed.getJSONObject(container).getJSONArray(key).getJSONObject(0).put("resting_hr_bpm", 1)
            assertFalse(container, canonicalFamilyContractMatches(original, changed))
        }
        val receipt = normalized(original)
        receipt.getJSONObject("details").getJSONObject("source_receipt").put("object_id", "other")
        assertFalse(canonicalFamilyContractMatches(original, receipt))
        val marker = normalized(original)
        marker.getJSONObject("details").getJSONObject("input_eligibility").put("rr_input", "other")
        assertFalse(canonicalFamilyContractMatches(original, marker))
    }
}
