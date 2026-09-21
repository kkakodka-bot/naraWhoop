package com.frwhoop.scoring

import com.frwhoop.scoring.b2.B2Config
import com.frwhoop.scoring.health.WorkerHeartbeatIdentity
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.time.Duration
import java.util.UUID

enum class ScoringRunMode { PERSISTENT, HISTORY, REPLAY, INVENTORY, ARCHIVE_ONLY, CHECK_CONFIG, MODELS_ONLY, ACTIVATE_MODELS }

/** Env-only configuration for the VPS scoring container. */
data class ScoringConfig(
    val databaseUrl: String,
    val ingestSecret: String,
    val supabaseUrl: String,
    val serviceRoleKey: String,
    val b2Config: B2Config? = null,
    val pollInterval: Duration = Duration.ofSeconds(8),
    val algorithmVersion: String = "frwhoop-physiology-2",
    val workerSecret: String? = null,
    val replayUserId: String? = null,
    val replayDay: String? = null,
    val replayDeviceId: String? = null,
    val workerInstanceId: String? = null,
    val workerSourceRevision: String? = null,
) {
    init { require(pollInterval.toMillis() in 1..600_000) { "Scoring poll interval must be positive and at most 10 minutes" } }

    /** Environment retained from a one-shot run must never turn the daemon into another replay. */
    fun runMode(args: Array<String>): ScoringRunMode {
        val mode = runModeFromArgs(args)
        if (mode == ScoringRunMode.REPLAY) {
            require(!replayUserId.isNullOrBlank()) { "REPLAY_USER_ID required for --replay-day" }
            require(!replayDay.isNullOrBlank()) { "REPLAY_DAY required for --replay-day" }
        }
        return mode
    }

    /** Check image provenance before opening the worker database or mutating its queue. */
    fun workerIdentity(packagedRevision: () -> String = { packagedSourceRevision() }): WorkerHeartbeatIdentity {
        val instance = workerInstanceId
        require(instance != null && instance.matches(Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))) {
            "SCORING_WORKER_INSTANCE_ID must be a canonical UUID"
        }
        val revision = workerSourceRevision
        require(revision != null && revision.matches(Regex("[0-9a-f]{40}"))) {
            "SCORING_WORKER_SOURCE_REVISION must be an immutable source revision"
        }
        val packaged = try { packagedRevision().trim() }
        catch (_: Exception) { throw IllegalArgumentException("Packaged scoring source revision unavailable") }
        require(packaged == revision) { "Packaged scoring source revision mismatch" }
        return WorkerHeartbeatIdentity(UUID.fromString(instance), revision)
    }

    companion object {
        /** An existing image marker is authoritative, including malformed/unreadable markers. */
        internal fun packagedSourceRevision(imageMarker: Path = Path.of("/app/release.sha"),
                                            bundled: () -> String? = {
                                                ScoringConfig::class.java.getResourceAsStream("/scoring-source-revision.txt")
                                                    ?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }
                                            }): String = if (Files.notExists(imageMarker, NOFOLLOW_LINKS)) {
            requireNotNull(bundled()) { "Packaged scoring source revision unavailable" }
        } else {
            require(Files.isRegularFile(imageMarker, NOFOLLOW_LINKS)) { "Packaged scoring source marker invalid" }
            Files.readString(imageMarker)
        }

        fun runModeFromArgs(args: Array<String>): ScoringRunMode = when {
            args.isEmpty() -> ScoringRunMode.PERSISTENT
            args.contentEquals(arrayOf("--history")) -> ScoringRunMode.HISTORY
            args.contentEquals(arrayOf("--replay-day")) -> ScoringRunMode.REPLAY
            args.contentEquals(arrayOf("--inventory-signals")) -> ScoringRunMode.INVENTORY
            args.contentEquals(arrayOf("--archive-only")) -> ScoringRunMode.ARCHIVE_ONLY
            args.contentEquals(arrayOf("--check-config")) -> ScoringRunMode.CHECK_CONFIG
            args.contentEquals(arrayOf("--models-only")) -> ScoringRunMode.MODELS_ONLY
            args.contentEquals(arrayOf("--activate-models")) -> ScoringRunMode.ACTIVATE_MODELS
            else -> throw IllegalArgumentException("Use no arguments, --history, --replay-day, --inventory-signals, --archive-only, --check-config, --models-only, or --activate-models; commands cannot be combined")
        }

        fun fromEnv(): ScoringConfig {
            val dbUrl = required("DATABASE_URL")
            val ingestSecret = required("INGEST_SECRET")
            val supabaseUrl = required("SUPABASE_URL").trimEnd('/')
            val serviceRoleKey = required("SUPABASE_SERVICE_ROLE_KEY")
            val pollSec = System.getenv("SCORING_POLL_SECONDS")?.toLongOrNull() ?: 8L
            return ScoringConfig(
                databaseUrl = dbUrl,
                ingestSecret = ingestSecret,
                supabaseUrl = supabaseUrl,
                serviceRoleKey = serviceRoleKey,
                b2Config = B2Config.fromEnv(),
                pollInterval = Duration.ofSeconds(pollSec),
                algorithmVersion = System.getenv("SCORING_ALGORITHM_VERSION") ?: "frwhoop-physiology-2",
                workerSecret = System.getenv("WORKER_SECRET"),
                replayUserId = System.getenv("REPLAY_USER_ID"),
                replayDay = System.getenv("REPLAY_DAY"),
                replayDeviceId = System.getenv("REPLAY_DEVICE_ID"),
                workerInstanceId = System.getenv("SCORING_WORKER_INSTANCE_ID"),
                workerSourceRevision = System.getenv("SCORING_WORKER_SOURCE_REVISION"),
            )
        }

        private fun required(name: String): String =
            System.getenv(name)?.trim()?.takeIf { it.isNotEmpty() }
                ?: error("Missing required env: $name")
    }
}
