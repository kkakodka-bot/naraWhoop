package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.b2.B2ObjectStore
import com.noop.analytics.RespirationEstimator
import com.noop.analytics.SleepOpportunityDetector
import org.json.JSONObject

/** Bound into the built distribution, not a mutable runtime qualification row. */
object ProductionAlgorithmManifest {
    @JvmStatic fun main(args: Array<String>) {
        println(CanonicalScorePayload.encode(JSONObject().put("publication_mode","shadow")
            .put("canonical_outputs_allowed",false).put("feature_manifest_hashes",hashes())
            .put("feature_manifests",JSONObject().apply {
                listOf("hrv","sleep","respiration").forEach { put(it,feature(it)) }
            })))
    }
    private val implementationHash: String by lazy {
        requireNotNull(javaClass.getResourceAsStream("/physiology-source.sha256")) { "Missing build source fingerprint" }
            .bufferedReader().use { it.readText().trim() }.also { require(it.matches(Regex("[a-f0-9]{64}"))) }
    }
    fun feature(feature: String): JSONObject {
        val (preprocessing,quality)=when(feature) {
            "hrv" -> "original-beat-continuity-v3" to "engineering-multisignal-90-v3"
            "sleep" -> SleepOpportunityDetector.VERSION to "sleep-v2-evidence-2"
            "respiration" -> RespirationEstimator.PREPROCESS_VERSION to "resp-quality-2"
            else -> error("Unsupported feature")
        }
        return JSONObject().put("schema_version",1).put("algorithm_version",CanonicalScorePayload.ALGORITHM_VERSION)
            .put("feature",feature).put("implementation_sha256",implementationHash)
            .put("checkpoint_kind","deterministic_source_not_learned_weights").put("checkpoint_sha256",implementationHash)
            .put("preprocessing_version",preprocessing).put("preprocessing_sha256",implementationHash)
            .put("quality_policy_version",quality).put("quality_policy_sha256",implementationHash)
            .put("mode","retrospective").put("accuracy_status","not_reference_validated")
    }
    fun hashes(): JSONObject = JSONObject().apply {
        listOf("hrv","sleep","respiration").forEach { put(it,B2ObjectStore.sha256Hex(
            CanonicalScorePayload.encode(feature(it)).toByteArray(Charsets.UTF_8))) }
    }
}
