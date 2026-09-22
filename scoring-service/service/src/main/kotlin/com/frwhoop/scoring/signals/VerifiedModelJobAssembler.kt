package com.frwhoop.scoring.signals

import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import kotlin.math.abs

/** Extracts model input from verified bytes and an operator-reviewed, hash-bound acquisition contract. */
class VerifiedModelJobAssembler(private val contracts: ContractResolver? = null) : PhysiologyShadowRunner.JobAssembler {
    data class Receipt(val bytes: ByteArray, val sha256: String)
    fun interface ContractResolver {
        fun resolve(model: PhysiologyShadowRunner.Model, request: PhysiologyShadowRunner.Request): Receipt?
    }

    override fun prepare(
        model: PhysiologyShadowRunner.Model,
        request: PhysiologyShadowRunner.Request,
        raw: List<VerifiedRawObjectReader.Decoded>,
    ): PhysiologyShadowRunner.PreparedJob? {
        val receipt = if (contracts != null) contracts.resolve(model, request) ?: return null else {
            // Local fixture/development path. The service uses the owner-scoped immutable registry.
            val asset = model.activation.optJSONObject("assets")?.optJSONObject("acquisition_contract") ?: return null
            val root = model.assetRoot.toRealPath()
            val path = root.resolve(asset.getString("path")).toRealPath()
            require(path.startsWith(root) && Files.isRegularFile(path) && Files.size(path) in 1..32L * 1024 * 1024) {
                "acquisition_contract_path_or_size_invalid"
            }
            Receipt(Files.readAllBytes(path), asset.getString("sha256"))
        }
        require(model.id in setOf("wav2sleep-cardiorespiratory", "neurokit2")) { "model_acquisition_adapter_unsupported" }
        val bytes = receipt.bytes
        require(bytes.size in 1..32 * 1024 * 1024) { "acquisition_contract_path_or_size_invalid" }
        val digest = sha256(bytes)
        require(hash(receipt.sha256) && digest == receipt.sha256) { "acquisition_contract_digest_mismatch" }
        val contract = JSONObject(String(bytes, Charsets.UTF_8))
        val adapterVersion = contract.getString("adapter_version")
        require(contract.getInt("schema_version") == 1 && adapterVersion in setOf(VERSION, DEDUPLICATING_VERSION)) { "acquisition_adapter_version_mismatch" }
        require(contract.getString("user_id") == request.userId.toString() &&
            contract.getString("device_id") == request.deviceId.toString() &&
            contract.getString("input_revision") == request.inputRevision) { "acquisition_owner_or_revision_mismatch" }
        require(contract.getLong("scope_start_s") == request.start && contract.getLong("scope_end_s") == request.end) {
            "acquisition_request_scope_mismatch"
        }
        require(contract.getString("model_id") == model.id &&
            contract.getString("preprocess_version") == model.activation.getString("preprocess_version") &&
            contract.getString("quality_policy_version") == model.activation.getString("quality_policy_version")) { "acquisition_pipeline_mismatch" }
        val checkpoint = model.activation.getJSONObject("assets").optJSONObject("weights")?.getString("sha256")
        require(contract.optString("checkpoint_sha256") == (checkpoint ?: "not_applicable")) { "acquisition_checkpoint_mismatch" }
        require(checkpoint == null || hash(checkpoint)) { "checkpoint_digest_invalid" }
        val review = contract.getJSONObject("review")
        require(review.getString("status") == "reviewed_for_shadow" && review.getString("reviewer").isNotBlank() &&
            listOf("timing_report_sha256", "semantics_report_sha256", "units_report_sha256", "synchronization_report_sha256")
                .all { hash(review.getString(it)) }) { "acquisition_review_missing" }
        require(contract.getString("device_family").isNotBlank() && contract.getString("capture_firmware").isNotBlank()) {
            "acquisition_device_identity_missing"
        }
        val start = finite(contract, "start_s"); val end = finite(contract, "end_s")
        require(start >= request.start && end <= request.end && end > start && end - start <= 14 * 3600) {
            "acquisition_time_scope_invalid"
        }
        require(contract.getString("mode") == "retrospective") { "noncausal_model_requires_retrospective_mode" }
        require(raw.size <= 8 && raw.map { it.manifest.id }.distinct().size == raw.size) { "raw_object_identity_conflict" }
        require(raw.all { source -> source.records.map { it.rowId }.distinct().size == source.records.size }) {
            "acquisition_duplicate_row_id"
        }
        val objects = raw.associateBy { it.manifest.id }
        val recordsByObject = raw.associate { it.manifest.id to it.records.associateBy { record -> record.rowId } }
        val attestations = contract.getJSONArray("raw_object_attestations")
        val attestedObjects = mutableSetOf<UUID>()
        for (i in 0 until attestations.length()) {
            val attestation = attestations.getJSONObject(i)
            val id = UUID.fromString(attestation.getString("object_id"))
            val source = objects[id] ?: error("acquisition_attested_object_missing")
            require(attestedObjects.add(id) && attestation.getString("object_sha256") == source.digest &&
                attestation.getString("user_id") == source.manifest.userId.toString() &&
                attestation.getString("device_id") == source.manifest.deviceId.toString() &&
                attestation.getString("device_family") == contract.getString("device_family") &&
                attestation.getString("capture_firmware") == contract.getString("capture_firmware") &&
                attestation.getString("decoder_version") == source.decoderVersion &&
                attestation.getString("qualification") == "verified_capture_metadata" &&
                hash(attestation.getString("capture_metadata_evidence_sha256"))) { "acquisition_capture_attestation_mismatch" }
        }
        val channels = contract.getJSONArray("channels")
        require(channels.length() == 1) { "model_acquisition_channel_set_unsupported" }
        val output = JSONArray()
        for (index in 0 until channels.length()) {
            val channel = channels.getJSONObject(index)
            val name = channel.getString("name")
            require(name == "PPG") { "model_acquisition_channel_set_unsupported" }
            require(channel.getString("unit") == "adc_count") { "acquisition_units_unsupported" }
            require(finite(channel, "wavelength_nm") in 300.0..1500.0) { "acquisition_wavelength_invalid" }
            val rate = finite(channel, "sample_rate_hz")
            require(rate in 10.0..2000.0) { "acquisition_sample_rate_invalid" }
            if (model.id == "wav2sleep-cardiorespiratory") require(rate <= 1024.0 / 30) { "downsampling_requires_frozen_antialias_adapter" }
            require(finite(channel, "clock_uncertainty_seconds") in 0.0..0.002 &&
                channel.getString("clock_id").isNotBlank() && channel.getString("acquisition_id").isNotBlank()) { "acquisition_clock_unverified" }
            val records = channel.getJSONArray("records")
            require(records.length() in 1..100_000) { "acquisition_records_invalid" }
            val values = JSONArray(); val observed = JSONArray(); val used = mutableSetOf<Pair<UUID, Long>>()
            // Archive/object IDs are storage identities, not physical sample identities. Replayed
            // packets (including conflicting bytes) must not turn into additional observed time.
            val physicalRecords = mutableMapOf<Pair<Long, Long>, String>()
            for (r in 0 until records.length()) {
                if (Thread.currentThread().isInterrupted) throw InterruptedException("model_assembly_cancelled")
                val mapping = records.getJSONObject(r)
                val id = UUID.fromString(mapping.getString("object_id"))
                val source = objects[id] ?: error("acquisition_raw_object_missing")
                require(id in attestedObjects) { "acquisition_capture_attestation_missing" }
                require(source.manifest.userId == request.userId && source.manifest.canonicalDeviceId == request.deviceId &&
                    source.digest == source.manifest.sha256 && source.digest == mapping.getString("object_sha256") &&
                    source.decoderVersion == contract.getString("decoder_version")) { "acquisition_raw_identity_mismatch" }
                require(source.kind == "ppg_i16_unqualified") { "acquisition_raw_kind_mismatch" }
                val rowId = mapping.getLong("row_id")
                require(used.add(id to rowId)) { "acquisition_duplicate_record" }
                val record = recordsByObject[id]?.get(rowId) ?: error("acquisition_record_missing")
                require(record.recordIndex != null && record.recordIndex == mapping.getLong("record_index") &&
                    record.timestamp == mapping.getLong("sensor_second")) { "acquisition_record_identity_mismatch" }
                val sampleStart = finite(mapping, "start_s")
                require(sampleStart >= source.manifest.start && sampleStart < source.manifest.end) { "acquisition_mapping_outside_object" }
                val offset = mapping.getInt("offset"); val stride = mapping.getInt("stride"); val count = mapping.getInt("count")
                require(offset >= 0 && stride in 1..8 && count in 1..100_000 &&
                    offset.toLong() + (count - 1L) * stride < record.columns.size) {
                    "acquisition_sample_shape_invalid"
                }
                val mask = mapping.getJSONArray("observed")
                require(mask.length() == count) { "acquisition_mask_shape_invalid" }
                val fingerprint = inputHash(JSONObject().put("start",sampleStart).put("offset",offset)
                    .put("stride",stride).put("count",count).put("observed",mask).put("columns",JSONArray(record.columns)))
                val prior = physicalRecords.putIfAbsent(record.recordIndex!! to record.timestamp,fingerprint)
                if (prior != null) {
                    require(adapterVersion == DEDUPLICATING_VERSION && prior == fingerprint) { "acquisition_replayed_physical_record" }
                    continue
                }
                require(values.length() + count <= MAX_SAMPLES) { "acquisition_sample_shape_invalid" }
                require(abs(sampleStart - (start + values.length() / rate)) <= 0.000001) { "acquisition_gap_or_overlap" }
                for (sample in 0 until count) {
                    require(mask.get(sample) is Boolean) { "acquisition_mask_invalid" }
                    values.put(record.columns[offset + sample * stride]); observed.put(mask.getBoolean(sample))
                }
            }
            // The final sample brackets the model's final target; no extrapolated tail is manufactured.
            require(values.length() >= 2 && abs(start + (values.length() - 1) / rate - end) <= 0.000001) {
                "acquisition_end_coverage_mismatch"
            }
            output.put(JSONObject().put("name", name).put("unit", "adc_count").put("sample_rate_hz", rate)
                .put("start", start).put("values", values).put("observed", observed)
                .put("timing_verified", true).put("semantics_verified", true)
                .put("clock_id", channel.getString("clock_id")).put("acquisition_id", channel.getString("acquisition_id"))
                .put("wavelength_nm", channel.getDouble("wavelength_nm")))
        }
        val payload = JSONObject().put("user_id", request.userId.toString()).put("device_id", request.deviceId.toString())
            .put("input_revision", request.inputRevision).put("mode", "retrospective").put("signals", output)
            .put("input_hash_encoding", "typed-json-sha256-1").put("acquisition_contract_sha256", digest)
            .put("acquisition_adapter_version", adapterVersion).put("checkpoint_sha256", checkpoint ?: JSONObject.NULL)
            .put("preprocess_version", model.activation.getString("preprocess_version"))
            .put("quality_policy_version", model.activation.getString("quality_policy_version"))
        if (model.id == "wav2sleep-cardiorespiratory") {
            require((end - start) % 30 == 0.0) { "model_epoch_alignment_invalid" }
            payload.put("epochs", ((end - start) / 30).toInt())
        }
        payload.put("input_hash", inputHash(payload))
        require(payload.toString().toByteArray(Charsets.UTF_8).size <= 15 * 1024 * 1024) { "model_input_size_limit" }
        return PhysiologyShadowRunner.PreparedJob(payload)
    }

    companion object {
        const val VERSION = "verified-npb1-extraction-1"
        const val DEDUPLICATING_VERSION = "verified-npb1-extraction-2"
        const val MAX_SAMPLES = 1_300_000
        private fun hash(value: String) = value.matches(Regex("[0-9a-f]{64}"))
        private fun finite(value: JSONObject, key: String) = value.getDouble(key).also { require(it.isFinite()) { "acquisition_nonfinite" } }
        private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

        /** Matches physiology_inference.contracts.typed_hash without JSON float-printer differences. */
        fun inputHash(value: JSONObject): String {
            val digest = MessageDigest.getInstance("SHA-256")
            fun bytes(text: String) { digest.update(text.toByteArray(Charsets.UTF_8)) }
            fun visit(item: Any?) {
                when (item) {
                    null, JSONObject.NULL -> bytes("n")
                    is Boolean -> bytes(if (item) "t" else "f")
                    is Number -> {
                        val number = item.toDouble()
                        require(number.isFinite() && (item !is Long || item in -9007199254740992L..9007199254740992L))
                        bytes("d"); digest.update(ByteBuffer.allocate(8).putDouble(number).array())
                    }
                    is String -> { val data = item.toByteArray(Charsets.UTF_8); bytes("s${data.size}:"); digest.update(data) }
                    is JSONArray -> { bytes("["); for (i in 0 until item.length()) visit(item.get(i)); bytes("]") }
                    is JSONObject -> {
                        bytes("{")
                        for (key in item.keySet().sorted()) {
                            require(key.all { it.code < 128 }); visit(key); visit(item.get(key))
                        }
                        bytes("}")
                    }
                    else -> error("input_hash_type_invalid")
                }
            }
            visit(value)
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
    }
}
