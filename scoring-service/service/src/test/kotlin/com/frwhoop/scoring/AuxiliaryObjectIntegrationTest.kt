package com.frwhoop.scoring

import com.frwhoop.scoring.b2.B2ObjectStore
import com.frwhoop.scoring.db.AuxiliaryObjectReader
import com.noop.data.V18AuxRow
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.util.UUID

class AuxiliaryObjectIntegrationTest : PgIntegrationBase() {
    private val lo=Instant.parse("2026-09-15T00:00:00Z").epochSecond
    private val objects=mutableMapOf<String,ByteArray>()
    private val requested=mutableListOf<String>()
    private val reader get()=AuxiliaryObjectReader(B2ObjectStore.ReadClient { bucket,key,max ->
        assertEquals("fixture-bucket",bucket); requested+=key
        objects.getValue(key).also { assertTrue(it.size<=max) }
    })
    private fun archive(value:Long,at:Long=lo,source:UUID=device,index:Long?=null,format:Int=1,bytes:ByteArray?=null):String {
        val id=UUID.randomUUID()
        val packed=bytes ?: AuxiliaryObjectReaderTest.pack(listOf(V18AuxRow(ts=at,recordIndex=index,auxByte82=value)),format)
        val wire=AuxiliaryObjectReaderTest.gzip(packed)
        val prefix="v3/diag/users/$u/devices/$source/v18AuxSample/2026/09/15/00"
        val key="$prefix/verified/$id/${UUID.randomUUID()}/$id.bin.gz"
        val manifest=JSONObject().put("id",id).put("user_id",u).put("device_id",source)
            .put("object_class","raw").put("object_kind","v18AuxSample").put("provider","b2").put("bucket","fixture-bucket")
            .put("object_key","$prefix/$id.bin.gz").put("start_at",Instant.ofEpochSecond(at)).put("end_at",Instant.ofEpochSecond(at+1))
            .put("period_day",day).put("sample_count",1).put("compressed_bytes",wire.size).put("uncompressed_bytes",packed.size)
            .put("format","bin_gzip_noop_push_v1").put("compression","gzip").put("schema_version",format)
            .put("push_protocol_version",if(format==2) "1.4" else "1.3").put("sha256",B2ObjectStore.sha256Hex(packed)).put("digest_scope","decoded")
            .put("retention_class","diag").put("source_id",UUID.randomUUID()).put("batch_id",UUID.randomUUID())
        pg.connection().use { c ->
            c.prepareStatement("select noop_reserve_object_manifest(?::jsonb)").use { s -> s.setString(1,manifest.toString());s.execute() }
            c.prepareStatement("select noop_commit_object_receipt(?,?,?,?,?,?,?)").use { s ->
                s.setObject(1,u);s.setObject(2,id);s.setString(3,key);s.setString(4,B2ObjectStore.sha256Hex(wire))
                s.setString(5,B2ObjectStore.sha256Hex(packed));s.setLong(6,wire.size.toLong());s.setLong(7,packed.size.toLong());s.execute()
            }
        }
        objects[key]=wire
        return key
    }

    @Test fun verifiedOwnerSourceWindowPreservesIndexSiblingsAndDeduplicatesExactObjects() {
        val first=archive(90,index=0,format=2); val sibling=archive(95,index=0xffff_ffffL,format=2)
        val duplicate=archive(90,index=0,format=2)
        archive(70,source=device2); archive(80,at=lo+86400)
        val result=pg.connection().use { reader.load(it,u,device,lo,lo+3600) }
        assertEquals(listOf(V18AuxRow(lo,recordIndex=0,auxByte82=90),V18AuxRow(lo,recordIndex=0xffff_ffffL,auxByte82=95)),result.rows)
        assertEquals(listOf(first,sibling,duplicate),requested)
        assertTrue(result.gaps.isEmpty())
        assertTrue(pg.connection().use { reader.load(it,other,device,lo,lo+3600) }.rows.isEmpty())
        assertEquals(3,requested.size)
    }

    @Test fun unknownAndZeroAreDistinctButConflictingPayloadForOneIdentityFailsExplicitly() {
        val unknown=archive(90);archive(95,index=0,format=2)
        val result=pg.connection().use { reader.load(it,u,device,lo,lo+3600) }
        assertEquals(listOf(null,0L),result.rows.map { it.recordIndex })
        assertEquals(setOf("candidate_record_identity_unknown"),result.gaps)
        val preserved=objects.getValue(unknown).clone()
        archive(99)
        val error=assertThrows(IllegalStateException::class.java) { pg.connection().use { reader.load(it,u,device,lo,lo+3600) } }
        assertEquals("candidate_identity_conflict",error.message)
        assertArrayEquals(preserved,objects.getValue(unknown))
        assertEquals("3",scalar("select count(*) from object_manifests where sha256_source='server_verified'"))
    }

    @Test fun unsupportedStoredBlobRemainsArchivedAndYieldsTypedValidationDebtNotInventedIdentity() {
        val blob=AuxiliaryObjectReaderTest.pack(listOf(V18AuxRow(lo,recordIndex=0,auxByte82=95)),2)
        blob[39]=99 // The NPB1 layout is valid; only its independent fields schema is unknown.
        val key=archive(95,index=0,format=2,bytes=blob)
        val result=pg.connection().use { reader.load(it,u,device,lo,lo+3600) }
        assertTrue(result.rows.isEmpty())
        assertEquals(setOf("candidate_aux_schema_unsupported"),result.gaps)
        assertTrue(objects.containsKey(key))
        assertEquals("verified_indexed",scalar("select durability_receipt->>'state' from object_manifests"))
    }

    @Test fun storedDigestMismatchFailsWorkInsteadOfPublishingFabricatedEmptyCandidate() {
        val key=archive(95)
        objects[key]=objects.getValue(key).copyOf().also { it[0]=(it[0].toInt() xor 1).toByte() }
        val error=assertThrows(IllegalStateException::class.java) { pg.connection().use { reader.load(it,u,device,lo,lo+3600) } }
        assertEquals("candidate_wire_digest_mismatch",error.message)
    }

    @Test fun unverifiedIndexedLegacyObjectIsAnExplicitGapAndNeverFetched() {
        val key=archive(95)
        sql("update object_manifests set sha256_source='client_claimed',durability_receipt=null,indexed_at=null where object_key='$key'")
        val result=pg.connection().use { reader.load(it,u,device,lo,lo+3600) }
        assertTrue(result.rows.isEmpty()); assertEquals(setOf("candidate_archive_pending_verification"),result.gaps)
        assertTrue(requested.isEmpty())
    }
}
