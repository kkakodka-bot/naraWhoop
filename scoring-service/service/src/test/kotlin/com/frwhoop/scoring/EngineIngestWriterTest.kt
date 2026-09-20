package com.frwhoop.scoring

import com.frwhoop.scoring.db.EngineIngestWriter
import com.frwhoop.scoring.db.ScoringWorkQueue
import com.frwhoop.scoring.scoring.ServerScoreBundle
import com.noop.analytics.DayResult
import com.noop.analytics.DetectedSleep
import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.UUID
import java.net.InetSocketAddress
import java.time.Duration
import java.time.Instant
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import com.sun.net.httpserver.HttpServer

class EngineIngestWriterTest {
    @Test fun stalledHttpPublicationCannotConsumeMoreThanTheRemainingGateBudget() {
        val entered=CountDownLatch(1)
        val server=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        val executor=Executors.newSingleThreadExecutor()
        server.executor=executor
        server.createContext("/rpc/engine_publish_physiology") { exchange ->
            entered.countDown()
            try { CountDownLatch(1).await(5,TimeUnit.SECONDS) }
            catch (_:InterruptedException) { Thread.currentThread().interrupt() }
            finally { exchange.close() }
        }
        server.start()
        try {
            val user=UUID.randomUUID();val device=UUID.randomUUID();val now=Instant.now()
            val item=ScoringWorkQueue.WorkItem(user,device,"2026-09-17",now,now,1,UUID.randomUUID(),UUID.randomUUID(),"UTC")
            val bundle=ServerScoreBundle(user,item.day,device.toString(),"frwhoop-physiology-2",
                DayResult(DailyMetric(deviceId=device.toString(),day=item.day),emptyList(),emptyList(),null,null))
            val writer=EngineIngestWriter("http://127.0.0.1:${server.address.port}","test","test")
            val started=System.nanoTime()
            try { writer.write(bundle,item,Duration.ofMillis(150));fail("expected bounded HTTP timeout") }
            catch (_:IOException) { /* The caller keeps its existing fenced retry path. */ }
            assertTrue(entered.await(1,TimeUnit.SECONDS))
            assertTrue(Duration.ofNanos(System.nanoTime()-started)<Duration.ofSeconds(2))
        } finally { server.stop(0);executor.shutdownNow() }
    }

    @Test
    fun payloadHasAlgorithmVersionAtRootAndOmitsForbiddenKeys() {
        val bundle = ServerScoreBundle(
            userId = UUID.fromString("00000000-0000-4000-8000-000000000001"),
            day = "2026-06-15",
            deviceId = "test-device",
            algorithmVersion = "frwhoop-server-1",
            result = DayResult(
                daily = DailyMetric(
                    deviceId = "test-device",
                    day = "2026-06-15",
                    avgHrv = 42.0,
                    avgSdnn = 55.0,
                    restingHr = 50,
                    respRateBpm = 14.0,
                    totalSleepMin = 420.0,
                    lightMin = 200.0,
                    deepMin = 90.0,
                    remMin = 130.0,
                    efficiency = 0.92,
                    disturbances = 2,
                ),
                sleepSessions = listOf(
                    DetectedSleep(
                        start = 1_749_513_600L,
                        end = 1_749_516_600L,
                        stages = emptyList(),
                        restingHR = 48,
                        avgHRV = 40.0,
                        efficiency = 0.9,
                    ),
                ),
                workouts = emptyList(),
                recovery = null,
                strain = null,
            ),
        )

        val payload = EngineIngestWriter.buildPayload(bundle)
        assertEquals("frwhoop-server-1", payload.getString("algorithm_version"))
        assertEquals("00000000-0000-4000-8000-000000000001", payload.getString("user_id"))

        val daily = payload.getJSONArray("daily_metrics").getJSONObject(0)
        assertEquals("test-device", daily.getString("source_device_id"))
        assertFalse(daily.has("algorithm_version"))
        for (key in listOf("charge", "effort", "rest", "steps", "kcal", "vo2", "stress", "Charge", "Effort", "Rest")) {
            assertFalse("forbidden key present: $key", daily.has(key))
        }
        assertFalse(payload.has("Charge"))
        assertFalse(payload.has("Effort"))
        assertFalse(payload.has("Rest"))
        val nights = payload.getJSONArray("sleep_nights")
        assertEquals(1, nights.length())
        assertEquals("test-device", nights.getJSONObject(0).getString("device_id"))
    }
}
