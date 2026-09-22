package com.noop.ble

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/** Immutable receipt identity. A reconnect starts a new session without asserting sensor continuity. */
data class BleCaptureIdentity(
    val namespace: String,
    val generation: String,
    val sourceId: String,
    val deviceId: String,
    val sessionId: String,
)

/** Bounded, single-writer buffer. The pending prefix remains charged until persistence succeeds. */
internal class LiveCaptureQueue<T>(
    scope: CoroutineScope,
    private val identity: (T) -> BleCaptureIdentity,
    private val persist: suspend (List<T>) -> Unit,
    private val committed: (List<T>) -> Unit,
    private val blocked: () -> Unit,
    private val maxAgeMs: Long = 750,
    private val batchRecords: Int = 64,
    private val batchBytes: Int = 256 * 1024,
    private val capacityRecords: Int = 4096,
    private val capacityBytes: Int = 8 * 1024 * 1024,
    private val retryMs: Long = 5_000,
    private val monotonicMs: () -> Long = { System.nanoTime() / 1_000_000 },
    private val rejected: () -> Unit = blocked,
) {
    private data class Entry<T>(val value: T, val bytes: Int, val received: Long)
    private val lock = Any()
    private val writer = Mutex()
    private val pending = ArrayDeque<Entry<T>>()
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private var bytes = 0
    private var accepting = true
    private var inFlight: List<Entry<T>>? = null
    val pendingCount: Int get() = synchronized(lock) { pending.size }

    init {
        require(maxAgeMs > 0 && batchRecords > 0 && batchBytes > 0 && retryMs > 0)
        scope.launch {
            for (signal in wake) {
                while (pendingCount > 0) {
                    val wait = synchronized(lock) {
                        if (pending.isEmpty()) return@synchronized 0L
                        if (pending.size >= batchRecords || bytes >= batchBytes) 0L
                        else (maxAgeMs - (monotonicMs() - pending.first().received)).coerceAtLeast(0)
                    }
                    if (wait > 0) {
                        withTimeoutOrNull(wait) { wake.receive() }
                        continue
                    }
                    if (!drain()) delay(retryMs)
                }
            }
        }
    }

    fun offer(value: T, sizeBytes: Int): Boolean {
        val accepted = synchronized(lock) {
            if (!accepting || sizeBytes !in 1..batchBytes || pending.size >= capacityRecords ||
                sizeBytes > capacityBytes - bytes) false
            else {
                pending.addLast(Entry(value, sizeBytes, monotonicMs()))
                bytes += sizeBytes
                true
            }
        }
        if (accepted) wake.trySend(Unit) else rejected()
        return accepted
    }

    fun stopAccepting() = synchronized(lock) { accepting = false }

    suspend fun drain(): Boolean = writer.withLock {
        // Each invocation has a finite IO budget even if notifications keep arriving.
        repeat(8) {
            val batch = inFlight ?: synchronized(lock) {
                val owner = pending.firstOrNull()?.let { identity(it.value) } ?: return@withLock true
                var selectedBytes = 0
                pending.take(batchRecords).takeWhile { entry ->
                    (identity(entry.value) == owner && entry.bytes <= batchBytes - selectedBytes)
                        .also { if (it) selectedBytes += entry.bytes }
                }
            }.also { inFlight = it }
            try {
                persist(batch.map { it.value })
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                blocked()
                return@withLock false
            }
            synchronized(lock) {
                repeat(batch.size) { bytes -= pending.removeFirst().bytes }
            }
            inFlight = null
            // A scheduler failure cannot turn an already committed row into a new observation.
            try { committed(batch.map { it.value }) } catch (_: Exception) { }
        }
        if (pendingCount > 0) wake.trySend(Unit)
        true
    }
}
