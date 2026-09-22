import com.noop.push.ServerScoreCacheCodec
import com.noop.push.ServerVitalSelection
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

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
        expected.optJSONArray("signalWindows")?.let { windows ->
            check(cache.signalWindows.size == windows.length()) { "$name: signal diagnostics were dropped" }
            cache.signalWindows.forEachIndexed { i, actual ->
                val wanted = windows.getJSONObject(i)
                check(actual.windowId == wanted.getString("id") && actual.kind == wanted.getString("kind") &&
                    actual.reason == wanted.getString("reason") && actual.measurementStatus == wanted.getString("status") &&
                    actual.inputRevision == wanted.getLong("revision")) { "$name: signal identity, revision or missingness differs" }
            }
            check(ServerScoreCacheCodec.parseSnapshot(cache.rawSnapshotJSON!!, day, cache.ownerId).signalWindows == cache.signalWindows) {
                "$name: diagnostic cache round trip differs"
            }
        }
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
}
