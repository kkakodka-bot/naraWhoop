package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.scoring.CanonicalScorePayload
import org.json.JSONObject
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Disposable reference evidence only: never an accuracy result or a deployable approval. */
internal object SignedPromotionFixtures {
    data class Approval(val payload: JSONObject, val signature: String, val keyId: String)
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

    fun prepare(db: PostgresClient, feature: String, version: String = "frwhoop-physiology-2",
                change: (JSONObject) -> Unit = {}): Approval = db.withConnection { c ->
        val secret = ByteArray(32).also(java.security.SecureRandom()::nextBytes)
        val key = hex(MessageDigest.getInstance("SHA-256").digest(secret))
        c.prepareStatement("insert into internal.physiology_approval_keys values (?,?,'disposable-test',null)").use {
            it.setString(1,key); it.setBytes(2,secret); it.executeUpdate()
        }
        val algorithmHash = c.prepareStatement("select manifest_hash from physiology_algorithm_versions where algorithm_version=?").use {
            it.setString(1,version); it.executeQuery().use { r -> check(r.next()); r.getString(1) }
        }
        val manifest = JSONObject().put("algorithm_version",version).put("feature",feature)
            .put("checkpoint_sha256","c".repeat(64)).put("preprocessing_version","disposable-preprocess-1")
            .put("preprocessing_sha256","d".repeat(64)).put("quality_policy_version","disposable-quality-1")
            .put("quality_policy_sha256","e".repeat(64))
        c.prepareStatement("""insert into physiology_feature_manifests
            (algorithm_version,feature,manifest,canonical_manifest,manifest_sha256,algorithm_manifest_sha256,checkpoint_sha256,
             preprocessing_version,preprocessing_sha256,quality_policy_version,quality_policy_sha256)
            select ?,?,?::jsonb,?,encode(sha256(convert_to(?,'UTF8')),'hex'),?,
              repeat('c',64),'disposable-preprocess-1',repeat('d',64),'disposable-quality-1',repeat('e',64)
            on conflict do nothing""").use {
            it.setString(1,version); it.setString(2,feature); it.setString(3,manifest.toString())
            it.setString(4,CanonicalScorePayload.encode(manifest)); it.setString(5,CanonicalScorePayload.encode(manifest))
            it.setString(6,algorithmHash); it.executeUpdate()
        }
        val manifestHash = c.prepareStatement("select manifest_sha256 from physiology_feature_manifests where algorithm_version=? and feature=?").use {
            it.setString(1,version); it.setString(2,feature); it.executeQuery().use { r -> check(r.next()); r.getString(1) }
        }
        val p = JSONObject(manifest.toString()).put("schema_version",1).put("purpose","physiology_feature_promotion")
            .put("approval_id",UUID.randomUUID().toString()).put("key_id",key).put("reviewer","disposable-test")
            .put("decision","approved").put("manifest_sha256",manifestHash).put("algorithm_manifest_sha256",algorithmHash)
            .put("evaluation_sha256","b".repeat(64)).put("policy_sha256","a".repeat(64))
            .put("reference_artifact_sha256","f".repeat(64)).put("reference_kind",when(feature) {
                "hrv" -> "synchronized_ecg_nn"; "sleep" -> "psg_30s_and_sleep_opportunities"
                else -> "synchronized_respiratory_reference" })
            .put("evaluation_partition","test").put("participant_disjoint",true)
            .put("functional_gates_passed",true).put("promotion_policy_passed",true)
            .put("policy_frozen_at","2020-01-01T00:00:00Z").put("evaluation_started_at","2020-01-02T00:00:00Z")
            .put("evaluation_finished_at","2020-01-03T00:00:00Z").put("approved_at",Instant.now().minusSeconds(1).toString())
        change(p)
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(secret,"HmacSHA256")) }
        Approval(p,hex(mac.doFinal(p.toString().toByteArray(Charsets.UTF_8))),key)
    }

    fun register(db: PostgresClient, approval: Approval) = db.withConnection { c ->
        c.createStatement().use { it.execute("select set_config('request.jwt.claim.role','service_role',false)") }
        try { c.prepareStatement("select register_physiology_promotion(?,?)").use {
            it.setString(1,approval.payload.toString()); it.setString(2,approval.signature); it.execute()
        } } finally { c.createStatement().use { it.execute("select set_config('request.jwt.claim.role','',false)") } }
    }
    fun qualify(db: PostgresClient, feature: String) = db.withConnection { c ->
        c.prepareStatement("""update physiology_feature_qualifications set qualification='reference_qualified',
            policy_sha256=repeat('a',64),evaluation_sha256=repeat('b',64),
            signed_policy=jsonb_build_object('payload',jsonb_build_object('metric_family',feature),'signature',jsonb_build_object('algorithm','HMAC-SHA256')),
            signed_evaluation=jsonb_build_object('payload',jsonb_build_object('policy_sha256',repeat('a',64)),'signature',jsonb_build_object('algorithm','HMAC-SHA256')),
            reviewed_by='disposable-test',reviewed_at=now() where algorithm_version='frwhoop-physiology-2' and feature=?""").use {
            it.setString(1,feature); it.executeUpdate()
        }
    }
    fun reset(db: PostgresClient) = db.withConnection { c -> c.createStatement().use {
        it.execute("insert into physiology_promotion_revocations(approval_id,reason) select approval_id,'test teardown' from physiology_promotion_approvals on conflict do nothing")
        it.execute("update physiology_feature_qualifications set qualification='shadow',policy_sha256=null,evaluation_sha256=null,signed_policy=null,signed_evaluation=null,reviewed_by=null,reviewed_at=null where algorithm_version='frwhoop-physiology-2'")
    } }
    fun hashes(db: PostgresClient): JSONObject = db.withConnection { c ->
        val value=JSONObject()
        c.createStatement().use { s -> s.executeQuery("select feature,manifest_sha256 from physiology_feature_manifests where algorithm_version='frwhoop-physiology-2'").use {
            while(it.next()) value.put(it.getString(1),it.getString(2))
        } }
        value
    }
}
