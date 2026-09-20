package com.frwhoop.scoring

import com.frwhoop.scoring.db.ScalarInputReader
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.math.BigDecimal
import java.math.BigInteger

class ScalarInputProvenanceTest {
    private val safeInteger=9_007_199_254_740_991L
    private val directKeys=setOf("recordIndex","frameSHA256")
    private val derivedKeys=setOf("algorithm","sampleRateHz","windowSettingSeconds","inputStartTs","inputEndTs","inputSHA256")
    private fun direct()=JSONObject().put("v",1).put("origin","whoop-v18")
        .put("recordIndex",0xffff_ffffL).put("frameSHA256","a".repeat(64))
    private fun derived()=JSONObject().put("v",1).put("origin","whoop-v26-ppg-derived")
        .put("algorithm","ppg-acf-sublag-v1").put("sampleRateHz",64).put("windowSettingSeconds",8)
        .put("inputStartTs",990).put("inputEndTs",999).put("inputSHA256","b".repeat(64))
    private fun legacy()=JSONObject().put("v",1).put("origin","legacy-unknown")
    private fun assertRetained(value:JSONObject,hi:Long=1000):JSONObject {
        val read=ScalarInputReader.provenance(value.toString(),hi)!!
        assertEquals(value.keySet(),read.keySet())
        assertTrue("metadata must not be filled or rewritten",value.similar(read))
        return read
    }
    private fun assertRejected(value:JSONObject,hi:Long=1000) {
        assertTrue("accepted $value at hi=$hi",runCatching { ScalarInputReader.provenance(value.toString(),hi) }.isFailure)
    }

    @Test fun strictVersionOneRetainsAbsentUnknownAndMaximumIdentity() {
        assertNull(ScalarInputReader.provenance(null,1000))
        assertNull(ScalarInputReader.provenance("null",1000))
        assertEquals(0xffff_ffffL,assertRetained(direct()).getLong("recordIndex"))
        for(algorithm in listOf("ppg-acf-v1","ppg-acf-sublag-v1")) assertRetained(derived().put("algorithm",algorithm))
        val minimal=assertRetained(legacy())
        assertFalse(minimal.has("algorithm"));assertFalse(minimal.has("recordIndex"))
        // Both direct identity fields are optional, never reconstructed from current settings.
        for(removed in listOf(setOf("recordIndex"),setOf("frameSHA256"),directKeys)) {
            val value=direct();removed.forEach(value::remove);assertRetained(value)
        }
        assertRetained(direct().put("recordIndex",0))
    }
    @Test fun invalidTypesNullMembersUnknownSchemaAndFutureInputNeverDowngradeToLegacy() {
        for(base in listOf(direct(),derived(),legacy())) {
            for(value in listOf<Any>(true,2,"1",JSONArray(),JSONObject())) assertRejected(JSONObject(base.toString()).put("v",value))
            for(value in listOf<Any>("unknown","WHOOP-V18",1,false,JSONArray(),JSONObject()))
                assertRejected(JSONObject(base.toString()).put("origin",value))
            for(key in listOf("v","origin")) assertRejected(JSONObject(base.toString()).also { it.remove(key) })
            assertRejected(JSONObject(base.toString()).put("other",JSONObject()))
        }
        for(value in listOf<Any>("guessed","",1,true,JSONObject(),JSONArray())) assertRejected(derived().put("algorithm",value))
        for(key in listOf("frameSHA256","inputSHA256")) for(value in listOf<Any>("A".repeat(64),"a".repeat(63),"g".repeat(64),0,true,JSONArray(),JSONObject())) {
            assertRejected((if(key=="frameSHA256") direct() else derived()).put(key,value))
        }
    }

    @Test fun derivedInputSelectionIsRetainedExactlyAndAbsenceIsNeverInferred() {
        val base=derived()
        assertFalse(ScalarInputReader.provenance(base.toString(),1000)!!.has("inputSelection"))
        for(selection in listOf("concat-records-per-second-v1","last-record-per-second-v1")) {
            val declared=JSONObject(base.toString()).put("inputSelection",selection)
            assertRetained(declared)
        }
        for(origin in listOf("whoop-v18","legacy-unknown")) {
            val absent=JSONObject().put("v",1).put("origin",origin)
            assertFalse(ScalarInputReader.provenance(absent.toString(),1000)!!.has("inputSelection"))
        }
    }

    @Test fun nullUnknownWrongTypeAndNonDerivedInputSelectionReject() {
        val base=derived()
        for(value in listOf<Any>(JSONObject.NULL,"","unknown","concat-records-per-second-v2",true,0,JSONArray(),JSONObject())) {
            assertTrue("inputSelection=$value",runCatching {
                ScalarInputReader.provenance(JSONObject(base.toString()).put("inputSelection",value).toString(),1000)
            }.isFailure)
        }
        for(origin in listOf("whoop-v18","legacy-unknown")) for(selection in listOf("concat-records-per-second-v1","last-record-per-second-v1")) {
            assertTrue("$origin/$selection",runCatching {
                ScalarInputReader.provenance(JSONObject().put("v",1).put("origin",origin).put("inputSelection",selection).toString(),1000)
            }.isFailure)
        }
    }

    @Test fun derivedRequiresEveryOneOfTheSixDeclaredInputs() {
        assertRejected(JSONObject().put("v",1).put("origin","whoop-v26-ppg-derived"))
        for(key in derivedKeys) {
            assertRejected(derived().also { it.remove(key) })
            assertRejected(derived().put("inputSelection","last-record-per-second-v1").also { it.remove(key) })
        }
    }

    @Test fun everyOriginRejectsAllForeignOriginFields() {
        for(key in directKeys) assertRejected(derived().put(key,direct().get(key)))
        val derivedWithSelection=derived().put("inputSelection","concat-records-per-second-v1")
        for(key in derivedKeys+"inputSelection") {
            assertRejected(direct().put(key,derivedWithSelection.get(key)))
            assertRejected(legacy().put(key,derivedWithSelection.get(key)))
        }
        for(key in directKeys) assertRejected(legacy().put(key,direct().get(key)))
        // This was previously (incorrectly) blessed by the positive fixture.
        assertRejected(derived().put("recordIndex",0xffff_ffffL).put("frameSHA256","a".repeat(64)))
    }

    @Test fun everyKnownExplicitNullRejectsOnAnOtherwiseValidOriginShape() {
        for(base in listOf(direct(),derived().put("inputSelection","last-record-per-second-v1"),legacy()))
            for(key in base.keySet()) assertRejected(JSONObject(base.toString()).put(key,JSONObject.NULL))
    }

    @Test fun knownIntegersRejectUnsafeRangeAndNonIntegerValues() {
        val fields=listOf("v","recordIndex","sampleRateHz","windowSettingSeconds","inputStartTs","inputEndTs")
        for(key in fields) {
            for(value in listOf<Any>(safeInteger+1,-safeInteger-1,Long.MAX_VALUE,Long.MIN_VALUE,
                BigInteger("9223372036854775808"),true,"1",BigDecimal("1.5"),JSONArray(),JSONObject())) {
                // Wide as-of bound and a valid companion bound isolate numeric admission, not future-window rejection.
                val base=if(key=="recordIndex") direct() else derived().put("inputStartTs",-safeInteger).put("inputEndTs",safeInteger)
                assertRejected(base.put(key,value),Long.MAX_VALUE-1)
            }
        }
        for(value in listOf(-1L,0x1_0000_0000L)) assertRejected(direct().put("recordIndex",value))
        for(key in listOf("sampleRateHz","windowSettingSeconds")) for(value in listOf(0,-1)) assertRejected(derived().put(key,value))
        // Do not let Double rounding turn an unsafe/fractional boundary into an admitted integer.
        assertRejected(derived().put("sampleRateHz",BigDecimal("9007199254740991.1")),Long.MAX_VALUE-1)
        assertRejected(derived().put("inputStartTs",BigDecimal("-9007199254740991.1")),Long.MAX_VALUE-1)
    }

    @Test fun safeIntegerBoundariesRetainActualMetadataAndAsOfCheckCannotOverflow() {
        val widest=derived().put("sampleRateHz",safeInteger).put("windowSettingSeconds",safeInteger)
            .put("inputStartTs",-safeInteger).put("inputEndTs",safeInteger)
        assertRetained(widest,safeInteger-1)
        assertRetained(widest,Long.MAX_VALUE)
        assertRetained(derived().put("sampleRateHz",1).put("windowSettingSeconds",1).put("inputStartTs",0).put("inputEndTs",1),0)
        assertRetained(derived().put("inputStartTs",-safeInteger).put("inputEndTs",-safeInteger+1),-safeInteger)
    }

    @Test fun halfOpenWindowOrderingAndNoFutureInputRemainStrict() {
        assertRetained(derived().put("inputEndTs",1001),1000)
        assertRejected(derived().put("inputEndTs",1002),1000)
        assertRejected(derived().put("inputEndTs",990))
        assertRejected(derived().put("inputEndTs",989))
    }

    @Test fun nonObjectAndOversizedMetadataFailClosed() {
        for(raw in listOf("[]","1","true","\"legacy-unknown\"","{"))
            assertTrue(raw,runCatching { ScalarInputReader.provenance(raw,1000) }.isFailure)
        assertRejected(derived().put("inputSHA256","b".repeat(1025)))
        assertTrue(runCatching { ScalarInputReader.provenance(" ".repeat(4097)+legacy(),1000) }.isFailure)
    }
}
