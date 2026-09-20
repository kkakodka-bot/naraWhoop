package com.frwhoop.scoring

import com.frwhoop.scoring.scoring.ScoringPoller
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class ScoringWorkerProcessTest {
    @Test fun normalCompletionAndOrdinaryFailuresDoNotTriggerFatalExit() {
        var ran=false
        ScoringWorkerProcess.run { ran=true }
        assertTrue(ran)
        val error=assertThrows(IllegalArgumentException::class.java) {
            ScoringWorkerProcess.run { throw IllegalArgumentException("fixture") }
        }
        assertEquals("fixture",error.message)
    }

    @Test fun unresponsiveAttemptExitsJvmDespiteNonDaemonThreadAndBlockedShutdownHook() {
        val classpath=listOf(ScoringProcessExitFixture::class.java,ScoringWorkerProcess::class.java,Unit::class.java)
            .map { File(it.protectionDomain.codeSource.location.toURI()).path }.distinct().joinToString(File.pathSeparator)
        require(classpath.isNotBlank())
        val process=ProcessBuilder(File(System.getProperty("java.home"),"bin/java").path,"-cp",classpath,
            ScoringProcessExitFixture::class.java.name).redirectErrorStream(true).start()
        val began=System.nanoTime()
        try {
            assertTrue("Fatal attempt must exit despite retained library threads/hooks",process.waitFor(5,TimeUnit.SECONDS))
            assertEquals(ScoringWorkerProcess.FATAL_EXIT_CODE,process.exitValue())
            assertTrue((System.nanoTime()-began)/1e9<5)
        } finally { if(process.isAlive) process.destroyForcibly() }
    }
}

/** Only executed in the child JVM; a normal System.exit would hang on this shutdown hook. */
object ScoringProcessExitFixture {
    @JvmStatic fun main(args:Array<String>) {
        Thread({ CountDownLatch(1).await() },"fixture-library-thread").apply { isDaemon=false;start() }
        Runtime.getRuntime().addShutdownHook(Thread({ CountDownLatch(1).await() },"fixture-blocked-shutdown"))
        ScoringWorkerProcess.run { throw ScoringPoller.UnresponsiveAttempt() }
        error("Fatal scoring worker returned")
    }
}
