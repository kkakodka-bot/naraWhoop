package com.noop.ble

import org.json.JSONObject
import com.noop.account.AccountStorageContext
import com.noop.data.BleRawCapture
import com.noop.data.StreamBatch
import com.noop.data.WhoopRepository
import com.noop.push.SelfHostedPushScheduler
import com.noop.push.SelfHostedPushSettings
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope

/** Exact protocol-tagged callback archive; host receipt time is not a qualified sample clock. */
class GenericNotificationCapture internal constructor(
    private val scope: CoroutineScope,
    val identity: BleCaptureIdentity,
    private val family: String,
    private val isCurrent: () -> Boolean,
    private val write: suspend (BleRawCapture, StreamBatch) -> Unit,
    private val committed: () -> Unit,
    private val blocked: () -> Unit,
    private val recovered: () -> Unit = {},
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val monotonicNs: () -> Long = System::nanoTime,
) {
    private class Entry(val raw: BleRawCapture) {
        val projection = CompletableDeferred<StreamBatch>()
        var streams = StreamBatch()
        var cursor: (() -> Unit)? = null
        var durable = false
    }
    private val lock = Any()
    private var sequence = 0L
    private var accepting = true
    private var current: Entry? = null
    private var last: Entry? = null
    private var retryAccepted: (() -> Boolean)? = null
    private val queue: LiveCaptureQueue<Entry> = LiveCaptureQueue(scope, { _: Entry -> identity },
        persist = { entries -> for (entry in entries) write(entry.raw, entry.projection.await()) },
        committed = { entries ->
            val callbacks = synchronized(lock) {
                entries.mapNotNull { it.durable = true; it.cursor.also { _ -> it.cursor = null } }
            }
            callbacks.forEach { it() }
            synchronized(lock) { retryAccepted?.let { if (it()) retryAccepted = null } }
            finishIfDrained()
            if (isCurrent()) {
                try { committed() } finally { if (isDrained) recovered() }
            }
        }, blocked = blocked, rejected = blocked, maxAgeMs = 200, batchRecords = 1,
        batchBytes = 65_536, capacityRecords = 16, capacityBytes = 1_048_576)

    val pendingCount: Int get() = queue.pendingCount
    internal val isDrained: Boolean get() = pendingCount == 0 && synchronized(lock) { retryAccepted == null }

    /** Keep delayed projection/cursor state in the same order as actual callbacks. */
    internal fun <T> withProjection(action: () -> T): T = synchronized(lock, action)

    /** Reserve raw capacity before decoding; even an unknown or throwing decoder keeps its original. */
    internal fun capture(bytes: ByteArray, service: String, characteristic: String,
                         decode: () -> Unit): Boolean = synchronized(lock) {
        if (!accepting || !isCurrent() || current != null || sequence == Long.MAX_VALUE ||
            bytes.size !in 1..512 || service.length !in 1..64 || characteristic.length !in 1..64) return@synchronized false
        val received = nowMs(); val uptime = monotonicNs()
        val envelope = linkedMapOf<String, Any>("format" to "nara.generic-notification.v1", "family" to family,
            "serviceUUID" to service, "characteristicUUID" to characteristic,
            "sessionID" to identity.sessionId, "sequence" to sequence,
            "receivedUnixSeconds" to received / 1000, "receivedUptime" to uptime / 1_000_000_000.0,
            "clockQuality" to "host_receipt_unverified",
            "rrProjectionStatus" to "unqualified", "rrProjectionReason" to "producer_not_implemented", "payload" to Base64.getEncoder().encodeToString(bytes))
        val raw = BleRawCapture.create(identity, listOf(JSONObject().apply { envelope.forEach { (key, value) -> put(key, value) } }.toString().toByteArray(Charsets.UTF_8)),
            family, received, uptime, received / 1000, received / 1000, "host_receipt_unverified", sequence.toString())
        val entry = Entry(raw)
        if (!queue.offer(entry, 65_536)) return@synchronized false
        sequence++; last = entry; current = entry
        try { decode() } finally {
            entry.projection.complete(entry.streams)
            current = null
        }
        true
    }

    /** A delayed decoder may attach only to an already captured prefix; it never manufactures bytes. */
    internal fun persist(batch: StreamBatch): Boolean = synchronized(lock) {
        if (batch.isEmpty) return@synchronized true
        val prior = current?.streams ?: StreamBatch()
        // Frozen-v1 consumes the legacy RR table without a qualified beat-clock filter.
        // These generic callbacks provide observed intervals but no validated beat adapter.
        // Keep their original words in the archive; never promote a host/record timestamp to beat timing.
        val merged = merge(prior, batch.copy(rr = emptyList()))
        if (merged.ppgHr.isNotEmpty() || merged.ppgWaveform.isNotEmpty() || merged.v18Aux.isNotEmpty() ||
            merged.rrPackets.isNotEmpty() || merged.standardHrReceipts.isNotEmpty()) return@synchronized false
        // Immutable scalar values with conservative space per row and all variable text bytes.
        val rows = merged.hr.size.toLong() + merged.rr.size + merged.events.size + merged.battery.size +
            merged.spo2.size + merged.skinTemp.size + merged.resp.size + merged.gravity.size +
            merged.steps.size + merged.sleepState.size
        val texts = merged.events.sumOf { it.kind.toByteArray().size.toLong() + it.payloadJSON.toByteArray().size } +
            merged.steps.sumOf { it.provenanceJSON?.toByteArray()?.size?.toLong() ?: 0 } +
            merged.sleepState.sumOf { it.provenanceJSON?.toByteArray()?.size?.toLong() ?: 0 }
        if (rows * 128 + texts > 49_152) return@synchronized false
        val frozen = merged
        val entry = current
        if (entry != null) { entry.streams = frozen; return@synchronized true }
        val original = last ?: return@synchronized false
        val delayed = Entry(original.raw)
        delayed.projection.complete(frozen)
        if (!queue.offer(delayed, 65_536)) return@synchronized false
        last = delayed
        true
    }

    internal fun setCursorAfterDurablePrefix(action: () -> Unit): Boolean = synchronized(lock) {
        val entry = last ?: return@synchronized false
        if (entry.durable) action() else entry.cursor = action
        true
    }

    internal fun seal(retry: (() -> Boolean)? = null) = synchronized(lock) {
        accepting = false
        if (retry != null) retryAccepted = if (retry()) null else retry
        finishIfDrained()
    }

    private fun finishIfDrained() {
        if (synchronized(lock) { !accepting && retryAccepted == null } && queue.pendingCount == 0) queue.finishWhenDrained()
    }

    internal suspend fun drain(): Boolean {
        val done = queue.drain()
        synchronized(lock) { retryAccepted?.let { if (it()) retryAccepted = null } }
        finishIfDrained()
        if (isCurrent() && isDrained) runCatching { recovered() }
        return done && isDrained
    }

    companion object {
        internal fun create(context: AccountStorageContext, repository: WhoopRepository, scope: CoroutineScope,
                            deviceId: String, family: String, blocked: () -> Unit, recovered: () -> Unit = {}): GenericNotificationCapture {
            checkNotNull(context.identity.scope) { "generic_capture_owner_required" }
            check(context.isCurrent()) { "generic_capture_owner_retired" }
            val identity = BleCaptureIdentity(context.namespace, context.identity.generation.toString(),
                SelfHostedPushSettings.from(context).sourceId(), deviceId, UUID.randomUUID().toString())
            return GenericNotificationCapture(scope, identity, family, context::isCurrent,
                write = { raw, batch -> repository.insert(batch, deviceId, rawCaptures = listOf(raw), markCloudPushDebt = true) },
                committed = { SelfHostedPushScheduler.enqueueOnLiveCommitted(context) }, blocked = blocked, recovered = recovered)
        }

        private fun merge(a: StreamBatch, b: StreamBatch) = StreamBatch(
            hr=a.hr+b.hr, rr=a.rr+b.rr, events=a.events+b.events, battery=a.battery+b.battery,
            spo2=a.spo2+b.spo2, skinTemp=a.skinTemp+b.skinTemp, resp=a.resp+b.resp,
            gravity=a.gravity+b.gravity, steps=a.steps+b.steps, sleepState=a.sleepState+b.sleepState,
            ppgHr=a.ppgHr+b.ppgHr, ppgWaveform=a.ppgWaveform+b.ppgWaveform, v18Aux=a.v18Aux+b.v18Aux,
            rrPackets=a.rrPackets+b.rrPackets, standardHrReceipts=a.standardHrReceipts+b.standardHrReceipts)
    }
}
