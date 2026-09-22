package com.frwhoop.scoring.db

/** Publishes non-numeric, immutable final-hosted dispositions after the scoring fence. */
class ComputeContractPublisher(private val db: PostgresClient) {
    fun publishDay(item: ScoringWorkQueue.WorkItem) = db.withConnection { connection ->
        connection.prepareStatement("select public.publish_compute_dispositions(?,?,?::date,?)").use { statement ->
            statement.queryTimeout = 15
            statement.setObject(1, item.userId)
            statement.setObject(2, item.deviceId)
            statement.setString(3, item.day)
            statement.setLong(4, item.inputRevision)
            statement.executeQuery().use { it.next(); it.getInt(1) }
        }
    }

    fun processSession(): Boolean = db.withConnection { connection ->
        connection.prepareStatement("select public.process_compute_session_request()").use { statement ->
            statement.queryTimeout = 15
            statement.executeQuery().use { it.next(); it.getBoolean(1) }
        }
    }
}
