package com.frwhoop.scoring

import com.frwhoop.scoring.b2.B2ObjectStore
import com.frwhoop.scoring.db.AuxiliaryObjectReader
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.util.Base64
import java.util.HexFormat

class AuxiliarySwiftGoldenTest {
    @Test fun actualSwiftFormatTwoGzipAndAllSameSecondIdentitiesDecodeExactly() {
        val fixture=javaClass.getResourceAsStream("/aux14-swift.json")!!.bufferedReader().use { JSONObject(it.readText()) }
        val expected=HexFormat.of().parseHex(fixture.getString("hex"))
        val wire=Base64.getDecoder().decode(fixture.getString("gzipBase64"))
        val manifest=fixture.getJSONObject("manifest")
        System.getenv("W4_SWIFT_AUX_FIXTURE_DIR")?.let { directory ->
            val root=Path.of(directory)
            assertArrayEquals(expected,Files.readAllBytes(root.resolve("payload.npb1")))
            assertArrayEquals(wire,Files.readAllBytes(root.resolve("payload.gz")))
            assertTrue(manifest.similar(JSONObject(Files.readString(root.resolve("manifest.json")))))
            val golden=JSONObject(Files.readString(root.resolve("golden.json")))
            assertEquals(fixture.getString("hex"),golden.getString("hex"))
            assertTrue(fixture.getJSONArray("fingerprints").similar(golden.getJSONArray("fingerprints")))
        }
        assertEquals(manifest.getInt("compressedBytes"),wire.size)
        assertEquals(fixture.getString("wireSha256"),B2ObjectStore.sha256Hex(wire))
        val decoded=AuxiliaryObjectReader.decode(wire,"bin_gzip_noop_push_v1",manifest.getInt("uncompressedBytes"))
        assertArrayEquals(expected,decoded)
        assertEquals(manifest.getString("contentSha256"),B2ObjectStore.sha256Hex(decoded))
        val rows=AuxiliaryObjectReader.parse(decoded)
        assertEquals(manifest.getInt("sampleCount"),rows.size)
        assertEquals(listOf(0L,0xffff_ffffL,null),rows.map { it.recordIndex })
        assertEquals(listOf(100L,100L,100L),rows.map { it.ts })
        assertEquals(3,rows.map { it.ts to it.recordIndex }.toSet().size)
        rows.forEachIndexed { i,row ->
            val key="v18AuxSample-v2\n${manifest.getString("deviceId")}\n${row.ts}\n${row.recordIndex ?: "unknown"}"
            assertEquals(fixture.getJSONArray("fingerprints").getString(i),B2ObjectStore.sha256Hex(key.toByteArray(Charsets.UTF_8)))
        }
        assertTrue(rows.all { it.ts>=manifest.getLong("startTs") && it.ts<manifest.getLong("endTs") })
    }
}
