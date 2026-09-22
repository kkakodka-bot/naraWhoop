package com.frwhoop.scoring

import com.frwhoop.scoring.b2.B2Config
import com.frwhoop.scoring.b2.B2ObjectStore
import com.frwhoop.scoring.db.AuxiliaryObjectReader
import com.github.luben.zstd.Zstd
import com.noop.data.V18AuxCodec
import com.noop.data.V18AuxRow
import okhttp3.*
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.GZIPOutputStream

class AuxiliaryObjectReaderTest {
    companion object {
        fun pack(rows:List<V18AuxRow>,format:Int=1,indices:List<Long?> = rows.map { it.recordIndex }):ByteArray {
            val fields=rows.map(V18AuxCodec::pack)
            return ByteBuffer.allocate(10+fields.indices.sumOf { 20+fields[it].size+(if(format==2) 1+(if(indices[it]!=null) 8 else 0) else 0) }).order(ByteOrder.LITTLE_ENDIAN).apply {
                putInt(0x3142504e);put(format.toByte());put(2);putInt(rows.size)
                rows.forEachIndexed { index,row ->
                    putLong(index.toLong());putLong(row.ts)
                    if(format==2) { put(if(indices[index]==null) 0.toByte() else 1.toByte());indices[index]?.let(::putLong) }
                    putInt(fields[index].size);put(fields[index])
                }
            }.array()
        }
        fun gzip(bytes:ByteArray):ByteArray=ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(bytes) } }.toByteArray()
    }

    @Test fun actualAuxStorageAndBinaryLayoutsRoundTripThroughBoundedGzipAndZstd() {
        val rows=listOf(V18AuxRow(ts=1789430400,auxByte82=95),V18AuxRow(ts=1789430401,auxByte82=99))
        val bytes=pack(rows)
        for((format,wire) in listOf("bin_gzip_noop_push_v1" to gzip(bytes),"protobuf_zstd_noop_push_v1" to Zstd.compress(bytes),
            "bin_zstd_noop_push_v1" to Zstd.compress(bytes))) {
            assertEquals(rows,AuxiliaryObjectReader.parse(AuxiliaryObjectReader.decode(wire,format,bytes.size)))
            assertThrows(IllegalStateException::class.java) { AuxiliaryObjectReader.decode(wire,format,bytes.size-1) }
        }
    }

    @Test fun malformedCountsLengthsVersionsAndTruncatedSlotsCannotBecomeCandidateData() {
        val bytes=pack(listOf(V18AuxRow(ts=1789430400,auxByte82=95)))
        val cases=listOf(bytes.copyOf(9),bytes.copyOf(bytes.size-1),bytes+byteArrayOf(0),
            bytes.copyOf().apply { this[4]=2 },bytes.copyOf().apply { this[5]=3 },
            bytes.copyOf().apply { ByteBuffer.wrap(this).order(ByteOrder.LITTLE_ENDIAN).putInt(6,Int.MAX_VALUE) },
            bytes.copyOf().apply { this[30]=1 })
        for(bad in cases) assertThrows(IllegalArgumentException::class.java) { AuxiliaryObjectReader.parse(bad) }
    }

    @Test fun formatTwoPreservesUnknownZeroMaximumAndSameSecondSiblingsWithoutUsingRowIdAsIdentity() {
        val rows=listOf(V18AuxRow(1789430400,recordIndex=null,auxByte82=90),V18AuxRow(1789430400,recordIndex=0,auxByte82=95),
            V18AuxRow(1789430400,recordIndex=0xffff_ffffL,auxByte82=99))
        assertEquals(rows,AuxiliaryObjectReader.parse(pack(rows,2)))
        // Old immutable objects may predate the stricter sender downgrade rule; validate their blob identity.
        assertEquals(rows,AuxiliaryObjectReader.parse(pack(rows,1)))
    }

    @Test fun formatTwoRefusesUnknownPresenceOutOfRangeAndEnvelopeBlobMismatch() {
        val rows=listOf(V18AuxRow(1789430400,recordIndex=0,auxByte82=95))
        val bytes=pack(rows,2)
        val invalid=listOf(pack(rows,2,listOf(null)),pack(rows,2,listOf(1)),
            pack(listOf(rows.single().copy(recordIndex=null)),2,listOf(0)),
            bytes.copyOf().apply { this[26]=2 },
            bytes.copyOf().apply { ByteBuffer.wrap(this).order(ByteOrder.LITTLE_ENDIAN).putLong(27,-1) },
            bytes.copyOf().apply { ByteBuffer.wrap(this).order(ByteOrder.LITTLE_ENDIAN).putLong(27,0x1_0000_0000L) })
        for(bad in invalid) assertThrows(IllegalArgumentException::class.java) { AuxiliaryObjectReader.parse(bad) }
    }

    @Test fun privateGetRefusesForeignBucketRedirectAndOversizedBodies() {
        val config=B2Config("fixture-key","fixture-secret","fixture-bucket","fixture.invalid","us-west-004")
        var calls=0
        fun store(code:Int,bytes:ByteArray)=B2ObjectStore(config,OkHttpClient.Builder().addInterceptor { chain ->
            calls++
            assertEquals("GET",chain.request().method)
            assertEquals("fixture.invalid",chain.request().url.host)
            assertEquals("identity",chain.request().header("Accept-Encoding"))
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(code).message("fixture")
                .header("Location","https://foreign.invalid/object").body(bytes.toResponseBody()).build()
        }.build())
        assertThrows(IllegalArgumentException::class.java) { store(200,byteArrayOf(1)).readObject("other","key",10) }
        assertEquals(0,calls)
        assertThrows(IllegalStateException::class.java) { store(302,byteArrayOf()).readObject("fixture-bucket","key",10) }
        assertEquals(1,calls)
        assertThrows(IllegalStateException::class.java) { store(200,ByteArray(11)).readObject("fixture-bucket","key",10) }
        assertArrayEquals(byteArrayOf(1,2),store(200,byteArrayOf(1,2)).readObject("fixture-bucket","key",2))
    }
}
