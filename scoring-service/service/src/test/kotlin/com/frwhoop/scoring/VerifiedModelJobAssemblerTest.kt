package com.frwhoop.scoring

import com.frwhoop.scoring.b2.B2ObjectStore
import com.frwhoop.scoring.signals.PhysiologyShadowRunner
import com.frwhoop.scoring.signals.VerifiedModelJobAssembler
import com.frwhoop.scoring.signals.VerifiedRawObjectReader
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID

class VerifiedModelJobAssemblerTest {
    private val user = UUID.randomUUID(); private val device = UUID.randomUUID()
    private val request = PhysiologyShadowRunner.Request(user, device, "7", 1000, 1040, emptyList())
    private val assembler = VerifiedModelJobAssembler()

    private fun fixture(block: (Path, JSONObject, VerifiedRawObjectReader.Decoded, (JSONObject) -> PhysiologyShadowRunner.Model) -> Unit) {
        val directory = Files.createTempDirectory("model-acquisition-test-")
        try {
            val count = 721
            val bytes = ByteBuffer.allocate(39 + count * 2).order(ByteOrder.LITTLE_ENDIAN).apply {
                put("NPB1".toByteArray()); put(2); put(1); putInt(1)
                putLong(1); putLong(1000); put(0); putLong(7); putInt(count * 2)
                for (i in 0 until count) putShort((i % 31 - 15).toShort())
            }.array()
            val manifest = VerifiedRawObjectReader.Manifest(UUID.randomUUID(), user, device,
                "v3/ppg/users/$user/devices/$device/fixture", B2ObjectStore.sha256Hex(bytes), "none", "noop_push_npb1",
                bytes.size, bytes.size, 1, 1000, 1040)
            val decoded = VerifiedRawObjectReader(object : B2ObjectStore.GetClient {
                override fun getObject(key: String, maximumBytes: Int) = bytes
            }).read(manifest, user, device)
            val contract = JSONObject().put("schema_version", 1).put("adapter_version", VerifiedModelJobAssembler.VERSION)
                .put("user_id", user).put("device_id", device).put("input_revision", "7")
                .put("scope_start_s", 1000).put("scope_end_s", 1040)
                .put("model_id", "wav2sleep-cardiorespiratory").put("checkpoint_sha256", "c".repeat(64))
                .put("preprocess_version", "fixture-preprocess").put("quality_policy_version", "fixture-quality")
                .put("device_family", "synthetic_fixture").put("capture_firmware", "fixture-not-hardware")
                .put("decoder_version", VerifiedRawObjectReader.VERSION).put("start_s", 1000).put("end_s", 1030)
                .put("raw_object_attestations", JSONArray().put(JSONObject().put("object_id", manifest.id)
                    .put("object_sha256", decoded.digest).put("user_id", user).put("device_id", device)
                    .put("device_family", "synthetic_fixture").put("capture_firmware", "fixture-not-hardware")
                    .put("decoder_version", VerifiedRawObjectReader.VERSION).put("qualification", "verified_capture_metadata")
                    .put("capture_metadata_evidence_sha256", "f".repeat(64))))
                .put("mode", "retrospective").put("review", JSONObject().put("status", "reviewed_for_shadow")
                    .put("reviewer", "synthetic-functional-test-not-acquisition-proof")
                    .put("timing_report_sha256", "a".repeat(64)).put("semantics_report_sha256", "b".repeat(64))
                    .put("units_report_sha256", "d".repeat(64)).put("synchronization_report_sha256", "e".repeat(64)))
                .put("channels", JSONArray().put(JSONObject().put("name", "PPG").put("unit", "adc_count")
                    .put("wavelength_nm", 525).put("sample_rate_hz", 24).put("clock_uncertainty_seconds", 0.001)
                    .put("clock_id", "synthetic-clock").put("acquisition_id", "synthetic-acquisition")
                    .put("records", JSONArray().put(JSONObject().put("object_id", manifest.id).put("object_sha256", decoded.digest)
                        .put("row_id", 1).put("record_index", 7).put("sensor_second", 1000).put("start_s", 1000)
                        .put("offset", 0).put("stride", 1).put("count", count).put("observed", JSONArray(List(count) { true }))))))
            fun model(value: JSONObject): PhysiologyShadowRunner.Model {
                val encoded = value.toString().toByteArray(); Files.write(directory.resolve("acquisition.json"), encoded)
                return PhysiologyShadowRunner.Model("wav2sleep-cardiorespiratory", JSONObject()
                    .put("preprocess_version", "fixture-preprocess").put("quality_policy_version", "fixture-quality")
                    .put("assets", JSONObject().put("weights", JSONObject().put("sha256", "c".repeat(64)))
                        .put("acquisition_contract", JSONObject().put("path", "acquisition.json").put("sha256", B2ObjectStore.sha256Hex(encoded)))), directory)
            }
            block(directory, contract, decoded, ::model)
        } finally {
            Files.deleteIfExists(directory.resolve("acquisition.json")); Files.deleteIfExists(directory)
        }
    }

    @Test fun verifiedBytesAndQualifiedMappingCreateOwnedCheckpointBoundInput() = fixture { _, contract, decoded, model ->
        assertFalse(decoded.timingVerifiedForWaveforms)
        val job = assembler.prepare(model(contract), request, listOf(decoded))!!.payload
        assertEquals(user.toString(), job.getString("user_id")); assertEquals("7", job.getString("input_revision"))
        assertEquals(1, job.getInt("epochs")); assertEquals("c".repeat(64), job.getString("checkpoint_sha256"))
        val channel = job.getJSONArray("signals").getJSONObject(0)
        assertEquals(721, channel.getJSONArray("values").length()); assertEquals(-15, channel.getJSONArray("values").getInt(0))
        val digest = job.remove("input_hash")
        assertEquals(digest, VerifiedModelJobAssembler.inputHash(job))
    }

    @Test fun missingProofDoesNotConvertNpb1IntoVerifiedWaveform() {
        assertNull(assembler.prepare(PhysiologyShadowRunner.Model("wav2sleep-cardiorespiratory", JSONObject(), Path.of(".")), request, emptyList()))
    }

    @Test fun ownerDeviceRevisionCheckpointAndPipelineCannotBeReused() = fixture { _, contract, decoded, model ->
        for ((field, bad) in listOf("user_id" to UUID.randomUUID().toString(), "device_id" to UUID.randomUUID().toString(),
            "input_revision" to "8", "checkpoint_sha256" to "f".repeat(64), "preprocess_version" to "other")) {
            val changed = JSONObject(contract.toString()).put(field, bad)
            assertThrows(IllegalArgumentException::class.java) { assembler.prepare(model(changed), request, listOf(decoded)) }
        }
    }

    @Test fun digestChangedBytesMissingRecordsGapAndMaskRejectOrRemainUnknown() = fixture { directory, contract, decoded, model ->
        val configured = model(contract)
        Files.writeString(directory.resolve("acquisition.json"), contract.toString() + " ")
        assertThrows(IllegalArgumentException::class.java) { assembler.prepare(configured, request, listOf(decoded)) }
        assertThrows(IllegalArgumentException::class.java) { assembler.prepare(model(contract), request, listOf(decoded.copy(digest = "f".repeat(64)))) }
        val record = contract.getJSONArray("channels").getJSONObject(0).getJSONArray("records").getJSONObject(0)
        record.put("start_s", 1000.1)
        assertThrows(IllegalArgumentException::class.java) { assembler.prepare(model(contract), request, listOf(decoded)) }
        record.put("start_s", 1000); record.getJSONArray("observed").put(10, false)
        val job = assembler.prepare(model(contract), request, listOf(decoded))!!.payload
        assertFalse(job.getJSONArray("signals").getJSONObject(0).getJSONArray("observed").getBoolean(10))
        record.getJSONArray("observed").put(10, 1)
        assertThrows(IllegalArgumentException::class.java) { assembler.prepare(model(contract), request, listOf(decoded)) }
    }

    @Test fun typedHashMatchesPythonGolden() {
        val value = JSONObject().put("n", JSONArray().put(JSONObject.NULL).put(true).put(false).put(1).put(1.5).put("é")).put("x", "abc")
        val prefix = "{s1:n[ntfd".toByteArray()
        val numbers = ByteBuffer.allocate(8).putDouble(1.0).array() + "d".toByteArray() + ByteBuffer.allocate(8).putDouble(1.5).array()
        val tail = "s2:é]s1:xs3:abc}".toByteArray()
        assertEquals(B2ObjectStore.sha256Hex(prefix + numbers + tail), VerifiedModelJobAssembler.inputHash(value))
        assertThrows(IllegalArgumentException::class.java) { VerifiedModelJobAssembler.inputHash(JSONObject().put("large", 9007199254740993L)) }
    }

    @Test fun replayedPhysicalRecordInDifferentArchiveAndDuplicateRowsReject() = fixture { _, contract, decoded, model ->
        val duplicateRow = decoded.copy(records = decoded.records + decoded.records)
        assertThrows(IllegalArgumentException::class.java) { assembler.prepare(model(contract), request, listOf(duplicateRow)) }
        val second = decoded.copy(manifest = decoded.manifest.copy(id = UUID.randomUUID()))
        contract.getJSONArray("raw_object_attestations").put(JSONObject(contract.getJSONArray("raw_object_attestations").getJSONObject(0).toString())
            .put("object_id", second.manifest.id))
        val mappings = contract.getJSONArray("channels").getJSONObject(0).getJSONArray("records")
        val replay = JSONObject(mappings.getJSONObject(0).toString()).put("object_id", second.manifest.id)
            .put("start_s", 1030.0416666666667)
        mappings.put(replay)
        val error = assertThrows(IllegalArgumentException::class.java) { assembler.prepare(model(contract), request, listOf(decoded, second)) }
        assertEquals("acquisition_replayed_physical_record", error.message)
        val conflicting = second.copy(records = second.records.map { it.copy(columns = it.columns.map { value -> value + 1 }) })
        assertEquals("acquisition_replayed_physical_record", assertThrows(IllegalArgumentException::class.java) {
            assembler.prepare(model(contract), request, listOf(decoded, conflicting))
        }.message)
    }

    @Test fun registryResolvesPerJobWithoutChangingModelActivationAndCaptureIdentityMustMatch() = fixture { _, contract, decoded, model ->
        val configured = model(contract)
        configured.activation.getJSONObject("assets").remove("acquisition_contract")
        fun registry(value: JSONObject) = VerifiedModelJobAssembler(VerifiedModelJobAssembler.ContractResolver { _, query ->
            if (query.inputRevision != value.getString("input_revision")) null else {
                val bytes = value.toString().toByteArray()
                VerifiedModelJobAssembler.Receipt(bytes, B2ObjectStore.sha256Hex(bytes))
            }
        })
        assertNotNull(registry(contract).prepare(configured, request, listOf(decoded)))
        assertNull(registry(contract).prepare(configured, request.copy(inputRevision = "8"), listOf(decoded)))
        contract.put("input_revision", "8")
        assertNotNull(registry(contract).prepare(configured, request.copy(inputRevision = "8"), listOf(decoded)))
        contract.getJSONArray("raw_object_attestations").getJSONObject(0).put("capture_firmware", "unrelated-firmware")
        assertEquals("acquisition_capture_attestation_mismatch", assertThrows(IllegalArgumentException::class.java) {
            registry(contract).prepare(configured, request.copy(inputRevision = "8"), listOf(decoded))
        }.message)
    }
}
