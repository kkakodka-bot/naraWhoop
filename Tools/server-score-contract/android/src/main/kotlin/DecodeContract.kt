import com.noop.push.ServerScoreCacheCodec
import com.noop.push.ServerVitalSelection
import com.noop.push.ServerScoreDayCache
import com.noop.push.ServerComputeContract
import com.noop.push.ServerComputeRevisionFence
import com.noop.push.ServerMetricOwnership
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

private fun changedContract(cache: ServerScoreDayCache, change: (JSONObject) -> Unit): ServerScoreDayCache {
    val compute = JSONObject(requireNotNull(cache.rawSnapshotJSON)).getJSONObject("server_scoring").getJSONObject("compute")
    change(compute)
    val owner = compute.getString("owner_id")
    val day = compute.getString("day")
    return cache.copy(ownerId = owner, day = day, compute = ServerComputeContract.decode(compute, owner, day))
}

private fun verifyCanonicalSelection(cache: ServerScoreDayCache, bytes: String, expected: JSONObject, directory: File) {
    val name = expected.getString("file")
    val target = File(directory, "kotlin-persisted").also { check(it.isDirectory || it.mkdirs()) }
    val cacheFile = File(target, name).also { it.writeText(bytes) }
    val restored = ServerScoreCacheCodec.parseSnapshot(cacheFile.readText(), cache.day, cache.ownerId)
    check(restored.compute == cache.compute) { "$name: canonical contract changed after disk reload" }
    check(ServerComputeRevisionFence.admits(cache, restored)) { "$name: identical revision rejected" }
    val contract = requireNotNull(restored.compute) { "$name: missing final canonical contract" }
    check(contract.families.size == 27 && contract.ownedMetrics == ServerComputeContract.metricIDs)
    val devices = contract.families.values.map { it.deviceId }.toSet()
    check(devices.size == 1) { "$name: mixed canonical devices" }
    if (devices.single() == null) {
        check(contract.families.values.all { it.reason == "device_registration_pending" &&
            !it.authorized && it.resultRevision == null && it.metrics.all { metric -> it.value(metric) == null } })
        return
    }
    val device = requireNotNull(devices.single())
    expected.optString("expectedDeviceId").takeUnless { it.isBlank() || it == "null" }?.let { check(device == it) }
    val observed = ServerMetricOwnership(contract.project, contract.ownerId, device).observe(restored)
    check(observed.metrics == ServerComputeContract.metricIDs) { "$name: production ledger lost family ownership" }
    // This is the production SharedPreferences ledger codec, persisted through a JVM file backend.
    // The Android application suite separately exercises the actual SharedPreferences adapter.
    val ledgerFile = File(target, "$name.ownership").also { it.writeText(observed.encode()) }
    val ledger = ServerMetricOwnership.restore(ledgerFile.readText(), contract.project, contract.ownerId, device)
    check(ledger == observed) { "$name: production ownership codec changed after disk reload" }
    val selected = requireNotNull(ledger.presentation(restored, cache.day))
    check(selected.compute == contract && selected.ownedMetrics == ServerComputeContract.metricIDs)
    val empty = requireNotNull(ledger.presentation(null, "1900-01-01", readFailed = true))
    check(empty.ownedMetrics == ServerComputeContract.metricIDs && empty.compute == null && empty.readFailure == "server_read_failed") {
        "$name: historical empty/read-failed day lost explicit server ownership"
    }
    for ((project, owner, strap) in listOf(Triple("https://other.invalid", contract.ownerId, device),
        Triple(contract.project, UUID.randomUUID().toString(), device),
        Triple(contract.project, contract.ownerId, UUID.randomUUID().toString()))) {
        check(ServerMetricOwnership.restore(ledgerFile.readText(), project, owner, strap).metrics.isEmpty()) {
            "$name: persisted ownership crossed project/account/device"
        }
    }
    val raw = JSONObject(bytes).getJSONObject("server_scoring").getJSONObject("compute")
    val rawFamilies = raw.getJSONObject("families")
    for ((key, family) in contract.families) {
        check(JSONObject(family.json).similar(rawFamilies.getJSONObject(key))) {
            "$name: $key immutable identity/evidence/value changed after persistence"
        }
        for (metric in family.metrics) {
            val value = if (family.authorized && !family.expired()) rawFamilies.getJSONObject(key).getJSONObject("values").opt(metric) else null
            check(JSONObject().put("value", value ?: JSONObject.NULL).similar(
                JSONObject().put("value", family.value(metric) ?: JSONObject.NULL))) { "$name: canonical $metric selection differs" }
        }
    }
    val aliases = mapOf("sleep" to "sleep_total_min", "hrv" to "hrv_rmssd_ms", "respiration" to "resp_rate_bpm")
    expected.optJSONObject("expectedValues")?.let { values -> for (key in values.keys()) {
        val metric = aliases.getValue(key)
        check(contract.familyFor(metric)?.number(metric) == values.getDouble(key)) {
            "$name: final canonical $metric differs from SQL fixture expectation"
        }
    } }
    expected.optJSONObject("expectedCanonicalValues")?.let { values -> for (metric in values.keys()) {
        check(contract.familyFor(metric)?.number(metric) == values.getDouble(metric)) { "$name: canonical $metric unit/value differs" }
    } }
    expected.getJSONArray("unavailableFeatures").let { unavailable -> for (i in 0 until unavailable.length()) {
        val metric = aliases.getValue(unavailable.getString(i))
        check(contract.familyFor(metric)?.value(metric) == null) { "$name: unauthorized canonical $metric was selected" }
    } }
    val restricted = (if (expected.getBoolean("nestedHrvAvailable")) emptyList() else listOf("hrv_rmssd_ms", "hrv_sdnn_ms",
        "resting_hr_bpm", "overnight_hr_bpm", "hrv_summary", "heart_rate_windows", "recovery", "strain", "spo2_pct", "skin_temp_c", "skin_temp_dev_c")) +
        (if (expected.getBoolean("nestedRespirationAvailable")) emptyList() else listOf("resp_rate_bpm", "respiration_summary"))
    val sleep = rawFamilies.getJSONObject("sleep")
    for (nights in listOf(sleep.getJSONObject("details").optJSONArray("nights"), sleep.getJSONObject("values").optJSONArray("sleep_sessions"))) {
        if (nights != null) for (i in 0 until nights.length()) for (field in restricted) {
            check(nights.getJSONObject(i).isNull(field)) { "$name: canonical sleep leaked $field" }
        }
    }
    for ((key, value) in listOf("project" to "https://other.invalid", "owner_id" to UUID.randomUUID().toString(),
        "source_id" to UUID.randomUUID().toString(), "device_id" to UUID.randomUUID().toString(), "day" to "1900-01-01")) {
        val other = changedContract(restored) { compute ->
            compute.put(key, value)
            val families = compute.getJSONObject("families")
            for (family in families.keys()) families.getJSONObject(family).put(if (key == "day") "window" else key, value)
        }
        check(!ServerComputeRevisionFence.admits(restored, other)) { "$name: revision fence crossed $key" }
    }
    for ((key, family) in contract.families) {
        val metric = family.metrics.firstOrNull { family.number(it) != null } ?: continue
        val value = requireNotNull(family.number(metric))
        val changed = changedContract(restored) {
            it.getJSONObject("families").getJSONObject(key).getJSONObject("values").put(metric, value + 1)
        }
        check(!ServerComputeRevisionFence.admits(restored, changed)) { "$name: immutable $key values mutated" }
        family.inputRevision?.takeIf { it > 0 }?.let { revision ->
            val older = changedContract(restored) { it.getJSONObject("families").getJSONObject(key).put("input_revision", revision - 1) }
            check(!ServerComputeRevisionFence.admits(restored, older)) { "$name: older input revision admitted" }
        }
        val revoked = changedContract(restored) {
            val result = it.getJSONObject("families").getJSONObject(key).put("status", "revoked").put("reason", "qualification_revoked")
            for (m in family.metrics) result.getJSONObject("values").put(m, JSONObject.NULL)
        }
        check(ServerComputeRevisionFence.admits(restored, revoked) &&
            revoked.compute?.families?.get(key)?.resultRevision == family.resultRevision &&
            revoked.compute?.families?.get(key)?.value(metric) == null) { "$name: same-identity revocation did not clear canonical value" }
    }
}

fun main(args: Array<String>) {
    require(args.size == 1) { "usage: DecodeContract FIXTURE_DIRECTORY" }
    val directory = File(args.single())
    val expectations = JSONArray(File(directory, "expectations.json").readText())
    require(expectations.length() > 0) { "No real Edge envelopes were supplied" }
    for (index in 0 until expectations.length()) {
        val expected = expectations.getJSONObject(index)
        val name = expected.getString("file")
        val bytes = File(directory, name).readText()
        val day = expected.getString("day")
        val cache = ServerScoreCacheCodec.parseSnapshot(bytes, day, expected.getString("ownerId"))
        verifyCanonicalSelection(cache, bytes, expected, directory)
        if (name.contains("pending-device")) {
            val compute = requireNotNull(cache.compute)
            check(compute.families.size == 27 && compute.ownedMetrics == com.noop.push.ServerComputeContract.metricIDs)
            check(compute.families.values.all { family ->
                family.deviceId == null && !family.authorized && family.resultRevision == null &&
                    family.reason == "device_registration_pending" && family.metrics.all { family.value(it) == null }
            }) { "$name: pending registration must remain explicitly server-owned without a fabricated device or measurement" }
        }
        // Legacy projection assertions retain provenance compatibility, not final-mode selection proof.
        val available = expected.getJSONArray("availableFeatures")
        val unavailable = expected.getJSONArray("unavailableFeatures")
        for (i in 0 until available.length()) {
            val key = available.getString(i)
            check(cache.features[key]?.isCanonicalAvailable == true) { "$name: $key did not activate" }
            (expected.opt("expectedDeviceId") as? String)?.let { device ->
                check(cache.features[key]?.deviceId == device) { "$name: selected device differs" }
            }
        }
        val metrics = mapOf("sleep" to ServerVitalSelection.Metric.SLEEP, "hrv" to ServerVitalSelection.Metric.HRV,
            "respiration" to ServerVitalSelection.Metric.RESPIRATORY)
        expected.optJSONObject("expectedValues")?.let { values ->
            for (key in values.keys()) {
                val selection = ServerVitalSelection.resolve(metrics.getValue(key), true, day, cache, null)
                check(selection.value == values.getDouble(key) && selection.fromServer && selection.displayDiagnostic.status == "available") {
                    "$name: selected $key value differs"
                }
            }
        }
        for (i in 0 until unavailable.length()) {
            val key = unavailable.getString(i)
            check(cache.features[key]?.isCanonicalAvailable != true) { "$name: $key unexpectedly activated" }
            metrics[key]?.let { metric ->
                val selection = ServerVitalSelection.resolve(metric, true, day, cache, null)
                check(selection.value == null && selection.displayDiagnostic.status == "unavailable") { "$name: unavailable value reached display selection" }
            }
        }
        val nestedHrv = expected.getBoolean("nestedHrvAvailable")
        val nestedRespiration = expected.getBoolean("nestedRespirationAvailable")
        check(cache.nights.any { it.hrvRmssdMs != null } == nestedHrv) { "$name: embedded HRV availability differs" }
        check(cache.nights.any { it.respRateBpm != null } == nestedRespiration) { "$name: embedded respiration availability differs" }
        val nights = JSONObject(bytes).getJSONObject("server_scoring").optJSONArray("nights") ?: JSONArray()
        for (i in 0 until nights.length()) {
            val night = nights.getJSONObject(i)
            val fields = (if (nestedHrv) emptyList() else listOf("hrv_rmssd_ms", "hrv_sdnn_ms", "resting_hr_bpm", "overnight_hr_bpm", "hrv_summary", "heart_rate_windows",
                "recovery", "strain", "spo2_pct", "skin_temp_c", "skin_temp_dev_c")) +
                (if (nestedRespiration) emptyList() else listOf("resp_rate_bpm", "respiration_summary"))
            for (field in fields) check(night.isNull(field)) { "$name: real Edge envelope leaked $field" }
        }
        println("kotlin $name: decoded and display selection verified")
    }
    println("kotlin: ${expectations.length()} real Edge envelopes passed")
    println("kotlin: ${expectations.length()} canonical persisted selections passed")
}
