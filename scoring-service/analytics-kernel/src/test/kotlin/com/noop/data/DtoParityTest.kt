package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The mechanical half of the DTO contract (migration spec §3.2): every plain DTO in this module
 * must carry the SAME field names, types, order, and defaults as the Room entity it twins in
 * `android/app/src/main/java/com/noop/data/Entities.kt` — annotations dropped, nothing else.
 *
 * Both sides are parsed as text with the same field grammar, so this is a field-list diff, not a
 * review-by-eye. A rename, retype, reorder, or added/removed field on either side fails the build.
 *
 * Runs from the module working directory (scoring-service/analytics-kernel).
 */
class DtoParityTest {

    private data class Field(val name: String, val type: String, val hasDefault: Boolean)

    /** Parses the constructor block of `data class <name>(...)` in [file]. Field grammar: one
     *  `val name: Type [= default]` per line, optional annotations/comments stripped. */
    private fun fieldsOf(file: File, className: String): List<Field> {
        val src = file.readText()
        val m = Regex(
            """data\s+class\s+""" + Regex.escape(className) + """\s*\((.*?)\n\s*\)""",
            RegexOption.DOT_MATCHES_ALL,
        ).find(src) ?: throw AssertionError("${className} not found in ${file.path}")
        val body = m.groupValues[1]
        val fields = mutableListOf<Field>()
        for (rawLine in body.split('\n')) {
            // Strip trailing comments and annotations.
            val line = rawLine.substringBefore("//").trim()
            if (line.isEmpty() || line.startsWith("@")) continue
            val fm = Regex("""val\s+(\w+)\s*:\s*([^=]+?)(\s*=\s*.+?)?,?$""").find(line.trim())
                ?: continue
            fields += Field(
                name = fm.groupValues[1],
                type = fm.groupValues[2].trim(),
                hasDefault = fm.groupValues[3].isNotBlank(),
            )
        }
        return fields
    }

    private fun assertParity(className: String) {
        val entities = File("../../android/app/src/main/java/com/noop/data/Entities.kt")
        val dto = File("src/main/kotlin/com/noop/data/${className}.kt")
        assertTrue("Entities.kt not found at ${entities.absolutePath}", entities.isFile)
        assertTrue("DTO not found at ${dto.absolutePath}", dto.isFile)
        val expected = fieldsOf(entities, className)
        val actual = fieldsOf(dto, className)
        assertTrue("no fields parsed from ${className} in Entities.kt", expected.isNotEmpty())
        assertEquals(
            "field-list diff for ${className} vs Entities.kt (expected <- Entities.kt, actual <- DTO)",
            expected, actual,
        )
    }

    @Test fun hrSampleParity() = assertParity("HrSample")
    @Test fun rrIntervalParity() = assertParity("RrInterval")
    @Test fun eventRowParity() = assertParity("EventRow")
    @Test fun spo2SampleParity() = assertParity("Spo2Sample")
    @Test fun skinTempSampleParity() = assertParity("SkinTempSample")
    @Test fun stepSampleParity() = assertParity("StepSample")
    @Test fun respSampleParity() = assertParity("RespSample")
    @Test fun gravitySampleParity() = assertParity("GravitySample")
    @Test fun dailyMetricParity() = assertParity("DailyMetric")
    @Test fun sleepSessionParity() = assertParity("SleepSession")

    @Test
    fun sourceKindParity() {
        val paired = File("../../android/app/src/main/java/com/noop/data/PairedDevice.kt")
        val dto = File("src/main/kotlin/com/noop/data/SourceKind.kt")
        assertTrue(paired.isFile)
        assertTrue(dto.isFile)
        val extract = { f: File ->
            Regex("""enum\s+class\s+SourceKind\s*\{([^}]*)\}""", RegexOption.DOT_MATCHES_ALL)
                .find(f.readText())!!.groupValues[1]
                .split(',').map { it.substringBefore('(').trim() }.filter { it.isNotEmpty() }
        }
        assertEquals(extract(paired), extract(dto))
    }
}
