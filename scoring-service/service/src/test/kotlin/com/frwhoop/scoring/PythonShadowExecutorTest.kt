package com.frwhoop.scoring

import com.frwhoop.scoring.signals.ModelQueueWorker
import com.frwhoop.scoring.signals.PhysiologyShadowRunner
import com.frwhoop.scoring.signals.PythonShadowExecutor
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path

class PythonShadowExecutorTest {
    private val model=PhysiologyShadowRunner.Model("neurokit2",JSONObject(),Path.of("."))
    private val job=PhysiologyShadowRunner.PreparedJob(JSONObject().put("user_id","fixture-user")
        .put("device_id","fixture-device").put("input_revision","1").put("input_hash","fixture-hash"))

    @Test fun pythonModelExceptionEnvelopeConsumesRetryInsteadOfTerminalAbstention() {
        assertEquals("model_execution_failed",ModelQueueWorker.transientFailure(JSONObject()
            .put("status","abstained").put("reason","model_execution_failed")))
        assertNull(ModelQueueWorker.transientFailure(JSONObject()
            .put("status","abstained").put("reason","channel_semantics_unverified")))
    }

    private fun script(body:String,run:(PythonShadowExecutor)->Unit) {
        val file=Files.createTempFile("model-child-fixture-",".sh")
        try {
            Files.writeString(file,"#!/bin/sh\n$body\n")
            check(file.toFile().setExecutable(true,true))
            run(PythonShadowExecutor(file,"fixture-no-python-imports",2))
        } finally { Files.deleteIfExists(file) }
    }

    @Test fun childCrashAndCorruptOutputStayUnavailableAndRetryable() {
        for ((body,reason) in listOf("exit 17" to "inference_worker_failed", "printf '{'" to "inference_request_failed")) {
            script(body) { executor ->
                repeat(2) {
                    val result=executor.run(model,job)
                    assertEquals(reason,result.getString("reason"))
                    assertNotNull(ModelQueueWorker.transientFailure(result))
                    assertFalse(result.getBoolean("canonical_outputs_allowed"))
                }
            }
        }
    }

    @Test fun timeoutKillsChildAndDoesNotPoisonNextSlot() {
        script("sleep 20") { executor ->
            val started=System.nanoTime()
            val result=executor.run(model,job)
            assertEquals("inference_timeout",result.getString("reason"))
            assertTrue((System.nanoTime()-started)/1e9<5)
            assertNotNull(ModelQueueWorker.transientFailure(result))
        }
    }

    @Test fun crossAccountOutputCannotPassProcessBoundary() {
        val output=JSONObject(job.payload.toString()).put("model_id",model.id).put("publication_mode","shadow")
            .put("canonical_outputs_allowed",false).put("status","complete").put("user_id","other-user")
        script("printf '%s' '$output'") { executor ->
            assertEquals("inference_output_contract_invalid",executor.run(model,job).getString("reason"))
        }
    }
}
