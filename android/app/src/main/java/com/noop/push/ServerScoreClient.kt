package com.noop.push

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONArray
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
        "${it.userId}:${it.sourceId}:${it.tokenId}:${localDeviceId(context)}"
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

    fun parseSnapshot(body: String, day: String, ownerId: String, fetchedAtMs: Long = System.currentTimeMillis()): ServerScoreDayCache {
        val o = JSONObject(body).getJSONObject("server_scoring")
        require(ownerId.isNotBlank() && o.optInt("schema_version") == 2 &&
            o.optString("user_id").lowercase() == ownerId.lowercase() && o.optString("day") == day) { "invalid score scope" }
        val rawFeatures = o.getJSONObject("features")
        require(rawFeatures.length() > 0) { "missing source selection" }
        val features = rawFeatures.keys().asSequence().associateWith { key ->
            val f = rawFeatures.getJSONObject(key)
            val status = f.optString("status", "unavailable")
            val device = f.str("device_id"); val version = f.str("algorithm_version")
            require(status == "unavailable" || (!device.isNullOrBlank() && !version.isNullOrBlank())) { "invalid source selection" }
            ServerScoreFeatureCache(status, f.str("reason"), device, version, f.long("input_revision"), f.long("required_revision"),
                f.str("computed_at"), f.str("observed_through"), f.str("publication_status"), f.str("archive_status"), f.str("manifest_hash"), f.bool("supports_boundary_overrides"),
                f.str("processing_status"), f.str("timezone_id"), f.optJSONArray("timezone_ids")?.let { a ->
                    (0 until a.length()).mapNotNull { a.opt(it) as? String }
                })
        }
        val daily = o.optJSONObject("daily")?.let { d -> ServerScoreDailyCache(
            hrvRmssdMs = d.num("hrv_rmssd_ms"), restingHrBpm = d.num("resting_hr_bpm")?.toInt(),
            sleepTotalMin = d.num("sleep_total_min"), sleepInBedMin = d.num("sleep_in_bed_min"),
            sleepAwakeMin = d.num("sleep_awake_min"), sleepLightMin = d.num("sleep_light_min"),
            sleepDeepMin = d.num("sleep_deep_min"), sleepRemMin = d.num("sleep_rem_min"),
            sleepEfficiency = d.num("sleep_efficiency"), respRateBpm = d.num("resp_rate_bpm"), computedAt = d.str("computed_at"),
            sleepUnstagedMin = d.num("sleep_unstaged_min"), stateUnknownMin = d.num("state_unknown_min"),
            offBodyMin = d.num("off_body_min"), opportunityKind = d.str("opportunity_kind"),
            recovery = d.num("recovery"), strain = d.num("strain"), spo2Pct = d.num("spo2_pct"),
            skinTempC = d.num("skin_temp_c"), skinTempDevC = d.num("skin_temp_dev_c")) }
        val nights = (o.optJSONArray("nights") ?: JSONArray()).objects().map { n ->
            val device = n.str("device_id")
            require(features["sleep"]?.deviceId == null || device == features["sleep"]?.deviceId) { "night device scope mismatch" }
            val sourceVersion = n.str("algorithm_version") ?: features["sleep"]?.algorithmVersion
            val legacy = sourceVersion == "frwhoop-server-1"
            val stages = (n.optJSONArray("stages") ?: n.optJSONArray("hypnogram") ?: JSONArray()).objects().map { s ->
                val lo = s.num("start") ?: error("missing epoch start")
                val hi = s.num("end") ?: error("missing epoch end")
                require(hi > lo && lo >= -62135596800.0 && hi <= 253402300799.0) { "invalid epoch span" }
                val stage = s.str("stage") ?: "unknown"
                val stageLegacy = legacy && (s.str("algorithm_version") ?: sourceVersion) == "frwhoop-server-1"
                val legacyState = when (stage) { "light", "deep", "rem" -> "sleep"; "wake", "awake" -> "awake"; else -> "state_unknown" }
                ServerScoreStageCache(lo.toLong(), hi.toLong(), stage, s.str("state") ?: if (stageLegacy) legacyState else "state_unknown",
                    s.num("p_sleep"), s.num("p_wake"), s.num("p_light"), s.num("p_deep"), s.num("p_rem"),
                    s.num("evidence_coverage"), s.str("reason") ?: if (stageLegacy) "legacy_quality_unavailable" else null,
                    s.str("calibration_status") ?: if (stageLegacy) "legacy_unvalidated" else null,
                    s.str("algorithm_version") ?: if (stageLegacy) sourceVersion else null, s.str("computation_mode"))
            }
            ServerScoreNightCache(id = n.getString("id").also { require(it.isNotBlank()) }, startAt = n.getString("start_at"),
                endAt = n.getString("end_at"), isNap = n.optBoolean("is_nap"), asleepMin = n.num("asleep_min"),
                inBedMin = n.num("in_bed_min"), lightMin = n.num("light_min"), deepMin = n.num("deep_min"),
                remMin = n.num("rem_min"), awakeMin = n.num("awake_min"), efficiency = n.num("efficiency"),
                hrvRmssdMs = n.num("hrv_rmssd_ms"), restingHrBpm = n.num("resting_hr_bpm")?.toInt(), stages = stages,
                deviceId = device, episodeType = n.str("episode_type") ?: if (legacy) (if (n.optBoolean("is_nap")) "nap" else "main_sleep") else null, mainSleepGroupId = n.str("main_sleep_group_id"),
                boundaryProvenance = n.str("boundary_provenance"), opportunityKind = n.str("opportunity_kind"),
                startTimezoneId = n.str("start_timezone_id"), endTimezoneId = n.str("end_timezone_id"),
                measurementAvailable = n.bool("measurement_available") ?: if (legacy) n.num("asleep_min")?.let { it >= 0 } else null, sleepUnstagedMin = n.num("sleep_unstaged_min"),
                stateUnknownMin = n.num("state_unknown_min"), offBodyMin = n.num("off_body_min"), stateCoverage = n.num("state_coverage"),
                manualEdit = n.bool("manual_edit"))
        }
        return ServerScoreDayCache(day, o.getString("algorithm_version"), daily, nights, o.str("computed_at"),
            o.optBoolean("stale", true), fetchedAtMs, ownerId.lowercase(), 2, features, body)
    }

    private fun JSONObject.str(key: String) = (opt(key) as? String)?.takeIf { it.isNotBlank() }
    private fun JSONObject.num(key: String) = (opt(key) as? Number)?.toDouble()?.takeIf { it.isFinite() }
    private fun JSONObject.long(key: String) = (opt(key) as? Number)?.toLong()
    private fun JSONObject.bool(key: String) = opt(key) as? Boolean
    private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }
}
