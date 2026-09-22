package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.protocol.PpgHr
import com.noop.ui.LiveSessionRunner
import kotlinx.coroutines.*
import org.junit.Test
import java.net.URLClassLoader

/** Separate production class loader: a final phone policy can never be reset for research tests. */
class FinalHostedComputeRuntimeTest {
    private fun isolated(method: String) {
        val urls = System.getProperty("noop.test.runtimeClasspath").split(java.io.File.pathSeparator)
            .map { java.io.File(it).toURI().toURL() }
        check(urls.isNotEmpty())
        URLClassLoader(urls.toTypedArray(), ClassLoader.getSystemClassLoader().parent).use { loader ->
            Class.forName(FinalHostedRuntimeProbe::class.java.name, true, loader).getMethod(method).invoke(null)
        }
    }
    @Test fun hostedAcquisitionAndLiveTimerPathsExecuteZeroInference() = isolated("admissionAndCapture")
    @Test fun accidentalDeepProducerExecutionFailsBeforeScoring() = isolated("negativeControl")
}

object FinalHostedRuntimeProbe {
    @JvmStatic fun admissionAndCapture() {
        PhoneComputeRuntime.installFinalHosted()
        check(PhoneComputeRuntime.finalHosted)
        check(CurrentHrv.derive(emptyList(), 1_700_000_000) == null)
        check(CurrentHrv.deriveObservations(emptyList(), 1_700_000_000) == null)
        check(StrainScorer.strain(emptyList()) == null)
        check(RestScorer.restFromDaily(DailyMetric("device", "2026-09-21")) == null)
        check(IllnessWatch.evaluate(emptyList()) == null)
        check(StepsCounter.stepsInWindow(emptyList()) == null)
        val waveform = (0 until 240).map { PpgHr.Sample(1_700_000_000L + it / 24, it % 256) }
        val original = waveform.toList()
        check(PpgHr.estimate(waveform).isEmpty())
        check(waveform == original) // Optical acquisition is not consumed, rewritten or estimated.
        check(PpgHr.estimateRecords(listOf(PpgHr.Record(1_700_000_000, 1, listOf(17, 18, 19)))).isEmpty())
        val rawFrame = ("aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc8bfd4c" +
            "febafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84fe15ff5cff40" +
            "5fb33c50080101006cb67c17").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        val rawCopy = rawFrame.copyOf()
        val decoded = com.noop.protocol.extractHistoricalStreams(listOf(rawFrame), 1_780_917_232, 1_780_917_232,
            com.noop.protocol.DeviceFamily.WHOOP5, wallNow = 1_780_917_232L)
        check(rawFrame.contentEquals(rawCopy) && decoded.ppgHr.isEmpty() && decoded.ppgWaveform.size == 1)
        val optical = decoded.ppgWaveform.single()
        check(optical.samples.size == 24 && optical.recordIndex != null)
        val sampleBytes = java.nio.ByteBuffer.allocate(optical.samples.size * 2).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            .also { b -> optical.samples.forEach { b.putShort(it.toShort()) } }.array()
        val record = com.noop.push.PushPpgWaveformRecord(1, optical.ts, optical.burstIndex, sampleBytes, optical.recordIndex)
        val upload = com.noop.push.PushBinaryCodec.pack(com.noop.push.PushBinaryTable.PPG_WAVEFORM_SAMPLE,
            listOf(com.noop.push.PushBinaryRow.PpgWaveform(record)), ppgIdentityV2 = true)
        val compressed = com.noop.push.PushBinaryCompression.compress(upload, "gzip")
        check(java.util.zip.GZIPInputStream(compressed.inputStream()).readBytes().contentEquals(upload))
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val transport = mutableListOf<Boolean>()
        val requests = mutableListOf<Pair<Long, Long?>>()
        var clock = 1_700_000_000L
        val runner = LiveSessionRunner(null, "device", scope, { 75 }, { error("local coaching") },
            { error("local physiology persistence") }, { transport.add(it) }, nowEpochSec = { clock },
            submitSession = { start, end -> requests.add(start to end) })
        runner.start(); clock += 12; runner.end(); scope.cancel()
        check(transport == listOf(true, false))
        check(requests == listOf(1_700_000_000L to null, 1_700_000_000L to 1_700_000_012L))
        check(runner.snapshot.value.ended && runner.snapshot.value.output == null && runner.band == null)
        check(PhoneComputeRuntime.evidence().isEmpty())
        check(PhoneComputeRuntime.forbiddenAttempts().isEmpty())
        check(PhoneComputeRuntime.blockedAdmissions().keys.containsAll(setOf("current_hrv", "ppg_estimate", "ppg_hr")))
        println("FINAL_HOSTED_RUNTIME admitted=0 forbidden=0 raw_ble_decode_and_upload_encoding=true raw_waveform_preserved=true live_timer_and_requests=true")
    }
    @JvmStatic fun negativeControl() {
        PhoneComputeRuntime.installFinalHosted()
        val failure = runCatching { HrvAnalyzer.rmssdRaw(listOf(800.0, 810.0)) }.exceptionOrNull()
        check(failure is IllegalStateException)
        check(PhoneComputeRuntime.evidence().isEmpty())
        check(PhoneComputeRuntime.forbiddenAttempts()["HrvAnalyzer.rmssdRaw"] == 1L)
        println("FINAL_HOSTED_NEGATIVE_CONTROL deep producer blocked before body")
    }
}
