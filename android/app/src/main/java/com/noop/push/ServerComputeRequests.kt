package com.noop.push

import android.content.Context
import com.noop.account.AccountStorageContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId
import java.util.UUID

/** Durable session intent only. Raw samples keep their existing transport and receipt path. */
class ServerComputeRequests(context: Context) {
    private val account = AccountStorageContext.capture(context)
    private val prefs = account.getSharedPreferences("noop_compute_requests_v1", Context.MODE_PRIVATE)
    fun capture(family: String, start: Long, end: Long?, sessionId: String = UUID.randomUUID().toString(),
                inputRevision: Long = 0, consent: Boolean = false, expiresAt: Long? = null): String? {
        require(family in ServerComputeContract.familyIDs && inputRevision >= 0)
        val identity = DeviceLinkStore.identity(account) ?: return null
        if (!account.isCurrent()) return null
        val id = UUID.randomUUID().toString()
        val body = JSONObject().put("deviceId", identity.device).put("request", JSONObject()
            .put("id", id).put("family", family).put("session_id", sessionId)
            .put("event_start", Instant.ofEpochSecond(start).toString())
            .put("event_end", end?.let { Instant.ofEpochSecond(it).toString() } ?: JSONObject.NULL)
            .put("timezone_id", ZoneId.systemDefault().id).put("input_revision", inputRevision)
            .put("algorithm_version", "vps-only-1").put("configuration_version", "vps-only-1")
            .put("consent", consent).put("expires_at", expiresAt?.let { Instant.ofEpochSecond(it).toString() } ?: JSONObject.NULL))
        synchronized(lock) {
            check(prefs.edit().putString("request:$id", JSONObject().put("scope", identity.key)
                .put("authorization_scope", ServerScoreClient.requestIdentity(account))
                .put("body", body).put("state", "queued").toString()).commit()) { "Session intent not durable" }
        }
        return id
    }

    suspend fun drain() = withContext(Dispatchers.IO) {
        val identity = DeviceLinkStore.identity(account) ?: return@withContext
        if (!account.isCurrent()) return@withContext
        val captured = synchronized(lock) { prefs.all.filterKeys { it.startsWith("request:") }.toMap() }
        for ((key, raw) in captured) {
            val entry = runCatching { JSONObject(raw as String) }.getOrNull() ?: continue
            if (entry.optString("scope") != identity.key || entry.optString("authorization_scope") != ServerScoreClient.requestIdentity(account)) continue
            val body = entry.getJSONObject("body")
            val id = body.getJSONObject("request").getString("id")
            val current = ServerScoreClient.requestIdentity(account)
            try {
                if (entry.optString("state") == "queued") {
                    ServerScoreClient.request(account, "/compute-requests", body)
                    entry.put("state", "processing")
                }
                val device = java.net.URLEncoder.encode(identity.device, "UTF-8")
                val result = ServerScoreClient.request(account, "/compute-requests?deviceId=$device&requestId=$id", null)
                require(JSONObject(result).getString("request_id") == id)
                if (!account.isCurrent() || ServerScoreClient.requestIdentity(account) != current) return@withContext
                entry.put("response", JSONObject(result))
                entry.put("state", JSONObject(result).optString("state", "processing"))
                synchronized(lock) { check(prefs.edit().putString(key, entry.toString()).commit()) }
            } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (_: Exception) { /* Persisted intent remains retryable; capture and raw upload are independent. */ }
        }
    }

    fun response(id: String): JSONObject? {
        val identity = DeviceLinkStore.identity(account) ?: return null
        if (!account.isCurrent()) return null
        return runCatching { JSONObject(prefs.getString("request:$id", null) ?: return null)
            .takeIf { it.getString("scope") == identity.key && it.optString("authorization_scope") == ServerScoreClient.requestIdentity(account) }?.optJSONObject("response") }.getOrNull()
    }

    fun latestId(family: String, start: Long? = null): String? {
        val identity = DeviceLinkStore.identity(account) ?: return null
        if (!account.isCurrent()) return null
        return synchronized(lock) { prefs.all.filterKeys { it.startsWith("request:") }.values.mapNotNull { raw ->
            runCatching {
                val entry = JSONObject(raw as String)
                val request = entry.getJSONObject("body").getJSONObject("request")
                if (entry.getString("scope") != identity.key || entry.optString("authorization_scope") != ServerScoreClient.requestIdentity(account) || request.getString("family") != family ||
                    (start != null && request.getString("event_start") != Instant.ofEpochSecond(start).toString())) null
                else request
            }.getOrNull()
        }.maxByOrNull { it.optString("event_end", it.getString("event_start")) }?.getString("id") }
    }

    fun result(id: String): ServerComputeFamily? = runCatching {
        val identity = DeviceLinkStore.identity(account) ?: return null
        if (!account.isCurrent()) return null
        val canonicalDevice = DeviceLinkStore.from(account).confirmed(identity) ?: return null
        val entry = JSONObject(prefs.getString("request:$id", null) ?: return null)
        require(entry.getString("scope") == identity.key)
        require(entry.optString("authorization_scope") == ServerScoreClient.requestIdentity(account))
        val request = entry.getJSONObject("body").getJSONObject("request")
        val response = entry.optJSONObject("response") ?: return null
        require(response.getString("request_id") == id)
        val raw = response.optJSONObject("result") ?: return null
        ServerComputeContract.decodeFamily(raw, request.getString("family"),
            identity.endpoint.removeSuffix("/functions/v1/push").trimEnd('/'), identity.owner, identity.source,
            request.getString("session_id"), canonicalDevice)
    }.getOrNull()

    /** Claims delivery before haptic playback. Expired results and duplicate decisions cannot replay. */
    fun admitDecision(family: ServerComputeFamily, nowMs: Long = System.currentTimeMillis()): Boolean = synchronized(lock) {
        val identity = DeviceLinkStore.identity(account) ?: return@synchronized false
        val device = DeviceLinkStore.from(account).confirmed(identity) ?: return@synchronized false
        if (!account.isCurrent() || family.ownerId != identity.owner || family.deviceId != device ||
            family.project != identity.endpoint.removeSuffix("/functions/v1/push").trimEnd('/') ||
            family.sourceId != identity.source || !family.usableDecision(nowMs)) return@synchronized false
        val key = "decision:${identity.key}:${family.decisionId}"
        if (prefs.contains(key)) return@synchronized false
        prefs.edit().putString(key, family.resultRevision).commit()
    }
    companion object { private val lock = Any() }
}
