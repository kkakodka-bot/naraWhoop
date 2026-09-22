package com.noop.location

import com.noop.data.HrSample
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.util.Collections

/** A destination projection, never a replacement for the ordered GPF1 observations. */
internal class GpsWorkoutProjectionWitness private constructor(entries: List<Entry>) {
    data class Entry(val row: HrSample, val originOrdinal: Int)
    val entries: List<Entry> = Collections.unmodifiableList(ArrayList(entries))

    fun validate(payload: GpsWorkoutPayload) {
        val first = firstOrdinals(payload)
        check(entries.size == first.size && entries.size <= MAX_ROWS) { "GPS witness coverage differs" }
        entries.zip(first.entries.sortedBy { it.key }).forEach { (entry, expected) ->
            check(entry.row.deviceId == payload.row.deviceId && entry.row.ts == expected.key) { "GPS witness key differs" }
            check(entry.originOrdinal == -1 || entry.originOrdinal == expected.value) { "GPS witness origin differs" }
            if (entry.originOrdinal >= 0) check(payload.samples[entry.originOrdinal] == entry.row) {
                "GPS inserted witness does not match its first capture"
            }
        }
    }

    fun encode(): ByteArray = ByteArrayOutputStream(12 + entries.size * 20).also { bytes ->
        check(entries.size <= MAX_ROWS)
        DataOutputStream(bytes).use { out ->
            out.writeInt(MAGIC); out.writeInt(1); out.writeInt(entries.size)
            entries.forEach { entry ->
                out.writeLong(entry.row.ts); out.writeInt(entry.row.bpm); out.writeInt(entry.row.synced)
                out.writeInt(entry.originOrdinal)
            }
        }
    }.toByteArray()

    companion object {
        const val MAX_ROWS = GpsWorkoutPayload.MAX_HR_SAMPLES
        const val MAX_BYTES = 12 + 20 * MAX_ROWS
        private const val MAGIC = 0x47505731 // GPW1, local canonical projection only.

        fun firstOrdinals(payload: GpsWorkoutPayload): Map<Long, Int> {
            check(payload.samples.size <= MAX_ROWS)
            return linkedMapOf<Long, Int>().also { first ->
                payload.samples.forEachIndexed { index, row ->
                    check(row.deviceId == payload.row.deviceId)
                    first.putIfAbsent(row.ts, index)
                }
            }
        }

        fun capture(payload: GpsWorkoutPayload, canonical: Map<Long, HrSample>, insertedIds: List<Long>): GpsWorkoutProjectionWitness {
            check(insertedIds.size == payload.samples.size)
            val first = firstOrdinals(payload)
            check(canonical.keys == first.keys) { "GPS canonical coverage differs" }
            insertedIds.forEachIndexed { index, id ->
                if (id > 0) check(first[payload.samples[index].ts] == index) { "GPS inserted a nonfirst duplicate" }
            }
            return GpsWorkoutProjectionWitness(first.entries.sortedBy { it.key }.map { (ts, ordinal) ->
                Entry(checkNotNull(canonical[ts]), if (insertedIds[ordinal] > 0) ordinal else -1)
            }).also { it.validate(payload) }
        }

        fun decode(bytes: ByteArray, payload: GpsWorkoutPayload): GpsWorkoutProjectionWitness {
            check(bytes.size in 12..MAX_BYTES) { "GPS witness size requires recovery" }
            return DataInputStream(ByteArrayInputStream(bytes)).use { input ->
                check(input.readInt() == MAGIC && input.readInt() == 1) { "GPS witness version requires recovery" }
                val count = input.readInt()
                check(count in 0..MAX_ROWS && bytes.size == 12 + count * 20)
                GpsWorkoutProjectionWitness(List(count) {
                    Entry(HrSample(payload.row.deviceId, input.readLong(), input.readInt(), input.readInt()), input.readInt())
                }).also { it.validate(payload); check(it.encode().contentEquals(bytes)) }
            }
        }
    }
}
