package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.GravitySample
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class HeartRateWindowsTest {
    @Test fun serializedParityAndAdversarialWindows() {
        val cases=JSONObject(javaClass.classLoader!!.getResourceAsStream("heart_rate_windows_oracle.json")!!.bufferedReader().use { it.readText() }).getJSONArray("cases")
        for(i in 0 until cases.length()) {
            val c=cases.getJSONObject(i); val id=c.getString("id"); val rows=c.getJSONArray("rows")
            val hr=(0 until rows.length()).map { val r=rows.getJSONArray(it); HrSample("d",r.getLong(0),r.getInt(1)) }
            val gravity=(0 until rows.length()).map { val r=rows.getJSONArray(it)
                GravitySample("d",r.getLong(0),0.0,0.0,1.0,dynAccel=if(r.isNull(2)) null else r.getDouble(2)) }
            val exclusions=c.getJSONArray("excluded")
            val result=HeartRateWindows.windows(c.getLong("start"),c.getLong("end"),hr,gravity,
                (0 until exclusions.length()).map { val pair=exclusions.getJSONArray(it); pair.getLong(0) to pair.getLong(1) })
            if(id=="leading_partial_skipped") { assertTrue(result.isEmpty()); continue }
            assertEquals(id,1,result.size); val window=result.single()
            fun number(key:String):Double?=if(c.isNull(key)) null else c.getDouble(key)
            fun text(key:String):String?=if(c.isNull(key)) null else c.getString(key)
            assertEquals(id,0L,window.start); assertEquals(id,300L,window.end)
            assertEquals(id,number("mean"),window.meanBpm); assertEquals(id,number("quiet"),window.lowMotionBpm)
            assertEquals(id,text("reason"),window.reason); assertEquals(id,text("quiet_reason"),window.lowMotionReason)
        }
    }

    @Test fun movingSecondsAreExcludedWithoutInvalidatingAnOtherwiseCoveredWindow() {
        val hr=(0L until 300L).map { HrSample("d",it,if(it==10L) 180 else 60) }
        val gravity=(0L until 300L).map { GravitySample("d",it,0.0,0.0,1.0,dynAccel=if(it<20) .04 else .01) }
        val window=HeartRateWindows.windows(0,300,hr,gravity).single()
        assertEquals(280.0/300.0,window.lowMotionSampleFraction,1e-12)
        assertEquals(60.0,window.lowMotionBpm!!,1e-12)
        assertNull(window.lowMotionReason)
        assertEquals(20,window.movingSeconds)
        assertEquals(300,window.motionObservedSeconds)

        val tooMuchMotion=(0L until 300L).map { GravitySample("d",it,0.0,0.0,1.0,dynAccel=if(it<31) .04 else .01) }
        val rejected=HeartRateWindows.windows(0,300,hr,tooMuchMotion).single()
        assertNull(rejected.lowMotionBpm)
        assertEquals("insufficient_motion_matched_samples",rejected.lowMotionReason)
        assertEquals(31,rejected.movingSeconds)
        assertEquals(300,rejected.motionObservedSeconds)
    }
}
