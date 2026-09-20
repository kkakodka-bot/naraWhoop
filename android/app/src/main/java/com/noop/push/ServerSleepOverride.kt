package com.noop.push

import org.json.JSONObject
import java.time.Instant
import java.util.UUID

data class ServerSleepOverride(val id: String,val deviceId: String,val originalStart: Long,val originalEnd: Long,
    val start: Long,val end: Long,val tombstone: Boolean,val revision: Long,
    val legacyRevision: String?=null,val originalStartAt: String?=null,val originalEndAt: String?=null)

data class ServerSleepEditTarget(val id: String,val ownerId: String,val deviceId: String,val day: String,
    val originalStart: Long,val originalEnd: Long,val start: Long,val end: Long,val expectedRevision: Long,
    val legacyRevision: String?=null,val originalStartAt: String?=null,val originalEndAt: String?=null) {
    val rpcName: String get()=if(legacyRevision==null) "set_physiology_sleep_override" else "continue_legacy_physiology_sleep_override"
    fun rpcArguments(start: Long,end: Long,tombstone: Boolean): JSONObject {
        require(end>start && end-start<=48*3600 && originalEnd>originalStart && originalEnd-originalStart<=48*3600) { "invalid sleep bounds" }
        return JSONObject().put("p_id",id).put("p_device",deviceId)
            .put("p_original_start",originalStartAt ?: Instant.ofEpochSecond(originalStart).toString())
            .put("p_original_end",originalEndAt ?: Instant.ofEpochSecond(originalEnd).toString())
            .put("p_start",Instant.ofEpochSecond(start).toString()).put("p_end",Instant.ofEpochSecond(end).toString())
            .put("p_tombstone",tombstone).put("p_expected_revision",expectedRevision)
            .apply { legacyRevision?.let { put("p_legacy_revision",it) } }
    }
    companion object {
        fun prepare(cache: ServerScoreDayCache,nightId: String,newId: String=UUID.randomUUID().toString()): ServerSleepEditTarget {
            require(cache.ownerId.isNotBlank() && cache.features["sleep"]?.supportsBoundaryOverrides==true) { "boundary edits unavailable" }
            val night=cache.nights.first { it.id==nightId }
            val device=night.deviceId ?: error("missing device")
            require(device==cache.features["sleep"]?.deviceId) { "device changed" }
            val start=Instant.parse(night.startAt).epochSecond; val end=Instant.parse(night.endAt).epochSecond
            val provenanceId=night.boundaryProvenance?.takeIf { it.startsWith("user_boundary:") }?.substringAfterLast(':')
            if(provenanceId!=null && runCatching { UUID.fromString(provenanceId) }.isSuccess) {
                val prior=cache.sleepOverrides.firstOrNull { it.deviceId==device && it.id.equals(provenanceId,ignoreCase=true) }
                require(prior!=null) { "missing override revision; refresh first" }
                return prepare(cache,prior)
            }
            val prior=cache.sleepOverrides.firstOrNull { it.deviceId==device && (
                (it.start==start && it.end==end) || (it.originalStart==start && it.originalEnd==end)) }
            if(prior!=null) return prepare(cache,prior)
            UUID.fromString(newId)
            return ServerSleepEditTarget(newId,cache.ownerId,device,cache.day,start,end,start,end,0)
        }
        fun prepare(cache: ServerScoreDayCache,existing: ServerSleepOverride): ServerSleepEditTarget {
            require(cache.ownerId.isNotBlank() && cache.features["sleep"]?.supportsBoundaryOverrides==true &&
                cache.features["sleep"]?.deviceId==existing.deviceId &&
                (existing.revision>0 || (existing.revision==0L && validLegacyToken(existing.legacyRevision)))) { "boundary edits unavailable" }
            UUID.fromString(existing.id)
            return ServerSleepEditTarget(existing.id,cache.ownerId,existing.deviceId,cache.day,existing.originalStart,
                existing.originalEnd,existing.start,existing.end,existing.revision,existing.legacyRevision,
                existing.originalStartAt,existing.originalEndAt)
        }
    }
}

private fun validLegacyToken(token: String?): Boolean = token?.matches(Regex("[a-f0-9]{64}"))==true

val ServerScoreDayCache.sleepOverrides: List<ServerSleepOverride> get() {
    val rows=rawSnapshotJSON?.let { JSONObject(it).optJSONObject("server_scoring")?.optJSONArray("sleep_overrides") } ?: return emptyList()
    return (0 until rows.length()).mapNotNull { i -> runCatching {
        val o=rows.getJSONObject(i)
        require(o.getString("device_id")==features["sleep"]?.deviceId)
        val token=o.optString("legacy_revision").takeIf { !o.isNull("legacy_revision") }
        val legacy=o.optString("source")=="legacy_user_boundary"
        val revision=o.getLong("revision")
        require((legacy && revision==0L && validLegacyToken(token)) || (!legacy && revision>0 && token==null))
        ServerSleepOverride(o.getString("id"),o.getString("device_id"),o.getLong("original_start"),o.getLong("original_end"),
            o.getLong("start"),o.getLong("end"),o.getBoolean("tombstone"),revision,token,
            o.optString("original_start_at").takeIf { !o.isNull("original_start_at") },
            o.optString("original_end_at").takeIf { !o.isNull("original_end_at") }).also {
                require(it.originalEnd>it.originalStart && it.end>it.start)
            }
    }.getOrNull() }
}
