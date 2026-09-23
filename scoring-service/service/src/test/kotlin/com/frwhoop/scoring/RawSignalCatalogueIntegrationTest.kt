package com.frwhoop.scoring

import com.frwhoop.scoring.b2.B2ObjectStore
import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.signals.PhysiologyShadowRunner
import org.json.JSONObject
import java.nio.file.Path
import com.frwhoop.scoring.signals.RawSignalCatalogue
import com.frwhoop.scoring.signals.VerifiedRawObjectReader
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.time.Instant
import java.util.UUID
import java.util.zip.GZIPOutputStream

class RawSignalCatalogueIntegrationTest {
    private lateinit var db: PostgresClient
    private val user = UUID.randomUUID()
    private val device = UUID.randomUUID()
    private val objectId = UUID.randomUUID()
    private val start = Instant.parse("2026-08-01T12:00:00Z").epochSecond
    private val key = "v3/ppg/users/$user/devices/$device/ppgWaveformSample/2026/08/01/12/$objectId.bin.gz"
    private val raw = ByteBuffer.allocate(45).order(ByteOrder.LITTLE_ENDIAN).apply {
        put("NPB1".toByteArray()); put(2); put(1); putInt(1)
        putLong(1); putLong(start); put(0); putLong(7)
        putInt(6); putShort((-32768).toShort()); putShort(0); putShort(32767)
    }.array()
    private val encoded = ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(raw) } }.toByteArray()

    @Before fun setup() {
        val url = System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run scripts/test-physiology-queue.sh", url != null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db = PostgresClient(url)
        resetFleetTestState(db)
        sql("insert into auth.users(id) values('$user')")
        sql("insert into profiles(id,timezone) values('$user','UTC') on conflict(id) do update set timezone='UTC'")
        sql("insert into devices(id,user_id,source_kind) values('$device','$user','whoop')")
        sql("insert into object_manifests(id,user_id,device_id,object_key,status,sha256_source,sha256,compression,format," +
            "object_class,object_kind,compressed_bytes,uncompressed_bytes,sample_count) values('$objectId','$user','$device','$key'," +
            "'ready','client_claimed','${B2ObjectStore.sha256Hex(raw)}','gzip','bin_gzip_noop_push_v1','raw','noop_ppg',${encoded.size},${raw.size},1)")
        sql("insert into noop_signal_windows(user_id,device_id,stream,hour_start,object_id,object_key,start_ts,end_ts) " +
            "values('$user','$device','ppg',$start,'$objectId','$key',$start,${start + 1})")
    }
    @After fun close() { if (::db.isInitialized) db.close() }

    @Test fun confirmedAliasReadsOriginalObjectsAndFencesCanonicalCorrectionsWithoutRewritingKeys() {
        val source=UUID.randomUUID(); val code=UUID.randomUUID(); val canonical=UUID.randomUUID()
        sql("insert into noop_enrollment_codes(id,user_id,code_hash,expires_at) values('$code','$user',repeat('a',64),now()+interval '1 day')")
        sql("insert into noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version) values('$source','$user','$code','ios','fixture')")
        sql("update devices set external_device_id='installation:$source:local-band' where id='$device'")
        sql("insert into devices(id,user_id,source_kind,external_device_id) values('$canonical','$user','whoop','whoop-SYNTH001')")
        sql("update object_manifests set source_id='$source' where id='$objectId'")
        db.withConnection { c ->
            c.autoCommit=false
            try {
                c.createStatement().use { s ->
                    s.execute("set local request.jwt.claim.role='service_role'")
                    s.execute("select confirm_noop_wearable('$user','$source','$device','$canonical',"+
                        "'{\"method\":\"device_information_serial_v1\",\"serial\":\"SYNTH001\",\"receiptSha256\":\"${"a".repeat(64)}\"}')")
                }; c.commit()
            } finally { c.rollback() }
        }
        val catalogue=catalogue { encoded }
        val manifest=catalogue.discover(user,canonical,start,start+60).single()
        assertEquals(device,manifest.deviceId);assertEquals(canonical,manifest.canonicalDeviceId)
        assertEquals(key,manifest.key)
        assertTrue(catalogue.discover(UUID.randomUUID(),canonical,start,start+60).isEmpty())
        catalogue.verify(manifest)
        val before=number("select input_revision from physiology_work_items where user_id='$user' and device_id='$canonical' and day='2026-08-01'")
        sql("delete from noop_signal_windows where object_id='$objectId'")
        assertTrue(number("select input_revision from physiology_work_items where user_id='$user' and device_id='$canonical' and day='2026-08-01'")>before)
        assertEquals(device.toString(),string("select device_id from object_manifests where id='$objectId'"))
    }

    @Test fun repeatedActualHashAndDecodeDoesNotContinuouslyRedirtyTheQueue() {
        var fetches = 0
        val catalogue = catalogue { fetches++; encoded }
        assertEquals(0L, number("select count(*) from physiology_work_items where user_id='$user'"))
        val first = catalogue.discover(user, device, start, start + 60).single()
        val decoded = catalogue.verify(first)
        assertEquals(listOf(-32768, 0, 32767), decoded.records.single().columns)
        assertFalse(decoded.channelSemanticsVerified)
        assertEquals(2L, number("select count(*) from physiology_work_items where user_id='$user'"))
        val revisions = string("select jsonb_object_agg(day,input_revision)::text from physiology_work_items where user_id='$user'")
        val timestamps = string("select jsonb_build_array(verified_at,decode_verified_at)::text from object_manifests where id='$objectId'")
        val second = catalogue.discover(user, device, start, start + 60).single()
        assertEquals(decoded.digest, catalogue.verify(second).digest)
        assertEquals(2, fetches)
        assertEquals(revisions, string("select jsonb_object_agg(day,input_revision)::text from physiology_work_items where user_id='$user'"))
        assertEquals(timestamps, string("select jsonb_build_array(verified_at,decode_verified_at)::text from object_manifests where id='$objectId'"))
        assertEquals(VerifiedRawObjectReader.VERSION, string("select decoder_version from object_manifests where id='$objectId'"))
    }

    @Test fun changedManifestAndCorruptBytesCannotAcquireVerificationProof() {
        val valid = catalogue { encoded }
        val manifest = valid.discover(user, device, start, start + 60).single()
        sql("update object_manifests set sha256=repeat('a',64) where id='$objectId'")
        try { valid.verify(manifest); fail("changed manifest must not be verified") }
        catch (failure: IllegalStateException) { assertEquals("raw_manifest_changed_during_read", failure.message) }
        val current = valid.discover(user, device, start, start + 60).single()
        try { valid.verify(current); fail("digest mismatch must not be verified") }
        catch (failure: IllegalArgumentException) { assertEquals("raw_digest_mismatch", failure.message) }
        assertEquals("client_claimed", string("select sha256_source from object_manifests where id='$objectId'"))
        assertEquals(0L, number("select count(*) from object_manifests where id='$objectId' and decode_verified_at is not null"))
        assertEquals(0L, number("select count(*) from physiology_work_items where user_id='$user'"))
    }

    @Test fun decodingContractChangedDuringFetchCannotAcquireVerificationProof() {
        for ((column, changed, restored) in listOf(Triple("compression", "'zstd'", "'gzip'"),
                Triple("format", "'unsupported_format'", "'bin_gzip_noop_push_v1'"), Triple("sample_count", "2", "1"))) {
            val catalogue = catalogue {
                sql("update object_manifests set $column=$changed where id='$objectId'")
                encoded
            }
            val manifest = catalogue.discover(user, device, start, start + 60).single()
            try { catalogue.verify(manifest); fail("$column changed while decoding old bytes") }
            catch (failure: IllegalStateException) { assertEquals("raw_manifest_changed_during_read", failure.message) }
            assertEquals(0L, number("select count(*) from object_manifests where id='$objectId' and decode_verified_at is not null"))
            sql("update object_manifests set $column=$restored where id='$objectId'")
        }
        assertEquals(0L, number("select count(*) from physiology_work_items where user_id='$user'"))
    }

    @Test fun decodingContractChangesRevokeOldProofAndDirtyItsConsumers() {
        val catalogue = catalogue { encoded }
        for ((column, changed, restored) in listOf(Triple("compression", "'zstd'", "'gzip'"),
                Triple("format", "'unsupported_format'", "'bin_gzip_noop_push_v1'"), Triple("sample_count", "2", "1"))) {
            catalogue.verify(catalogue.discover(user, device, start, start + 60).single())
            val revision = number("select input_revision from physiology_work_items where user_id='$user' and day='2026-08-01'")
            sql("update object_manifests set $column=$changed where id='$objectId'")
            assertEquals("client_claimed", string("select sha256_source from object_manifests where id='$objectId'"))
            assertEquals(0L, number("select count(*) from object_manifests where id='$objectId' and " +
                "(verified_at is not null or decode_verified_at is not null or decoder_version is not null)"))
            assertEquals(revision + 1, number("select input_revision from physiology_work_items where user_id='$user' and day='2026-08-01'"))
            sql("update object_manifests set $column=$restored where id='$objectId'")
        }
    }

    @Test fun plannedDiscoveryReadsEveryPageWithEqualTimestampsAndFailsClosedOnMissingObject() {
        val all = addObjects(257) + objectId
        var reads = 0
        val catalogue = RawSignalCatalogue(db.dataSource, VerifiedRawObjectReader(object : B2ObjectStore.GetClient {
            override fun getObject(key: String, maximumBytes: Int): ByteArray { reads++; return encoded }
        }))
        assertEquals("raw_catalogue_budget_exceeded", assertThrows(IllegalArgumentException::class.java) {
            catalogue.discover(user, device, start, start + 60)
        }.message)
        val discovered = catalogue.discover(user, device, start, start + 60, all.toSet())
        assertEquals(all.toSet(), discovered.map { it.id }.toSet())
        assertEquals(258, discovered.size)
        assertEquals("Metadata discovery must not fetch objects while its transaction is open", 0, reads)
        assertEquals(listOf(objectId), catalogue.discover(user, device, start, start + 60, setOf(objectId)).map { it.id })
        sql("delete from noop_signal_windows where object_id='${all[128]}'")
        assertEquals("raw_required_objects_missing", assertThrows(IllegalArgumentException::class.java) {
            catalogue.discover(user, device, start, start + 60, all.toSet())
        }.message)
        assertEquals(0, reads)
    }

    @Test fun incompleteOrOverBudgetPlannedInputsNeverDownloadOrExecuteAPrefix() {
        val second = addObjects(1).single()
        var reads = 0; var executions = 0; var assemblies = 0
        val catalogue = RawSignalCatalogue(db.dataSource, VerifiedRawObjectReader(object : B2ObjectStore.GetClient {
            override fun getObject(key: String, maximumBytes: Int): ByteArray { reads++; return encoded }
        }))
        val model = PhysiologyShadowRunner.Model("neurokit2", JSONObject(), Path.of("."))
        fun run(required: Set<UUID>): JSONObject {
            val assembler = object : PhysiologyShadowRunner.JobAssembler {
                override fun prepare(model: PhysiologyShadowRunner.Model, request: PhysiologyShadowRunner.Request,
                                     raw: List<VerifiedRawObjectReader.Decoded>): PhysiologyShadowRunner.PreparedJob? = error("unplanned path")
                override fun plan(model: PhysiologyShadowRunner.Model, request: PhysiologyShadowRunner.Request) =
                    PhysiologyShadowRunner.RawInputPlan(required) { assemblies++; error("incomplete data must not assemble") }
            }
            return PhysiologyShadowRunner(catalogue, listOf(model),
                PhysiologyShadowRunner.Executor { _, _ -> executions++; error("incomplete data must not execute") }, assembler)
                .evaluateModel(PhysiologyShadowRunner.Request(user, device, "1", start, start + 60, emptyList()), model.id)
        }
        val missing = run(setOf(objectId, second, UUID.randomUUID()))
        assertEquals("required_verified_model_inputs_unavailable", missing.getString("reason"))
        sql("update object_manifests set uncompressed_bytes=${RawSignalCatalogue.MAX_ASSEMBLY_BYTES} where id='$second'")
        val budget = run(setOf(objectId, second))
        assertEquals("raw_input_budget_exceeded", budget.getString("reason"))
        assertEquals(0, reads); assertEquals(0, assemblies); assertEquals(0, executions)
    }

    private fun addObjects(count: Int): List<UUID> {
        val ids = List(count) { UUID.randomUUID() }
        val values = ids.joinToString(",") { id ->
            "('$id','$user','$device','v3/ppg/users/$user/devices/$device/$id','ready','client_claimed'," +
                "'${B2ObjectStore.sha256Hex(raw)}','gzip','bin_gzip_noop_push_v1','raw','noop_ppg',${encoded.size},${raw.size},1)"
        }
        sql("insert into object_manifests(id,user_id,device_id,object_key,status,sha256_source,sha256,compression,format," +
            "object_class,object_kind,compressed_bytes,uncompressed_bytes,sample_count) values $values")
        sql("insert into noop_signal_windows(user_id,device_id,stream,hour_start,object_id,object_key,start_ts,end_ts) " +
            "select user_id,device_id,'ppg',$start,id,object_key,$start,${start + 1} from object_manifests " +
            "where id in (${ids.joinToString(",") { "'$it'" }})")
        return ids
    }

    private fun catalogue(bytes: () -> ByteArray) = RawSignalCatalogue(db.dataSource,
        VerifiedRawObjectReader(object : B2ObjectStore.GetClient {
            override fun getObject(key: String, maximumBytes: Int): ByteArray {
                assertEquals(this@RawSignalCatalogueIntegrationTest.key, key)
                return bytes().also { assertTrue(it.size <= maximumBytes) }
            }
        }))
    private fun sql(value: String) = db.withConnection { c -> c.createStatement().use { it.execute(value) }; Unit }
    private fun string(value: String) = db.withConnection { c -> c.createStatement().use { statement ->
        statement.executeQuery(value).use { rows -> check(rows.next()); rows.getString(1) }
    } }
    private fun number(value: String) = string(value).toLong()
}
