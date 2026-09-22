package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.sql.SQLException

class PhysiologyPromotionIntegrationTest {
    private lateinit var db: PostgresClient
    @Before fun setup() {
        val url=System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run scripts/test-physiology-queue.sh",url!=null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db=PostgresClient(url); SignedPromotionFixtures.reset(db)
        resetFleetTestState(db)
    }
    @After fun close() { if(::db.isInitialized) { SignedPromotionFixtures.reset(db); db.close() } }
    private fun sql(value:String)=db.withConnection { c -> c.createStatement().use { it.execute(value) } }
    private fun canonical(feature:String,version:String="frwhoop-physiology-2")=db.withConnection { c ->
        c.createStatement().use { s -> s.executeQuery("select physiology_feature_is_canonical('$version','$feature')").use {
            it.next(); it.getBoolean(1) } }
    }
    private fun denied(code:String="22023", action:()->Unit) {
        try { action(); fail("Expected rejection") } catch(e:SQLException) { assertEquals(code,e.sqlState) }
    }
    @Test fun defaultsAreLegacyAndQualificationRowsCannotBypassSignature() {
        for(feature in listOf("hrv","sleep","respiration")) {
            assertTrue(canonical(feature,"frwhoop-server-1")); assertFalse(canonical(feature))
            SignedPromotionFixtures.qualify(db,feature); assertFalse(canonical(feature))
            denied { sql("update physiology_feature_defaults set algorithm_version='frwhoop-physiology-2' where feature='$feature'") }
        }
    }
    @Test fun missingEvidenceAndTamperedSignaturesFailClosed() {
        val missing=SignedPromotionFixtures.prepare(db,"hrv") { it.remove("checkpoint_sha256") }
        denied { SignedPromotionFixtures.register(db,missing) }
        val tampered=SignedPromotionFixtures.prepare(db,"hrv")
        tampered.payload.put("feature","sleep")
        denied { SignedPromotionFixtures.register(db,tampered) }
    }
    @Test fun referenceKindParticipantLeakageAndUnfrozenPolicyAreRejected() {
        for(change in listOf<(org.json.JSONObject)->Unit>(
            { it.put("reference_kind","vendor_agreement") },
            { it.put("participant_disjoint",false) },
            { it.put("policy_frozen_at","2020-01-04T00:00:00Z") },
            { it.put("quality_policy_sha256","0".repeat(64)) },
            { it.put("approved_at","2099-01-01T00:00:00Z") })) {
            denied { SignedPromotionFixtures.register(db,SignedPromotionFixtures.prepare(db,"hrv",change=change)) }
        }
    }
    @Test fun independentFeaturePromotionRevocationAndRollbackDoNotRelabelResults() {
        val approval=SignedPromotionFixtures.prepare(db,"hrv")
        SignedPromotionFixtures.register(db,approval); SignedPromotionFixtures.qualify(db,"hrv")
        assertTrue(canonical("hrv")); assertFalse(canonical("sleep")); assertFalse(canonical("respiration"))
        sql("update physiology_feature_defaults set algorithm_version='frwhoop-physiology-2' where feature='hrv'")
        try {
            sql("insert into physiology_promotion_revocations(approval_id,reason) values ('${approval.payload.getString("approval_id")}','rollback')")
            assertFalse(canonical("hrv"))
        } finally { sql("update physiology_feature_defaults set algorithm_version='frwhoop-server-1' where feature='hrv'") }
        assertTrue(canonical("hrv","frwhoop-server-1"))
    }
    @Test fun revokedKeyAndImmutableManifestPreventReuse() {
        val approval=SignedPromotionFixtures.prepare(db,"sleep")
        SignedPromotionFixtures.register(db,approval); SignedPromotionFixtures.qualify(db,"sleep")
        assertTrue(canonical("sleep"))
        denied { sql("update physiology_feature_manifests set checkpoint_sha256=repeat('0',64) where algorithm_version='frwhoop-physiology-2' and feature='sleep'") }
        denied { sql("update physiology_algorithm_versions set manifest_hash=repeat('0',64) where algorithm_version='frwhoop-physiology-2'") }
        sql("update internal.physiology_approval_keys set revoked_at=now() where key_id='${approval.keyId}'")
        assertFalse(canonical("sleep"))
    }
    @Test fun applicationCannotReadOrProvisionSigningSecrets() {
        db.withConnection { c -> c.createStatement().use { s ->
            s.execute("set role service_role")
            try { denied("42501") { s.executeQuery("select * from internal.physiology_approval_keys") } }
            finally { s.execute("reset role") }
        } }
    }
}
