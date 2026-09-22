package com.noop.push

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

object ServerScoreClient {
    class Unauthorized(val accessToken: String) : IllegalStateException("unauthorized")
    class Conflict : IllegalStateException("override revision changed")

    internal fun localDeviceId(context: Context): String {
        val app = context.applicationContext as com.noop.NoopApplication
        return app.sourceCoordinator.activeDeviceId.value ?: app.activeDeviceId
    }

    internal fun requestIdentity(context: Context): String? = EnrollmentDataScope.credential(context)?.let {
        org.json.JSONArray(listOf(SelfHostedPushSettings.from(context).configuredEndpoint()?.url,
            it.userId, it.sourceId, it.tokenId, localDeviceId(context))).toString()
    }

    suspend fun saveSleepOverride(context: Context, target: ServerSleepEditTarget, start: Long, end: Long, tombstone: Boolean): Long =
        withContext(Dispatchers.IO) {
            val credential = EnrollmentDataScope.credential(context) ?: error("enrollment required")
            check(credential.userId == target.ownerId) { "account changed" }
            val payload = JSONObject().put("deviceId", localDeviceId(context))
                .put("arguments", target.rpcArguments(start, end, tombstone))
            enrolledRequest(context, credential, "/sleep-overrides", payload).trim().toLong()
                .also { check(it > target.expectedRevision) { "invalid override revision" } }
        }

    suspend fun registerCurrentDevice(context: Context): String = withContext(Dispatchers.IO) {
        val credential = EnrollmentDataScope.credential(context) ?: error("enrollment required")
        val identity = DeviceLinkStore.identity(context) ?: error("device identity unavailable")
        val response = enrolledRequest(context, credential, "/devices", JSONObject().put("deviceId", identity.device))
        validateIdentityReceipt(JSONObject(response), credential, identity.device, requireDevice = true)
        check(DeviceLinkStore.identity(context) == identity) { "device changed during registration" }
        DeviceLinkStore.from(context).record(identity, response)
    }

    suspend fun fetchDaySnapshot(context: Context, day: String, ownerId: String): ServerScoreDayCache =
        withContext(Dispatchers.IO) {
            val credential = EnrollmentDataScope.credential(context) ?: error("enrollment required")
            check(credential.userId == ownerId) { "account changed" }
            val device = localDeviceId(context)
            registerCurrentDevice(context)
            check(localDeviceId(context) == device) { "device changed during registration" }
            val encode: (String) -> String = { java.net.URLEncoder.encode(it, "UTF-8") }
            val body = enrolledRequest(context, credential, "?day=${encode(day)}&deviceId=${encode(device)}", null)
            validateEnrollmentReceipt(body, credential, device)
            parseSnapshot(body, day, ownerId)
        }

    internal fun validateEnrollmentReceipt(body: String, credential: PushEnrollmentCredential, localDevice: String) {
        val root = JSONObject(body)
        val canonical = validateIdentityReceipt(root, credential, localDevice)
        val features = root.getJSONObject("server_scoring").getJSONObject("features")
        for (key in features.keys()) {
            val selected = features.getJSONObject(key).opt("device_id") as? String
            require(selected == null || (canonical != null && selected == canonical)) { "score device mismatch" }
        }
    }

    internal fun validateIdentityReceipt(root: JSONObject, credential: PushEnrollmentCredential, localDevice: String, requireDevice: Boolean = false): String? {
        val identity = root.getJSONObject("identity")
        require(identity.getString("userId") == credential.userId &&
            identity.getString("sourceId") == credential.sourceId &&
            identity.getString("externalDeviceId") == localDevice) { "invalid enrollment receipt" }
        val canonical = (identity.opt("deviceId") as? String)?.takeIf { it.isNotBlank() }
        require(!requireDevice || canonical?.let(PushEnrollmentCredential::isCanonicalUuid) == true) { "missing registered device" }
        return canonical
    }

    private suspend fun enrolledRequest(context: Context, credential: PushEnrollmentCredential, path: String, payload: JSONObject?): String {
        val settings = SelfHostedPushSettings.from(context)
        val endpoint = settings.configuredEndpoint()?.url ?: error("not configured")
        require(endpoint.endsWith("/functions/v1/push")) { "unsupported endpoint" }
        val fleet = settings.fleetToken() ?: error("not configured")
        val identity = requestIdentity(context)
        val conn = (URL(endpoint.removeSuffix("/push") + "/scores" + path).openConnection() as HttpURLConnection).apply {
            requestMethod = if (payload == null) "GET" else "POST"
            instanceFollowRedirects = false
            connectTimeout = 15_000; readTimeout = 30_000
            setRequestProperty("Authorization", "Bearer ${credential.uploadToken}")
            setRequestProperty("X-NOOP-Fleet-Token", fleet)
            setRequestProperty("Content-Type", "application/json")
            doOutput = payload != null
        }
        try {
            currentCoroutineContext().ensureActive()
            check(EnrollmentDataScope.credential(context) == credential) { "enrollment changed" }
            payload?.let { value -> conn.outputStream.use { it.write(value.toString().toByteArray()) } }
            val code = conn.responseCode
            if (code == 401 || code == 403) throw Unauthorized(credential.uploadToken)
            if (code == 409) throw Conflict()
            check(code == 200) { "score request failed" }
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            currentCoroutineContext().ensureActive()
            check(identity != null && identity == requestIdentity(context)) { "score scope changed" }
            return body
        } finally { conn.disconnect() }
    }

    fun parseSnapshot(body: String, day: String, ownerId: String, fetchedAtMs: Long = System.currentTimeMillis()): ServerScoreDayCache =
        ServerScoreCacheCodec.parseSnapshot(body, day, ownerId, fetchedAtMs)
}
