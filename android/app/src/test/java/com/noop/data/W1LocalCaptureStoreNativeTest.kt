package com.noop.data

import android.app.Application
import androidx.sqlite.db.SupportSQLiteDatabase
import com.noop.account.CaptureOwner
import com.noop.data.CaptureIndexNativeFixture.Companion.digest
import com.noop.data.CaptureIndexNativeFixture.Companion.key
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class W1LocalCaptureStoreNativeTest {
    @Test fun oneFilePreservesEveryRecordAndBothIndependentSameSecondDestinations() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(128, true)
            assertEquals(CaptureRegistration(true, 256), f.store.register(capture))
            val page = f.store.pendingMembers(limit = 256)
            assertEquals(capture.resource, page.first().resource)
            assertEquals(capture.members, page.map { it.member })
            assertEquals(1, page.map { it.member.receivedAtMs }.distinct().size)
            assertEquals(1L, f.count("localCaptureResource")); assertEquals(256L, f.count("localCaptureMember"))
            assertEquals(1, f.file(capture).parentFile!!.listFiles()!!.size)
        }
    }

    @Test fun replayPreservesSettlementAndNeverCreatesAnotherDestination() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(2, true); val target = key(capture)
            val bytes = digest(f.file(capture)); val projection = CaptureFixtureProjection()
            f.store.register(capture)
            assertEquals(CaptureApplyResult.APPLIED, f.store.applyMember(capture, target, projection))
            assertEquals(CaptureRegistration(false, 0), f.store.register(capture))
            assertEquals(CaptureApplyResult.ALREADY_APPLIED, f.store.applyMember(capture, target, projection))
            assertEquals(1, projection.writes); assertEquals(1, f.state(target))
            assertEquals(3, f.store.pendingMembers().size); assertEquals(1L, f.count("captureProjectionFixture"))
            assertEquals(bytes, digest(f.file(capture)))
        }
    }

    @Test fun declaredSuccessWithWrongDestinationRollsBackBothDestinationAndMarker() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(); f.store.register(capture)
            failure(CaptureIndexFailure.DESTINATION_MISMATCH) {
                f.store.applyMember(capture, key(capture), CaptureFixtureProjection(corruptDevice = true))
            }
            assertEquals(0L, f.count("captureProjectionFixture")); assertEquals(0, f.state(key(capture)))
        }
    }

    @Test fun settledMarkerAloneCannotAcknowledgeMissingOrAlteredDestination() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(); val target = key(capture); val projection = CaptureFixtureProjection()
            f.store.register(capture); f.store.applyMember(capture, target, projection)
            for ((column, replacement) in listOf("projectURL" to "https://other.example.test", "userID" to UUID.randomUUID().toString(),
                "sourceID" to UUID.randomUUID().toString(), "deviceID" to "other-strap", "serverDeviceID" to UUID.randomUUID().toString(),
                "namespace" to "STANDARD_HR", "sessionID" to "other-session")) {
                val original = f.db.query("SELECT $column FROM captureProjectionFixture").use { it.moveToFirst(); it.getString(0) }
                f.db.execSQL("UPDATE captureProjectionFixture SET $column=?", arrayOf(replacement))
                failure(CaptureIndexFailure.DESTINATION_MISMATCH) { f.store.applyMember(capture, target, projection) }
                f.db.execSQL("UPDATE captureProjectionFixture SET $column=?", arrayOf(original))
            }
            f.db.execSQL("UPDATE captureProjectionFixture SET payload=?", arrayOf(byteArrayOf(99)))
            failure(CaptureIndexFailure.DESTINATION_MISMATCH) { f.store.applyMember(capture, target, projection) }
            f.db.execSQL("DELETE FROM captureProjectionFixture")
            failure(CaptureIndexFailure.DESTINATION_MISMATCH) { f.store.applyMember(capture, target, projection) }
            assertEquals(1, projection.writes)
        }
    }

    @Test fun deferredAndConflictDecisionsRollBackEvenIfCallbackAlreadyWrote() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(); f.store.register(capture)
            for ((decision, result) in listOf(CaptureProjectionDecision.DEFERRED to CaptureApplyResult.DEFERRED,
                CaptureProjectionDecision.CONFLICT to CaptureApplyResult.CONFLICT)) {
                assertEquals(result, f.store.applyMember(capture, key(capture), CaptureFixtureProjection(decision)))
                assertEquals(0L, f.count("captureProjectionFixture")); assertEquals(0, f.state(key(capture)))
            }
        }
    }

    @Test fun thrownProjectionAndMissingMemberLeaveFrozenFileAndIndexDebt() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(); val digest = digest(f.file(capture)); f.store.register(capture)
            try { f.store.applyMember(capture, key(capture), CaptureFixtureProjection(throwAfterWrite = true)); fail("callback failure") }
            catch (failure: IllegalStateException) { assertEquals("synthetic projection failure", failure.message) }
            failure(CaptureIndexFailure.MISSING_MEMBER) { f.store.applyMember(capture, key(capture, route = 1), CaptureFixtureProjection()) }
            assertEquals(0L, f.count("captureProjectionFixture")); assertEquals(0, f.state(key(capture)))
            assertEquals(digest, digest(f.file(capture)))
        }
    }

    @Test fun nativeInsertionFaultRollsBackResourceAndAllEarlierMemberships() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(3); val digest = digest(f.file(capture))
            f.db.execSQL("CREATE TRIGGER captureSyntheticFailure BEFORE INSERT ON localCaptureMember WHEN NEW.recordOrdinal=1 " +
                "BEGIN SELECT RAISE(ABORT,'synthetic member failure'); END")
            try { f.store.register(capture); fail("insertion failure") } catch (e: android.database.sqlite.SQLiteException) {
                assertTrue(e.message.orEmpty().contains("synthetic member failure"))
            }
            assertEquals(0L, f.count("localCaptureResource")); assertEquals(0L, f.count("localCaptureMember"))
            f.db.execSQL("DROP TRIGGER captureSyntheticFailure")
            assertEquals(CaptureRegistration(true, 3), f.store.register(f.journal.recoverPage().single()))
            assertEquals(digest, digest(f.file(capture)))
        }
    }

    @Test fun conflictingResourceOrMemberIsNeverReplacedDuringReplay() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(); f.store.register(capture)
            f.db.execSQL("UPDATE localCaptureResource SET deviceID='different-device'")
            failure(CaptureIndexFailure.CONFLICT) { f.store.register(capture) }
            f.db.query("SELECT deviceID FROM localCaptureResource").use { it.moveToFirst(); assertEquals("different-device", it.getString(0)) }
            f.db.execSQL("UPDATE localCaptureResource SET deviceID=?", arrayOf(capture.resource.deviceID))
            f.db.execSQL("UPDATE localCaptureMember SET sessionID='different-session'")
            failure(CaptureIndexFailure.CONFLICT) { f.store.register(capture) }
            assertEquals(1L, f.count("localCaptureMember")); assertEquals(0L, f.count("captureProjectionFixture"))
        }
    }

    @Test fun missingMigrationDoesNotCreateTablesOrLoseTheAuthoritativeFile() = runBlocking {
        CaptureIndexNativeFixture(createIndex = false).use { f ->
            val capture = f.capture(); val digest = digest(f.file(capture))
            failure(CaptureIndexFailure.NOT_READY) { f.store.register(capture) }
            f.db.query("SELECT count(*) FROM sqlite_master WHERE name='localCaptureResource'").use { it.moveToFirst(); assertEquals(0, it.getInt(0)) }
            LocalCaptureSchema.create(f.db)
            assertEquals(CaptureRegistration(true, 1), f.store.register(f.journal.recoverPage().single()))
            assertEquals(digest, digest(f.file(capture)))
        }
    }

    @Test fun absentOrWrongDatabaseOwnerCannotBindOrIndexCapture() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture()
            f.db.execSQL("UPDATE localAccountOwner SET userID=? WHERE singleton=1", arrayOf(UUID.randomUUID().toString()))
            failure(CaptureIndexFailure.OWNER_MISMATCH) { f.store.register(capture) }
            f.db.execSQL("DELETE FROM localAccountOwner")
            failure(CaptureIndexFailure.OWNER_MISMATCH) { f.store.register(capture) }
            assertEquals(0L, f.count("localCaptureResource")); assertEquals(0L, f.count("localCaptureMember"))
        }
    }

    @Test fun wrongSourceCannotAdoptCaptureEvenInTheSameAccountDatabase() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(); var opened = false
            val other = LocalCaptureStore(CaptureOwner(f.owner.scope, UUID.randomUUID()), f.admission, { opened = true; f.db })
            failure(CaptureIndexFailure.OWNER_MISMATCH) { other.register(capture) }
            assertFalse(opened); assertEquals(0L, f.count("localCaptureResource"))
        }
    }

    @Test fun nativeIntegerTypesAndRangesFailClosedInsteadOfCursorCoercion() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(); f.store.register(capture)
            for (value in listOf<Any>("invalid", 0.5, 4_294_967_296L, -1L, 2L)) {
                f.db.execSQL("UPDATE localCaptureMember SET projectionState=?", arrayOf(value))
                failure(CaptureIndexFailure.INVALID_CAPTURE) { f.store.pendingMembers() }
                failure(CaptureIndexFailure.INVALID_CAPTURE) { f.store.register(capture) }
            }
            f.db.execSQL("UPDATE localCaptureMember SET projectionState=0")
            assertEquals(1, f.store.pendingMembers().size)
        }
    }

    @Test fun keysetPaginationIncludesEverySameSecondRecordRouteAndCapture() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val captures = List(3) { f.capture(3, true).also { f.store.register(it) } }
            val expected = captures.sortedBy { it.resource.captureId }.flatMap { c -> c.members.map { CaptureMemberKey(it.captureId, it.recordOrdinal, it.routeOrdinal) } }
            val actual = mutableListOf<CaptureMemberKey>(); var after: CaptureMemberKey? = null
            while (true) {
                val page = f.store.pendingMembers(after, 5); if (page.isEmpty()) break
                actual += page.map { it.key }; after = page.last().key
            }
            assertEquals(expected, actual); assertEquals(18, actual.distinct().size)
            for (limit in listOf(0, 257)) try { f.store.pendingMembers(limit = limit); fail("invalid limit") } catch (_: IllegalArgumentException) { }
        }
    }

    @Test fun reindexAfterLostIndexReusesExactDestinationWithoutAnotherWriteRevision() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(); f.store.register(capture)
            f.store.applyMember(capture, key(capture), CaptureFixtureProjection())
            val digest = digest(f.file(capture))
            // Models an older index snapshot. It does not exercise production backup/restore.
            f.db.execSQL("DELETE FROM localCaptureMember"); f.db.execSQL("DELETE FROM localCaptureResource")
            val restored = f.journal.recoverPage().single()
            assertEquals(CaptureRegistration(true, 1), f.store.register(restored))
            assertEquals(CaptureApplyResult.APPLIED, f.store.applyMember(restored, key(restored), CaptureFixtureProjection()))
            assertEquals(1L, f.count("captureProjectionFixture")); assertEquals(1, f.state(key(restored)))
            assertEquals(capture.resource, restored.resource); assertEquals(digest, digest(f.file(capture)))
        }
    }

    @Test fun copiedProjectionPayloadCannotMutateAuthoritativeCapture() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(); f.store.register(capture)
            val delegate = CaptureFixtureProjection()
            val projection = object : CaptureMemberProjection {
                override fun write(database: SupportSQLiteDatabase, input: CaptureProjectionInput): CaptureProjectionDecision {
                    input.payload()[0] = 99
                    assertArrayEquals(byteArrayOf(0, 42), input.payload())
                    return delegate.write(database, input)
                }
                override fun destinationMatches(database: SupportSQLiteDatabase, input: CaptureProjectionInput) = delegate.destinationMatches(database, input)
            }
            assertEquals(CaptureApplyResult.APPLIED, f.store.applyMember(capture, key(capture), projection))
            assertArrayEquals(byteArrayOf(0, 42), capture.payload(0))
        }
    }

    private suspend fun failure(expected: CaptureIndexFailure, body: suspend () -> Unit) {
        try { body(); fail("expected $expected") } catch (error: CaptureIndexException) { assertEquals(expected, error.failure) }
    }
}
