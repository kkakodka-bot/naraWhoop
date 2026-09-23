package com.noop.analytics

/** Process policy is installed before application services start and cannot be disabled afterwards.
 * Plain JVM server/reference runners never install the phone policy. No preference controls it. */
object PhoneComputeRuntime {
    @Volatile private var hosted = false
    val finalHosted: Boolean get() = hosted
    private val lock = Any()
    private val admitted = mutableMapOf<String, Long>()
    private val blocked = mutableMapOf<String, Long>()
    private val violations = mutableMapOf<String, Long>()
    private var admittedTotal = 0L
    private var blockedTotal = 0L
    private var violationTotal = 0L
    // Random runtime correlation, not an owner/source/device ID. Preserve it through UUID redaction.
    private val processGeneration = java.util.UUID.randomUUID().toString().replace('-', '_')
    private var observationWallMs: Long? = null
    private var observationNanos = 0L

    private fun observeLocked() {
        if (observationWallMs == null) {
            observationWallMs = System.currentTimeMillis()
            observationNanos = System.nanoTime()
        }
    }
    private fun increment(value: Long) = if (value == Long.MAX_VALUE) value else value + 1
    fun installFinalHosted() = synchronized(lock) { observeLocked(); hosted = true }
    fun allowsLocal(producer: String): Boolean = synchronized(lock) {
        observeLocked()
        if (!hosted) return@synchronized true
        blocked[producer] = increment(blocked[producer] ?: 0)
        blockedTotal = increment(blockedTotal)
        false
    }
    fun inferenceStarted(producer: String) = synchronized(lock) {
        observeLocked()
        if (hosted) {
            violations[producer] = increment(violations[producer] ?: 0)
            violationTotal = increment(violationTotal)
        }
        check(!hosted) { "Local physiological inference forbidden in final hosted mode: $producer" }
        admitted[producer] = increment(admitted[producer] ?: 0)
        admittedTotal = increment(admittedTotal)
    }
    fun evidence(): Map<String, Long> = synchronized(lock) { admitted.toMap() }
    fun blockedAdmissions(): Map<String, Long> = synchronized(lock) { blocked.toMap() }
    fun forbiddenAttempts(): Map<String, Long> = synchronized(lock) { violations.toMap() }

    /** Fixed-size, value-free evidence. Unexported counters from a prior process are not recovered. */
    fun diagnosticSnapshot(): Map<String, Any> = synchronized(lock) {
        observeLocked()
        mapOf(
            "schema_version" to 1,
            "process_generation" to processGeneration,
            "coverage" to "current_process_only",
            "previous_process_coverage" to "NOT_MEASURED",
            "first_observed_at_unix_ms" to requireNotNull(observationWallMs),
            "captured_at_unix_ms" to System.currentTimeMillis(),
            "observation_elapsed_ms" to ((System.nanoTime() - observationNanos).coerceAtLeast(0) / 1_000_000),
            "final_hosted" to hosted,
            "execution_count" to admittedTotal,
            "denied_admission_count" to blockedTotal,
            "forbidden_attempt_count" to violationTotal,
            "counter_saturated" to listOf(admittedTotal, blockedTotal, violationTotal).contains(Long.MAX_VALUE),
        )
    }
}
