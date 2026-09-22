package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.db.SignalSampleReader
import org.json.JSONObject

/** Explicit, stable per-metric precedence. Imports never become raw strap HRV/baseline observations. */
object ImportedMetricResolver {
    data class Reading(val value:Double,val unit:String,val source:JSONObject,val revision:Long)
    private val priority=mapOf("apple_health" to 0,"health_connect" to 1,"oura_import" to 2,"whoop_import" to 3,"miband_import" to 4)
    fun resolve(input:SignalSampleReader.DayInputs,day:String=input.day):Map<String,Reading> {
        require(day<=input.day)
        val imports=input.history.values.filter { it.kind=="imported_daily" && !it.deleted && it.payload.getString("day")==day }
            .sortedWith(compareBy({ priority[it.payload.getJSONObject("source").getString("kind")] ?: 99 },
                { it.payload.getJSONObject("source").getString("externalDeviceId") },{it.entity}))
        val values=linkedMapOf<String,Reading>()
        for(row in imports) {
            val source=row.payload.getJSONObject("source"); val fields=row.payload.getJSONObject("values")
            for(key in fields.keySet().sorted()) {
                val field=fields.getJSONObject(key)
                if(!field.isNull("value") && key !in values) values[key]=Reading(field.getDouble("value"),field.getString("unit"),source,row.revision)
            }
        }
        return values
    }
}
