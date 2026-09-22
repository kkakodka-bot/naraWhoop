package com.frwhoop.scoring

import com.frwhoop.scoring.b2.B2Config
import com.frwhoop.scoring.b2.B2ObjectStore
import com.frwhoop.scoring.derived.DerivedArchivePayload
import com.frwhoop.scoring.derived.DerivedArtifactKey
import com.frwhoop.scoring.derived.DerivedArtifactWriter
import com.frwhoop.scoring.scoring.ServerScoreBundle
import com.github.luben.zstd.Zstd
import com.noop.analytics.DayResult
import com.noop.analytics.DetectedSleep
import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.util.UUID

class DerivedArtifactWriterTest {
    private val userId = UUID.fromString("00000000-0000-4000-8000-000000000001")
    private val deviceId = "00000000-0000-4000-8000-000000000002"

    private fun sampleBundle(): ServerScoreBundle =
        ServerScoreBundle(
            userId = userId,
            day = "2026-06-15",
            deviceId = deviceId,
            algorithmVersion = "frwhoop-server-1",
            result = DayResult(
                daily = DailyMetric(
                    deviceId = deviceId,
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

    @Test
    fun objectKeyIsStable() {
        val key = DerivedArtifactKey.objectKey(userId, "2026-06-15", "frwhoop-server-1")
        assertEquals(
            "v3/derived/users/00000000-0000-4000-8000-000000000001/days/2026-06-15/frwhoop-server-1.json.zst",
            key,
        )
    }

    @Test
    fun payloadOmitsForbiddenKeysAndUsesDailyNightsShape() {
        val payload = DerivedArchivePayload.build(sampleBundle(), Instant.parse("2026-06-15T12:00:00Z"))
        assertEquals("frwhoop-server-1", payload.getString("algorithm_version"))
        assertEquals(userId.toString(), payload.getString("user_id"))
        assertEquals(deviceId, payload.getString("device_id"))
        assertEquals("2026-06-15", payload.getString("day"))
        assertTrue(payload.has("daily"))
        assertTrue(payload.has("nights"))
        assertFalse(payload.has("daily_metrics"))
        assertFalse(payload.has("sleep_nights"))
        for (key in listOf("charge", "effort", "rest", "Charge", "Effort", "Rest")) {
            assertFalse("forbidden key: $key", payload.has(key))
            assertFalse("forbidden in daily: $key", payload.getJSONObject("daily").has(key))
        }
    }

    @Test
    fun sha256IsOverCompressedBytes() {
        val json = DerivedArchivePayload.build(sampleBundle()).toString()
        val compressed = Zstd.compress(json.toByteArray(Charsets.UTF_8))
        val sha = B2ObjectStore.sha256Hex(compressed)
        assertEquals(64, sha.length)

        var captured: ByteArray? = null
        val fakePut = object : B2ObjectStore.PutClient {
            override fun putObject(key: String, body: ByteArray, contentType: String): B2ObjectStore.PutResult {
                captured = body
                return B2ObjectStore.PutResult(etag = "\"etag\"", bytes = body.size)
            }
        }
        val cfg = B2Config("k", "s", "FRWHOOP", "s3.us-west-004.backblazeb2.com", "us-west-004")
        val manifestHttp = okhttp3.OkHttpClient.Builder().addInterceptor { chain ->
            okhttp3.Response.Builder().request(chain.request()).protocol(okhttp3.Protocol.HTTP_1_1)
                .code(201).message("fixture accepted").body(okhttp3.ResponseBody.create(null, "")).build()
        }.build()
        val writer = DerivedArtifactWriter(cfg, "http://fixture.invalid", "role-key", fakePut, manifestHttp)
        val result = writer.archive(sampleBundle())
        assertEquals(captured!!.size, result.compressedBytes)
        assertEquals(B2ObjectStore.sha256Hex(captured!!), result.sha256)
    }

    @Test
    fun writerUsesFakePutClientWithoutNetwork() {
        val keys = mutableListOf<String>()
        val fakePut = object : B2ObjectStore.PutClient {
            override fun putObject(key: String, body: ByteArray, contentType: String): B2ObjectStore.PutResult {
                keys.add(key)
                assertTrue(body.isNotEmpty())
                assertEquals("application/json", contentType)
                return B2ObjectStore.PutResult(etag = null, bytes = body.size)
            }
        }
        val cfg = B2Config("k", "s", "FRWHOOP", "s3.us-west-004.backblazeb2.com", "us-west-004")
        val manifestHttp = okhttp3.OkHttpClient.Builder().addInterceptor { chain ->
            okhttp3.Response.Builder().request(chain.request()).protocol(okhttp3.Protocol.HTTP_1_1)
                .code(503).message("fixture unavailable").body(okhttp3.ResponseBody.create(null, "")).build()
        }.build()
        val writer = DerivedArtifactWriter(cfg, "http://fixture.invalid", "role-key", fakePut, manifestHttp)
        org.junit.Assert.assertThrows(IllegalStateException::class.java) { writer.archive(sampleBundle()) }
        assertEquals(1, keys.size)
        assertTrue(keys[0].endsWith("frwhoop-server-1.json.zst"))
    }
}
