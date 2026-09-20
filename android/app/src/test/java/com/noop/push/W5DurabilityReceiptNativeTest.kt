package com.noop.push

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class W5DurabilityReceiptNativeTest {
    private val other = "22222222-2222-4222-8222-222222222222"
    private val staging = "v3/research/synthetic-staging.bin.gz"
    private fun parse(json: String = objectVector) = PushDurabilityReceipt.parse(json.toByteArray(Charsets.UTF_8))
    private fun changed(field: String, value: Any?, json: String = objectVector) =
        JSONObject(json).put(field, value ?: JSONObject.NULL).toString()
    private fun raw(field: String, value: String, json: String = objectVector): String {
        val obj = JSONObject(json)
        val original = JSONObject().put(field, obj.get(field)).toString().removeSurrounding("{", "}")
        return obj.toString().replace(original, JSONObject.quote(field) + ":" + value)
    }
    private fun rejected(json: String) {
        try { parse(json); fail("Invalid receipt accepted") }
        catch (error: PushDurabilityReceipt.InvalidReceiptException) { assertEquals("Invalid durability receipt", error.message) }
    }
    // Expectations are frozen fixture request values, not extracted from the receipt being checked.
    private fun objectExpected() = PushDurabilityReceipt.ExpectedObject(
        PushDurabilityReceipt.ExpectedContent(
            "11111111-1111-4111-8111-111111111111", "33333333-3333-4333-8333-333333333333",
            "8bb8b3c9-d7d7-469a-a302-fe3289c80f9c", "c053d884-bf08-476c-a3e8-aef1af752486",
            "44444444-4444-4444-8444-444444444444", "ppgWaveformSample", 2,
            "ff07444dd10e5eeffd55d8c44a2747689824bc9d135a6bc5e7b275aeee7d3ed8", 156),
        "a700e5de8f9882f7edaf9059d4bb6b903695aa8e8b13dfe74391b1f371688c26", 88, staging)
    private fun inlineExpected() = PushDurabilityReceipt.ExpectedInline(PushDurabilityReceipt.ExpectedContent(
        "11111111-1111-4111-8111-111111111111", "33333333-3333-4333-8333-333333333333",
        "015b8127-cb7d-4270-baf3-f3dad070fd42", "015b8127-cb7d-4270-baf3-f3dad070fd42",
        "44444444-4444-4444-8444-444444444444", "stepSample", 2,
        "92ca768b4616b43c68f01d44bb7a8152bb5847ac52edbdf18c10e7e16c1d475b", 500))

    @Test fun actualEdgeObjectReceiptPreservesFieldsAndBindsExactRequest() {
        val receipt = parse()
        assertTrue(receipt.matches(objectExpected()))
        assertEquals(1, receipt.version); assertEquals("verified_indexed", receipt.state)
        assertEquals("1bbcbb3f-5326-4584-a90c-474369fa338f", receipt.receiptId)
        assertEquals("2026-09-18T01:11:32.295661-07:00", receipt.verifiedAt)
        assertEquals(receipt.verifiedAt, receipt.indexedAt)
        assertNotEquals(staging, receipt.objectKey)
    }

    @Test fun swiftFixtureUtcTimestampsAndOpaqueVerifiedKeyRemainCompatible() {
        // Exact timestamp/key literals from PushObjectLaneTests.swift:346-353.
        val json = JSONObject(objectVector).put("objectKey", "k/verified")
            .put("receiptId", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
            .put("verifiedAt", "2026-09-18T00:00:00Z").put("indexedAt", "2026-09-18T00:00:01Z")
        val receipt = parse(json.toString())
        assertTrue(receipt.matches(objectExpected().copy(verifiedObjectKey = "k/verified")))
    }

    @Test fun actualEdgeInlineReceiptBindsDecodedBodyNotClientGzip() {
        val receipt = parse(inlineVector)
        assertTrue(receipt.matches(inlineExpected()))
        // Server recompression remains an archive attestation, not a client-wire equality check.
        val serverRecompressed = JSONObject(inlineVector).put("wireSha256", "b".repeat(64)).put("compressedBytes", 333)
        assertTrue(parse(serverRecompressed.toString()).matches(inlineExpected()))
        assertFalse(receipt.matches(inlineExpected().copy(content = inlineExpected().content.copy(contentSha256 = "b".repeat(64)))))
        assertFalse(receipt.matches(inlineExpected().copy(content = inlineExpected().content.copy(uncompressedBytes = 501))))
    }

    @Test fun everyRequiredMemberIsPresentTypedAndNonNull() {
        val keys = JSONObject(objectVector).keys().asSequence().toList()
        assertEquals(17, keys.size)
        for (key in keys) {
            val missing = JSONObject(objectVector).also { it.remove(key) }
            rejected(missing.toString())
            rejected(changed(key, null))
        }
    }

    @Test fun integerFieldsRejectCoercionFractionsExponentOverflowAndNonJsonNumbers() {
        for (field in listOf("version", "schemaVersion", "compressedBytes", "uncompressedBytes")) {
            for (token in listOf("true", "false", "\"1\"", "null", "0", "-1", "-0", "1.5", "1.0", "1e0",
                "1E0", "9223372036854775808", "-9223372036854775809", "1e100", "{}", "[]", "+1", "01", "0x1", "NaN", "Infinity")) {
                rejected(raw(field, token))
            }
        }
        rejected(raw("schemaVersion", "2147483648"))
    }

    @Test fun int64MaximumIsExactWithoutFloatingPointRounding() {
        val json = JSONObject(objectVector).put("compressedBytes", Long.MAX_VALUE).put("uncompressedBytes", Long.MAX_VALUE).toString()
        val receipt = parse(json)
        assertEquals(Long.MAX_VALUE, receipt.compressedBytes)
        assertEquals(Long.MAX_VALUE, receipt.uncompressedBytes)
        assertTrue(receipt.matches(objectExpected().copy(compressedBytes = Long.MAX_VALUE,
            content = objectExpected().content.copy(uncompressedBytes = Long.MAX_VALUE))))
        assertFalse(receipt.matches(objectExpected()))
    }

    @Test fun onlyReceiptV1VerifiedIndexedStateIsSupported() {
        for (version in listOf(2, Int.MAX_VALUE, Long.MAX_VALUE)) rejected(changed("version", version))
        for (state in listOf("ready", "verified", "accepted", "pending", "failed", "VERIFIED_INDEXED", "verified_indexed ", ""))
            rejected(changed("state", state))
        rejected("""{"status":"ready","duplicate":true}""")
        rejected("""{"durabilityReceipt":""" + objectVector + "}")
    }

    @Test fun allSixUuidsRequireCanonicalLowercaseFullForm() {
        for (key in listOf("receiptId", "ownerUserId", "deviceId", "objectId", "batchId", "sourceId")) {
            for (bad in listOf("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "1-1-1-1-1", other + "\n",
                "{" + other + "}", other.replace("-", ""), "", "not-a-uuid"))
                rejected(changed(key, bad))
        }
        // Legacy repair receipts with unknown provenance never match the new bound contract.
        rejected(changed("batchId", null)); rejected(changed("sourceId", null))
    }

    @Test fun stringMembersNeverCoerceNumbersBooleansObjectsOrArrays() {
        val numeric = setOf("version", "schemaVersion", "compressedBytes", "uncompressedBytes")
        for (key in JSONObject(objectVector).keys().asSequence().filter { it !in numeric }) {
            for (token in listOf("1", "true", "false", "{}", "[]")) rejected(raw(key, token))
        }
    }

    @Test fun timestampsUseStrictCalendarOffsetAndChronologicalComparison() {
        for (bad in listOf("2026-02-30T00:00:00Z", "2026-13-01T00:00:00Z", "2026-09-18",
            "2026-09-18T00:00:00", "2026-09-18T24:00:00Z", "2026-09-18T00:00:60Z",
            "2026-09-18T00:00:00+25:00", "2026-09-18T00:00:00.1234567890Z",
            "2026-09-18T00:00:00Z\n", "1970-01-01T00:00:00Z", "1969-12-31T23:59:59Z")) {
            rejected(changed("verifiedAt", bad))
        }
        rejected(changed("indexedAt", "2026-09-18T08:11:32.295660Z"))
        val equal = changed("indexedAt", "2026-09-18T08:11:32.295661Z")
        assertTrue(parse(equal).matches(objectExpected()))
        assertTrue(parse(changed("indexedAt", "2026-09-18T08:11:32.295662Z")).matches(objectExpected()))
    }

    @Test fun malformedIndexedTimestampIsRejectedIndependently() {
        for (bad in listOf("tomorrow", "", "2026-02-30T00:00:00Z", "2026-09-18T24:00:00Z"))
            rejected(changed("indexedAt", bad))
    }

    @Test fun hashesAndObjectKeysHaveBoundedExactSyntax() {
        for (field in listOf("wireSha256", "contentSha256")) {
            for (bad in listOf("A".repeat(64), "a".repeat(63), "a".repeat(65), "a".repeat(64) + "\n", "g".repeat(64)))
                rejected(changed(field, bad))
        }
        for (key in listOf("", "a b", "a\tb", "a\nb", "a\u0000b", "a\u00a0b", "a".repeat(1025)))
            rejected(changed("objectKey", key))
        assertEquals(1024, parse(changed("objectKey", "a".repeat(1024))).objectKey.length)
        for (stream in listOf("", " ", "ppgWaveformSample\n")) rejected(changed("stream", stream))
    }

    @Test fun everyFrozenContentFieldParticipatesInBinding() {
        val receipt = parse(); val e = objectExpected(); val c = e.content
        val alternatives = listOf(c.copy(ownerUserId = other), c.copy(deviceId = other),
            c.copy(sourceId = other), c.copy(objectId = other), c.copy(batchId = other),
            c.copy(stream = "rawBatch"), c.copy(schemaVersion = 1),
            c.copy(contentSha256 = "b".repeat(64)), c.copy(uncompressedBytes = 157))
        for (content in alternatives) assertFalse(receipt.matches(e.copy(content = content)))
        assertFalse(receipt.matches(e.copy(wireSha256 = "b".repeat(64))))
        assertFalse(receipt.matches(e.copy(compressedBytes = 89)))
    }

    @Test fun returnedValidButWrongOwnerDeviceSourceBatchAndSchemaCannotBind() {
        for (field in listOf("ownerUserId", "deviceId", "sourceId", "objectId", "batchId"))
            assertFalse(parse(changed(field, other)).matches(objectExpected()))
        assertFalse(parse(changed("schemaVersion", 1)).matches(objectExpected()))
        assertFalse(parse(changed("stream", "rawBatch")).matches(objectExpected()))
    }

    @Test fun stagingAndVerifiedKeysAreNeverInterchangeable() {
        val receipt = parse(); val expected = objectExpected()
        assertTrue(receipt.matches(expected.copy(verifiedObjectKey = receipt.objectKey)))
        assertTrue(receipt.matches(expected.copy(stagingObjectKey = null, verifiedObjectKey = receipt.objectKey)))
        assertFalse(receipt.matches(expected.copy(stagingObjectKey = receipt.objectKey)))
        assertFalse(receipt.matches(expected.copy(verifiedObjectKey = "other/verified")))
        assertFalse(parse(changed("objectKey", staging)).matches(expected))
        assertFalse(parse(inlineVector).matches(inlineExpected().copy(verifiedObjectKey = "other/verified")))
    }

    @Test fun expectationsRejectMalformedValuesAndInlineIdentityMismatch() {
        fun invalid(block: () -> Unit) {
            try { block(); fail("Invalid expectation accepted") } catch (_: IllegalArgumentException) { }
        }
        val e = objectExpected()
        invalid { e.content.copy(ownerUserId = "1-1-1-1-1") }
        invalid { e.content.copy(deviceId = "raw-local-device") }
        invalid { e.content.copy(schemaVersion = 0) }
        invalid { e.content.copy(uncompressedBytes = 0) }
        invalid { e.copy(wireSha256 = "A".repeat(64)) }
        invalid { e.copy(compressedBytes = 0) }
        invalid { e.copy(stagingObjectKey = "same", verifiedObjectKey = "same") }
        invalid { PushDurabilityReceipt.ExpectedInline(e.content) }
    }

    @Test fun flatJsonRejectsDuplicateEscapedDuplicateUnknownAndNestedMembers() {
        val json = JSONObject(objectVector).toString()
        rejected(json.dropLast(1) + ""","version":1}""")
        rejected(json.dropLast(1) + ""","\u0076ersion":1}""")
        rejected(json.dropLast(1) + ""","future":{"state":"verified_indexed"}}""")
        rejected(json.dropLast(1) + ""","delete":true}""")
        rejected("{}"); rejected("[]")
    }

    @Test fun jsonReaderRejectsCommentsUnquotedKeysAndTrailingData() {
        val json = JSONObject(objectVector).toString()
        for (bad in listOf("/*comment*/" + json, json + "{}", json + "garbage",
            json.replace("\"version\":1", "version:1"), json.replace("\"version\":1", "'version':1"),
            json.dropLast(1) + ",}", json.replace("\"version\":1", "\"version\"=1"),
            json.replace("\"version\":1", "\"version\":1/*comment*/"))) rejected(bad)
    }

    @Test fun strictUtf8AndEnvelopeSizePreventSilentRepair() {
        for (bytes in listOf(byteArrayOf(), byteArrayOf(0xc3.toByte(), 0x28), byteArrayOf(0xff.toByte()),
            byteArrayOf(0xef.toByte(), 0xbb.toByte(), 0xbf.toByte()) + objectVector.toByteArray(),
            ByteArray(PushDurabilityReceipt.MAX_BYTES + 1) { 32 })) {
            try { PushDurabilityReceipt.parse(bytes); fail("Invalid encoding accepted") }
            catch (_: PushDurabilityReceipt.InvalidReceiptException) { }
        }
    }

    @Test fun escapedStringsAndWhitespaceAreParsedButInvalidSurrogatesFail() {
        val json = JSONObject(objectVector).toString()
        assertTrue(parse(" \r\n\t" + json.replace("verified_indexed", """verified_\u0069ndexed""").replace("/", "\\/") + "\n").matches(objectExpected()))
        for (bad in listOf(""""bad\uD800"""", """"bad\uDC00"""", """"bad\q"""", "\"bad\nkey\""))
            rejected(raw("objectKey", bad))
        assertEquals("archive/\uD83D\uDE00", parse(raw("objectKey", """"archive/\uD83D\uDE00"""")).objectKey)
    }

    @Test fun sourceByteMutationDoesNotChangeParsedImmutableData() {
        val bytes = objectVector.toByteArray()
        val receipt = PushDurabilityReceipt.parse(bytes)
        bytes.fill(0)
        assertTrue(receipt.matches(objectExpected()))
        assertFalse(receipt.toString().contains(receipt.ownerUserId))
    }

    companion object {
        // Actual synthetic Edge/SQL export from intake_integration_test.ts's receipt-example.json.
        // Artifact: edge-pg-17f80266373b2ea3/receipt-example.json, SHA256:
        // 30c0582fdaf9e42361df5b12ef42fad7f11924837e224b6246db01af55e6d9e4
        private val objectVector = """{
  "state": "verified_indexed",
  "stream": "ppgWaveformSample",
  "batchId": "c053d884-bf08-476c-a3e8-aef1af752486",
  "version": 1,
  "deviceId": "33333333-3333-4333-8333-333333333333",
  "objectId": "8bb8b3c9-d7d7-469a-a302-fe3289c80f9c",
  "sourceId": "44444444-4444-4444-8444-444444444444",
  "indexedAt": "2026-09-18T01:11:32.295661-07:00",
  "objectKey": "v3/research/users/11111111-1111-4111-8111-111111111111/devices/33333333-3333-4333-8333-333333333333/ppgWaveformSample/2026/09/21/14/verified/8bb8b3c9-d7d7-469a-a302-fe3289c80f9c/3e7cb649-43bd-48c6-9933-9ba82bc26f8d/8bb8b3c9-d7d7-469a-a302-fe3289c80f9c.bin.gz",
  "receiptId": "1bbcbb3f-5326-4584-a90c-474369fa338f",
  "verifiedAt": "2026-09-18T01:11:32.295661-07:00",
  "wireSha256": "a700e5de8f9882f7edaf9059d4bb6b903695aa8e8b13dfe74391b1f371688c26",
  "ownerUserId": "11111111-1111-4111-8111-111111111111",
  "contentSha256": "ff07444dd10e5eeffd55d8c44a2747689824bc9d135a6bc5e7b275aeee7d3ed8",
  "schemaVersion": 2,
  "compressedBytes": 88,
  "uncompressedBytes": 156
}"""
        // Actual first scalar receipt from identity_provenance_integration_test.ts's exported proof.
        // Artifact: edge-pg-43b355f197e6d420/identity-provenance-proof.json, SHA256:
        // 0d9369d6abc3a031f47231939ec5fc98bde068842e1bfa776ee587d21332cab5
        private val inlineVector = """{
  "state": "verified_indexed",
  "stream": "stepSample",
  "batchId": "015b8127-cb7d-4270-baf3-f3dad070fd42",
  "version": 1,
  "deviceId": "33333333-3333-4333-8333-333333333333",
  "objectId": "015b8127-cb7d-4270-baf3-f3dad070fd42",
  "sourceId": "44444444-4444-4444-8444-444444444444",
  "indexedAt": "2026-09-18T08:12:30.645934-07:00",
  "objectKey": "v3/core/users/11111111-1111-4111-8111-111111111111/devices/33333333-3333-4333-8333-333333333333/stepSample/2026/09/21/14/verified/015b8127-cb7d-4270-baf3-f3dad070fd42/2486d5d6-d0f1-4c2b-80fc-b38df58b4f5e/015b8127-cb7d-4270-baf3-f3dad070fd42.ndjson.gz",
  "receiptId": "4a3959c2-b37c-48fb-8661-759a98a1cd7b",
  "verifiedAt": "2026-09-18T08:12:30.645934-07:00",
  "wireSha256": "9c28b44b694e48e33b0de37d17c6e7e795253e4c385f883da7aab476583677e4",
  "ownerUserId": "11111111-1111-4111-8111-111111111111",
  "contentSha256": "92ca768b4616b43c68f01d44bb7a8152bb5847ac52edbdf18c10e7e16c1d475b",
  "schemaVersion": 2,
  "compressedBytes": 332,
  "uncompressedBytes": 500
}"""
    }
}
