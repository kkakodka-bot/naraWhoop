package com.frwhoop.scoring.derived

import com.frwhoop.scoring.db.PostgresClient
import org.json.JSONObject
import org.slf4j.LoggerFactory
import java.util.UUID

/** Retries archive failures without rescoring or acquiring a physiology work lease. */
class DerivedArchiveOutbox(private val db: PostgresClient, private val writer: DerivedArtifactWriter) {
    private val log = LoggerFactory.getLogger(DerivedArchiveOutbox::class.java)

    data class Claim(val id: Long, val token: UUID, val key: String, val payload: JSONObject)

    fun processOne(): Boolean {
        if (!writer.enabled) return false
        val claim = claimOne() ?: return false
        try {
            val uploaded = writer.archive(claim.payload, claim.key)
            finish(claim, uploaded.sha256, null)
        } catch (error: Exception) {
            finish(claim, null, error.javaClass.simpleName)
            log.warn("derived archive retry deferred for outbox {}: {}", claim.id, error.javaClass.simpleName)
        }
        return true
    }

    internal fun claimOne(userId: UUID? = null): Claim? = db.withConnection { connection ->
        connection.prepareStatement("""
            with candidate as (
              select id from public.physiology_archive_outbox
              where status <> 'verified' and next_attempt_at <= clock_timestamp()
                and (?::uuid is null or user_id=?::uuid)
                and (lease_expires_at is null or lease_expires_at <= clock_timestamp())
              order by next_attempt_at, id for update skip locked limit 1
            ), claimed as (
              update public.physiology_archive_outbox a
              set status='uploading', lease_token=gen_random_uuid(),
                  lease_expires_at=clock_timestamp()+interval '2 minutes', attempts=attempts+1
              from candidate c where a.id=c.id returning a.*
            )
            select c.id,c.lease_token,c.object_key,r.payload
            from claimed c join public.server_physiology_results r
              on r.user_id=c.user_id and r.device_id=c.device_id and r.period_day=c.period_day
                and r.algorithm_version=c.algorithm_version and r.input_revision=c.input_revision
        """.trimIndent()).use { statement ->
            statement.setObject(1,userId); statement.setObject(2,userId)
            statement.executeQuery().use { rows ->
                if (!rows.next()) null else Claim(rows.getLong("id"),
                    rows.getObject("lease_token", UUID::class.java), rows.getString("object_key"),
                    JSONObject(rows.getString("payload")))
            }
        }
    }

    internal fun finish(claim: Claim, hash: String?, error: String?): Boolean = db.withConnection { connection ->
        connection.prepareStatement("""
            update public.physiology_archive_outbox
            set status=case when ?::text is null then 'failed' else 'verified' end,
                content_sha256=?, last_error=?,
                uploaded_at=case when ?::text is null then uploaded_at else clock_timestamp() end,
                verified_at=case when ?::text is null then null else clock_timestamp() end,
                next_attempt_at=clock_timestamp()+make_interval(secs=>least(3600,30*power(2,least(attempts,7)))::int),
                lease_token=null, lease_expires_at=null
            where id=? and lease_token=? and lease_expires_at>clock_timestamp()
        """.trimIndent()).use { statement ->
            statement.setString(1, hash); statement.setString(2, hash); statement.setString(3, error)
            statement.setString(4, hash); statement.setString(5, hash)
            statement.setLong(6, claim.id); statement.setObject(7, claim.token)
            statement.executeUpdate() == 1
        }
    }
}
