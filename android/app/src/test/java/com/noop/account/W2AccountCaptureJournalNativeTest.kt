package com.noop.account

import com.noop.push.AccountScope
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class W2AccountCaptureJournalNativeTest {
    private class Admission : CaptureAdmission {
        private val lock = Any()
        private var current = true
        override fun <T> withCurrent(block: () -> T): T = synchronized(lock) {
            if (!current) throw CaptureBlockedException(CaptureBlocked.STALE)
            block()
        }
        fun revoke() = synchronized(lock) { current = false }
    }

    private class NamespaceAccess : CaptureNamespaceAccess {
        private val lock = Any()
        override fun <T> withLock(scope: AccountScope, block: () -> T): T = synchronized(lock, block)
    }

    private class Fixture(
        val limits: CaptureLimits = CaptureLimits(),
        val root: File = Files.createTempDirectory("capture-native-").toFile(),
    ) : AutoCloseable {
        var fault: (CaptureFilePoint) -> Unit = {}
        val accounts = File(root, "accounts-v1")
        val access = NamespaceAccess()
        val pool = runBlocking { CaptureRetirement.open(accounts, access, limits, faults = CaptureFileFaults { fault(it) }) }
        val journals = mutableListOf<AccountCaptureJournal>()
        suspend fun journal(
            admission: Admission = Admission(),
            owner: CaptureOwner = OWNER,
            generation: UUID = GENERATION,
            id: () -> UUID = UUID::randomUUID,
        ) = AccountCaptureJournal.open(pool, owner, generation, admission, id).also { journals += it }
        fun folder(owner: CaptureOwner = OWNER) = File(File(accounts, owner.scope.namespace), "capture-v1")
        override fun close() = runBlocking {
            fault = {}
            journals.forEach { assertTrue(pool.settle(it.beginRetirement()).await().settled) }
            pool.close()
        }
    }

    private suspend fun blocked(expected: CaptureBlocked, action: suspend () -> Unit) {
        try { action(); fail("expected $expected") }
        catch (failure: CaptureBlockedException) { assertEquals(expected, failure.reason) }
    }

    @Test fun batchKeeps128NotificationsAndBothRoutesInOneFile() = runBlocking {
        Fixture().use { f ->
            val journal = f.journal()
            val batch = batch(128, twoRoutes = true)
            val accepted = journal.commit(journal.reserveBatch(batch))
            assertEquals(128, accepted.resource.recordCount)
            assertEquals(256, accepted.resource.memberCount)
            assertEquals(1, f.folder().listFiles()!!.size)
            assertEquals(1, f.pool.usage().resources)
            assertEquals(256L, f.pool.usage().members)
            assertEquals(0, f.pool.inFlightUsage().resources)
            assertArrayEquals(byteArrayOf(0, 1), accepted.payload(0))
            assertArrayEquals(byteArrayOf(127, 1), accepted.payload(127))
            assertEquals(setOf("IMU_BOUNDED", "IMU_CONTINUOUS"), accepted.members.map { it.namespace }.toSet())
            assertEquals(1, accepted.members.map { it.receivedAtMs }.distinct().size)
        }
    }

    @Test fun inputAndOutputArraysCannotMutateTheFrozenEnvelope() = runBlocking {
        Fixture().use { f ->
            val journal = f.journal()
            val bytes = byteArrayOf(1, 2, 3)
            val routes = mutableListOf(CaptureRoute(CaptureNamespace.STANDARD_HR, "hr-session"))
            val record = CaptureRecord(0, 1, bytes, routes)
            val records = mutableListOf(record)
            val input = CaptureBatch("strap", DEVICE, PRODUCER, CaptureFormat.STANDARD_HR_V1, records)
            bytes[0] = 99; routes.clear(); records.clear()
            val reservation = journal.reserveBatch(input)
            val first = journal.commit(reservation)
            first.payload(0)[0] = 80
            val replay = journal.commit(reservation)
            assertArrayEquals(byteArrayOf(1, 2, 3), replay.payload(0))
            assertEquals(first.resource, replay.resource)
        }
    }

    @Test fun reservedBytesFinalizeAfterRevocationButFreshAdmissionFails() = runBlocking {
        Fixture().use { f ->
            val admission = Admission()
            val journal = f.journal(admission)
            val reservation = journal.reserveBatch(batch())
            admission.revoke()
            blocked(CaptureBlocked.STALE) { journal.reserveBatch(batch()) }
            val result = journal.commit(reservation)
            assertEquals(OWNER.scope.userID, result.resource.userID)
            assertEquals(GENERATION.toString(), result.resource.generation)
            blocked(CaptureBlocked.STALE) { journal.recoverPage() }
        }
    }

    @Test fun reservationCannotBeUsedByAnotherAccountJournal() = runBlocking {
        Fixture().use { f ->
            val a = f.journal(); val b = f.journal(owner = OTHER)
            val reserved = a.reserveBatch(batch())
            try { b.commit(reserved); fail("cross-owner reservation") } catch (_: IllegalArgumentException) { }
            assertEquals(0, f.folder(OTHER).listFiles()!!.size)
            assertEquals(OWNER, a.commit(reserved).owner)
        }
    }

    @Test fun samePathCannotReopenUntilRetirementSettlesExistingBytes() = runBlocking {
        Fixture().use { f ->
            val a = f.journal()
            a.reserveBatch(batch())
            val ticket = a.beginRetirement()
            blocked(CaptureBlocked.SAME_PATH_BUSY) { f.journal(generation = UUID.randomUUID()) }
            assertTrue(f.pool.settle(ticket).await().settled)
            val next = f.journal(generation = UUID.randomUUID())
            assertEquals(GENERATION.toString(), next.recoverPage().single().resource.generation)
        }
    }

    @Test fun retirementIsIdempotentAndNeverReopensAdmission() = runBlocking {
        Fixture().use { f ->
            val journal = f.journal()
            val ticket = journal.beginRetirement()
            assertSame(ticket, journal.beginRetirement())
            blocked(CaptureBlocked.STALE) { journal.reserveBatch(batch()) }
            assertTrue(f.pool.settle(ticket).await().settled)
            assertTrue(f.pool.settle(ticket).await().settled)
        }
    }

    @Test fun fileFailureKeepsExactDebtAndDoesNotSkipAnotherReservation() = runBlocking {
        Fixture().use { f ->
            val journal = f.journal()
            val first = journal.reserveBatch(batch())
            val second = journal.reserveBatch(batch())
            val writes = AtomicInteger()
            f.fault = { if (it == CaptureFilePoint.BEFORE_WRITE && writes.incrementAndGet() == 1) throw IOException("synthetic") }
            val ticket = journal.beginRetirement()
            val result = f.pool.settle(ticket).await()
            assertFalse(result.settled)
            assertEquals(listOf(first.captureId), result.unsettledCaptureIds)
            assertEquals(listOf(second.captureId), result.durableCaptureIds)
            assertEquals(1, f.pool.inFlightUsage().resources)
            assertEquals(1, f.pool.retainedDrainCount())
            f.fault = {}
            assertTrue(f.pool.settle(ticket).await().settled)
            assertEquals(2, f.folder().listFiles()!!.size)
            assertEquals(0, f.pool.retainedDrainCount())
        }
    }

    @Test fun failureAfterEachPublicationBoundaryRetriesTheSameIdAndBytes() = runBlocking {
        for (point in CaptureFilePoint.values()) Fixture().use { f ->
            val journal = f.journal()
            val reservation = journal.reserveBatch(batch(4))
            f.fault = { if (it == point) throw IOException("synthetic") }
            try { journal.commit(reservation); fail("$point") } catch (_: IOException) { }
            assertEquals(1, f.pool.inFlightUsage().resources)
            blocked(CaptureBlocked.STORAGE) { journal.reserveBatch(batch()) }
            f.fault = {}
            val accepted = journal.commit(reservation)
            assertEquals(reservation.captureId, accepted.resource.captureId)
            assertEquals(4, accepted.resource.recordCount)
            assertEquals(1, f.folder().listFiles()!!.size)
            assertEquals(0, f.pool.inFlightUsage().resources)
        }
    }

    @Test fun reopenedPoolRecoversOriginalOwnerGenerationAndPayloadWithoutRAM() = runBlocking {
        val f = Fixture()
        val journal = f.journal()
        val original = journal.commit(journal.reserveBatch(batch(32, true)))
        val root = f.root
        f.close()
        Fixture(root = root).use { reopened ->
            val next = reopened.journal(generation = UUID.randomUUID())
            val restored = next.recoverPage().single()
            assertEquals(original.resource, restored.resource)
            assertEquals(original.members, restored.members)
            assertArrayEquals(original.payload(31), restored.payload(31))
            assertEquals(1, reopened.pool.usage().resources)
        }
    }

    @Test fun resourceCapacityStillAllowsEveryAlreadyReservedSettlement() = runBlocking {
        Fixture(CaptureLimits(resources = 2)).use { f ->
            val journal = f.journal()
            journal.reserveBatch(batch()); journal.reserveBatch(batch())
            blocked(CaptureBlocked.CAPACITY) { journal.reserveBatch(batch()) }
            assertTrue(f.pool.settle(journal.beginRetirement()).await().settled)
            assertEquals(2, f.pool.usage().resources)
            assertEquals(0, f.pool.inFlightUsage().resources)
            assertTrue(f.pool.usage().settlementAllowanceBytes > 0)
        }
    }

    @Test fun memberCapacityCountsBothDestinationsAndRejectsWithoutAFile() = runBlocking {
        Fixture(CaptureLimits(members = 1)).use { f ->
            val journal = f.journal()
            blocked(CaptureBlocked.CAPACITY) { journal.reserveBatch(batch(twoRoutes = true)) }
            assertEquals(0, f.pool.usage().resources)
            assertEquals(0, f.folder().listFiles()!!.size)
            journal.commit(journal.reserveBatch(batch()))
            assertEquals(1L, f.pool.usage().members)
        }
    }

    @Test fun inFlightCountIsReleasedOnlyAfterDurablePublication() = runBlocking {
        Fixture(CaptureLimits(inFlightReservations = 1)).use { f ->
            val journal = f.journal()
            val reservation = journal.reserveBatch(batch())
            blocked(CaptureBlocked.CAPACITY) { journal.reserveBatch(batch()) }
            journal.commit(reservation)
            journal.commit(journal.reserveBatch(batch()))
            assertEquals(2, f.pool.usage().resources)
        }
    }

    @Test fun zeroRoomForEnvelopeRejectsWithoutConsumingQuota() = runBlocking {
        Fixture(CaptureLimits(payloadBytes = 16, inFlightBytes = 16)).use { f ->
            val journal = f.journal()
            blocked(CaptureBlocked.CAPACITY) { journal.reserveBatch(batch()) }
            assertEquals(CaptureUsage(0, 0, 0), f.pool.usage())
        }
    }

    @Test fun globalDiskQuotaIncludesAnotherOwnerAndSurvivesReopen() = runBlocking {
        val f = Fixture(CaptureLimits(resources = 1))
        val a = f.journal(); a.commit(a.reserveBatch(batch()))
        val b = f.journal(owner = OTHER)
        blocked(CaptureBlocked.CAPACITY) { b.reserveBatch(batch()) }
        val root = f.root; f.close()
        Fixture(CaptureLimits(resources = 1), root).use { next ->
            blocked(CaptureBlocked.CAPACITY) { next.journal(owner = OTHER).reserveBatch(batch()) }
        }
    }

    @Test fun activeWriterPreReservesFiniteRetirementSlot() = runBlocking {
        Fixture(CaptureLimits(retainedDrains = 1)).use { f ->
            val a = f.journal()
            blocked(CaptureBlocked.DRAIN_CAPACITY) { f.journal(owner = OTHER) }
            assertTrue(f.pool.settle(a.beginRetirement()).await().settled)
            f.journal(owner = OTHER)
            assertEquals(1, f.pool.retainedDrainCount())
        }
    }

    @Test fun sourceIdentityMismatchCannotAdoptExistingCapture() = runBlocking {
        Fixture().use { f ->
            val a = f.journal(); a.commit(a.reserveBatch(batch()))
            f.pool.settle(a.beginRetirement()).await()
            val replacement = f.journal(owner = CaptureOwner(OWNER.scope, UUID.randomUUID()))
            blocked(CaptureBlocked.ID_CONFLICT) { replacement.recoverPage() }
        }
    }

    @Test fun onePoolPerAccountsPathPreventsUncoordinatedQuotaWriters() = runBlocking {
        Fixture().use { f ->
            try {
                CaptureRetirement.open(f.accounts, f.access)
                fail("second quota writer")
            } catch (_: java.nio.channels.OverlappingFileLockException) { }
        }
    }

    @Test fun repeatedCaptureIdNeverConsumesANewSlotOrOverwrites() = runBlocking {
        Fixture().use { f ->
            val id = UUID.randomUUID()
            val journal = f.journal(id = { id })
            val reservation = journal.reserveBatch(batch())
            blocked(CaptureBlocked.ID_CONFLICT) { journal.reserveBatch(batch()) }
            journal.commit(reservation)
            blocked(CaptureBlocked.ID_CONFLICT) { journal.reserveBatch(batch()) }
            assertEquals(1, f.pool.usage().resources)
        }
    }

    @Test fun paginationUsesCaptureIdentityNotSameSecondTimestamp() = runBlocking {
        Fixture().use { f ->
            val journal = f.journal()
            val ids = (1..3).map { journal.commit(journal.reserveBatch(batch())).resource.captureId }.sorted()
            val first = journal.recoverPage(limit = 2)
            assertEquals(ids.take(2), first.map { it.resource.captureId })
            assertEquals(ids.drop(2), journal.recoverPage(first.last().resource.captureId, 2).map { it.resource.captureId })
        }
    }

    @Test fun cancellingTheWaiterDoesNotCancelRetainedFinalization() = runBlocking {
        Fixture().use { f ->
            val journal = f.journal(); journal.reserveBatch(batch())
            val entered = CountDownLatch(1); val release = CountDownLatch(1)
            f.fault = { if (it == CaptureFilePoint.BEFORE_WRITE) { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) } }
            val ticket = journal.beginRetirement()
            val work = f.pool.settle(ticket)
            assertTrue(entered.await(10, TimeUnit.SECONDS))
            val waiter = async { work.await() }
            waiter.cancelAndJoin()
            release.countDown()
            assertTrue(work.await().settled)
        }
    }

    companion object {
        private val OWNER = CaptureOwner(AccountScope.create("https://capture.example.test", "10000000-0000-4000-8000-000000000001"), UUID.fromString("30000000-0000-4000-8000-000000000001"))
        private val OTHER = CaptureOwner(AccountScope.create("https://capture.example.test", "10000000-0000-4000-8000-000000000002"), UUID.fromString("30000000-0000-4000-8000-000000000002"))
        private val GENERATION = UUID.fromString("40000000-0000-4000-8000-000000000001")
        private val DEVICE = UUID.fromString("20000000-0000-4000-8000-000000000001")
        private val PRODUCER = UUID.fromString("50000000-0000-4000-8000-000000000001")
        private fun batch(count: Int = 1, twoRoutes: Boolean = false) = CaptureBatch("synthetic-strap", DEVICE, PRODUCER,
            CaptureFormat.WHOOP_FRAME_V1, List(count) { ordinal -> CaptureRecord(ordinal.toLong(), 1_000,
                byteArrayOf(ordinal.toByte(), 1), buildList {
                    add(CaptureRoute(CaptureNamespace.IMU_BOUNDED, "bounded-session", 0))
                    if (twoRoutes) add(CaptureRoute(CaptureNamespace.IMU_CONTINUOUS, "continuous-session", 0))
                }) })
    }
}
