package com.frwhoop.scoring.db

import com.frwhoop.scoring.b2.B2ObjectStore
import com.github.luben.zstd.ZstdInputStream
import com.noop.data.V18AuxCodec
import com.noop.data.V18AuxRow
import com.noop.data.V18AuxSlot
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.sql.Connection
import java.util.UUID
import java.util.zip.GZIPInputStream

/** Reads only indexed immutable owner/device objects; hashes the bytes again before using a candidate. */
class AuxiliaryObjectReader(private val objects: B2ObjectStore.ReadClient?) {
    data class Result(val rows: List<V18AuxRow>, val gaps: Set<String>)
    private data class Identity(val ts:Long,val recordIndex:Long?)
    private data class Record(val rowId:Long,val row:V18AuxRow?,val fieldsDigest:String,val gap:String?)

    fun load(c: Connection, owner: UUID, device: UUID, lo: Long, hi: Long): Result {
        val manifests = c.prepareStatement("""
            select to_jsonb(m)::text from object_manifests m
            where m.user_id=? and m.device_id=? and m.object_kind='v18AuxSample' and m.object_class='raw'
              and exists(select 1 from noop_signal_windows w where w.object_id=m.id and w.object_key=m.object_key
                and w.user_id=m.user_id and w.device_id=m.device_id and w.stream='v18AuxSample'
                and w.start_ts<=? and w.end_ts>?)
            order by m.created_at,m.id limit 513
        """.trimIndent()).use { s ->
            s.setObject(1,owner); s.setObject(2,device); s.setLong(3,hi); s.setLong(4,lo)
            s.executeQuery().use { r -> buildList { while(r.next()) add(JSONObject(r.getString(1))) } }
        }
        check(manifests.size<=512) { "candidate_object_count_limit" }
        val rows = mutableMapOf<Identity,Record>(); val gaps = linkedSetOf<String>()
        var decodedBytes = 0L
        for(m in manifests) {
            val receipt = m.optJSONObject("durability_receipt")
            if(m.optString("sha256_source")!="server_verified" || m.isNull("indexed_at") ||
                receipt?.optString("state")!="verified_indexed" || m.optString("status") !in setOf("ready","verified")) {
                gaps+="candidate_archive_pending_verification"; continue
            }
            check(receipt.getString("ownerUserId")==owner.toString() && receipt.getString("deviceId")==device.toString() &&
                receipt.getString("objectId")==m.getString("id") && receipt.getString("objectKey")==m.getString("object_key") &&
                receipt.getString("stream")=="v18AuxSample") { "candidate_receipt_identity_mismatch" }
            check(m.getString("provider")=="b2" && m.getString("object_key").startsWith("v3/diag/users/$owner/devices/$device/v18AuxSample/") &&
                m.getString("object_key").contains("/verified/${m.getString("id")}/")) { "candidate_object_key_scope" }
            val compressed = receipt.getInt("compressedBytes"); val decoded = receipt.getInt("uncompressedBytes")
            check(compressed in 1..MAX_WIRE && decoded in 1..MAX_DECODED &&
                compressed.toLong()==m.getLong("compressed_bytes") && decoded.toLong()==m.getLong("uncompressed_bytes")) { "candidate_object_size_limit" }
            decodedBytes+=decoded
            check(decodedBytes<=256L*1024*1024) { "candidate_window_size_limit" }
            val wire = checkNotNull(objects) { "candidate_object_reader_unconfigured" }
                .readObject(m.getString("bucket"),m.getString("object_key"),compressed)
            check(wire.size==compressed && B2ObjectStore.sha256Hex(wire)==receipt.getString("wireSha256")) { "candidate_wire_digest_mismatch" }
            val unpacked=decode(wire,m.getString("format"),decoded)
            check(B2ObjectStore.sha256Hex(unpacked)==receipt.getString("contentSha256")) { "candidate_content_digest_mismatch" }
            val parsed=parseRecords(unpacked)
            check(parsed.size.toLong()==m.getLong("sample_count")) { "candidate_record_count_mismatch" }
            for(record in parsed) {
                record.gap?.let { gaps+=it }
                val row=record.row ?: continue
                if(row.ts !in lo..hi) continue
                if(row.recordIndex==null) gaps+="candidate_record_identity_unknown"
                val identity=Identity(row.ts,row.recordIndex)
                val previous=rows[identity]
                check(previous==null || previous.fieldsDigest==record.fieldsDigest) { "candidate_identity_conflict" }
                if(previous==null) rows[identity]=record
            }
        }
        return Result(rows.values.map { requireNotNull(it.row) }.sortedWith(compareBy({it.ts},{it.recordIndex ?: -1L})),gaps)
    }

    companion object {
        private const val MAX_WIRE=64*1024*1024
        private const val MAX_DECODED=128*1024*1024

        internal fun decode(wire:ByteArray,format:String,expectedSize:Int):ByteArray {
            require(expectedSize in 1..MAX_DECODED)
            val raw=ByteArrayInputStream(wire)
            val stream=when(format) {
                "bin_gzip_noop_push_v1" -> GZIPInputStream(raw)
                "protobuf_zstd_noop_push_v1", "bin_zstd_noop_push_v1" -> ZstdInputStream(raw).setLongMax(27)
                else -> error("candidate_object_format_unsupported")
            }
            return stream.use {
                val bytes=it.readNBytes(expectedSize+1)
                check(bytes.size==expectedSize) { "candidate_decoded_size_mismatch" }; bytes
            }
        }

        internal fun parse(bytes:ByteArray):List<V18AuxRow> {
            return parseRecords(bytes).map { requireNotNull(it.row) { it.gap ?: "candidate_aux_invalid" } }
        }

        private fun parseRecords(bytes:ByteArray):List<Record> {
            val b=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            require(b.remaining()>=10 && b.int==0x3142504e) { "candidate_binary_header" }
            val format=b.get().toInt()
            require(format in 1..2 && b.get().toInt()==2) { "candidate_binary_header" }
            val count=b.int
            val minimum=if(format==1) 20 else 21
            require(count in 0..1_000_000 && count.toLong()*minimum<=b.remaining()) { "candidate_binary_count" }
            val rows=ArrayList<Record>(count)
            repeat(count) {
                require(b.remaining()>=minimum) { "candidate_binary_truncated" }
                val rowId=b.long; val ts=b.long
                val index=if(format==2) {
                    val present=b.get().toInt()
                    require(present in 0..1) { "candidate_record_index_presence" }
                    if(present==1) {
                        require(b.remaining()>=12) { "candidate_binary_truncated" }
                        b.long.also { require(it in 0..0xffff_ffffL) { "candidate_record_index_range" } }
                    } else null
                } else null
                val length=b.int
                require(rowId>=0 && ts>0 && length in 0..4096 && length<=b.remaining()) { "candidate_binary_record" }
                val fields=ByteArray(length); b.get(fields)
                val digest=B2ObjectStore.sha256Hex(fields)
                if(fields.size<V18AuxCodec.HEADER_BYTES) {
                    rows+=Record(rowId,null,digest,"candidate_aux_truncated");return@repeat
                }
                val bitmap=ByteBuffer.wrap(fields,1,4).order(ByteOrder.LITTLE_ENDIAN).int
                if(fields[0].toInt()!=V18AuxCodec.FORMAT_VERSION || bitmap ushr V18AuxSlot.entries.size!=0) {
                    rows+=Record(rowId,null,digest,"candidate_aux_schema_unsupported");return@repeat
                }
                val expected=V18AuxCodec.HEADER_BYTES+V18AuxSlot.entries.filter { bitmap and (1 shl it.index)!=0 }.sumOf { it.width }
                if(fields.size!=expected) {
                    rows+=Record(rowId,null,digest,"candidate_aux_truncated");return@repeat
                }
                val row=V18AuxCodec.unpack(fields,ts)
                require(format==1 || row.recordIndex==index) { "candidate_record_index_mismatch" }
                rows+=Record(rowId,row,digest,null)
            }
            require(!b.hasRemaining()) { "candidate_binary_trailing_bytes" }
            return rows.sortedBy { it.rowId }
        }
    }
}
