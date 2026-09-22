package com.frwhoop.scoring.db

import org.json.JSONObject
import java.time.Duration
import java.time.Instant
import java.util.UUID

/** All mutations are fenced in Postgres; one claim represents one immediately runnable job. */
class ScoringWorkQueue(
    internal val db: PostgresClient,
    val algorithmVersion: String = "frwhoop-server-1",
    val claimLease: Duration = Duration.ofMinutes(5),
    val historyMode: Boolean = algorithmVersion == "frwhoop-server-2-history",
) {
    init { require(claimLease.seconds in 1..3600) }

    data class WorkItem(
        val userId: UUID,
        val deviceId: UUID,
        val day: String,
        val algorithmVersion: String,
        val inputRevision: Long,
        val leaseToken: UUID,
        val leaseUntil: Instant,
        val historyGeneration: Long? = null,
        val predecessorRevision: Long? = null,
    )

    fun maintain(limit: Int = 128) {
        db.withConnection { c ->
            val registration = if (historyMode) "register_scoring_history_v3" else "register_scoring_algorithm_v2"
            c.prepareStatement("select public.$registration(?)").use {
                it.setString(1, algorithmVersion); it.execute()
            }
            c.prepareStatement("select public.repair_legacy_scoring_v2(?), public.expand_scoring_invalidations_v2(?)").use {
                it.setInt(1, limit); it.setInt(2, limit); it.execute()
            }
            c.prepareStatement("select public.reconcile_scoring_versions_v2(?)").use {
                it.setInt(1, limit); it.execute()
            }
            if (historyMode) c.prepareStatement("select public.expand_scoring_history_v3(?)").use {
                it.setInt(1,limit); it.execute()
            }
        }
    }

    fun dirtyWorkItem(userId: UUID, deviceId: UUID, day: String): Long = db.withConnection { c ->
        c.prepareStatement("select public.enqueue_scoring_v2(?, ?, ?::date, ?, 'explicit_replay')").use {
            it.setObject(1, userId); it.setObject(2, deviceId); it.setString(3, day); it.setString(4, algorithmVersion)
            it.executeQuery().use { r -> r.next(); r.getLong(1) }
        }
    }

    fun claim(): WorkItem? = db.withConnection { c ->
        val function = if (historyMode) "claim_scoring_history_v3" else "claim_scoring_v2"
        c.prepareStatement("select * from public.$function(?, ?)").use {
            it.setString(1, algorithmVersion); it.setInt(2, claimLease.seconds.toInt())
            it.executeQuery().use { r ->
                if (!r.next()) null else WorkItem(
                    UUID.fromString(r.getString("user_id")), UUID.fromString(r.getString("device_id")),
                    r.getString("day"), r.getString("algorithm_version"), r.getLong("input_revision"),
                    UUID.fromString(r.getString("lease_token")), r.getTimestamp("lease_until").toInstant(),
                    if (historyMode) r.getLong("history_claim_generation") else null,
                    if (historyMode) r.getLong("history_predecessor_revision").let { if (r.wasNull()) null else it } else null,
                )
            }
        }
    }

    fun renew(item: WorkItem): Boolean = db.withConnection { c ->
        c.prepareStatement("select public.renew_scoring_v2(?, ?)").use {
            it.setObject(1, item.leaseToken); it.setInt(2, claimLease.seconds.toInt())
            it.executeQuery().use { r -> r.next(); r.getBoolean(1) }
        }
    }

    fun markFailed(item: WorkItem, error: String): Boolean = db.withConnection { c ->
        c.prepareStatement("select public.fail_scoring_v2(?, ?, ?)").use {
            it.setObject(1, item.leaseToken); it.setLong(2, item.inputRevision); it.setString(3, error.take(2000))
            it.executeQuery().use { r -> r.next(); r.getBoolean(1) }
        }
    }

    fun publish(item: WorkItem, payload: JSONObject, durationMs: Long): Long? = db.withConnection { c ->
        require(item.historyGeneration == null) { "history_publication_requires_checkpoint" }
        c.prepareStatement("select public.publish_scoring_snapshot_v2(?, ?, ?::jsonb, ?)").use {
            it.setObject(1, item.leaseToken); it.setLong(2, item.inputRevision)
            it.setString(3, payload.toString()); it.setLong(4, durationMs)
            it.executeQuery().use { r -> r.next(); r.getLong(1).let { v -> if (r.wasNull()) null else v } }
        }
    }

    fun publishHistory(item: WorkItem, payload: JSONObject, state: JSONObject, profileRevision: Long,
                       configurationRevision: Long, durationMs: Long): Long? = db.withConnection { c ->
        requireNotNull(item.historyGeneration)
        c.prepareStatement("select public.publish_scoring_history_v3(?,?,?, ?,?::jsonb,?::jsonb,?,?,?)").use {
            it.setObject(1,item.leaseToken); it.setLong(2,item.inputRevision); it.setLong(3,item.historyGeneration)
            if (item.predecessorRevision == null) it.setNull(4,java.sql.Types.BIGINT) else it.setLong(4,item.predecessorRevision)
            it.setString(5,payload.toString()); it.setString(6,state.toString()); it.setLong(7,profileRevision)
            it.setLong(8,configurationRevision); it.setLong(9,durationMs)
            it.executeQuery().use { r -> r.next(); r.getLong(1).let { v -> if (r.wasNull()) null else v } }
        }
    }

    fun metrics(): JSONObject = db.withConnection { c ->
        c.createStatement().use { s ->
            s.executeQuery("select row_to_json(m)::text from public.scoring_queue_metrics_v2 m").use { r ->
                r.next(); JSONObject(r.getString(1))
            }
        }
    }
}
