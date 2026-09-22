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
        val runtime = com.noop.account.AccountStorageContext.runtime(context)
            ?: error("captured account runtime unavailable")
        return runtime.sourceCoordinator.activeDeviceId.value ?: runtime.activeDeviceId
    }

    internal fun ownerId(context: Context): String? = EnrollmentDataScope.credential(context)?.userId
        ?: CloudAuthClient.identitySnapshot(context).scope?.userID
    internal fun requestIdentity(context: Context): String? {
        val credential = EnrollmentDataScope.credential(context)
        val account = CloudAuthClient.identitySnapshot(context)
        val owner = credential?.userId ?: account.scope?.userID ?: return null
        return org.json.JSONArray(listOf(DeviceLinkStore.identity(context)?.endpoint,
            owner, credential?.sourceId ?: SelfHostedPushSettings.from(context).sourceId(),
            credential?.tokenId ?: account.generation.toString(), localDeviceId(context))).toString()
    }

    suspend fun saveSleepOverride(context: Context, target: ServerSleepEditTarget, start: Long, end: Long, tombstone: Boolean): Long =
        withContext(Dispatchers.IO) {
            check(ownerId(context) == target.ownerId) { "account changed" }
            val payload = JSONObject().put("deviceId", localDeviceId(context))
                .put("arguments", target.rpcArguments(start, end, tombstone))
            request(context, "/sleep-overrides", payload).trim().toLong()
                .also { check(it > target.expectedRevision) { "invalid override revision" } }
        }

    suspend fun registerCurrentDevice(context: Context): String = withContext(Dispatchers.IO) {
        val identity = DeviceLinkStore.identity(context) ?: error("device identity unavailable")
        val response = request(context, "/devices", JSONObject().put("deviceId", identity.device))
        check(DeviceLinkStore.identity(context) == identity) { "device changed during registration" }
        DeviceLinkStore.from(context).record(identity, response)
    }

    suspend fun fetchDaySnapshot(context: Context, day: String, ownerId: String): ServerScoreDayCache =
        withContext(Dispatchers.IO) {
            check(ownerId(context) == ownerId) { "account changed" }
            val device = localDeviceId(context)
            try { registerCurrentDevice(context) }
            catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (_: Exception) { /* The read route can return an explicit registration-pending disposition. */ }
            check(localDeviceId(context) == device) { "device changed during registration" }
            val encode: (String) -> String = { java.net.URLEncoder.encode(it, "UTF-8") }
            val body = request(context, "?day=${encode(day)}&deviceId=${encode(device)}", null)
            val identity = DeviceLinkStore.identity(context) ?: error("identity changed")
            val cache = parseSnapshot(body, day, ownerId)
            val receipt = JSONObject(body).getJSONObject("identity")
            require(receipt.getString("userId") == identity.owner && receipt.getString("sourceId") == identity.source &&
                receipt.getString("externalDeviceId") == identity.device) { "Readback identity changed" }
            val canonical = if (receipt.isNull("deviceId")) {
                val compute = requireNotNull(cache.compute) { "Unregistered device requires explicit compute disposition" }
                require(compute.families.values.all { it.deviceId == null && !it.authorized &&
                    it.reason == "device_registration_pending" && it.resultRevision == null })
                null
            } else DeviceLinkStore.from(context).record(identity, body)
            require(cache.features.values.all { it.deviceId == null || it.deviceId == canonical })
            cache.compute?.let { contract ->
                require(contract.project == identity.endpoint.removeSuffix("/functions/v1/push").trimEnd('/') &&
                    contract.sourceId == identity.source && contract.families.values.all { it.deviceId == canonical })
            }
            cache
        }

    internal suspend fun request(context: Context, path: String, payload: JSONObject?): String {
        EnrollmentDataScope.credential(context)?.let { return enrolledRequest(context, it, path, payload) }
        val account = com.noop.account.AccountStorageContext.capture(context)
        val expected = requestIdentity(context) ?: error("account required")
        val auth = CloudAuthClient.authorizedSession(account)
        val project = auth.context.scope.projectURL
        val source = SelfHostedPushSettings.from(context).sourceId()
        val key = ServerScoringSettings.anonKey() ?: error("not configured")
        val conn = (URL("$project/functions/v1/scores$path").openConnection() as HttpURLConnection).apply {
            requestMethod = if (payload == null) "GET" else "POST"
            instanceFollowRedirects = false; connectTimeout = 15_000; readTimeout = 30_000
            setRequestProperty("Authorization", "Bearer ${auth.accessToken}")
            setRequestProperty("apikey", key); setRequestProperty("x-noop-source-id", source)
            setRequestProperty("Content-Type", "application/json"); doOutput = payload != null
        }
        try {
            currentCoroutineContext().ensureActive()
            check(account.isCurrent() && requestIdentity(context) == expected)
            payload?.let { conn.outputStream.use { out -> out.write(it.toString().toByteArray()) } }
            if (conn.responseCode == 409) throw Conflict()
            check(conn.responseCode in 200..299) { "score request failed" }
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            require(body.toByteArray().size <= ServerSnapshotDecoder.MAX_BYTES)
            currentCoroutineContext().ensureActive()
            check(account.isCurrent() && requestIdentity(context) == expected)
            return body
        } finally { conn.disconnect() }
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
