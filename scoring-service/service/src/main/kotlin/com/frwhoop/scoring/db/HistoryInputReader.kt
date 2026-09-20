package com.frwhoop.scoring.db

import com.noop.analytics.UserProfile
import org.json.JSONObject
import java.sql.Connection
import java.util.UUID

/** Read inside the same repeatable-read transaction as raw streams, never from client daily outputs. */
object HistoryInputReader {
    data class Input(val kind: String, val entity: String, val revision: Long, val deleted: Boolean, val payload: JSONObject)
    data class Day(val values: List<Input> = emptyList(), val profileJournalExists: Boolean = false) {
        val profile get() = values.singleOrNull { it.kind == "profile" && it.entity == "primary" }
        val config get() = values.singleOrNull { it.kind == "config" && it.entity == "primary" }
        val sleepEdits get() = values.filter { it.kind == "sleep_edit" }
        fun effectiveProfile(): UserProfile {
            val p = profile?.takeUnless { it.deleted }?.payload ?: JSONObject()
            fun number(key: String, default: Double) = if (p.isNull(key)) default else p.getDouble(key)
            return UserProfile(age=number("age",30.0),weightKg=number("weightKg",70.0),heightCm=number("heightCm",170.0),
                sex=if (p.isNull("sex")) "nonbinary" else p.getString("sex"),
                waistCm=number("waistCm",0.0),stepTicksPerStep=number("stepTicksPerStep",1.0))
        }
        val timezone get() = profile?.takeUnless { it.deleted }?.payload?.optString("timezone","UTC") ?: "UTC"
        val configuration get() = config?.takeUnless { it.deleted }?.payload ?: JSONObject()
    }

    fun load(c: Connection, owner: UUID, device: UUID, day: String): Day {
        val values = c.prepareStatement("""
            select distinct on(kind,entity) kind,entity,revision,deleted,payload::text
            from scoring_history_inputs_v3 where user_id=? and device_id=? and effective_day<=?::date
            order by kind,entity,case when kind in ('sleep_edit','manual_workout') then null else effective_day end desc,revision desc
        """.trimIndent()).use { s ->
            s.setObject(1,owner); s.setObject(2,device); s.setString(3,day)
            s.executeQuery().use { r -> buildList {
                while (r.next()) add(Input(r.getString(1),r.getString(2),r.getLong(3),r.getBoolean(4),JSONObject(r.getString(5))))
            } }
        }
        val hasProfile = c.prepareStatement("select exists(select 1 from scoring_history_inputs_v3 where user_id=? and device_id=? and kind='profile')").use { s ->
            s.setObject(1,owner); s.setObject(2,device)
            s.executeQuery().use { it.next(); it.getBoolean(1) }
        }
        return Day(values,hasProfile)
    }
}
