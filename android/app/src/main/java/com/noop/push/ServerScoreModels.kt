package com.noop.push

data class ServerScoreDailyCache(
    val hrvRmssdMs: Double? = null,
    val restingHrBpm: Int? = null,
    val sleepTotalMin: Double? = null,
    val sleepInBedMin: Double? = null,
    val sleepAwakeMin: Double? = null,
    val sleepLightMin: Double? = null,
    val sleepDeepMin: Double? = null,
    val sleepRemMin: Double? = null,
    val sleepEfficiency: Double? = null,
    val respRateBpm: Double? = null,
    val computedAt: String? = null,
    val sleepUnstagedMin: Double? = null,
    val stateUnknownMin: Double? = null,
    val offBodyMin: Double? = null,
    val opportunityKind: String? = null,
    val recovery: Double? = null,
    val strain: Double? = null,
    val spo2Pct: Double? = null,
    val skinTempC: Double? = null,
    val skinTempDevC: Double? = null,
)

data class ServerScoreNightCache(
    val id: String,
    val startAt: String,
    val endAt: String,
    val isNap: Boolean,
    val asleepMin: Double? = null,
    val inBedMin: Double? = null,
    val lightMin: Double? = null,
    val deepMin: Double? = null,
    val remMin: Double? = null,
    val awakeMin: Double? = null,
    val efficiency: Double? = null,
    val hrvRmssdMs: Double? = null,
    val restingHrBpm: Int? = null,
    val stages: List<ServerScoreStageCache> = emptyList(),
    val deviceId: String? = null,
    val episodeType: String? = null,
    val mainSleepGroupId: String? = null,
    val boundaryProvenance: String? = null,
    val opportunityKind: String? = null,
    val measurementAvailable: Boolean? = null,
    val sleepUnstagedMin: Double? = null,
    val stateUnknownMin: Double? = null,
    val offBodyMin: Double? = null,
    val stateCoverage: Double? = null,
    val manualEdit: Boolean? = null,
    val startTimezoneId: String? = null,
    val endTimezoneId: String? = null,
)

data class ServerScoreDayCache(
    val day: String,
    val algorithmVersion: String,
    val daily: ServerScoreDailyCache?,
    val nights: List<ServerScoreNightCache>,
    val computedAt: String?,
    val stale: Boolean,
    val fetchedAtMs: Long,
    val ownerId: String = "",
    val schemaVersion: Int = 2,
    val features: Map<String, ServerScoreFeatureCache> = emptyMap(),
    val rawSnapshotJSON: String? = null,
) {
    val scopeKey: String get() = org.json.JSONArray(features.keys.sorted().map {
        listOf(it, features[it]?.deviceId ?: "", features[it]?.algorithmVersion ?: "")
    }).toString()
    val measurementsJSON: String? get() = rawSnapshotJSON?.let {
        org.json.JSONObject(it).optJSONObject("server_scoring")?.optJSONArray("measurements")?.toString()
    }
}

data class ServerScoreStageCache(
    val start: Long, val end: Long, val stage: String, val state: String,
    val sleepProbability: Double?, val pWake: Double?, val pLight: Double?, val pDeep: Double?, val pRem: Double?,
    val evidenceCoverage: Double?, val reason: String?, val calibrationStatus: String?,
    val algorithmVersion: String?, val computationMode: String?,
)

data class ServerScoreFeatureCache(
    val status: String, val reason: String?, val deviceId: String?, val algorithmVersion: String?,
    val inputRevision: Long?, val requiredRevision: Long?, val computedAt: String?, val observedThrough: String?,
    val publicationStatus: String?, val archiveStatus: String?, val manifestHash: String?,
    val supportsBoundaryOverrides: Boolean? = null,
    val processingStatus: String? = null,
    val timezoneId: String? = null,
    val timezoneIds: List<String>? = null,
)

val ServerScoreDayCache.sleepMetadataLines: List<String> get() {
    val feature = features["sleep"] ?: return emptyList()
    return buildList {
        add("Device: ${feature.deviceId ?: "unavailable"}")
        add("Model: ${feature.algorithmVersion ?: "unavailable"}")
        if (feature.algorithmVersion == "frwhoop-server-1") add("Legacy baseline · quality and evidence coverage unavailable")
        add("Observed through: ${feature.observedThrough ?: "unavailable"}")
        add("Computed: ${feature.computedAt ?: "unavailable"}")
        add("Fetched: ${java.time.Instant.ofEpochMilli(fetchedAtMs)}")
        add("Revision: ${feature.inputRevision ?: "unavailable"} · required: ${feature.requiredRevision ?: "unavailable"}")
        add("Processing: ${feature.processingStatus ?: "unavailable"} · archive: ${feature.archiveStatus ?: "unavailable"}")
        val zones = feature.timezoneIds?.filter { it.isNotBlank() } ?: listOfNotNull(feature.timezoneId)
        add("Time zones: ${zones.takeIf { it.isNotEmpty() }?.joinToString(" · ") ?: "unavailable"}")
    }
}

val ServerScoreNightCache.stateCoverageDescription: String get() = stateCoverage?.takeIf { it.isFinite() && it in 0.0..1.0 }
    ?.let { String.format(java.util.Locale.getDefault(), "State coverage: %.0f%%", it * 100) } ?: "State coverage: unavailable"

/** Shared account fence; delayed values remain rejected after later same-owner sign-in. */
class ServerScoreSessionState {
    private var owner: String? = null
    private var epoch: Long = 0
    private val values = mutableMapOf<String, ServerScoreDayCache>()
    private val requests = mutableMapOf<String, Long>()
    @Synchronized fun ownerId(): String? = owner
    @Synchronized fun generation(): Long = epoch
    @Synchronized fun activate(ownerId: String?) {
        owner = ownerId?.lowercase(); epoch++; values.clear(); requests.clear()
    }
    @Synchronized fun beginRequest(day: String): Long = ((requests[day] ?: 0) + 1).also { requests[day] = it }
    @Synchronized fun isCurrentRequest(day: String, generation: Long, currentOwnerId: String?, request: Long): Boolean =
        generation == epoch && owner != null && currentOwnerId?.lowercase() == owner && requests[day] == request
    @Synchronized fun overlay(day: String, currentOwnerId: String?): ServerScoreDayCache? =
        if (owner != null && currentOwnerId?.lowercase() == owner) values[day] else null
    @Synchronized fun accept(value: ServerScoreDayCache, generation: Long, currentOwnerId: String?, request: Long? = null): Boolean {
        if (generation != epoch || owner == null || currentOwnerId?.lowercase() != owner || value.ownerId != owner ||
            value.schemaVersion != 2 || value.features.isEmpty()) return false
        if (request != null && requests[value.day] != request) return false
        val old = values[value.day]
        if (old?.scopeKey == value.scopeKey && old.features.any { (key, prior) ->
            prior.inputRevision != null && value.features[key]?.inputRevision?.let { it < prior.inputRevision } == true
        }) return false
        values[value.day] = value
        return true
    }
}
