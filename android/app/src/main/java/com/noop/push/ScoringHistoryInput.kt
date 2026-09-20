package com.noop.push

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId

/** Only approved mobile input families have constructors. Other server kinds remain inactive. */
data class ScoringProfileInput(val age: Double?, val sex: String?, val weightKg: Double?, val heightCm: Double?,
    val waistCm: Double?, val stepTicksPerStep: Double?, val timezone: String) {
    fun payload(): String {
        ZoneId.of(timezone)
        require(sex == null || sex in setOf("male", "female", "nonbinary"))
        require(listOf(age, weightKg, heightCm, waistCm, stepTicksPerStep).all { it == null || (it.isFinite() && it > 0 && it <= 500) })
        return SyncJson.canonical(JSONObject().put("schemaVersion", 1).put("age", age ?: JSONObject.NULL)
            .put("sex", sex ?: JSONObject.NULL).put("weightKg", weightKg ?: JSONObject.NULL)
            .put("heightCm", heightCm ?: JSONObject.NULL).put("waistCm", waistCm ?: JSONObject.NULL)
            .put("stepTicksPerStep", stepTicksPerStep ?: JSONObject.NULL).put("timezone", timezone))
    }
}
data class ScoringConfigInput(val maxHR: Double?, val effortMethod: String, val deepHrvWindow: Boolean,
    val useSleepStagerV2: Boolean, val useMotionAwareWake: Boolean, val sleepNeedHours: Double?,
    val hrvBaselineEpoch: Long, val recoveryBaselineEpoch: Long, val sourceEra: String) {
    fun payload(): String {
        require(maxHR == null || maxHR in 80.0..240.0); require(sleepNeedHours == null || sleepNeedHours in 3.0..14.0)
        require(effortMethod in setOf("EDWARDS", "BANISTER")); require(hrvBaselineEpoch >= 0 && recoveryBaselineEpoch >= 0)
        require(sourceEra.isNotBlank() && sourceEra.length <= 512)
        return SyncJson.canonical(JSONObject().put("schemaVersion", 1).put("maxHR", maxHR ?: JSONObject.NULL)
            .put("effortMethod", effortMethod).put("deepHrvWindow", deepHrvWindow).put("useSleepStagerV2", useSleepStagerV2)
            .put("useMotionAwareWake", useMotionAwareWake).put("sleepNeedHours", sleepNeedHours ?: JSONObject.NULL)
            .put("hrvBaselineEpoch", hrvBaselineEpoch).put("recoveryBaselineEpoch", recoveryBaselineEpoch).put("sourceEra", sourceEra)
            .put("journalContextEnabled", false).put("cycleAwarenessEnabled", false).put("daytimePersonalBaselineEnabled", false))
    }
}
data class ScoringSleepEdit(val session: ScoreSleep, val start: Long, val end: Long, val isNap: Boolean,
    val dismissed: Boolean, val stages: List<ScoreStage>? = null) {
    fun payload(): String {
        require(start > 0 && end > start && end - start <= 48 * 3600 && end <= 253402300799L)
        require(session.originalStart > 0 && session.originalEnd > session.originalStart)
        var prior = start
        stages?.forEach { require(it.start >= prior && it.end > it.start && it.end <= end && it.stage in setOf("wake", "light", "deep", "rem")); prior = it.end }
        val o = JSONObject().put("schemaVersion", 1).put("originalStart", session.originalStart).put("originalEnd", session.originalEnd)
            .put("start", start).put("end", end).put("isNap", isNap).put("dismissed", dismissed)
        stages?.let { o.put("stages", JSONArray(it.map { s -> JSONObject().put("start", s.start).put("end", s.end).put("stage", s.stage) })) }
        return SyncJson.canonical(o)
    }
    fun earliestDay(timezone: String): String = listOf(session.originalEnd, session.end, end)
        .minOf { Instant.ofEpochSecond(it).atZone(ZoneId.of(timezone)).toLocalDate().toString() }
}
data class ScoringInputKey(val device: String, val kind: String, val entity: String) {
    init {
        require(SyncJson.uuid(device) == device)
        require(kind in setOf("profile", "config", "sleep_edit"))
        require(if (kind == "sleep_edit") entity.startsWith("sleep:") && SyncJson.uuid(entity.removePrefix("sleep:")) == entity.removePrefix("sleep:") else entity == "primary")
    }
    val storageKey: String get() = "$device/$kind/$entity"
    fun rpc() = JSONObject().put("p_device", device).put("p_kind", kind).put("p_entity", entity)
}
data class ScoringInputHead(val key: ScoringInputKey, val revision: Long) {
    companion object {
        fun decode(body: String, scope: AccountScope, key: ScoringInputKey): ScoringInputHead {
            val o = JSONObject(body); validateInputIdentity(o, scope, key)
            return ScoringInputHead(key, SyncJson.long(o, "headRevision").also { require(it >= 0) })
        }
    }
}

data class ScoringHistoryValue(val key: ScoringInputKey, val headRevision: Long, val revision: Long?,
    val effectiveDay: String?, val deleted: Boolean?, val payloadJson: String?) {
    companion object {
        fun decode(body: String, scope: AccountScope, key: ScoringInputKey, asOfDay: String): ScoringHistoryValue {
            SyncJson.day(asOfDay)
            val o = JSONObject(body); validateInputIdentity(o, scope, key)
            val head = SyncJson.long(o, "headRevision"); require(head >= 0)
            if (o.isNull("revision")) {
                require(o.isNull("effectiveDay") && o.isNull("deleted") && o.isNull("payload"))
                return ScoringHistoryValue(key, head, null, null, null, null)
            }
            val revision = SyncJson.long(o, "revision"); require(revision in 1..head)
            val effective = SyncJson.day(SyncJson.string(o, "effectiveDay")); require(effective <= asOfDay)
            val deleted = SyncJson.bool(o, "deleted")
            val payload = SyncJson.objectOrNull(o, "payload")
            if (deleted) require(payload == null) else require(payload != null && SyncJson.long(payload, "schemaVersion") == 1L)
            return ScoringHistoryValue(key, head, revision, effective, deleted, payload?.let(SyncJson::canonical))
        }
    }
}
internal fun validateInputIdentity(o: JSONObject, scope: AccountScope, key: ScoringInputKey) {
    require(SyncJson.long(o, "schemaVersion") == 1L && SyncJson.uuid(SyncJson.string(o, "userId")) == scope.userID &&
        SyncJson.uuid(SyncJson.string(o, "sourceDeviceId")) == key.device && SyncJson.string(o, "kind") == key.kind &&
        SyncJson.string(o, "entity") == key.entity)
}

data class ScoringInputReceipt(val revision: Long, val invalidatedFrom: String, val json: String) {
    companion object {
        fun decode(body: String, scope: AccountScope, request: ScoringInputMutation): ScoringInputReceipt {
            val o = JSONObject(body); val b = JSONObject(request.body)
            validateInputIdentity(o, scope, request.key())
            require(SyncJson.uuid(SyncJson.string(o, "clientId")) == b.getString("p_client_id") &&
                SyncJson.uuid(SyncJson.string(o, "clientMutationId")) == request.mutationId &&
                SyncJson.long(o, "clientRevision") == request.clientRevision &&
                SyncJson.string(o, "effectiveDay") == b.getString("p_effective_day") &&
                SyncJson.bool(o, "deleted") == b.getBoolean("p_deleted"))
            val revision = SyncJson.long(o, "revision"); require(revision > b.getLong("p_expected_revision"))
            val from = SyncJson.day(SyncJson.string(o, "invalidatedFrom")); require(from <= b.getString("p_effective_day"))
            // Retain the typed proof, like Swift's Codable receipt, not arbitrary server extension
            // blobs. Every retained field is bounded by the validated UUID/day/key/integer contract.
            val proof = JSONObject()
            for (key in listOf("schemaVersion", "userId", "sourceDeviceId", "kind", "entity", "revision",
                "clientId", "clientMutationId", "clientRevision", "effectiveDay", "deleted", "invalidatedFrom"))
                proof.put(key, o.get(key))
            return ScoringInputReceipt(revision, from, SyncJson.canonical(proof))
        }
    }
}
