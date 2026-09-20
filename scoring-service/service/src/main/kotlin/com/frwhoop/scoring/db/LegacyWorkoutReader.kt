package com.frwhoop.scoring.db

import org.json.JSONObject
import java.sql.Connection
import java.util.UUID

/** Existing push workout bounds/measurements, not client-computed HR, zones or load. */
object LegacyWorkoutReader {
    data class Workout(val id:String,val start:Long,val end:Long,val sport:String,val source:String,
                       val userModified:Boolean,val energyKcal:Double?,val distanceM:Double?,val steps:Int?)
    fun load(c:Connection,owner:UUID,device:UUID,lo:Long,hi:Long):List<Workout> = c.prepareStatement("""
        select s.id::text,extract(epoch from s.start_at)::bigint,extract(epoch from s.end_at)::bigint,
          s.summary->>'sport',s.source,s.user_modified,
          jsonb_build_object('energyKcal',s.summary->'calories_kcal','distanceM',s.summary->'distance_m','steps',s.summary->'steps')::text
        from sessions s where s.user_id=? and s.device_id=? and s.kind in ('workout','manual_workout')
          and s.start_at>=to_timestamp(?) and s.end_at<=to_timestamp(?)
          and not exists(select 1 from scoring_algorithms_v2 a where a.algorithm_version=s.algorithm_version)
          and s.source not in ('server','server_scoring','frwhoop_scoring_v2')
        order by s.updated_at desc,s.id limit 513
    """.trimIndent()).use { s ->
        s.setObject(1,owner);s.setObject(2,device);s.setLong(3,lo);s.setLong(4,hi+1)
        s.executeQuery().use { r -> buildList {
            while(r.next()) {
                check(size<512) { "legacy_workout_window_limit" }
                val j=JSONObject(r.getString(7))
                fun number(key:String,max:Double):Double?=(j.opt(key) as? Number)?.toDouble()?.takeIf { it.isFinite() && it in 0.0..max }
                val start=r.getLong(2);val end=r.getLong(3);val sport=r.getString(4)?.takeIf { it.length in 1..128 } ?: "Activity"
                if(start>0 && end>start) add(Workout(r.getString(1),start,end,sport,r.getString(5),r.getBoolean(6),
                    number("energyKcal",100000.0),number("distanceM",10000000.0),number("steps",1000000.0)?.toInt()))
            }
        } }
    }
}
