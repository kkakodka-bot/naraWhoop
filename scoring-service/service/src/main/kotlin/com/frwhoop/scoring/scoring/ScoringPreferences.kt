package com.frwhoop.scoring.scoring

import org.json.JSONObject

/** Shapes have already passed the immutable input RPC's strict validation. */
internal object ScoringPreferences {
    fun displayZones(age:Double,config:JSONObject):com.noop.analytics.HrZoneSet {
        val manual=if(config.isNull("maxHR")) null else config.getDouble("maxHR")
        // Swift Profile.hrMax rounds the Tanaka estimate before building its display-zone model.
        val maxHR=manual ?: kotlin.math.floor(com.noop.analytics.HrZones.tanakaMaxHR(age)+0.5)
        return com.noop.analytics.HrZones.zones(maxHR,if(manual==null) "tanaka" else "manual",customZones(config))
    }
    fun customZones(config: JSONObject): List<Double>? = config.optJSONArray("customHRZoneLowerBounds")?.let { a ->
        (0 until a.length()).map { a.getDouble(it) }
    }
    fun manualSteps(config: JSONObject): Double? = if (config.isNull("stepsManualCoefficient")) null
        else config.getDouble("stepsManualCoefficient").takeIf { it > 0 }
}
