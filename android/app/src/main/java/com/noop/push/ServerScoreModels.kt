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
    val rest: Double? = null,
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
    val respRateBpm: Double? = null,
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
    val ownedMetrics: Set<String>? = null,
    val readFailure: String? = null,
    val compute: ServerComputeContract? = null,
) {
    val scopeKey: String get() = org.json.JSONArray(features.keys.sorted().map {
        listOf(it, features[it]?.deviceId ?: "", features[it]?.algorithmVersion ?: "")
    }).toString()
    val measurementsJSON: String? get() = rawSnapshotJSON?.let {
        org.json.JSONObject(it).optJSONObject("server_scoring")?.optJSONArray("measurements")?.toString()
    }

    /** Diagnostic shadow windows preserve missingness; they never authorize a displayed physiological value. */
    val signalWindows: List<ServerSignalWindowCache> get() = runCatching {
        val root = org.json.JSONObject(rawSnapshotJSON ?: return emptyList()).getJSONObject("server_scoring")
        require(root.opt("user_id") == ownerId && root.opt("day") == day)
        val device = root.opt("signal_windows_device_id") as? String ?: return emptyList()
        val rows = root.optJSONArray("signal_windows") ?: return emptyList()
        require(rows.length() <= 4096)
        (0 until rows.length()).mapNotNull { index -> ServerSignalWindowCache.decode(rows.getJSONObject(index),ownerId,device) }
    }.getOrDefault(emptyList())
}

data class ServerSignalWindowCache(val windowId: String,val kind: String,val start: Long,val end: Long,
    val modality: String,val unit: String,val measurementStatus: String,val reason: String?,
    val inputRevision: Long,val freshnessStatus: String,val observedFraction: Double?) {
    companion object {
        fun decode(j: org.json.JSONObject,owner: String,device: String): ServerSignalWindowCache? = runCatching {
            val kind=text(j,"kind"); val start=integer(j,"start"); val end=integer(j,"end")
            val duration=if(kind=="spo2") 900L else 300L
            require(owner.isNotEmpty() && device.isNotEmpty() && integer(j,"schema_version")==1L &&
                text(j,"algorithm_version")=="sensor-windows-1" && text(j,"user_id")==owner && text(j,"device_id")==device &&
                kind in setOf("hrv","ppg","imu","temperature","spo2") && start>=0 && end<=4102444800L && end>start && start%duration==0L && end-start==duration &&
                integer(j,"duration_seconds")==duration && integer(j,"stride_seconds")==duration &&
                text(j,"publication_status")=="shadow" && j.has("values") && j.opt("values") === org.json.JSONObject.NULL)
            val state=text(j,"measurement_status")
            require(state in setOf("unavailable","unqualified","blocked"))
            val revisionText=text(j,"input_revision")
            require(revisionText.matches(Regex("[1-9][0-9]{0,18}")) && text(j,"result_revision")==revisionText)
            val revision=revisionText.toLong()
            val required=if(explicitNull(j,"required_revision")) null else integer(j,"required_revision").also { require(it>0) }
            val freshness=text(j,"freshness_status")
            require(freshness==if(required!=null && required>revision) "stale" else "snapshot")
            val fraction=nullableNumber(j,"observed_fraction",0.0..1.0)
            nullableNumber(j,"maximum_gap_seconds",0.0..duration.toDouble())
            nullableNumber(j,"observed_through",start.toDouble()..end.toDouble())
            val identifier=text(j,"window_id"); require(java.util.UUID.fromString(identifier).toString().equals(identifier,ignoreCase=true))
            val reason=text(j,"reason"); require(reason.matches(Regex("[a-z][a-z0-9_]{0,95}")))
            require(j.opt("quality") is org.json.JSONObject && text(j,"computation_mode")=="retrospective" &&
                text(j,"provenance")=="vps_estimate" && text(j,"calibration_status")=="not_reference_validated")
            for(key in listOf("computed_at","quality_policy_version","preprocess_version")) text(j,key)
            for(key in listOf("published_at","source")) if(!explicitNull(j,key)) text(j,key)
            val modality=text(j,"modality"); val unit=text(j,"unit")
            require(unit==mapOf("hrv" to "ms","ppg" to "bpm","imu" to "m_s2_and_rad_s","temperature" to "degC_skin","spo2" to "percent")[kind] &&
                (if(kind=="hrv") modality in setOf("unknown","ppg_ibi","ecg_nn") else modality==if(kind=="spo2") "unknown" else kind) &&
                (kind!="spo2" || state=="blocked"))
            ServerSignalWindowCache(identifier,kind,start,end,modality,unit,state,reason,revision,freshness,fraction)
        }.getOrNull()

        private fun text(j: org.json.JSONObject,key: String): String = (j.opt(key) as? String)
            ?.takeIf { it.isNotBlank() } ?: error("invalid_signal_text")
        private fun integer(j: org.json.JSONObject,key: String): Long = (j.opt(key) as? Number)
            ?.toString()?.toLongOrNull() ?: error("invalid_signal_integer")
        private fun explicitNull(j: org.json.JSONObject,key: String) = j.has(key) && j.opt(key) === org.json.JSONObject.NULL
        private fun nullableNumber(j: org.json.JSONObject,key: String,range: ClosedFloatingPointRange<Double>): Double? {
            if(explicitNull(j,key)) return null
            val value=(j.opt(key) as? Number)?.toDouble() ?: error("invalid_signal_number")
            require(value.isFinite() && value in range)
            return value
        }
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
    val canonicalQualification: String? = null,
    val featureManifestHash: String? = null,
) {
    val hasCanonicalAuthorization: Boolean get() = publicationStatus !in setOf("shadow", "revoked") &&
        (algorithmVersion == "frwhoop-server-1" ||
            (canonicalQualification == "signed_reference_approval" && featureManifestHash?.matches(Regex("^[a-f0-9]{64}$")) == true))
    val isCanonicalAvailable: Boolean get() = status in setOf("available", "fresh", "stale") && hasCanonicalAuthorization

    fun matchesCanonicalSnapshot(other: ServerScoreFeatureCache?): Boolean = isCanonicalAvailable &&
        other?.isCanonicalAvailable == true && deviceId == other.deviceId &&
        algorithmVersion == other.algorithmVersion && inputRevision == other.inputRevision

    val decodeDiagnostic: ServerScoreStageDiagnostic get() = ServerScoreStageDiagnostic("decoded",
        if (isCanonicalAvailable) "available" else "unavailable",
        if (publicationStatus in setOf("shadow", "revoked")) "publication_not_canonical" else if (!hasCanonicalAuthorization)
            "canonical_qualification_missing" else reason?.let { if (it.matches(Regex("^[a-z0-9_]{1,96}$"))) it else "unclassified_reason" })
}

/** Bounded local diagnostic metadata; no account, device, credentials or physiological values. */
data class ServerScoreStageDiagnostic(val stage: String, val status: String, val reason: String?)

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
        if (!ServerComputeRevisionFence.admits(old, value)) return false
        if (value.compute == null && old?.scopeKey == value.scopeKey && old.features.any { (key, prior) ->
            prior.inputRevision != null && value.features[key]?.inputRevision?.let { it < prior.inputRevision } == true
        }) return false
        values[value.day] = value
        return true
    }
}
