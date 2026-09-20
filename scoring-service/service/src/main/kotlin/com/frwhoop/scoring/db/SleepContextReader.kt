package com.frwhoop.scoring.db

import com.frwhoop.scoring.scoring.SleepBoundaryOverride
import com.noop.analytics.SleepContextSpan
import java.sql.Connection
import java.util.UUID

/** Reads only explicit annotations/boundaries; vendor states remain a separate corroboration stream. */
internal object SleepContextReader {
    fun annotations(conn: Connection,user: UUID,device: UUID,from: Long,to: Long): List<SleepContextSpan> =
        conn.prepareStatement("""
            select label,start_ts,end_ts,source,confidence,floor(extract(epoch from updated_at))::bigint as available_at
            from public.noop_event_labels where user_id=? and (device_id=? or device_id is null)
              and start_ts<=? and end_ts>? and confidence='confirmed'
              and label in ('awake','reading','phone_use','off_body','sleep','bed_occupancy')
            order by start_ts,id
        """.trimIndent()).use { p ->
            p.setObject(1,user);p.setObject(2,device);p.setLong(3,to);p.setLong(4,from)
            p.executeQuery().use { r -> buildList { while(r.next()) {
                val label=r.getString("label")
                // The source label is user-writable, not an attestation of an independently
                // qualified sleep detector. All these sleep reports remain annotations.
                add(SleepContextSpan(r.getLong("start_ts"),r.getLong("end_ts"),label,
                    "event_label:${r.getString("source")}:${r.getString("confidence")}",
                    qualifiedBinarySleep=false,
                    availableAt=r.getLong("available_at")))
            } } }
        }

    fun bandState(conn: Connection,user: UUID,device: UUID,from: Long,to: Long): List<Pair<Long,Int>> =
        conn.prepareStatement("""
            select ts,state from public.noop_sleep_state_samples where user_id=? and device_id=?
              and ts between ? and ? order by ts
        """.trimIndent()).use { p ->
            p.setObject(1,user);p.setObject(2,device);p.setLong(3,from);p.setLong(4,to)
            p.executeQuery().use { r -> buildList { while(r.next()) add(r.getLong(1) to r.getInt(2)) } }
        }

    fun overrides(conn: Connection,user: UUID,device: UUID,from: Long,to: Long): List<SleepBoundaryOverride> =
        conn.prepareStatement("""
            select id,original_start_at,original_end_at,start_at,end_at,tombstone,revision,provenance from (
              select o.id,o.original_start_at,o.original_end_at,o.start_at,o.end_at,o.tombstone,
                o.revision,'physiology_override' as provenance,o.updated_at
              from public.physiology_sleep_overrides o where o.user_id=? and o.device_id=?
              union all
              select l.id,l.original_start_at,l.original_end_at,l.start_at,l.end_at,false,0,
                'legacy_user_boundary',l.updated_at
              from public.physiology_legacy_sleep_boundaries(?,?) l
              where not exists(select 1 from public.physiology_sleep_overrides o
                where o.id=l.id and o.user_id=? and o.device_id=?)
            ) edits where least(original_start_at,start_at)<=to_timestamp(?)
                and greatest(original_end_at,end_at)>to_timestamp(?) order by updated_at,id
        """.trimIndent()).use { p ->
            p.setObject(1,user);p.setObject(2,device);p.setObject(3,user);p.setObject(4,device)
            p.setObject(5,user);p.setObject(6,device);p.setLong(7,to);p.setLong(8,from)
            p.executeQuery().use { r -> buildList { while(r.next()) add(SleepBoundaryOverride(
                r.getString("id"),r.getTimestamp("original_start_at").toInstant().epochSecond,
                r.getTimestamp("original_end_at").toInstant().epochSecond,
                r.getTimestamp("start_at").toInstant().epochSecond,r.getTimestamp("end_at").toInstant().epochSecond,
                r.getBoolean("tombstone"),r.getLong("revision"),r.getString("provenance"))) } }
        }
}
