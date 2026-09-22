package com.noop.analytics

/** Process policy is installed before application services start and cannot be disabled afterwards.
 * Plain JVM server/reference runners never install the phone policy. No preference controls it. */
object PhoneComputeRuntime {
    @Volatile private var hosted = false
    val finalHosted: Boolean get() = hosted
    private val admitted = java.util.concurrent.ConcurrentHashMap<String, java.util.concurrent.atomic.AtomicLong>()
    private val blocked = java.util.concurrent.ConcurrentHashMap<String, java.util.concurrent.atomic.AtomicLong>()
    private val violations = java.util.concurrent.ConcurrentHashMap<String, java.util.concurrent.atomic.AtomicLong>()
    fun installFinalHosted() { hosted = true }
    fun allowsLocal(producer: String): Boolean {
        if (!hosted) return true
        blocked.computeIfAbsent(producer) { java.util.concurrent.atomic.AtomicLong() }.incrementAndGet()
        return false
    }
    fun inferenceStarted(producer: String) {
        if (hosted) violations.computeIfAbsent(producer) { java.util.concurrent.atomic.AtomicLong() }.incrementAndGet()
        check(!hosted) { "Local physiological inference forbidden in final hosted mode: $producer" }
        admitted.computeIfAbsent(producer) { java.util.concurrent.atomic.AtomicLong() }.incrementAndGet()
    }
    fun evidence(): Map<String, Long> = admitted.mapValues { it.value.get() }
    fun blockedAdmissions(): Map<String, Long> = blocked.mapValues { it.value.get() }
    fun forbiddenAttempts(): Map<String, Long> = violations.mapValues { it.value.get() }
}
