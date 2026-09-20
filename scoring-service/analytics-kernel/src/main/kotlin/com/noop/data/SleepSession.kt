package com.noop.data

/**
 * Plain-JVM DTO twin of the Room entity in `android/app/src/main/java/com/noop/data/Entities.kt`.
 * Constructor field names, types, order, and defaults are byte-verbatim; Room annotations are
 * dropped (inert). The derived members ([effectiveStartTs], [durationHours], [isNapShaped],
 * [NAP_MAX_HOURS]) are part of the type's behavior — `AnalyticsEngine.sleepSessionFromProvided`
 * reads [effectiveStartTs] — so they are copied verbatim too. `DtoParityTest` diffs the constructor
 * field list against `Entities.kt` mechanically — do not rename, retype, reorder, or "improve"
 * anything here.
 */
data class SleepSession(
    val deviceId: String,
    val startTs: Long,
    val endTs: Long,
    val efficiency: Double? = null,
    val restingHr: Int? = null,
    val avgHrv: Double? = null,
    val stagesJSON: String? = null,
    val userEdited: Boolean = false,
    val startTsAdjusted: Long? = null,
    val motionJSON: String? = null,
    val sleepStateJSON: String? = null,
    val stagingSparse: Boolean? = null,
) {
    /** The bed (onset) time to DISPLAY / sort / re-stage by: the user's hand-set onset when edited,
     *  else the immutable detected [startTs]. Mirrors Swift `CachedSleepSession.effectiveStartTs`. */
    val effectiveStartTs: Long get() = startTsAdjusted ?: startTs

    /** Whole-block duration in hours (effective onset → wake). */
    val durationHours: Double get() = (endTs - effectiveStartTs) / 3600.0

    /** DERIVED nap classification (#518), computed at READ time, NO schema column. Verbatim copy of
     *  the entity's member — see Entities.kt for the full contract comment. */
    val isNapShaped: Boolean
        get() {
            val cal = java.util.Calendar.getInstance().apply { timeInMillis = effectiveStartTs * 1000L }
            val h = cal.get(java.util.Calendar.HOUR_OF_DAY)
            val overnightOnset = h >= 20 || h < 10
            return durationHours < NAP_MAX_HOURS || !overnightOnset
        }

    companion object {
        /** A block shorter than this is nap-shaped regardless of onset. Mirrors iOS SleepView.napMaxHours. */
        const val NAP_MAX_HOURS: Double = 3.0
    }
}
