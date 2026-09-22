package com.noop.account

import com.noop.push.AccountScope
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class W2CaptureRecordAdmissionNativeTest {
    private class Admission : CaptureAdmission {
        private val lock = Any()
        private var current = true
        var admitted: () -> Unit = {}
        override fun <T> withCurrent(block: () -> T): T = synchronized(lock) {
            if (!current) throw CaptureBlockedException(CaptureBlocked.STALE)
            admitted()
            block()
        }
        fun revoke() = synchronized(lock) { current = false }
    }

    private class RecordingDispatcher : CoroutineDispatcher() {
        val calls = AtomicInteger()
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            calls.incrementAndGet()
            Dispatchers.IO.dispatch(context, block)
        }
    }

    private class Fixture(
        limits: CaptureLimits = CaptureLimits(),
        val root: File = Files.createTempDirectory("capture-record-native-").toFile(),
        dispatcher: CoroutineDispatcher = Dispatchers.IO,
    ) : AutoCloseable {
        val namespaceCalls = AtomicInteger()
        var fault: (CaptureFilePoint) -> Unit = {}
        private val accounts = File(root, "accounts-v1")
        private val namespaceLock = Any()
        val pool = runBlocking {
            CaptureRetirement.open(accounts, object : CaptureNamespaceAccess {
                override fun <T> withLock(scope: AccountScope, block: () -> T): T = synchronized(namespaceLock) {
                    namespaceCalls.incrementAndGet()
                    block()
                }
            }, limits, dispatcher, CaptureFileFaults { fault(it) })
        }
        private val journals = mutableListOf<AccountCaptureJournal>()
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
            assertEquals(0, pool.inFlightReservationCount())
            pool.close()
        }
    }

    private suspend fun blocked(expected: CaptureBlocked, body: suspend () -> Unit) {
        try { body(); fail("expected $expected") }
        catch (failure: CaptureBlockedException) { assertEquals(expected, failure.reason) }
    }

    @Test fun synchronousAdmissionSharesOneResourceAndDoesNotDispatchOrTouchFiles() = runBlocking {
        val dispatcher = RecordingDispatcher()
        Fixture(dispatcher = dispatcher).use { f ->
            val journal = f.journal()
            val beforeDispatch = dispatcher.calls.get()
            val beforeNamespace = f.namespaceCalls.get()
            f.fault = { fail("admission or sealing attempted file publication") }
            val tickets = List(128) { journal.reserveRecord(PRODUCER, record(it, twoRoutes = true)) }
            assertEquals(beforeDispatch, dispatcher.calls.get())
            assertEquals(beforeNamespace, f.namespaceCalls.get())
            assertEquals(1, tickets.map { it.captureId }.distinct().size)
            assertEquals((0..127).toList(), tickets.map { it.recordOrdinal })
            assertEquals((0L..127L).toList(), tickets.map { it.encounterOrdinal })
            assertEquals(1, f.pool.usage().resources)
            assertEquals(256L, f.pool.usage().members)
            assertEquals(128, f.pool.inFlightReservationCount())
            assertEquals(0, f.folder().listFiles()!!.size)
            val reservedUsage = f.pool.usage()
            val sealed = journal.sealRecords(tickets.first())
            assertTrue(dispatcher.calls.get() > beforeDispatch)
            assertEquals(beforeNamespace, f.namespaceCalls.get())
            assertEquals(reservedUsage, f.pool.usage())
            assertEquals(128, f.pool.inFlightReservationCount())
            assertEquals(0, f.folder().listFiles()!!.size)
            assertSame(sealed, journal.sealRecords(tickets.last()))
            f.fault = {}
            val durable = journal.commit(sealed)
            assertEquals(128, durable.resource.recordCount)
            assertEquals(256, durable.resource.memberCount)
            assertEquals(reservedUsage.fileBytes, durable.resource.fileBytes)
            assertEquals(0, f.pool.inFlightReservationCount())
            assertEquals(1, f.folder().listFiles()!!.size)
            assertArrayEquals(byteArrayOf(127, 1), durable.payload(127))
        }
    }

    @Test fun recordPathKeepsTheExistingNcapFormatByteForByte() = runBlocking {
        val id = UUID.randomUUID()
        val records = listOf(record(0, true), record(1), record(2, true))
        var expected: ByteArray? = null
        Fixture().use { f ->
            val journal = f.journal(id = { id })
            journal.commit(journal.reserveBatch(batch(records)))
            expected = File(f.folder(), "$id.ncap").readBytes()
        }
        Fixture().use { f ->
            val journal = f.journal(id = { id })
            val tickets = records.map { journal.reserveRecord(PRODUCER, it) }
            val reserved = f.pool.usage()
            journal.commit(journal.sealRecords(tickets.first()))
            val actual = File(f.folder(), "$id.ncap").readBytes()
            assertArrayEquals(expected, actual)
            assertEquals(actual.size.toLong(), reserved.fileBytes)
        }
    }

    @Test fun admissionFreezesRawBytesRoutesAndEveryIdentityBeforeRevocation() = runBlocking {
        Fixture().use { f ->
            val admission = Admission()
            val journal = f.journal(admission)
            val bytes = byteArrayOf(1, 4, 9)
            val routes = mutableListOf(CaptureRoute(CaptureNamespace.STANDARD_HR, "session-é", null))
            val producer = PRODUCER.copy(deviceId = "strap-é", format = CaptureFormat.STANDARD_HR_V1)
            val ticket = journal.reserveRecord(producer, CaptureRecord(42, 123_456, bytes, routes))
            bytes.fill(0); routes.clear()
            admission.revoke()
            val usage = f.pool.usage()
            blocked(CaptureBlocked.STALE) { journal.reserveRecord(producer, record(43)) }
            assertEquals(usage, f.pool.usage())
            val result = journal.commit(journal.sealRecords(ticket))
            assertEquals(OWNER, result.owner)
            assertEquals(GENERATION.toString(), result.resource.generation)
            assertEquals(producer.deviceId, result.resource.deviceID)
            assertEquals(producer.serverDeviceId.toString(), result.resource.serverDeviceID)
            assertEquals(producer.producerId.toString(), result.resource.producerID)
            assertEquals(producer.format.name, result.resource.format)
            assertEquals(usage.fileBytes, result.resource.fileBytes)
            assertArrayEquals(byteArrayOf(1, 4, 9), result.payload(0))
            assertEquals(42L, result.members.single().encounterOrdinal)
            assertEquals(123_456L, result.members.single().receivedAtMs)
            assertEquals("session-é", result.members.single().sessionID)
        }
    }

    @Test fun sealingClosesOnlyThatBatchAndRetriesItsExactIdentity() = runBlocking {
        Fixture().use { f ->
            val journal = f.journal()
            val first = journal.reserveRecord(PRODUCER, record(0))
            val second = journal.reserveRecord(PRODUCER, record(1))
            val sealed = journal.sealRecords(first)
            val next = journal.reserveRecord(PRODUCER, record(2))
            assertEquals(first.captureId, second.captureId)
            assertNotEquals(first.captureId, next.captureId)
            assertSame(sealed, journal.sealRecords(second))
            val durable = journal.commit(sealed)
            assertEquals(2, durable.resource.recordCount)
            assertEquals(durable.resource, journal.commit(journal.sealRecords(first)).resource)
            assertEquals(1, f.pool.inFlightReservationCount())
        }
    }

    @Test fun recordAndMemberBatchLimitsRotateWithoutDroppingSameSecondEncounters() = runBlocking {
        for (limits in listOf(CaptureLimits(batchRecords = 2), CaptureLimits(batchMembers = 4))) {
            Fixture(limits).use { f ->
                val journal = f.journal()
                val tickets = List(5) { journal.reserveRecord(PRODUCER, record(it, twoRoutes = true)) }
                assertEquals(listOf(0, 1, 0, 1, 0), tickets.map { it.recordOrdinal })
                assertEquals(3, tickets.map { it.captureId }.distinct().size)
                assertTrue(f.pool.settle(journal.beginRetirement()).await().settled)
                assertEquals(3, f.folder().listFiles()!!.size)
                val next = f.journal(generation = UUID.randomUUID())
                val restored = next.recoverPage().sortedBy { it.members.first().encounterOrdinal }
                assertEquals(listOf(2, 2, 1), restored.map { it.resource.recordCount })
                assertEquals((0L..4L).toList(), restored.flatMap { it.members.filter { row -> row.routeOrdinal == 0 }.map { row -> row.encounterOrdinal } })
                assertTrue(restored.flatMap { it.members }.all { it.receivedAtMs == 1_000L })
            }
        }
    }

    @Test fun exactEncodedBatchByteLimitRotatesAtTheExistingFormatBoundary() = runBlocking {
        val twoRecordsBytes = publishedBytes(2).toInt()
        Fixture(CaptureLimits(batchBytes = twoRecordsBytes)).use { f ->
            val journal = f.journal()
            val tickets = List(3) { journal.reserveRecord(PRODUCER, record(it)) }
            assertEquals(tickets[0].captureId, tickets[1].captureId)
            assertNotEquals(tickets[1].captureId, tickets[2].captureId)
            assertEquals(twoRecordsBytes.toLong(), journal.commit(journal.sealRecords(tickets[0])).resource.fileBytes)
        }
    }

    @Test fun exactGlobalAndInFlightByteCapsRejectWithoutLeakingDebt() = runBlocking {
        val twoRecordsBytes = publishedBytes(2)
        for (limits in listOf(CaptureLimits(payloadBytes = twoRecordsBytes), CaptureLimits(inFlightBytes = twoRecordsBytes))) {
            Fixture(limits).use { f ->
                val journal = f.journal()
                val first = journal.reserveRecord(PRODUCER, record(0))
                journal.reserveRecord(PRODUCER, record(1))
                val usage = f.pool.usage()
                assertEquals(twoRecordsBytes, usage.fileBytes)
                blocked(CaptureBlocked.CAPACITY) { journal.reserveRecord(PRODUCER, record(2)) }
                assertEquals(usage, f.pool.usage())
                assertEquals(2, f.pool.inFlightReservationCount())
                assertEquals(twoRecordsBytes, journal.commit(journal.sealRecords(first)).resource.fileBytes)
            }
        }
    }

    @Test fun membersResourcesAndCompletionSlotsAreChargedTogether() = runBlocking {
        Fixture(CaptureLimits(resources = 1, members = 4, inFlightReservations = 2)).use { f ->
            val journal = f.journal()
            val first = journal.reserveRecord(PRODUCER, record(0, true))
            journal.reserveRecord(PRODUCER, record(1, true))
            val usage = f.pool.usage()
            assertEquals(1, usage.resources)
            assertEquals(4L, usage.members)
            assertEquals(2, f.pool.inFlightReservationCount())
            blocked(CaptureBlocked.CAPACITY) { journal.reserveRecord(PRODUCER, record(2)) }
            blocked(CaptureBlocked.CAPACITY) { journal.reserveRecord(PRODUCER.copy(producerId = UUID.randomUUID()), record(0)) }
            val sealed = journal.sealRecords(first)
            assertEquals(usage, f.pool.usage())
            assertEquals(2, f.pool.inFlightReservationCount())
            journal.commit(sealed)
            assertEquals(usage, f.pool.usage())
            assertEquals(0, f.pool.inFlightReservationCount())
        }
    }

    @Test fun legacyAndRecordReservationsShareTheSameCompletionBudget() = runBlocking {
        Fixture(CaptureLimits(inFlightReservations = 3)).use { f ->
            val journal = f.journal()
            val legacy = journal.reserveBatch(batch(listOf(record(0), record(1))))
            val admitted = journal.reserveRecord(PRODUCER, record(2))
            journal.reserveRecord(PRODUCER, record(3))
            assertEquals(2, f.pool.inFlightUsage().resources)
            assertEquals(3, f.pool.inFlightReservationCount())
            blocked(CaptureBlocked.CAPACITY) { journal.reserveBatch(batch()) }
            blocked(CaptureBlocked.CAPACITY) { journal.reserveRecord(PRODUCER, record(4)) }
            journal.sealRecords(admitted)
            assertEquals(3, f.pool.inFlightReservationCount())
            journal.commit(legacy)
            assertEquals(2, f.pool.inFlightReservationCount())
            journal.reserveRecord(PRODUCER, record(4))
            assertEquals(3, f.pool.inFlightReservationCount())
        }
    }

    @Test fun memberLimitRejectsAtomicallyAndStillAllowsASmallerRecord() = runBlocking {
        Fixture(CaptureLimits(members = 3)).use { f ->
            val journal = f.journal()
            val first = journal.reserveRecord(PRODUCER, record(0, true))
            val usage = f.pool.usage()
            blocked(CaptureBlocked.CAPACITY) { journal.reserveRecord(PRODUCER, record(1, true)) }
            assertEquals(usage, f.pool.usage())
            assertEquals(1, f.pool.inFlightReservationCount())
            val next = journal.reserveRecord(PRODUCER, record(1))
            assertEquals(first.captureId, next.captureId)
            assertEquals(3, journal.commit(journal.sealRecords(first)).resource.memberCount)
        }
    }

    @Test fun completionLimitIsGlobalAcrossAccountsAndSealingDoesNotReleaseIt() = runBlocking {
        Fixture(CaptureLimits(inFlightReservations = 2)).use { f ->
            val a = f.journal(); val b = f.journal(owner = OTHER)
            val first = a.reserveRecord(PRODUCER, record(0))
            val second = b.reserveRecord(PRODUCER, record(0))
            val usage = f.pool.usage()
            blocked(CaptureBlocked.CAPACITY) { a.reserveRecord(PRODUCER, record(1)) }
            assertEquals(usage, f.pool.usage())
            val sealed = a.sealRecords(first)
            blocked(CaptureBlocked.CAPACITY) { b.reserveRecord(PRODUCER, record(1)) }
            assertEquals(2, f.pool.inFlightReservationCount())
            a.commit(sealed)
            assertEquals(1, f.pool.inFlightReservationCount())
            assertEquals(second.captureId, b.reserveRecord(PRODUCER, record(1)).captureId)
            assertEquals(2, f.pool.inFlightReservationCount())
        }
    }

    @Test fun oneRecordCannotExceedTheBatchMemberCeiling() = runBlocking {
        Fixture(CaptureLimits(batchMembers = 1)).use { f ->
            val journal = f.journal()
            blocked(CaptureBlocked.CAPACITY) { journal.reserveRecord(PRODUCER, record(0, true)) }
            assertEquals(CaptureUsage(0, 0, 0), f.pool.usage())
            assertEquals(0, f.pool.inFlightReservationCount())
        }
    }

    @Test fun fullGlobalResourceQuotaStillAllowsAppendingWithinReservedResource() = runBlocking {
        Fixture(CaptureLimits(resources = 1)).use { f ->
            val a = f.journal()
            val b = f.journal(owner = OTHER)
            val first = a.reserveRecord(PRODUCER, record(0))
            blocked(CaptureBlocked.CAPACITY) { b.reserveRecord(PRODUCER, record(0)) }
            val second = a.reserveRecord(PRODUCER, record(1))
            assertEquals(first.captureId, second.captureId)
            assertEquals(2, a.commit(a.sealRecords(second)).resource.recordCount)
        }
    }

    @Test fun rejectingAnOversizedRecordDoesNotReserveAnEmptyBatchOrSlot() = runBlocking {
        Fixture(CaptureLimits(batchBytes = 16)).use { f ->
            val journal = f.journal()
            blocked(CaptureBlocked.CAPACITY) { journal.reserveRecord(PRODUCER, record(0)) }
            assertEquals(CaptureUsage(0, 0, 0), f.pool.usage())
            assertEquals(0, f.pool.inFlightReservationCount())
            assertEquals(0, f.folder().listFiles()!!.size)
        }
    }

    @Test fun duplicateOrDecreasingEncounterOrdinalIsRejectedWithoutChangingQuota() = runBlocking {
        Fixture().use { f ->
            val journal = f.journal()
            journal.reserveRecord(PRODUCER, record(10))
            val usage = f.pool.usage()
            for (ordinal in listOf(10, 9)) {
                try { journal.reserveRecord(PRODUCER, record(ordinal)); fail("duplicate/decreasing ordinal") }
                catch (_: IllegalArgumentException) { }
            }
            assertEquals(usage, f.pool.usage())
            assertEquals(1, f.pool.inFlightReservationCount())
        }
    }

    @Test fun recordIdCannotCollideWithLegacyOrAnotherProducerBatch() = runBlocking {
        Fixture().use { f ->
            val id = UUID.randomUUID()
            val journal = f.journal(id = { id })
            val ticket = journal.reserveRecord(PRODUCER, record(0))
            val usage = f.pool.usage()
            blocked(CaptureBlocked.ID_CONFLICT) { journal.reserveBatch(batch()) }
            blocked(CaptureBlocked.ID_CONFLICT) {
                journal.reserveRecord(PRODUCER.copy(deviceId = "other-strap"), record(0))
            }
            assertEquals(usage, f.pool.usage())
            journal.commit(journal.sealRecords(ticket))
            blocked(CaptureBlocked.ID_CONFLICT) { journal.reserveRecord(PRODUCER, record(1)) }
            assertEquals(1, f.pool.usage().resources)
        }
    }

    @Test fun differentDeviceProducerAndFormatNeverShareAnEnvelope() = runBlocking {
        Fixture().use { f ->
            val journal = f.journal()
            val producers = listOf(PRODUCER, PRODUCER.copy(deviceId = "second-strap"),
                PRODUCER.copy(serverDeviceId = UUID.randomUUID()), PRODUCER.copy(producerId = UUID.randomUUID()),
                PRODUCER.copy(format = CaptureFormat.STANDARD_HR_V1))
            val tickets = producers.map { journal.reserveRecord(it, record(0)) }
            assertEquals(producers.size, tickets.map { it.captureId }.distinct().size)
            tickets.zip(producers).forEach { (ticket, producer) ->
                val resource = journal.commit(journal.sealRecords(ticket)).resource
                assertEquals(producer.deviceId, resource.deviceID)
                assertEquals(producer.serverDeviceId.toString(), resource.serverDeviceID)
                assertEquals(producer.producerId.toString(), resource.producerID)
                assertEquals(producer.format.name, resource.format)
            }
        }
    }

    @Test fun ticketCannotSealThroughAnotherOwnerOrNewGeneration() = runBlocking {
        Fixture().use { f ->
            val a = f.journal(); val b = f.journal(owner = OTHER)
            val ticket = a.reserveRecord(PRODUCER, record(0))
            try { b.sealRecords(ticket); fail("foreign owner ticket") } catch (_: IllegalArgumentException) { }
            assertTrue(f.pool.settle(a.beginRetirement()).await().settled)
            val next = f.journal(generation = UUID.randomUUID())
            try { next.sealRecords(ticket); fail("foreign generation ticket") } catch (_: IllegalArgumentException) { }
            assertEquals(GENERATION.toString(), next.recoverPage().single().resource.generation)
        }
    }

    @Test fun retirementSealsUnsealedRecordsAndRejectsUnusedBatchCapacity() = runBlocking {
        Fixture().use { f ->
            val journal = f.journal()
            val reserved = journal.reserveRecord(PRODUCER, record(0))
            val ticket = journal.beginRetirement()
            assertSame(ticket, journal.beginRetirement())
            blocked(CaptureBlocked.STALE) { journal.reserveRecord(PRODUCER, record(1)) }
            val report = f.pool.settle(ticket).await()
            assertTrue(report.settled)
            assertEquals(listOf(reserved.captureId), report.durableCaptureIds)
            blocked(CaptureBlocked.STALE) { journal.reserveRecord(PRODUCER, record(1)) }
        }
    }

    @Test fun samePathRemainsHeldUntilRecordDebtIsPublished() = runBlocking {
        Fixture().use { f ->
            val journal = f.journal()
            val admitted = journal.reserveRecord(PRODUCER, record(0))
            val ticket = journal.beginRetirement()
            blocked(CaptureBlocked.SAME_PATH_BUSY) { f.journal(generation = UUID.randomUUID()) }
            val report = f.pool.settle(ticket).await()
            assertEquals(listOf(admitted.captureId), report.durableCaptureIds)
            assertTrue(report.settled)
            val next = f.journal(generation = UUID.randomUUID())
            assertEquals(admitted.captureId, next.recoverPage().single().resource.captureId)
        }
    }

    @Test fun faultedRecordBatchKeepsCompletionSlotsWhileLegacyAndOtherBatchesSettle() = runBlocking {
        Fixture().use { f ->
            val journal = f.journal()
            val first = journal.reserveRecord(PRODUCER, record(0))
            journal.reserveRecord(PRODUCER, record(1))
            val second = journal.reserveRecord(PRODUCER.copy(producerId = UUID.randomUUID()), record(2))
            val legacy = journal.reserveBatch(batch())
            val writes = AtomicInteger()
            f.fault = { if (it == CaptureFilePoint.BEFORE_WRITE && writes.incrementAndGet() == 1) throw IOException("synthetic") }
            val ticket = journal.beginRetirement()
            val report = f.pool.settle(ticket).await()
            assertEquals(listOf(first.captureId), report.unsettledCaptureIds)
            assertEquals(setOf(second.captureId, legacy.captureId), report.durableCaptureIds.toSet())
            assertEquals(2, f.pool.inFlightReservationCount())
            assertEquals(1, f.pool.inFlightUsage().resources)
            f.fault = {}
            assertTrue(f.pool.settle(ticket).await().settled)
            assertEquals(0, f.pool.inFlightReservationCount())
            assertEquals(3, f.folder().listFiles()!!.size)
        }
    }

    @Test fun postFileSyncFailureIsNotPublicationAndRetriesTheIdenticalReservation() = runBlocking {
        Fixture().use { f ->
            val journal = f.journal()
            val ticket = journal.reserveRecord(PRODUCER, record(0))
            val sealed = journal.sealRecords(ticket)
            f.fault = { if (it == CaptureFilePoint.AFTER_FILE_SYNC) throw IOException("synthetic") }
            try { journal.commit(sealed); fail("publication must fail") } catch (_: IOException) { }
            assertEquals(1, f.pool.inFlightReservationCount())
            assertEquals(listOf("${ticket.captureId}.pending"), f.folder().listFiles()!!.map { it.name })
            blocked(CaptureBlocked.STORAGE) { journal.reserveRecord(PRODUCER, record(1)) }
            val pendingBytes = File(f.folder(), "${ticket.captureId}.pending").readBytes()
            f.fault = {}
            assertSame(sealed, journal.sealRecords(ticket))
            val result = journal.commit(sealed)
            assertEquals(ticket.captureId, result.resource.captureId)
            assertArrayEquals(pendingBytes, File(f.folder(), "${ticket.captureId}.ncap").readBytes())
            assertEquals(0, f.pool.inFlightReservationCount())
        }
    }

    @Test fun recordAdmissionDoesNotWaitForNamespaceOrDiskIoAlreadyInFlight() = runBlocking {
        Fixture().use { f ->
            val journal = f.journal()
            val legacy = journal.reserveBatch(batch())
            val entered = CountDownLatch(1); val release = CountDownLatch(1)
            f.fault = { if (it == CaptureFilePoint.BEFORE_WRITE) { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) } }
            val committing = async(Dispatchers.Default) { journal.commit(legacy) }
            try {
                assertTrue(entered.await(10, TimeUnit.SECONDS))
                val ticket = journal.reserveRecord(PRODUCER, record(2))
                assertEquals(0, ticket.recordOrdinal)
                assertEquals(2, f.pool.inFlightReservationCount())
            } finally { release.countDown() }
            committing.await()
            assertEquals(1, f.pool.inFlightReservationCount())
        }
    }

    @Test fun cancelledQueuedSealingLeavesAdmittedBytesForRetirement() = runBlocking {
        Fixture().use { f ->
            val journal = f.journal()
            val legacy = journal.reserveBatch(batch())
            val entered = CountDownLatch(1); val release = CountDownLatch(1)
            f.fault = { if (it == CaptureFilePoint.BEFORE_WRITE) { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) } }
            val committing = async(Dispatchers.Default) { journal.commit(legacy) }
            val first = journal.reserveRecord(PRODUCER, record(1))
            try {
                assertTrue(entered.await(10, TimeUnit.SECONDS))
                val sealing = async(start = CoroutineStart.UNDISPATCHED) { journal.sealRecords(first) }
                sealing.cancelAndJoin()
                val second = journal.reserveRecord(PRODUCER, record(2))
                assertNotEquals(first.captureId, second.captureId)
                journal.beginRetirement()
            } finally { release.countDown() }
            committing.await()
            assertTrue(f.pool.settle(journal.beginRetirement()).await().settled)
            assertEquals(3, f.folder().listFiles()!!.size)
        }
    }

    @Test fun revocationLinearizesWithRecordAdmissionNotWithLaterSealing() = runBlocking {
        Fixture().use { f ->
            val admission = Admission()
            val journal = f.journal(admission)
            val entered = CountDownLatch(1); val release = CountDownLatch(1)
            val revoked = CountDownLatch(1)
            val revokeAttempted = CountDownLatch(1)
            admission.admitted = { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
            val admitting = async(Dispatchers.Default) { journal.reserveRecord(PRODUCER, record(0)) }
            assertTrue(entered.await(10, TimeUnit.SECONDS))
            val revoking = async(Dispatchers.Default) { revokeAttempted.countDown(); admission.revoke(); revoked.countDown() }
            try {
                assertTrue(revokeAttempted.await(10, TimeUnit.SECONDS))
                assertFalse(revoked.await(50, TimeUnit.MILLISECONDS))
            }
            finally { release.countDown() }
            val admitted = admitting.await()
            revoking.await()
            blocked(CaptureBlocked.STALE) { journal.reserveRecord(PRODUCER, record(1)) }
            val durable = journal.commit(journal.sealRecords(admitted))
            assertEquals(1, durable.resource.recordCount)
        }
    }

    @Test fun reopenedPoolRetainsRecordEnvelopeIdentityAndQuotaWithoutTickets() = runBlocking {
        val first = Fixture()
        val journal = first.journal()
        val ticket = journal.reserveRecord(PRODUCER, record(0, true))
        journal.reserveRecord(PRODUCER, record(1, true))
        val durable = journal.commit(journal.sealRecords(ticket))
        val usage = first.pool.usage()
        val root = first.root
        first.close()
        Fixture(root = root).use { reopened ->
            val next = reopened.journal(generation = UUID.randomUUID())
            val restored = next.recoverPage().single()
            assertEquals(durable.resource, restored.resource)
            assertEquals(durable.members, restored.members)
            assertArrayEquals(durable.payload(1), restored.payload(1))
            assertEquals(usage, reopened.pool.usage())
            assertEquals(0, reopened.pool.inFlightReservationCount())
        }
    }

    private suspend fun publishedBytes(count: Int): Long = Fixture().use { f ->
        val journal = f.journal()
        journal.commit(journal.reserveBatch(batch(List(count) { record(it) }))).resource.fileBytes
    }

    companion object {
        private val OWNER = CaptureOwner(AccountScope.create("https://capture.example.test", "10000000-0000-4000-8000-000000000001"), UUID.fromString("30000000-0000-4000-8000-000000000001"))
        private val OTHER = CaptureOwner(AccountScope.create("https://capture.example.test", "10000000-0000-4000-8000-000000000002"), UUID.fromString("30000000-0000-4000-8000-000000000002"))
        private val GENERATION = UUID.fromString("40000000-0000-4000-8000-000000000001")
        private val PRODUCER = CaptureProducer("synthetic-strap", UUID.fromString("20000000-0000-4000-8000-000000000001"),
            UUID.fromString("50000000-0000-4000-8000-000000000001"), CaptureFormat.WHOOP_FRAME_V1)
        private fun record(ordinal: Int, twoRoutes: Boolean = false) = CaptureRecord(ordinal.toLong(), 1_000,
            byteArrayOf(ordinal.toByte(), 1), buildList {
                add(CaptureRoute(CaptureNamespace.IMU_BOUNDED, "bounded-session", 0))
                if (twoRoutes) add(CaptureRoute(CaptureNamespace.IMU_CONTINUOUS, "continuous-session", 0))
            })
        private fun batch(records: List<CaptureRecord> = listOf(record(0))) = CaptureBatch(PRODUCER.deviceId,
            PRODUCER.serverDeviceId, PRODUCER.producerId, PRODUCER.format, records)
    }
}
