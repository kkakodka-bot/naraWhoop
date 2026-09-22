package com.frwhoop.scoring.signals

import com.frwhoop.scoring.b2.B2ObjectStore
import com.frwhoop.scoring.db.SignalSampleReader
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** A stalled object fetch occupies at most one daemon; scalar publication waits at most two seconds. */
class BoundedRawFeatureLane(objects: B2ObjectStore.GetClient?, private val timeoutMs: Long = 2000) : AutoCloseable {
    init { require(timeoutMs in 1..2000) }
    private val extractor = objects?.let(::QualifiedRawFeatures)
    // One handoff slot covers the interval between Future completion and an idle
    // executor thread. Admission still rejects work behind an active extraction.
    private val executor = ThreadPoolExecutor(1,1,0,TimeUnit.SECONDS,ArrayBlockingQueue(1),
        { task -> Thread(task,"bounded-signal-extraction").apply { isDaemon = true } },ThreadPoolExecutor.AbortPolicy())
    private val admission = AtomicReference<Any?>(null)
    private val cache = object : LinkedHashMap<String,QualifiedRawFeatures.Features>(32,.75f,true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String,QualifiedRawFeatures.Features>?) = size > 2048
    }
    data class Outcome(val features: QualifiedRawFeatures.Features? = null, val reason: String? = null)
    fun evaluate(inputs: SignalSampleReader.DayInputs): Map<String,Outcome> {
        val receipts = inputs.acquisitionEvidence.receipts.filter { it.kind in setOf("ppg","imu") }.sortedByDescending { it.start }
        if(receipts.isEmpty()) return emptyMap()
        if(extractor == null) return receipts.associate { it.digest to Outcome(reason="archive_worker_unavailable") }
        val result = ConcurrentHashMap<String,Outcome>()
        // Metadata changes invalidate a successful cache even when an operator has not revoked its receipt yet.
        fun key(receipt: SensorAcquisitionProof.Receipt): String {
            val ids=com.frwhoop.scoring.db.SensorAcquisitionReader.objectIds(com.frwhoop.scoring.db.SensorAcquisitionReader.Evidence(listOf(receipt)))
            return SensorAcquisitionProof.sha256((receipt.digest + ":" + inputs.rawManifests.filter { it.id in ids }.sortedBy { it.id }.joinToString(";") {
            "${it.id}:${it.sourceId}:${it.key}:${it.sha256}:${it.format}:${it.compression}:${it.records}:${it.start}:${it.end}:${it.compressedBytes}:${it.uncompressedBytes}"
        }).toByteArray())
        }
        val keys=receipts.associate { it.digest to key(it) }
        for(receipt in receipts) synchronized(cache) { cache[keys.getValue(receipt.digest)] }?.let {
            result[receipt.digest] = Outcome(it)
        }
        val pending=receipts.filter { !result.containsKey(it.digest) }
        fun outcomes(reason: String)=receipts.associate { it.digest to (result[it.digest] ?: Outcome(reason=reason)) }
        if(pending.isEmpty()) return outcomes("raw_budget_exceeded")
        val ticket=Any()
        if(!admission.compareAndSet(null,ticket)) return outcomes("raw_worker_busy")
        val phase=AtomicInteger(0) // queued, running, cancelled-before-start
        val future = try { executor.submit {
            if(!phase.compareAndSet(0,1)) return@submit
            try { for(receipt in pending) {
                if(Thread.currentThread().isInterrupted) break
                val identity = keys.getValue(receipt.digest)
                val cached = synchronized(cache) { cache[identity] }
                if(cached != null) { result[receipt.digest] = Outcome(cached); continue }
                try {
                    val proof = SensorAcquisitionProof.verify(receipt,inputs.userId,java.util.UUID.fromString(inputs.deviceId))
                    val value = extractor.extract(proof,inputs.rawManifests,inputs.userId,java.util.UUID.fromString(inputs.deviceId))
                    synchronized(cache) { cache[identity] = value }
                    result[receipt.digest] = Outcome(value)
                } catch (e: InterruptedException) { Thread.currentThread().interrupt(); break }
                catch (e: Exception) { result[receipt.digest] = Outcome(reason=safeReason(e)) }
            } } finally { admission.compareAndSet(ticket,null) }
        } } catch (_: RejectedExecutionException) {
            admission.compareAndSet(ticket,null)
            return outcomes("raw_worker_busy")
        }
        fun cancel() {
            future.cancel(true)
            if(phase.compareAndSet(0,2)) admission.compareAndSet(ticket,null)
            if(future is Runnable) executor.remove(future)
        }
        try { future.get(timeoutMs,TimeUnit.MILLISECONDS) }
        catch (_: TimeoutException) { cancel() }
        catch (e: InterruptedException) { cancel(); Thread.currentThread().interrupt(); throw e }
        catch (_: ExecutionException) { cancel() }
        return outcomes("raw_budget_exceeded")
    }
    override fun close() { executor.shutdownNow() }
    companion object {
        fun safeReason(error: Exception): String = error.message?.takeIf { it.matches(Regex("[a-z][a-z0-9_]{0,79}")) } ?: "raw_input_rejected"
    }
}
