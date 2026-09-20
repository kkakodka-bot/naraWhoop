package com.noop.push

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

internal object SyncJson {
    fun objectOrNull(o: JSONObject, key: String): JSONObject? = if (o.isNull(key)) null else o.get(key) as JSONObject
    fun arrayOrNull(o: JSONObject, key: String): JSONArray? = if (o.isNull(key)) null else o.get(key) as JSONArray
    fun uuid(value: String): String = UUID.fromString(value).toString().also {
        require(it.equals(value, true)) { "Invalid UUID" }
    }
    fun day(value: String): String = LocalDate.parse(value).toString().also { require(it == value && value.length == 10) }
    fun long(o: JSONObject, key: String): Long {
        val value = o.get(key)
        require(value is Int || value is Long) { "Integer required: $key" }
        return (value as Number).toLong()
    }
    fun number(o: JSONObject, key: String, negative: Boolean = false): Double? {
        if (!o.has(key) || o.isNull(key)) return null
        val value = o.get(key)
        require(value is Number)
        return value.toDouble().also { require(it.isFinite() && kotlin.math.abs(it) <= Int.MAX_VALUE && (negative || it >= 0)) }
    }
    fun string(o: JSONObject, key: String, limit: Int = 512): String = (o.get(key) as String).also {
        require(it.toByteArray().size <= limit)
    }
    fun bool(o: JSONObject, key: String): Boolean = o.get(key) as Boolean
    fun canonical(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(",", "{", "}") {
            JSONObject.quote(it) + ":" + canonical(value.get(it))
        }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
        is String -> JSONObject.quote(value)
        is Number -> JSONObject.numberToString(value)
        is Boolean -> value.toString()
        else -> error("Unsupported JSON")
    }
}

data class ScoreMetric(val value: Double?, val unit: String?, val status: String?, val method: String?)
data class ScoreChartPoint(val start: Long, val end: Long?, val value: Double?, val count: Long?, val min: Double?, val max: Double?)
data class ScoreHistoryDay(val day: String, val metrics: Map<String, ScoreMetric>)
data class ScoreDependency(val stateSchemaVersion: Long, val generation: Long, val predecessorResultRevision: Long?,
    val configurationRevision: Long, val profileRevision: Long, val sourceEra: String)
data class ScoreStage(val start: Long, val end: Long, val stage: String)
data class ScoreSleep(val id: String, val start: Long, val end: Long, val isNap: Boolean,
    val originalStart: Long, val originalEnd: Long, val editEntity: String, val stages: List<ScoreStage>,
    val values: Map<String, Double?>) {
    fun legacy() = ServerScoreNightCache(id, Instant.ofEpochSecond(start).toString(), Instant.ofEpochSecond(end).toString(), isNap,
        values["asleep_min"], values["in_bed_min"], values["light_min"], values["deep_min"], values["rem_min"],
        values["awake_min"], values["efficiency"], values["hrv_rmssd_ms"], values["resting_hr_bpm"]?.toInt())
}

/** One validated immutable result. The JSON string, including unknown extensions, is preserved. */
data class ServerSnapshotV2 internal constructor(
    val userId: String, val sourceDeviceId: String, val day: String, val timezone: String,
    val algorithmVersion: String, val inputRevision: Long, val resultRevision: Long,
    val computedAt: String, val dataThrough: String?, val status: String,
    val capabilities: Set<String>, val daily: Map<String, Double?>, val sleep: List<ScoreSleep>,
    val metrics: Map<String, ScoreMetric>, val charts: Map<String, List<ScoreChartPoint>>,
    val history: List<ScoreHistoryDay>, val dependency: ScoreDependency?,
    val coverageJson: String, val chartMetadataJson: String?, val detailsJson: String?, val json: String,
) {
    fun value(key: String): Double? = if (key !in capabilities || status == "no_data") null
        else if (metrics.containsKey(key)) metrics.getValue(key).value else daily[key]
    fun legacy(fetchedAt: Long, pending: Boolean) = ServerScoreDayCache(day, algorithmVersion,
        if (status == "no_data") null else ServerScoreDailyCache(
            value("hrv_rmssd_ms"), value("resting_hr_bpm")?.toInt(), value("sleep_total_min"), value("sleep_in_bed_min"),
            value("sleep_awake_min"), value("sleep_light_min"), value("sleep_deep_min"), value("sleep_rem_min"),
            value("sleep_efficiency"), value("resp_rate_bpm"), computedAt),
        if ("sleep_sessions" in capabilities) sleep.map { it.legacy() } else emptyList(), computedAt, pending, fetchedAt)
}

data class ServerSnapshotResponse(val day: String, val status: String, val sourceDeviceId: String?, val timezone: String?,
    val algorithmVersion: String?, val pending: Boolean, val requestedInputRevision: Long?, val archiveStatus: String?,
    val snapshot: ServerSnapshotV2?)

object ServerSnapshotDecoder {
    const val MAX_BYTES = 512 * 1024
    val coreCapabilities = setOf("hrv_rmssd_ms", "hrv_sdnn_ms", "resting_hr_bpm", "resp_rate_bpm", "sleep_total_min",
        "sleep_in_bed_min", "sleep_awake_min", "sleep_light_min", "sleep_deep_min", "sleep_rem_min", "sleep_efficiency",
        "disturbances", "sleep_sessions")
    private fun nullableString(o: JSONObject, key: String) = if (o.isNull(key)) null else SyncJson.string(o, key)
    private fun nullableLong(o: JSONObject, key: String) = if (o.isNull(key)) null else SyncJson.long(o, key).also { require(it >= 0) }
    private fun timestamp(value: String): Long = Instant.parse(value).epochSecond.also { require(it in 0..253402300799L) }
    private fun metricMap(o: JSONObject): Map<String, ScoreMetric> {
        require(o.length() <= 256)
        return o.keys().asSequence().associateWith { key ->
            require(key.length <= 128)
            val m = o.getJSONObject(key)
            ScoreMetric(SyncJson.number(m, "value", key in setOf("skin_temp_c", "skin_temp_dev_c")),
                nullableString(m, "unit"), nullableString(m, "status"), nullableString(m, "method"))
        }
    }
    fun decode(body: String, owner: AccountScope, requestedDay: String, expectedTimezone: String? = null): ServerSnapshotResponse {
        require(body.toByteArray().size <= MAX_BYTES)
        val o = JSONObject(body)
        require(SyncJson.long(o, "schemaVersion") == 2L) { "Unsupported snapshot schema" }
        val day = SyncJson.day(SyncJson.string(o, "day")); require(day == requestedDay)
        val status = SyncJson.string(o, "status")
        require(status in setOf("available", "partial", "no_data", "pending", "failed", "unsupported"))
        // The unsupported algorithm envelope intentionally carries no owner; it can never replace data.
        if (status != "unsupported") require(SyncJson.uuid(SyncJson.string(o, "userId")) == owner.userID)
        val source = nullableString(o, "sourceDeviceId")?.let(SyncJson::uuid)
        val timezone = nullableString(o, "timezone")?.also { ZoneId.of(it) }
        if (expectedTimezone != null && timezone != null) require(timezone == expectedTimezone) { "Timezone mismatch" }
        val algorithm = nullableString(o, "algorithmVersion")?.also { require(it.isNotBlank()) }
        val pending = if (o.isNull("pending")) status == "pending" else SyncJson.bool(o, "pending")
        val revision = nullableLong(o, "requestedInputRevision")
        val archive = nullableString(o, "archiveStatus")
        if (status !in setOf("available", "partial", "no_data"))
            return ServerSnapshotResponse(day, status, source, timezone, algorithm, pending, revision, archive, null)
        require(source != null && timezone != null && algorithm != null)
        val input = SyncJson.long(o, "inputRevision"); val result = SyncJson.long(o, "resultRevision")
        require(input >= 0 && result > 0)
        val computed = SyncJson.string(o, "computedAt").also(::timestamp)
        val through = nullableString(o, "dataThrough")?.also(::timestamp)
        val caps = SyncJson.arrayOrNull(o, "capabilities")?.let { a ->
            require(a.length() <= 256)
            (0 until a.length()).map { (a.get(it) as String).also { s -> require(s.length <= 128) } }.toSet()
        } ?: coreCapabilities
        val daily = SyncJson.objectOrNull(o, "daily")?.let { d ->
            require(d.length() <= 256)
            coreCapabilities.filter { it != "sleep_sessions" }.forEach { if (d.has(it)) SyncJson.number(d, it) }
            d.keys().asSequence().filter { d.isNull(it) || d.get(it) is Number }.associateWith {
                SyncJson.number(d, it, it in setOf("skin_temp_c", "skin_temp_dev_c"))
            }
        } ?: emptyMap()
        val sleepArray = o.getJSONArray("sleep"); require(sleepArray.length() <= 128)
        val sleep = (0 until sleepArray.length()).map { decodeSleep(sleepArray.getJSONObject(it)) }
        require(sleep.map { it.id }.toSet().size == sleep.size)
        val metrics = metricMap(SyncJson.objectOrNull(o, "metrics") ?: JSONObject())
        if (status == "no_data") require(o.isNull("daily") && sleep.isEmpty() && metrics.values.none { it.value != null })
        val chartsObject = SyncJson.objectOrNull(o, "charts") ?: JSONObject(); require(chartsObject.length() <= 64)
        val charts = chartsObject.keys().asSequence().associateWith { key ->
            require(key.length <= 128)
            val a = chartsObject.getJSONArray(key); require(a.length() <= 10080)
            var previousEnd = 0L
            (0 until a.length()).map { index ->
                val p = a.getJSONObject(index); val start = SyncJson.long(p, "start"); val end = nullableLong(p, "end")
                require(start in previousEnd..253402300799L && (end == null || end in (start + 1)..253402300799L))
                previousEnd = end ?: start + 1
                val count = nullableLong(p, "count"); require(count == null || count > 0)
                val v = SyncJson.number(p, "value", true); val lo = SyncJson.number(p, "min", true); val hi = SyncJson.number(p, "max", true)
                require(lo == null || hi == null || lo <= hi)
                require(v == null || ((lo == null || v >= lo) && (hi == null || v <= hi)))
                ScoreChartPoint(start, end, v, count, lo, hi)
            }
        }
        val ha = SyncJson.arrayOrNull(o, "history") ?: JSONArray(); require(ha.length() <= 400)
        val history = (0 until ha.length()).map {
            val h = ha.getJSONObject(it); val hd = SyncJson.day(SyncJson.string(h, "day")); require(hd <= day)
            ScoreHistoryDay(hd, metricMap(h.getJSONObject("metrics")))
        }; require(history.map { it.day }.toSet().size == history.size)
        val dependency = SyncJson.objectOrNull(o, "dependency")?.let { d ->
            ScoreDependency(SyncJson.long(d, "stateSchemaVersion").also { require(it == 1L) },
                SyncJson.long(d, "generation").also { require(it >= 0) }, nullableLong(d, "predecessorResultRevision"),
                SyncJson.long(d, "configurationRevision").also { require(it >= 0) },
                SyncJson.long(d, "profileRevision").also { require(it >= 0) }, SyncJson.string(d, "sourceEra"))
        }
        val snapshot = ServerSnapshotV2(owner.userID, source, day, timezone, algorithm, input, result, computed, through, status,
            caps, daily, sleep, metrics, charts, history, dependency, SyncJson.canonical(o.getJSONObject("coverage")),
            SyncJson.objectOrNull(o, "chartMetadata")?.let(SyncJson::canonical), SyncJson.objectOrNull(o, "details")?.let(SyncJson::canonical),
            SyncJson.canonical(o))
        return ServerSnapshotResponse(day, status, source, timezone, algorithm, pending, revision, archive, snapshot)
    }
    private fun decodeSleep(o: JSONObject): ScoreSleep {
        val id = SyncJson.uuid(SyncJson.string(o, "id")); val start = timestamp(SyncJson.string(o, "start_at"))
        val end = timestamp(SyncJson.string(o, "end_at")); require(end > start && end - start <= 7 * 86400)
        val originalStart = nullableLong(o, "originalStart"); val originalEnd = nullableLong(o, "originalEnd")
        val entity = nullableString(o, "editEntity")
        if (originalStart != null || originalEnd != null || entity != null)
            require(originalStart != null && originalEnd != null && originalStart > 0 && originalEnd > originalStart &&
                originalEnd <= 253402300799L && entity == "sleep:$id")
        val a = o.getJSONArray("stages"); require(a.length() <= 10080)
        var previousEnd = start
        val stages = (0 until a.length()).map {
            val s = a.getJSONObject(it); val lo = SyncJson.long(s, "start"); val hi = SyncJson.long(s, "end")
            val stage = SyncJson.string(s, "stage"); require(stage in setOf("wake", "awake", "light", "deep", "rem"))
            require(lo >= previousEnd && hi > lo && hi <= end); previousEnd = hi
            ScoreStage(lo, hi, stage)
        }
        val values = listOf("in_bed_min", "asleep_min", "awake_min", "light_min", "deep_min", "rem_min", "efficiency",
            "resting_hr_bpm", "hrv_rmssd_ms").associateWith { SyncJson.number(o, it) }
        return ScoreSleep(id, start, end, SyncJson.bool(o, "is_nap"), originalStart ?: start, originalEnd ?: end,
            entity ?: "sleep:$id", stages, values)
    }
}
