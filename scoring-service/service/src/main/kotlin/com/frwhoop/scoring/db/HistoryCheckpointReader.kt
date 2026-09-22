package com.frwhoop.scoring.db

import org.json.JSONObject
import java.sql.Connection

/** Immutable predecessor and its strictly earlier observations, from one database snapshot. */
class HistoryCheckpointReader(private val db: PostgresClient) {
    data class Seed(val predecessor: JSONObject?, val history: List<JSONObject>)
    fun load(item: ScoringWorkQueue.WorkItem): Seed = db.withConnection { c ->
        requireNotNull(item.historyGeneration)
        c.transactionIsolation=Connection.TRANSACTION_REPEATABLE_READ; c.autoCommit=false
        try {
            val rows = c.prepareStatement("""
                select distinct on(day) result_revision,state::text from scoring_history_checkpoints_v3
                where user_id=? and device_id=? and algorithm_version=? and day<?::date
                order by day,result_revision desc
            """.trimIndent()).use { s ->
                s.setObject(1,item.userId); s.setObject(2,item.deviceId); s.setString(3,item.algorithmVersion); s.setString(4,item.day)
                s.executeQuery().use { r -> buildList { while(r.next()) add(r.getLong(1) to JSONObject(r.getString(2))) } }
            }
            check(rows.lastOrNull()?.first == item.predecessorRevision) { "history_predecessor_changed" }
            Seed(rows.lastOrNull()?.second,rows.mapNotNull { it.second.optJSONObject("observation") })
        } finally {
            c.rollback(); c.autoCommit=true; c.transactionIsolation=Connection.TRANSACTION_READ_COMMITTED
        }
    }
}
