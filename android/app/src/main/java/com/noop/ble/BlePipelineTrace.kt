package com.noop.ble

import android.content.Context
import android.os.SystemClock
import com.noop.account.AccountStorageContext

/** Six independent, metadata-only frontiers per account. Null source time is NOT_MEASURED.
 * Diagnostic timestamps never stand in for the outbox's durable receipts. */
object BlePipelineTrace {
    enum class Stage { RECEIVE, LOCAL_COMMIT, UPLOAD_ATTEMPT, CLOUD_ACK, PROJECTION, DISPLAY }
    private val lastReceive = java.util.concurrent.ConcurrentHashMap<String, Long>()
    fun event(context: Context, stage: Stage, sourceTimeMs: Long? = null) {
        runCatching {
            val account = AccountStorageContext.capture(context)
            if (!account.isCurrent()) return
            val monotonic = SystemClock.elapsedRealtime()
            if (stage == Stage.RECEIVE) {
                val last = lastReceive[account.namespace]
                if (last != null && monotonic - last < 1000) return
                lastReceive[account.namespace] = monotonic
            }
            val key = stage.name.lowercase()
            val edit = account.getSharedPreferences("ble-pipeline-frontiers-v1", Context.MODE_PRIVATE).edit()
                .putLong("$key.observedAtMs", System.currentTimeMillis()).putLong("$key.monotonicMs", monotonic)
            if (sourceTimeMs == null) edit.remove("$key.sourceTimeMs") else edit.putLong("$key.sourceTimeMs", sourceTimeMs)
            edit.apply()
            android.os.Trace.beginSection("BLE.$key"); android.os.Trace.endSection()
        }
    }
}
