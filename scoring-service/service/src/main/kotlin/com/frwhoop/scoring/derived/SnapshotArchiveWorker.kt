package com.frwhoop.scoring.derived

import com.frwhoop.scoring.b2.B2ObjectStore
import com.frwhoop.scoring.db.LeaseHeartbeat
import com.frwhoop.scoring.db.PostgresClient
import java.time.Duration
import java.util.UUID

/** Archives the immutable Postgres serialization; every retry has identical bytes and identity. */
class SnapshotArchiveWorker(
    private val db: PostgresClient,
    private val put: B2ObjectStore.PutClient,
    private val bucket: String,
    private val retentionDays: Int = 90,
    private val lease: Duration = Duration.ofMinutes(5),
) {
    data class Job(val revision: Long, val key: String, val token: UUID, val bytes: ByteArray)

    fun claim(): Job? = db.withConnection { c ->
        c.prepareStatement("select * from public.claim_scoring_archive_v2(?)").use {
            it.setInt(1, lease.seconds.toInt())
            it.executeQuery().use { r ->
                if (!r.next()) null else Job(r.getLong(1),r.getString(2),UUID.fromString(r.getString(3)),
                    r.getString(4).toByteArray(Charsets.UTF_8))
            }
        }
    }

    fun runOne(): Boolean {
        val job = claim() ?: return false
        try {
            LeaseHeartbeat(lease) { renew(job) }.use { guard ->
                val receipt = put.putObject(job.key, job.bytes, "application/json")
                check(receipt.bytes == job.bytes.size) { "archive_size_mismatch" }
                guard.requireValid()
                complete(job)
            }
        } catch (err: Exception) { fail(job, err.javaClass.simpleName) }
        return true
    }

    fun renew(job: Job): Boolean = db.withConnection { c ->
        c.prepareStatement("select public.renew_scoring_archive_v2(?,?)").use {
            it.setObject(1,job.token); it.setInt(2,lease.seconds.toInt())
            it.executeQuery().use { r -> r.next(); r.getBoolean(1) }
        }
    }

    fun complete(job: Job): Boolean = db.withConnection { c ->
        c.prepareStatement("select public.complete_scoring_archive_v2(?,?,?,?,?)").use {
            it.setObject(1,job.token); it.setString(2,B2ObjectStore.sha256Hex(job.bytes))
            it.setLong(3,job.bytes.size.toLong()); it.setString(4,bucket); it.setInt(5,retentionDays)
            it.executeQuery().use { r -> r.next(); r.getBoolean(1) }
        }
    }

    fun fail(job: Job, error: String): Boolean = db.withConnection { c ->
        c.prepareStatement("select public.fail_scoring_archive_v2(?,?)").use {
            it.setObject(1,job.token); it.setString(2,error.take(2000))
            it.executeQuery().use { r -> r.next(); r.getBoolean(1) }
        }
    }
}
