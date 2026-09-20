package com.noop.push

import android.app.Application
import com.noop.data.GpsWorkoutDeliveryStore
import com.noop.data.HrSample
import com.noop.data.WorkoutRow
import com.noop.location.GpsWorkoutPayload
import com.noop.location.GpsWorkoutProjectionWitness
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W2GpsProjectionWitnessTest {
    private fun payload(f: StorageMutationFixture, samples: List<HrSample>) = GpsWorkoutPayload.capture(
        f.account(), "synthetic-session", WorkoutRow("source", 0, 900, "Walk", "manual"), samples)

    @Test fun emptyProjectionIsExplicitTwelveByteWitnessNotMissingProof() {
        StorageMutationFixture().use { f ->
            val payload = payload(f, emptyList())
            val witness = GpsWorkoutProjectionWitness.capture(payload, emptyMap(), emptyList())
            assertEquals(12, witness.encode().size)
            assertTrue(GpsWorkoutProjectionWitness.decode(witness.encode(), payload).entries.isEmpty())
            assertThrows(IllegalStateException::class.java) { GpsWorkoutProjectionWitness.decode(byteArrayOf(), payload) }
        }
    }

    @Test fun maximumWitnessHasExactBoundAndRetainsFirstOrdinalMapping() {
        StorageMutationFixture().use { f ->
            val samples = List(GpsWorkoutPayload.MAX_HR_SAMPLES) { HrSample("source", (GpsWorkoutPayload.MAX_HR_SAMPLES - it).toLong(), 140, it % 3) }
            val payload = payload(f, samples)
            val witness = GpsWorkoutProjectionWitness.capture(payload, samples.associateBy { it.ts }, List(samples.size) { it + 1L })
            val bytes = witness.encode()
            assertEquals(5_242_892, bytes.size); assertEquals(GpsWorkoutProjectionWitness.MAX_BYTES, bytes.size)
            val restored = GpsWorkoutProjectionWitness.decode(bytes, payload)
            assertArrayEquals(bytes, restored.encode())
            assertEquals(samples.last(), restored.entries.first().row)
            assertEquals(samples.lastIndex, restored.entries.first().originOrdinal)
            assertEquals(0, restored.entries.last().originOrdinal)
        }
    }

    @Test fun duplicateTimestampCannotClaimLaterCapturedOrdinalEvenWhenValueIsIdentical() {
        StorageMutationFixture().use { f ->
            val hr = HrSample("source", 100, 140)
            val payload = payload(f, listOf(hr, hr))
            val bytes = GpsWorkoutProjectionWitness.capture(payload, mapOf(100L to hr), listOf(1, -1)).encode()
            ByteBuffer.wrap(bytes).putInt(28, 1)
            assertThrows(IllegalStateException::class.java) { GpsWorkoutProjectionWitness.decode(bytes, payload) }
            assertThrows(IllegalStateException::class.java) {
                GpsWorkoutProjectionWitness.capture(payload, mapOf(100L to hr), listOf(-1, 2))
            }
        }
    }

    @Test fun unrelatedCanonicalValueRequiresExplicitPreexistingOriginAndFullTypedRow() {
        StorageMutationFixture().use { f ->
            val hr = HrSample("source", 100, 140, 0); val raw = hr.copy(bpm = 150, synced = 7)
            val payload = payload(f, listOf(hr))
            val valid = GpsWorkoutProjectionWitness.capture(payload, mapOf(100L to raw), listOf(-1)).encode()
            assertEquals(raw, GpsWorkoutProjectionWitness.decode(valid, payload).entries.single().row)
            ByteBuffer.wrap(valid).putInt(28, 0)
            assertThrows(IllegalStateException::class.java) { GpsWorkoutProjectionWitness.decode(valid, payload) }
        }
    }

    @Test fun unknownVersionTruncationTrailingBytesAndCountsNeverBecomeAnEmptyWitness() {
        StorageMutationFixture().use { f ->
            val hr = HrSample("source", 100, 140); val payload = payload(f, listOf(hr))
            val good = GpsWorkoutProjectionWitness.capture(payload, mapOf(100L to hr), listOf(1)).encode()
            val bad = listOf(good.dropLast(1).toByteArray(), good + 0.toByte(),
                good.copyOf().also { ByteBuffer.wrap(it).putInt(4, 2) },
                good.copyOf().also { ByteBuffer.wrap(it).putInt(8, -1) },
                good.copyOf().also { ByteBuffer.wrap(it).putInt(8, GpsWorkoutProjectionWitness.MAX_ROWS + 1) })
            bad.forEach { assertThrows(IllegalStateException::class.java) { GpsWorkoutProjectionWitness.decode(it, payload) } }
        }
    }

    @Test fun missingExtraUnsortedOrWrongOwnerCanonicalKeysAreNotCovered() {
        StorageMutationFixture().use { f ->
            val rows = listOf(HrSample("source", 100, 140), HrSample("source", 101, 141))
            val payload = payload(f, rows)
            assertThrows(IllegalStateException::class.java) { GpsWorkoutProjectionWitness.capture(payload, mapOf(100L to rows[0]), listOf(1, 2)) }
            assertThrows(IllegalStateException::class.java) { GpsWorkoutProjectionWitness.capture(payload, rows.associateBy { it.ts } + (102L to rows[0].copy(ts = 102)), listOf(1, 2)) }
            assertThrows(IllegalStateException::class.java) { GpsWorkoutProjectionWitness.capture(payload, rows.associateBy { it.ts }.mapValues { it.value.copy(deviceId = "other") }, listOf(-1, -1)) }
            val bytes = GpsWorkoutProjectionWitness.capture(payload, rows.associateBy { it.ts }, listOf(1, 2)).encode()
            ByteBuffer.wrap(bytes).putLong(12, 101).putLong(32, 100)
            assertThrows(IllegalStateException::class.java) { GpsWorkoutProjectionWitness.decode(bytes, payload) }
        }
    }

    @Test fun productionRetainedBoundsCannotBeRaisedThroughTestLimits() {
        assertEquals(1_024, GpsWorkoutDeliveryStore.Limits().artifacts)
        assertEquals(256L * 1024 * 1024, GpsWorkoutDeliveryStore.Limits().bytes)
        assertThrows(IllegalArgumentException::class.java) { GpsWorkoutDeliveryStore.Limits(1_025) }
        assertThrows(IllegalArgumentException::class.java) { GpsWorkoutDeliveryStore.Limits(bytes = 256L * 1024 * 1024 + 1) }
    }
}
