package com.noop.location

import com.noop.account.AccountStorageContext
import com.noop.data.HrSample
import com.noop.data.WorkoutRow
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.util.Collections
import java.util.UUID

/** Local-only v1 intent. It records the complete destination row, not inputs to recompute it. */
internal class GpsWorkoutPayload private constructor(
    val namespace: String,
    val project: String,
    val user: String,
    val capturedGeneration: String,
    val sessionId: String,
    val row: WorkoutRow,
    samples: List<HrSample>,
) {
    val samples: List<HrSample> = Collections.unmodifiableList(ArrayList(samples))

    fun validate(account: AccountStorageContext, session: AccountGpsJournal.Snapshot) {
        val endMs = checkNotNull(session.endMs)
        check(namespace == account.namespace && project == account.identity.projectURL.orEmpty() &&
            user == account.identity.scope?.userID.orEmpty()) { "GPS finalization owner mismatch" }
        check(UUID.fromString(capturedGeneration).toString() == capturedGeneration)
        check(sessionId == session.id && row.deviceId == session.deviceId && row.sport == session.sport &&
            row.startTs == session.startMs / 1000 && row.endTs == endMs / 1000)
        check(row.source == "manual" && row.durationS ==
            (endMs - session.startMs - session.pausedDurationMs).coerceAtLeast(0) / 1000.0)
        check(row.distanceM == session.distanceM.takeIf { it > 0 })
        check(samples.size <= MAX_HR_SAMPLES && samples.all { it.deviceId == row.deviceId && it.bpm > 0 })
        listOf(row.durationS, row.energyKcal, row.strain, row.distanceM).forEach { check(it == null || it.isFinite()) }
    }

    fun encode(): ByteArray {
        val bytes = object : ByteArrayOutputStream() {
            override fun write(b: Int) { check(count < MAX_BYTES); super.write(b) }
            override fun write(b: ByteArray, off: Int, len: Int) {
                check(len >= 0 && count <= MAX_BYTES - len); super.write(b, off, len)
            }
        }
        DataOutputStream(bytes).use { out ->
            out.writeInt(MAGIC); out.writeInt(1)
            listOf(namespace, project, user, capturedGeneration, sessionId).forEach { out.text(it) }
            out.text(row.deviceId); out.writeLong(row.startTs); out.writeLong(row.endTs)
            out.text(row.sport); out.text(row.source)
            out.optionalDouble(row.durationS); out.optionalDouble(row.energyKcal)
            out.optionalInt(row.avgHr); out.optionalInt(row.maxHr)
            out.optionalDouble(row.strain); out.optionalDouble(row.distanceM)
            out.optionalText(row.zonesJSON); out.optionalText(row.notes); out.optionalText(row.routePolyline)
            out.optionalInt(row.steps)
            check(samples.size <= MAX_HR_SAMPLES)
            out.writeInt(samples.size)
            samples.forEach {
                check(it.deviceId == row.deviceId)
                out.writeLong(it.ts); out.writeInt(it.bpm); out.writeInt(it.synced)
            }
        }
        return bytes.toByteArray()
    }

    companion object {
        const val MAX_HR_SAMPLES = 262_144
        const val MAX_BYTES = 16 * 1024 * 1024
        private const val MAX_TEXT_BYTES = 8 * 1024 * 1024
        private const val MAGIC = 0x47504631 // GPF1, not a network protocol.

        fun capture(account: AccountStorageContext, sessionId: String, row: WorkoutRow, samples: List<HrSample>): GpsWorkoutPayload {
            require(samples.size <= MAX_HR_SAMPLES)
            return GpsWorkoutPayload(account.namespace, account.identity.projectURL.orEmpty(),
                account.identity.scope?.userID.orEmpty(), account.identity.generation.toString(), sessionId, row, samples)
        }

        fun decode(bytes: ByteArray): GpsWorkoutPayload {
            check(bytes.size <= MAX_BYTES)
            return DataInputStream(ByteArrayInputStream(bytes)).use { input ->
                check(input.readInt() == MAGIC && input.readInt() == 1) { "GPS payload version requires recovery" }
                val namespace = input.text(); val project = input.text(); val user = input.text()
                val generation = input.text(); val sessionId = input.text()
                val row = WorkoutRow(deviceId = input.text(), startTs = input.readLong(), endTs = input.readLong(),
                    sport = input.text(), source = input.text(), durationS = input.optionalDouble(), energyKcal = input.optionalDouble(),
                    avgHr = input.optionalInt(), maxHr = input.optionalInt(), strain = input.optionalDouble(), distanceM = input.optionalDouble(),
                    zonesJSON = input.optionalText(), notes = input.optionalText(), routePolyline = input.optionalText(), steps = input.optionalInt())
                val count = input.readInt()
                check(count in 0..MAX_HR_SAMPLES && count <= input.available() / 16)
                val samples = List(count) { HrSample(row.deviceId, input.readLong(), input.readInt(), input.readInt()) }
                check(input.available() == 0)
                GpsWorkoutPayload(namespace, project, user, generation, sessionId, row, samples).also {
                    check(it.encode().contentEquals(bytes)) { "Noncanonical GPS payload requires recovery" }
                }
            }
        }

        private fun DataOutputStream.text(value: String) {
            val bytes = value.toByteArray(Charsets.UTF_8)
            check(bytes.size <= MAX_TEXT_BYTES); writeInt(bytes.size); write(bytes)
        }
        private fun DataInputStream.text(): String {
            val size = readInt(); check(size in 0..MAX_TEXT_BYTES && size <= available())
            val bytes = ByteArray(size); readFully(bytes)
            return bytes.toString(Charsets.UTF_8).also { check(it.toByteArray(Charsets.UTF_8).contentEquals(bytes)) }
        }
        private fun DataOutputStream.optionalText(value: String?) { writeBoolean(value != null); if (value != null) text(value) }
        private fun DataInputStream.optionalText(): String? = if (readBoolean()) text() else null
        private fun DataOutputStream.optionalDouble(value: Double?) {
            writeBoolean(value != null); if (value != null) { check(value.isFinite()); writeLong(value.toRawBits()) }
        }
        private fun DataInputStream.optionalDouble(): Double? = if (readBoolean()) Double.fromBits(readLong()).also { check(it.isFinite()) } else null
        private fun DataOutputStream.optionalInt(value: Int?) { writeBoolean(value != null); if (value != null) writeInt(value) }
        private fun DataInputStream.optionalInt(): Int? = if (readBoolean()) readInt() else null
    }
}
