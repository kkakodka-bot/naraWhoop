package com.frwhoop.scoring.db

import java.time.Duration
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Renewal survives a slow compute or PUT; publication independently checks the database lease. */
class LeaseHeartbeat(lease: Duration, renew: () -> Boolean) : AutoCloseable {
    private val executor = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "scoring-lease-renewal").apply { isDaemon = true }
    }
    private val valid = AtomicBoolean(true)
    init {
        val cadence = (lease.toMillis() / 3).coerceAtLeast(100)
        executor.scheduleAtFixedRate({
            try { if (!renew()) valid.set(false) } catch (_: Exception) { valid.set(false) }
        }, cadence, cadence, TimeUnit.MILLISECONDS)
    }
    fun requireValid() = check(valid.get()) { "lease_lost" }
    override fun close() { executor.shutdownNow() }
}
