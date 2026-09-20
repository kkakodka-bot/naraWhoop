package com.frwhoop.scoring.db

import com.frwhoop.scoring.scoring.CanonicalScorePayload
import com.noop.analytics.Baselines
import com.noop.analytics.ProfileBaselines
import org.json.JSONObject
import java.sql.Connection
import java.time.LocalDate
import java.util.UUID

/** Only prior, measurement-current publications from the same owner, device and algorithm enter a baseline. */
object CanonicalBaselineReader {
    const val HISTORY_DAYS = 28L

    fun load(connection: Connection, user: UUID, device: UUID, day: String): ProfileBaselines {
        val date = LocalDate.parse(day)
        val history = connection.prepareStatement("""
            select distinct on(r.period_day) r.period_day,
              public.scoring_composite_contribution(r.payload)::text as contribution,
              exists(select 1 from public.physiology_feature_qualifications f where f.algorithm_version=r.algorithm_version
                and f.feature='hrv' and f.qualification in ('reference_qualified','published')) as hrv_qualified,
              exists(select 1 from public.physiology_feature_qualifications f where f.algorithm_version=r.algorithm_version
                and f.feature='sleep' and f.qualification in ('reference_qualified','published')) as sleep_qualified,
              exists(select 1 from public.physiology_feature_qualifications f where f.algorithm_version=r.algorithm_version
                and f.feature='respiration' and f.qualification in ('reference_qualified','published')) as resp_qualified
            from public.server_physiology_results r
            join public.physiology_work_items q on q.user_id=r.user_id and q.device_id=r.device_id and q.day=r.period_day
            join public.devices d on d.id=r.device_id and d.user_id=r.user_id
            where r.user_id=? and r.device_id=? and r.algorithm_version=?
              and r.measurement_revision=q.measurement_revision and r.period_day>=? and r.period_day<?
            order by r.period_day,r.input_revision desc
        """.trimIndent()).use { statement ->
            statement.setObject(1, user); statement.setObject(2, device)
            statement.setString(3, CanonicalScorePayload.ALGORITHM_VERSION)
            statement.setObject(4, date.minusDays(HISTORY_DAYS)); statement.setObject(5, date)
            statement.executeQuery().use { rows -> buildMap {
                while (rows.next()) {
                    val contribution = JSONObject(rows.getString("contribution"))
                    val sleep = rows.getBoolean("sleep_qualified")
                    if (!sleep || !rows.getBoolean("hrv_qualified")) contribution.remove("hrv")
                    if (!sleep) { contribution.remove("resting_hr"); contribution.remove("skin_temp") }
                    if (!sleep || !rows.getBoolean("resp_qualified")) contribution.remove("resp")
                    put(LocalDate.parse(rows.getString("period_day")), contribution)
                }
            } }
        }
        fun fold(key: String) = Baselines.foldHistory((HISTORY_DAYS downTo 1L).map { offset ->
            val value = history[date.minusDays(offset)]?.opt(key)
            (value as? Number)?.toDouble()?.takeIf { it.isFinite() }
        }, Baselines.metricCfg.getValue(key))
        // Null calendar days are intentional: the existing kernel must see real wear gaps and staleness.
        return ProfileBaselines(hrv = fold("hrv"), restingHR = fold("resting_hr"), resp = fold("resp"), skinTemp = fold("skin_temp"))
    }
}
