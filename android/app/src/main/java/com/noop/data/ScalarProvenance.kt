package com.noop.data

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Immutable capture metadata only; no current settings or inferred history are used on readback. */
object ScalarProvenance {
    private val names = setOf("v", "origin", "recordIndex", "frameSHA256", "algorithm", "sampleRateHz",
        "windowSettingSeconds", "inputStartTs", "inputEndTs", "inputSHA256", "inputSelection")
    private val digest = Regex("[0-9a-f]{64}")
    private const val MAX_SAFE_INTEGER = 9007199254740991L
    private val directKeys = setOf("recordIndex", "frameSHA256")
    private val derivedKeys = setOf("algorithm", "sampleRateHz", "windowSettingSeconds", "inputStartTs", "inputEndTs", "inputSHA256")

    fun validated(json: String): Map<String, Any> {
        require(json.toByteArray(Charsets.UTF_8).size <= 1024)
        val o = JSONObject(json)
        return validated(o.keys().asSequence().associateWith { o.get(it) })
    }

    /** Validate original JSON value types BEFORE serialization can turn e.g. Double(1.0) into 1. */
    fun validated(values: Map<*, *>): Map<String, Any> {
        require(values.keys.all { it is String })
        val keys = values.keys.filterIsInstance<String>().toSet()
        require(keys.all { it in names } && keys.containsAll(setOf("v", "origin")))
        val result = keys.associateWith { requireNotNull(values[it]) }
        require(integer(result["v"]) == 1L)
        require(result["origin"] in setOf("whoop-v18", "whoop-v26-ppg-derived", "legacy-unknown"))
        when (result["origin"]) {
            "whoop-v18" -> require(keys.intersect(derivedKeys + "inputSelection").isEmpty())
            "whoop-v26-ppg-derived" -> require(keys.containsAll(derivedKeys) && keys.intersect(directKeys).isEmpty())
            "legacy-unknown" -> require(keys.intersect(directKeys + derivedKeys + "inputSelection").isEmpty())
        }
        result["recordIndex"]?.let { require(integer(it) in 0..4294967295L) }
        for (key in listOf("frameSHA256", "inputSHA256")) result[key]?.let { require(it is String && digest.matches(it)) }
        result["algorithm"]?.let { require(it in setOf("ppg-acf-v1", "ppg-acf-sublag-v1")) }
        result["inputSelection"]?.let { require(it in setOf("concat-records-per-second-v1", "last-record-per-second-v1")) }
        for (key in listOf("sampleRateHz", "windowSettingSeconds")) result[key]?.let { require(integer(it) in 1..MAX_SAFE_INTEGER) }
        for (key in listOf("inputStartTs", "inputEndTs")) result[key]?.let { require(integer(it) in -MAX_SAFE_INTEGER..MAX_SAFE_INTEGER) }
        if (result.containsKey("inputStartTs") && result.containsKey("inputEndTs"))
            require(integer(result["inputEndTs"]) > integer(result["inputStartTs"]))
        require(JSONObject(result).toString().toByteArray(Charsets.UTF_8).size <= 1024)
        return result
    }

    fun canonical(json: String): String = JSONObject(java.util.TreeMap(validated(json))).toString()

    fun v18(frame: ByteArray, recordIndex: Long?): String {
        val o = JSONObject().put("v", 1).put("origin", "whoop-v18")
            .put("frameSHA256", V18AuxIdentityMigration.sha256(frame))
        recordIndex?.let { o.put("recordIndex", it) }
        return canonical(o.toString())
    }

    data class PpgInput(val ts: Long, val recordIndex: Long?, val samples: List<Int>)

    /** Android's current estimator consumes ALL records at each second, in encounter order. */
    fun derivedPpg(records: List<PpgInput>, sampleRateHz: Int, windowSettingSeconds: Int,
                   subLagInterp: Boolean): String {
        require(records.isNotEmpty() && records.all { it.samples.isNotEmpty() })
        val o = JSONObject().put("v", 1).put("origin", "whoop-v26-ppg-derived")
            .put("algorithm", if (subLagInterp) "ppg-acf-sublag-v1" else "ppg-acf-v1")
            .put("sampleRateHz", sampleRateHz).put("windowSettingSeconds", windowSettingSeconds)
            .put("inputStartTs", records.first().ts).put("inputEndTs", Math.addExact(records.last().ts, 1))
            .put("inputSHA256", ppgInputDigest(records)).put("inputSelection", "concat-records-per-second-v1")
        return canonical(o.toString())
    }

    /** Caller supplies the estimator's ACTUALLY selected records, in nondecreasing time order. */
    fun ppgInputDigest(records: List<PpgInput>): String {
        require(records.isNotEmpty() && records.zipWithNext().all { (a, b) -> a.ts <= b.ts })
        val bytes = ByteArrayOutputStream()
        bytes.write("w1-ppg-input-v1\n".toByteArray(Charsets.UTF_8))
        fun i32(n: Int) { bytes.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(n).array()) }
        fun i64(n: Long) { bytes.write(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(n).array()) }
        i32(records.size)
        for (record in records) {
            i64(record.ts)
            if (record.recordIndex == null) bytes.write(0) else {
                require(record.recordIndex in 0..4294967295L); bytes.write(1); i64(record.recordIndex)
            }
            i32(record.samples.size)
            for (sample in record.samples) {
                require(sample in Short.MIN_VALUE..Short.MAX_VALUE)
                bytes.write(sample and 255); bytes.write((sample ushr 8) and 255)
            }
        }
        return V18AuxIdentityMigration.sha256(bytes.toByteArray())
    }

    private fun integer(value: Any?): Long {
        require(value is Byte || value is Short || value is Int || value is Long)
        return (value as Number).toLong()
    }
}
