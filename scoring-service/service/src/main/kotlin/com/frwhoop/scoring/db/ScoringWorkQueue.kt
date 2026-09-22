package com.frwhoop.scoring.db

import java.sql.PreparedStatement
import java.sql.ResultSet
import java.sql.Timestamp
import java.time.Duration
import java.time.Instant
import java.util.UUID

/** Durable input revisions are enqueued by transaction-local database triggers. */
class ScoringWorkQueue(
    private val db: PostgresClient,
    val claimLease: Duration = Duration.ofMinutes(5),
    private val maxAttempts: Int = 8,
) {
    private val inputGate = ScoringInputGate(db)

    fun enqueueClosedSensorWindows(): Int = db.withConnection { connection ->
        connection.prepareStatement("select public.sensor_enqueue_closed_windows()").use { query ->
            query.executeQuery().use { rows -> rows.next(); rows.getInt(1) }
        }
    }

    data class Cursor(val nextAttemptAt: Instant, val dirtyAt: Instant,
                      val userId: UUID, val deviceId: UUID, val day: String,
                      val classRank: Int = 0, val lastDispatch: Long = 0)
    data class Candidate(val userId: UUID, val deviceId: UUID, val day: String, val cursor: Cursor? = null)
    data class DeviceKey(val userId: UUID, val deviceId: UUID)

    /** Look before acquiring the input gate; a waiting worker must not age a live claim. */
    fun peekOne(userId: UUID? = null, deviceId: UUID? = null, day: String? = null,
                excludedDevices: Set<DeviceKey> = emptySet(), after: Cursor? = null): Candidate? =
        db.withConnection { conn ->
            // A device gate covers every day. Another worker's live day claim therefore
            // makes its other pending days unavailable too; look for unrelated work first.
            val excluded = excludedDevices.joinToString(" ") { "and not (w.user_id=? and w.device_id=?)" }
            val cursorClause = if(after == null) "" else
                "and (w.class_rank,w.last_dispatch,w.next_attempt_at,w.dirty_at,w.user_id,w.device_id,w.day) > (?::integer,?::bigint,?::timestamptz,?::timestamptz,?::uuid,?::uuid,?::date)"
            conn.prepareStatement("""
                select w.user_id,w.device_id,w.day,w.next_attempt_at,w.dirty_at,w.class_rank,w.last_dispatch from public.scoring_fleet_candidates w
                where w.done_at is null and w.next_attempt_at<=clock_timestamp()
                  and (w.lease_expires_at is null or w.lease_expires_at<=clock_timestamp())
                  and (w.failure_revision<>w.input_revision or w.consecutive_failures<?)
                  and (?::uuid is null or w.user_id=?) and (?::uuid is null or w.device_id=?)
                  and (?::date is null or w.day=?::date)
                  and not exists (select 1 from public.physiology_work_items active
                    where active.user_id=w.user_id and active.device_id=w.device_id
                      and active.status='running' and active.lease_expires_at>clock_timestamp())
                  $excluded
                  $cursorClause
                order by w.class_rank,w.last_dispatch,w.next_attempt_at,w.dirty_at,w.user_id,w.device_id,w.day limit 1
            """.trimIndent()).use { p ->
                p.setInt(1,maxAttempts); p.setObject(2,userId); p.setObject(3,userId)
                p.setObject(4,deviceId); p.setObject(5,deviceId); p.setString(6,day); p.setString(7,day)
                excludedDevices.forEachIndexed { index, key ->
                    p.setObject(8+index*2,key.userId); p.setObject(9+index*2,key.deviceId)
                }
                after?.let { cursor ->
                    val index=8+excludedDevices.size*2
                    p.setInt(index,cursor.classRank);p.setLong(index+1,cursor.lastDispatch)
                    p.setTimestamp(index+2,Timestamp.from(cursor.nextAttemptAt))
                    p.setTimestamp(index+3,Timestamp.from(cursor.dirtyAt))
                    p.setObject(index+4,cursor.userId);p.setObject(index+5,cursor.deviceId);p.setString(index+6,cursor.day)
                }
                p.executeQuery().use { r -> if (r.next()) {
                    val owner=r.getObject("user_id",UUID::class.java)
                    val device=r.getObject("device_id",UUID::class.java)
                    val date=r.getDate("day").toString()
                    Candidate(owner,device,date,Cursor(r.getTimestamp("next_attempt_at").toInstant(),
                        r.getTimestamp("dirty_at").toInstant(),owner,device,date,r.getInt("class_rank"),r.getLong("last_dispatch")))
                } else null }
            }
        }

    fun <T : Any> withInputGate(candidate: Candidate, block: (ScoringInputGate.Guard) -> T): T? =
        inputGate.withGate(candidate.userId,candidate.deviceId,block)

    internal fun abortConnectionsOwnedBy(owner: Thread) = db.abortConnectionsOwnedBy(owner)

    data class WorkItem(
        val userId: UUID,
        val deviceId: UUID,
        val day: String,
        val dirtyAt: Instant,
        val claimedAt: Instant,
        val inputRevision: Long,
        val leaseToken: UUID,
        val runId: UUID,
        val timezoneId: String,
    )

    /** This serial worker claims one runnable item, never a backlog whose leases age in memory. */
    fun claimOne(userId: UUID? = null, deviceId: UUID? = null, day: String? = null): WorkItem? =
        db.withConnection { conn ->
            conn.prepareStatement("select * from public.scoring_claim_one(?, ?, ?, ?, ?::date)").use { ps ->
                ps.setInt(1, claimLease.seconds.toInt())
                ps.setInt(2, maxAttempts)
                ps.setObject(3, userId)
                ps.setObject(4, deviceId)
                ps.setString(5, day)
                ps.executeQuery().use { rs -> if (rs.next()) rs.workItem() else null }
            }
        }

    fun renew(item: WorkItem): Boolean = db.withConnection { conn ->
        conn.prepareStatement("select public.scoring_renew_lease(?, ?, ?::date, ?, ?, ?, ?)").use { ps ->
            ps.bindIdentity(item)
            ps.setInt(7, claimLease.seconds.toInt())
            ps.executeQuery().use { rs -> rs.next() && rs.getBoolean(1) }
        }
    }

    fun markDone(item: WorkItem, durationMs: Int): Boolean = finish(item, "done", durationMs, null)

    fun markWaiting(item: WorkItem, reason: String): Boolean = finish(item, "waiting", null, reason)

    fun markFailed(item: WorkItem, error: String): Boolean = finish(item, "failed", null, error)

    private fun finish(item: WorkItem, outcome: String, durationMs: Int?, error: String?): Boolean =
        db.withConnection { conn ->
            conn.prepareStatement("select public.scoring_finish_work(?, ?, ?::date, ?, ?, ?, ?, ?, ?)").use { ps ->
                ps.bindIdentity(item)
                ps.setString(7, outcome)
                ps.setObject(8, durationMs)
                ps.setString(9, error?.take(2000))
                ps.executeQuery().use { rs -> rs.next() && rs.getBoolean(1) }
            }
        }

    /** Explicit replay is a new revision and uses the same publication fence as arrival work. */
    fun dirtyWorkItem(userId: UUID, deviceId: UUID, day: String): Long = db.withConnection { conn ->
        conn.prepareStatement(
            """
            select public.physiology_enqueue_day(?, ?, ?::date,
              coalesce((select timezone_id from public.physiology_work_items
                where user_id=? and device_id=? and day=?::date),
                public.scoring_timezone_at(?, ?::date::timestamp at time zone 'UTC')), 0)
            """.trimIndent(),
        ).use { ps ->
            ps.setObject(1, userId)
            ps.setObject(2, deviceId)
            ps.setString(3, day)
            ps.setObject(4, userId)
            ps.setObject(5, deviceId)
            ps.setString(6, day)
            ps.setObject(7, userId)
            ps.setString(8, day)
            ps.executeQuery().use { rs -> check(rs.next()); rs.getLong(1) }
        }
    }

    private fun PreparedStatement.bindIdentity(item: WorkItem) {
        setObject(1, item.userId)
        setObject(2, item.deviceId)
        setString(3, item.day)
        setLong(4, item.inputRevision)
        setObject(5, item.leaseToken)
        setObject(6, item.runId)
    }

    private fun ResultSet.workItem() = WorkItem(
        userId = getObject("user_id", UUID::class.java),
        deviceId = getObject("device_id", UUID::class.java),
        day = getDate("day").toString(),
        dirtyAt = getTimestamp("dirty_at").toInstant(),
        claimedAt = getTimestamp("claimed_at").toInstant(),
        inputRevision = getLong("input_revision"),
        leaseToken = getObject("lease_token", UUID::class.java),
        runId = getObject("run_id", UUID::class.java),
        timezoneId = getString("timezone_id"),
    )
}
