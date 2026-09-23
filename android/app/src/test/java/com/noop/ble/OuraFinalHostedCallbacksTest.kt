package com.noop.ble

import android.os.Looper
import com.noop.analytics.PhoneComputeRuntime
import com.noop.data.StreamBatch
import com.noop.oura.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers

/** Executes the production callback bodies and persistence mapper, without a Bluetooth device. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class,
    instrumentedPackages = ["com.noop.analytics.PhoneComputeRuntime"])
class OuraFinalHostedCallbacksTest {
    private val ringTime = 10_000L
    private val epoch = 1_700_000_000L

    private fun anchoredDriver(): OuraDriver {
        val driver = OuraDriver(OuraRingGen.GEN3, null)
        val payload = IntArray(8) { ((epoch ushr (8 * it)) and 255).toInt() } + intArrayOf(0)
        driver.ingest(OuraRecord(OuraEventTag.TIME_SYNC.raw, ringTime, payload))
        assertEquals(epoch, driver.unixSeconds(ringTime))
        return driver
    }

    @Test fun finalHostedHypnogramCallbackRetainsCodesWithoutComputingSleepSession() {
        PhoneComputeRuntime.installFinalHosted()
        val batches = mutableListOf<StreamBatch>()
        val sessions = mutableListOf<OuraSleepSession>()
        val logs = mutableListOf<String>()
        val source = OuraLiveSource(RuntimeEnvironment.getApplication(), "fixture-ring", OuraRingGen.GEN3,
            liveSink = { _, _ -> }, authKey = { null }, persist = { batch, _ -> batches += batch },
            persistSleepSession = { session, _ -> sessions += session }, log = { logs += it })
        ReflectionHelpers.setField(source, "driver", anchoredDriver())
        val phases = listOf(OuraSleepStage.DEEP, OuraSleepStage.LIGHT, OuraSleepStage.REM, OuraSleepStage.AWAKE)
            .mapIndexed { index, stage -> OuraSleepPhase(ringTime, index, stage) }
        val burst = OuraHypnogramBurst(listOf(OuraHypnogramRecord(ringTime, phases)))
        ReflectionHelpers.callInstanceMethod<Any?>(source, "persistHypnogramBurst",
            ReflectionHelpers.ClassParameter.from(OuraHypnogramBurst::class.java, burst))
        ReflectionHelpers.callInstanceMethod<Any?>(source, "flush")
        val raw = batches.flatMap { it.events }.filter { it.kind == "OURA_SLEEP_PHASE" }
        assertEquals(4, raw.size)
        assertEquals(listOf(epoch - 120, epoch - 90, epoch - 60, epoch - 30), raw.map { it.ts })
        assertTrue("raw capture cannot publish a locally aggregated night", sessions.isEmpty())
        assertFalse(logs.any { it.contains("deep/light/rem/awake=") || it.contains("eff=") })
        assertTrue((PhoneComputeRuntime.blockedAdmissions()["oura_sleep_stage_totals"] ?: 0L) > 0)
        assertTrue(PhoneComputeRuntime.evidence().isEmpty())
        assertTrue(PhoneComputeRuntime.forbiddenAttempts().isEmpty())
    }

    @Test fun finalHostedBankedAndLiveCallbacksRetainIBIWithoutDerivedHR() {
        PhoneComputeRuntime.installFinalHosted()
        val batches = mutableListOf<StreamBatch>()
        val live = mutableListOf<Pair<Int, List<Int>>>()
        val source = OuraLiveSource(RuntimeEnvironment.getApplication(), "fixture-ring", OuraRingGen.GEN3,
            liveSink = { hr, rr -> live += hr to rr }, authKey = { null }, persist = { batch, _ -> batches += batch })
        val driver = anchoredDriver()
        ReflectionHelpers.setField(source, "driver", driver)
        val banked = listOf(800, 900, 1_000).map { OuraEvent.Ibi(OuraIBI(ringTime, it)) }
        ReflectionHelpers.callInstanceMethod<Any?>(source, "emit",
            ReflectionHelpers.ClassParameter.from(List::class.java, banked))
        val push = intArrayOf(2, 0, 2, 0, 0, 1, 4, 0, 0, 0, 0, 0, 0, 127)
        ReflectionHelpers.callInstanceMethod<Any?>(source, "routeSecure",
            ReflectionHelpers.ClassParameter.from(OuraDriver::class.java, driver),
            ReflectionHelpers.ClassParameter.from(OuraSecureFrame::class.java, OuraSecureFrame(0x28, push)))
        ReflectionHelpers.callInstanceMethod<Any?>(source, "flush")
        Shadows.shadowOf(Looper.getMainLooper()).idle()
        assertEquals(listOf(800, 900, 1_000, 1_025), batches.flatMap { it.rr }.map { it.rrMs })
        assertTrue(batches.flatMap { it.hr }.isEmpty())
        assertTrue(live.all { it.first == 0 })
        assertEquals(4, live.sumOf { it.second.size })
        assertTrue(PhoneComputeRuntime.evidence().isEmpty())
        assertTrue(PhoneComputeRuntime.forbiddenAttempts().isEmpty())
    }

    @Test fun directSleepAggregationIsAlsoBlockedInFinalHosted() {
        PhoneComputeRuntime.installFinalHosted()
        assertNull(OuraSleepSessionMapping.session(listOf(epoch to OuraSleepStage.DEEP)))
        assertTrue(PhoneComputeRuntime.evidence().isEmpty())
        assertTrue(PhoneComputeRuntime.forbiddenAttempts().isEmpty())
    }
}
