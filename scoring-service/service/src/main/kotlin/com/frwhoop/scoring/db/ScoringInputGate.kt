package com.frwhoop.scoring.db

import java.sql.SQLException
import java.time.Duration
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Briefly pauses projection commits, while the receiver retains unacknowledged batches.
 * The idle transaction owns only the input gate; publication/renewal use other connections
 * and their existing revision/lease fence. A crash or deadline releases this transaction.
 */
class ScoringInputGate(
    private val db: PostgresClient,
    private val maximumDuration: Duration = Duration.ofSeconds(120),
    private val acquisitionTimeout: Duration = Duration.ofSeconds(2),
) {
    init {
        require(maximumDuration.toMillis() in 1..120_000)
        require(acquisitionTimeout.toMillis() in 1..10_000)
    }

    class Guard internal constructor(duration: Duration) {
        private val deadline = System.nanoTime() + duration.toNanos()
        @Volatile private var closed = false
        val active: Boolean get() = !closed && System.nanoTime() < deadline
        val remainingDuration: Duration get() = Duration.ofNanos(
            if (closed) 0 else (deadline-System.nanoTime()).coerceAtLeast(0))
        fun requireActive() = check(active) { "Scoring input gate deadline exceeded" }
        internal fun close() { closed = true }
    }

    /** Null means the device was busy; no job was claimed or failure budget consumed. */
    fun <T : Any> withGate(user: UUID, device: UUID, block: (Guard) -> T): T? = db.withConnection { conn ->
        conn.autoCommit = false
        var guard: Guard? = null
        var timeout: java.util.concurrent.ScheduledFuture<*>? = null
        try {
            conn.prepareStatement("select set_config('lock_timeout', ?, true), " +
                "set_config('idle_in_transaction_session_timeout', ?, true)").use { p ->
                p.setString(1, "${acquisitionTimeout.toMillis()}ms")
                p.setString(2, "${maximumDuration.toMillis()}ms")
                p.execute()
            }
            try {
                conn.prepareStatement("select public.scoring_acquire_input_gate(?, ?)").use { p ->
                    p.setObject(1, user); p.setObject(2, device); p.execute()
                }
            } catch (error: SQLException) {
                if (error.sqlState == "55P03") return@withConnection null
                throw error
            }
            val acquired = Guard(maximumDuration)
            guard = acquired
            // The database idle timeout remains a second bound if this process stops making
            // progress. abort closes the physical connection, never returning a live lock to
            // the pool; the deadline also stops new publication calls from starting.
            timeout = deadlines.schedule({
                acquired.close()
                runCatching { conn.abort { task -> task.run() } }
            }, maximumDuration.toMillis(), TimeUnit.MILLISECONDS)
            block(acquired)
        } finally {
            guard?.close()
            timeout?.cancel(false)
            runCatching { conn.rollback() }
            runCatching { conn.autoCommit = true }
        }
    }

    companion object {
        private val deadlines = Executors.newSingleThreadScheduledExecutor { task ->
            Thread(task, "scoring-input-gate-deadline").apply { isDaemon = true }
        }
    }
}
