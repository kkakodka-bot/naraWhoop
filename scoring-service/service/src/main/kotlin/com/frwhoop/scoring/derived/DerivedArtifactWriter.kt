package com.frwhoop.scoring.derived

import com.frwhoop.scoring.b2.B2Config
import com.frwhoop.scoring.b2.B2ObjectStore
import com.frwhoop.scoring.scoring.ServerScoreBundle
import com.github.luben.zstd.Zstd
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.time.Instant
import java.util.UUID

/**
 * Archives the in-memory scored bundle to the same B2 bucket as raw objects, then registers
 * `object_manifests`. Score rows are already committed when this runs; failures are retryable
 * on the next re-score of the day.
 */
class DerivedArtifactWriter(
    private val b2Config: B2Config?,
    private val supabaseUrl: String,
    private val serviceRoleKey: String,
    private val putClient: B2ObjectStore.PutClient? = null,
    private val http: OkHttpClient = OkHttpClient.Builder().build(),
) {
    private val livePut: B2ObjectStore.PutClient? =
        if (putClient != null) putClient
        else b2Config?.let { config ->
            val store = B2ObjectStore(config, http)
            object : B2ObjectStore.PutClient {
                override fun putObject(key: String, body: ByteArray, contentType: String) =
                    store.putObject(key, body, contentType)
            }
        }

    val enabled: Boolean = livePut != null

    data class UploadResult(
        val objectKey: String,
        val sha256: String,
        val compressedBytes: Int,
    )

    fun archive(bundle: ServerScoreBundle): UploadResult {
        val client = livePut ?: error("derived artifact upload disabled — B2 credentials missing")
        val cfg = b2Config ?: error("B2 config required")
        val computedAt = Instant.now()
        val json = DerivedArchivePayload.build(bundle, computedAt).toString()
        val compressed = Zstd.compress(json.toByteArray(Charsets.UTF_8))
        val objectKey = DerivedArtifactKey.objectKey(bundle.userId, bundle.day, bundle.algorithmVersion)
        val sha256 = B2ObjectStore.sha256Hex(compressed)
        val contentType = "application/json"

        client.putObject(objectKey, compressed, contentType)
        registerManifest(bundle, cfg, objectKey, compressed.size, sha256, computedAt)
        return UploadResult(objectKey = objectKey, sha256 = sha256, compressedBytes = compressed.size)
    }

    private fun registerManifest(
        bundle: ServerScoreBundle,
        cfg: B2Config,
        objectKey: String,
        compressedBytes: Int,
        sha256: String,
        computedAt: Instant,
    ) {
        val deviceUuid = runCatching { UUID.fromString(bundle.deviceId) }.getOrNull()
        val expiresAt = computedAt.plusSeconds(cfg.derivedRetentionDays.toLong() * 86400)
        val row = JSONObject()
            .put("user_id", bundle.userId.toString())
            .put("device_id", deviceUuid?.toString())
            .put("object_class", "derived")
            .put("object_kind", "derived_scores")
            .put("provider", "b2")
            .put("bucket", cfg.bucket)
            .put("object_key", objectKey)
            .put("period_day", bundle.day)
            .put("compressed_bytes", compressedBytes)
            .put("content_type", CONTENT_TYPE)
            .put("format", "json_zstd_frwhoop_derived_v1")
            .put("compression", "zstd")
            .put("sha256", sha256)
            .put("sha256_source", "server_verified")
            .put("algorithm_version", bundle.algorithmVersion)
            .put("status", "ready")
            .put("retention_class", "derived")
            .put("expires_at", expiresAt.toString())
            .put("uploaded_at", computedAt.toString())
            .put("verified_at", computedAt.toString())

        val body = row.toString().toRequestBody("application/json".toMediaType())
        val req = Request.Builder()
            .url("$supabaseUrl/object_manifests?on_conflict=object_key")
            .post(body)
            .header("apikey", serviceRoleKey)
            .header("Authorization", "Bearer $serviceRoleKey")
            .header("Content-Type", "application/json")
            .header("Prefer", "resolution=merge-duplicates,return=minimal")
            .build()
        http.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) {
                error("object_manifests upsert failed: ${resp.code} ${resp.body?.string()?.take(200)}")
            }
        }
    }

    companion object {
        const val CONTENT_TYPE = "application/json"
    }
}
