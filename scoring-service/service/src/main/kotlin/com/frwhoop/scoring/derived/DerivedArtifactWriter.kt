package com.frwhoop.scoring.derived

import com.frwhoop.scoring.b2.B2Config
import com.frwhoop.scoring.b2.B2ObjectStore
import com.frwhoop.scoring.scoring.CanonicalScorePayload
import com.frwhoop.scoring.scoring.ServerScoreBundle
import com.github.luben.zstd.Zstd
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.time.Instant
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Archives exactly the committed DTO, verifies fetched bytes, then registers its manifest. */
class DerivedArtifactWriter(
    private val b2Config: B2Config?,
    private val supabaseUrl: String,
    private val serviceRoleKey: String,
    private val putClient: B2ObjectStore.PutClient? = null,
    private val http: OkHttpClient = OkHttpClient.Builder().callTimeout(30, TimeUnit.SECONDS).build(),
    private val getClient: B2ObjectStore.GetClient? = null,
) {
    private val store = b2Config?.let { B2ObjectStore(it, http) }
    val enabled: Boolean = b2Config != null && (putClient != null || store != null)

    data class UploadResult(val objectKey: String, val sha256: String, val compressedBytes: Int)

    /** Compatibility helper for offline tooling; the running service uses the durable outbox overload. */
    fun archive(bundle: ServerScoreBundle): UploadResult {
        val payload = DerivedArchivePayload.build(bundle)
        val key = DerivedArtifactKey.objectKey(bundle.userId, UUID.fromString(bundle.deviceId),
            bundle.day, bundle.algorithmVersion, 0, CanonicalScorePayload.hash(payload))
        return archive(payload, key)
    }

    fun archive(payload: JSONObject, objectKey: String): UploadResult {
        val cfg = b2Config ?: error("B2 configuration unavailable")
        val compressed = Zstd.compress(CanonicalScorePayload.encode(payload).toByteArray(Charsets.UTF_8))
        val sha256 = B2ObjectStore.sha256Hex(compressed)
        if (putClient != null) putClient.putObject(objectKey, compressed, CONTENT_TYPE)
        else (store ?: error("B2 upload unavailable")).putObject(objectKey, compressed, CONTENT_TYPE)
        val fetched = if (getClient != null) getClient.getObject(objectKey, compressed.size)
            else (store ?: error("B2 verification unavailable")).getObject(objectKey, compressed.size)
        check(fetched.size == compressed.size && B2ObjectStore.sha256Hex(fetched) == sha256) {
            "derived archive content digest mismatch"
        }
        registerManifest(payload, cfg, objectKey, compressed.size, sha256)
        return UploadResult(objectKey, sha256, compressed.size)
    }

    private fun registerManifest(payload: JSONObject, cfg: B2Config, key: String, bytes: Int, hash: String) {
        val verifiedAt = Instant.now()
        val row = JSONObject()
            .put("user_id", payload.getString("user_id"))
            .put("device_id", payload.getString("device_id"))
            .put("object_class", "derived").put("object_kind", "derived_scores")
            .put("provider", "b2").put("bucket", cfg.bucket).put("object_key", key)
            .put("period_day", payload.getString("day"))
            .put("compressed_bytes", bytes).put("content_type", CONTENT_TYPE)
            .put("format", "json_zstd_frwhoop_derived_v2").put("compression", "zstd")
            .put("sha256", hash).put("sha256_source", "server_verified")
            .put("algorithm_version", payload.getString("algorithm_version"))
            .put("status", "ready").put("retention_class", "derived")
            .put("expires_at", verifiedAt.plusSeconds(cfg.derivedRetentionDays.toLong() * 86400).toString())
            .put("uploaded_at", verifiedAt.toString()).put("verified_at", verifiedAt.toString())
        val request = Request.Builder().url("$supabaseUrl/object_manifests?on_conflict=object_key")
            .post(row.toString().toRequestBody("application/json".toMediaType()))
            .header("apikey", serviceRoleKey).header("Authorization", "Bearer $serviceRoleKey")
            .header("Prefer", "resolution=merge-duplicates,return=minimal").build()
        http.newCall(request).execute().use { response ->
            check(response.isSuccessful) { "archive manifest registration failed: HTTP ${response.code}" }
        }
    }

    companion object { const val CONTENT_TYPE = "application/json" }
}
