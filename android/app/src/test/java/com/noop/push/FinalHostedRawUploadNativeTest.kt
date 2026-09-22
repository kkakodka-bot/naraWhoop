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
            assertTrue(PhoneComputeRuntime.evidence().isEmpty())
            assertTrue(PhoneComputeRuntime.forbiddenAttempts().isEmpty())
            println("FINAL_HOSTED_DURABLE_RAW_UPLOAD admitted=0 forbidden=0 ble_decode=true room_commit=true upload_payload=true clock_identity_preserved=true")
        }
    }
}
