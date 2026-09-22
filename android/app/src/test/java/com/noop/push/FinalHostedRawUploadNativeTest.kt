package com.noop.push

import android.app.Application
import com.noop.analytics.PhoneComputeRuntime
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import com.noop.protocol.DeviceFamily
import com.noop.protocol.extractHistoricalStreams
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class,
    instrumentedPackages = ["com.noop.analytics.PhoneComputeRuntime"])
class FinalHostedRawUploadNativeTest {
    @Test fun rawBleCaptureCommitsAndProducesUploadWithAllPhoneAnalyticsDisabled() = runBlocking(Dispatchers.IO) {
        PhoneComputeRuntime.installFinalHosted()
        W4NativeFixture().use { fixture ->
            val frame = ("aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc8bfd4c" +
                "febafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84fe15ff5cff40" +
                "5fb33c50080101006cb67c17").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            val streams = extractHistoricalStreams(listOf(frame), 1_780_917_232, 1_780_917_232,
                DeviceFamily.WHOOP5, wallNow = 1_780_917_232L)
            assertEquals(1, streams.ppgWaveform.size)
            assertTrue(streams.ppgHr.isEmpty())
            val db = WhoopDatabase.get(fixture.account())
            WhoopRepository(db).insert(streams, fixture.device, markPostBackfillDebt = true)
            val rows = PushDao(db).binaryRows(PushBinaryTable.PPG_WAVEFORM_SAMPLE, fixture.device, 0, 100)
            assertEquals(1, rows.size)
            val optical = (rows.single() as PushBinaryRow.PpgWaveform).record
            assertEquals(streams.ppgWaveform.single().recordIndex, optical.recordIndex)
            assertTrue(db.whoopDao().ppgHrSamples(fixture.device, 1_780_917_232, 1_780_917_300, 100).isEmpty())
            val upload = PushProtocol.binaryObjectBatch(PushBinaryTable.PPG_WAVEFORM_SAMPLE,
                "00000000-0000-4000-8000-000000000001", fixture.device, null, rows, "1.4")
            assertTrue(upload.payload.isNotEmpty())
            assertTrue(upload.manifestJSON.isNotEmpty())
            val repo = WhoopRepository(db)
            val session = com.noop.data.SleepSession(fixture.device, 1_780_900_000, 1_780_904_000,
                efficiency = 0.9, restingHr = 56, avgHrv = 44.0,
                stagesJSON = "[{\"start\":1780900000,\"end\":1780904000,\"stage\":\"light\"}]")
            db.whoopDao().insertSleepSession(session)
            repo.updateSleepSessionTimes(session, session.startTs + 60, session.endTs - 60)
            val edited = db.whoopDao().sleepSessions(fixture.device, session.startTs, session.endTs, 10).single()
            assertEquals(session.startTs + 60, edited.effectiveStartTs)
            assertNull(edited.stagesJSON)
            assertNull(edited.efficiency)
            assertNull(edited.avgHrv)
            repo.addManualNap(fixture.device, 1_780_906_000, 1_780_907_200)
            val nap = db.whoopDao().sleepSessions(repo.computedDeviceId(fixture.device), 1_780_906_000, 1_780_907_200, 10).single()
            assertTrue(nap.userEdited)
            assertNull(nap.stagesJSON)
            assertNull(nap.efficiency)
            assertNull(com.noop.oura.OuraDecoders.decodeLiveHRPush(intArrayOf(0, 0, 0, 0, 0, 32, 3), 1_780_917_232L))
            assertEquals("", com.noop.ble.PuffinDeepBufferLog.decodedImuField(ByteArray(1244)))
            assertTrue(PhoneComputeRuntime.evidence().isEmpty())
            assertTrue(PhoneComputeRuntime.forbiddenAttempts().isEmpty())
            println("FINAL_HOSTED_DURABLE_RAW_UPLOAD admitted=0 forbidden=0 ble_decode=true room_commit=true upload_payload=true clock_identity_preserved=true")
        }
    }
}
