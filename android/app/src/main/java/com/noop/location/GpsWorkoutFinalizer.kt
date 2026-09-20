package com.noop.location

import androidx.room.withTransaction
import androidx.sqlite.db.SupportSQLiteDatabase
import com.noop.account.AccountStorageContext
import com.noop.account.AccountStorageMutationLease
import com.noop.analytics.Calories
import com.noop.analytics.RouteMath
import com.noop.analytics.StrainScorer
import com.noop.analytics.UserProfile
import com.noop.data.HrSample
import com.noop.data.GpsWorkoutCommit
import com.noop.data.GpsWorkoutDeliveryStore
import com.noop.data.GpsDestinationDurabilityBarrier
import com.noop.data.WhoopDatabase
import com.noop.data.WorkoutRow
import com.noop.data.requireDurableAccountCommit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** Freeze before delivery; prove the current destination before retiring the separate GPS debt. */
internal class GpsWorkoutFinalizer(
    private val account: AccountStorageContext,
    private val session: AccountGpsSession,
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val afterDestinationWrite: suspend (GpsWorkoutPayload) -> Unit = {},
    private val beforeGpsDelete: () -> Unit = {},
    private val onCommitted: (GpsWorkoutCommit) -> Unit = {},
    private val durabilityView: (SupportSQLiteDatabase) -> SupportSQLiteDatabase = { it },
    private val deliveryLimits: GpsWorkoutDeliveryStore.Limits = GpsWorkoutDeliveryStore.Limits(),
    private val destinationBarrier: GpsDestinationDurabilityBarrier = GpsDestinationDurabilityBarrier(),
) {
    data class Inputs(
        val samples: List<HrSample>,
        val profile: UserProfile,
        val maxHr: Double,
        val restingHr: Double = StrainScorer.defaultRestingHR,
        val method: StrainScorer.Method = StrainScorer.Method.EDWARDS,
        val sex: String = profile.sex,
    )

    init { session.requireAccount(account) }

    suspend fun finish(sessionId: String, inputs: Inputs): WorkoutRow {
        val payload = session.prepareFinalization(sessionId, nowMs(), admit = { candidate ->
            require(inputs.samples.size <= GpsWorkoutPayload.MAX_HR_SAMPLES) { "GPS finalization HR capacity reached" }
            check(inputs.samples.size >= 2 || candidate.pointCount >= 2) { "No route or heart-rate samples to save" }
            check(inputs.samples.all { it.deviceId == candidate.deviceId }) { "GPS heart-rate source mismatch" }
        }) { frozen ->
            val samples = inputs.samples.toList()
            val endMs = checkNotNull(frozen.endMs)
            val row = WorkoutRow(deviceId = frozen.deviceId, startTs = frozen.startMs / 1000, endTs = endMs / 1000,
                sport = frozen.sport, source = "manual",
                durationS = (endMs - frozen.startMs - frozen.pausedDurationMs).coerceAtLeast(0) / 1000.0,
                avgHr = samples.takeIf { it.isNotEmpty() }?.let { it.sumOf { hr -> hr.bpm } / it.size },
                maxHr = samples.maxOfOrNull { it.bpm },
                strain = if (samples.size >= 2) StrainScorer.strain(samples, maxHR = inputs.maxHr,
                    restingHR = inputs.restingHr, method = inputs.method, sex = inputs.sex) else null,
                energyKcal = if (samples.size >= 2) Calories.estimateBoutCalories(samples, inputs.profile,
                    inputs.maxHr, inputs.restingHr).first.takeIf { it > 0 } else null,
                distanceM = frozen.distanceM.takeIf { it > 0 },
                routePolyline = if (frozen.track.size >= 2) RouteMath.encode(frozen.track) else null)
            GpsWorkoutPayload.capture(account, frozen.id, row, samples)
        }
        currentCoroutineContext().ensureActive()
        // A cancelled caller cannot split successful commit from its captured runtime notification.
        // get()/Room may wait; no namespace monitor is held over suspension or writer acquisition.
        withContext(NonCancellable + Dispatchers.IO) {
            val database = WhoopDatabase.get(account)
            val inserted = database.withTransaction {
                requireDurableAccountCommit(durabilityView(database.openHelper.writableDatabase))
                GpsWorkoutDeliveryStore(account, database, deliveryLimits).deliver(payload)
            }
            onCommitted(GpsWorkoutCommit(account, database, inserted))
        }
        afterDestinationWrite(payload)
        session.settleFinalization(payload, beforeGpsDelete, durabilityView, destinationBarrier)
        return payload.row
    }

    companion object {
        internal fun settleCurrent(account: AccountStorageContext, payload: GpsWorkoutPayload,
            durabilityView: (SupportSQLiteDatabase) -> SupportSQLiteDatabase = { it },
            destinationBarrier: GpsDestinationDurabilityBarrier = GpsDestinationDurabilityBarrier(), deleteGps: () -> Unit) {
            val lease = AccountStorageMutationLease.capture(account)
            lease.withStorageLock {
                val current = WhoopDatabase.get(account)
                destinationBarrier.synchronize(account, current, durabilityView) {
                    GpsWorkoutDeliveryStore(account, current).verify(payload)
                }
                // Synchronous on the caller's IO thread. The SQLite writer lock excludes ordinary
                // workout/HR edits from this proof through deletion; the namespace lock excludes restore.
                current.runInTransaction {
                    requireDurableAccountCommit(durabilityView(current.openHelper.writableDatabase))
                    GpsWorkoutDeliveryStore(account, current).verify(payload)
                    deleteGps()
                }
            }
        }

    }
}
