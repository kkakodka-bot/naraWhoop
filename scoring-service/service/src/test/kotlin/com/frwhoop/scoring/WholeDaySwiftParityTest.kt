package com.frwhoop.scoring

import org.junit.Test
import java.nio.file.Path

/** Only the dedicated Gradle gate runs this externally produced corpus. No assumptions/skips. */
class WholeDaySwiftParityTest {
    @Test fun actualSwiftWholeDays() {
        val root = Path.of("../..").toAbsolutePath().normalize()
        val directory = Path.of(System.getenv("W4_SWIFT_DAY_FIXTURE_DIR")
            ?: root.resolve("Tests/Fixtures/w4-whole-day-swift-v1").toString())
        val cases = WholeDaySwiftCorpus.read(directory, root)
        val runner = WholeDaySwiftRunner()
        for (case in cases.sortedWith(compareBy({ it.input.getString("day") }, { it.id }))) {
            try {
                WholeDaySwiftCorpus.compare(runner.run(case), case.expected, case.id)
                println("Actual-Swift ${case.mode} PASS: ${case.id}")
            } catch (failure: Throwable) {
                throw AssertionError("Actual-Swift ${case.mode} case ${case.id}: ${failure.message}", failure)
            }
        }
        println("Actual-Swift corpus modes: ${cases.groupingBy { it.mode }.eachCount()}; kernel_calendar does not establish shipped DST/server_day parity")
    }
}
