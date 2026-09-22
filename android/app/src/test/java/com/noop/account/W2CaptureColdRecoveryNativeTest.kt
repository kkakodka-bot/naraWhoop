package com.noop.account

import com.noop.push.AccountScope
import java.io.File
import java.nio.file.Files
import java.security.Permission
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class W2CaptureColdRecoveryNativeTest {
    private class Admission : CaptureAdmission {
        var current = true
        override fun <T> withCurrent(block: () -> T): T {
            if (!current) throw CaptureBlockedException(CaptureBlocked.STALE)
            return block()
        }
    }

    private class Access : CaptureNamespaceAccess {
        var after: () -> Unit = {}
        override fun <T> withLock(scope: AccountScope, block: () -> T): T = block().also { after() }
    }

    private class Cold(
        val limits: CaptureLimits = CaptureLimits(),
        haltPoint: CaptureFilePoint = CaptureFilePoint.AFTER_FILE_SYNC,
    ) : AutoCloseable {
        val root = Files.createTempDirectory("capture-cold-").toFile()
        val accounts = File(root, "accounts-v1")
        val access = Access()
        var pool: CaptureRetirement? = null
        private val journals = mutableListOf<AccountCaptureJournal>()
        init {
            val process = ProcessBuilder(File(System.getProperty("java.home"), "bin/java").path,
                "-cp", System.getProperty("java.class.path"), CaptureColdProcess::class.java.name, root.path, haltPoint.name)
                .redirectErrorStream(true).redirectOutput(File(root, "producer.log")).start()
            check(process.waitFor(20, TimeUnit.SECONDS)) { "cold producer timeout" }
            check(process.exitValue() == 86) { File(root, "producer.log").readText() }
            if (haltPoint == CaptureFilePoint.AFTER_RENAME) {
                check(file(PENDING).isFile)
                check(!file(PENDING, "pending").exists())
            } else {
                check(file(PENDING, "pending").isFile)
                check(!file(PENDING).exists())
            }
        }
        fun folder(owner: CaptureOwner = OWNER) = File(File(accounts, owner.scope.namespace), "capture-v1")
        fun file(id: UUID, suffix: String = "ncap", owner: CaptureOwner = OWNER) = File(folder(owner), "$id.$suffix")
        suspend fun journal(admission: Admission = Admission(), owner: CaptureOwner = OWNER): AccountCaptureJournal {
            if (pool == null) pool = CaptureRetirement.openForRecovery(accounts, access, limits)
            return AccountCaptureJournal.open(pool!!, owner, UUID.randomUUID(), admission).also { journals += it }
        }
        override fun close() = runBlocking {
            access.after = {}
            journals.forEach { assertTrue(pool!!.settle(it.beginRetirement()).await().settled) }
            journals.clear()
            pool?.close()
            Unit
        }
    }

    private suspend fun pages(journal: AccountCaptureJournal, limit: Int = 32): List<CaptureRecoveryPage> =
        journal.openRecovery().use { reader ->
            buildList {
                do {
                    val page = reader.nextPage(limit)
                    assertTrue(page.inspectedEntries <= limit)
                    assertTrue(page.verified.size <= 1)
                    assertTrue(page.inventoryIncomplete)
                    assertTrue(page.admissionPaused)
                    add(page)
                    check(size < 10_000)
                } while (!page.traversalExhausted)
            }
        }

    private suspend fun blocked(reason: CaptureBlocked, body: suspend () -> Unit) {
        try { body(); fail("expected $reason") }
        catch (failure: CaptureBlockedException) { assertEquals(reason, failure.reason) }
    }

    private suspend fun assertHeldWithHealthy(f: Cold, issue: CaptureRecoveryIssue, name: String) {
        val result = pages(f.journal())
        assertTrue(result.flatMap { it.retained }.any { it.entryName == name && it.issue == issue })
        assertTrue(result.flatMap { it.verified }.any { it.resource.captureId == FIRST.toString() })
        val other = pages(f.journal(owner = OTHER)).flatMap { it.verified }
        assertEquals(setOf(THIRD.toString()), other.map { it.resource.captureId }.toSet())
        assertTrue(other.all { it.owner == OTHER })
    }

    @Test fun killedProducerCompletePendingRecoversExactIdentityBytesRoutesAndGeneration() = runBlocking {
        Cold().use { f ->
            val bytes = f.file(PENDING, "pending").readBytes()
            val expected = AccountCaptureJournal.readFile(f.file(PENDING, "pending"), f.limits)
            val result = pages(f.journal(), 1).flatMap { it.verified }
            val recovered = result.first { it.resource.captureId == PENDING.toString() }
            assertEquals(expected.owner, recovered.owner)
            assertEquals(expected.resource, recovered.resource)
            assertEquals(expected.members, recovered.members)
            assertEquals(GENERATION.toString(), recovered.resource.generation)
            assertArrayEquals(byteArrayOf(4, 8, 12), recovered.payload(0))
            assertArrayEquals(bytes, f.file(PENDING).readBytes())
            assertFalse(f.file(PENDING, "pending").exists())
            assertEquals(0, f.pool!!.inFlightReservationCount())
        }
    }

    private fun torn(keep: (ByteArray) -> ByteArray) = runBlocking {
        Cold().use { f ->
            val file = f.file(PENDING, "pending")
            val damaged = keep(file.readBytes())
            file.writeBytes(damaged)
            assertHeldWithHealthy(f, CaptureRecoveryIssue.CORRUPT, file.name)
            assertArrayEquals(damaged, file.readBytes())
            assertFalse(f.file(PENDING).exists())
        }
    }

    @Test fun tornHeaderDoesNotPoisonEitherAccount() = torn { it.copyOf(7) }
    @Test fun tornPayloadDoesNotPoisonEitherAccount() = torn { it.copyOf(it.size - 34) }
    @Test fun corruptTrailerDoesNotPoisonEitherAccount() = torn { it.also { b -> b[b.lastIndex] = (b.last() + 1).toByte() } }
    @Test fun emptyPendingIsRetainedWithoutReconstructingLostRam() = torn { byteArrayOf() }

    @Test fun unknownFilenameIsRetainedWithoutTreatingValidBodyAsAuthority() = runBlocking {
        Cold().use { f ->
            val unknown = File(f.folder(), "not-a-capture.payload")
            val original = f.file(FIRST).readBytes()
            unknown.writeBytes(original)
            assertHeldWithHealthy(f, CaptureRecoveryIssue.UNKNOWN_NAME, unknown.name)
            assertArrayEquals(original, unknown.readBytes())
        }
    }

    private fun duplicate(different: Boolean) = runBlocking {
        Cold().use { f ->
            val staged = f.file(SECOND, "pending")
            val bytes = if (different) byteArrayOf(9, 1) else f.file(SECOND).readBytes()
            staged.writeBytes(bytes)
            val committed = f.file(SECOND).readBytes()
            val result = pages(f.journal(), 1)
            assertEquals(2, result.flatMap { it.retained }.count { it.issue == CaptureRecoveryIssue.DUPLICATE_ID })
            assertFalse(result.flatMap { it.verified }.any { it.resource.captureId == SECOND.toString() })
            assertTrue(result.flatMap { it.verified }.any { it.resource.captureId == FIRST.toString() })
            assertArrayEquals(bytes, staged.readBytes())
            assertArrayEquals(committed, f.file(SECOND).readBytes())
        }
    }

    @Test fun identicalDuplicatePairIsConflictNotEnumerationPreference() = duplicate(false)
    @Test fun differingDuplicatePairIsConflictAndBothOriginalsRemain() = duplicate(true)

    @Test fun symlinkPayloadIsNeverOpenedOrRenamed() = runBlocking {
        Cold().use { f ->
            val outside = File(f.root, "outside-synthetic.ncap")
            val original = f.file(SECOND).readBytes()
            outside.writeBytes(original)
            Files.delete(f.file(SECOND).toPath())
            Files.createSymbolicLink(f.file(SECOND).toPath(), outside.toPath())
            assertHeldWithHealthy(f, CaptureRecoveryIssue.UNSAFE_PATH, f.file(SECOND).name)
            assertTrue(Files.isSymbolicLink(f.file(SECOND).toPath()))
            assertArrayEquals(original, outside.readBytes())
        }
    }

    @Test fun brokenSymlinkDoesNotDisappearFromRetainedDiagnostics() = runBlocking {
        Cold().use { f ->
            val link = File(f.folder(), "unknown.pending")
            Files.createSymbolicLink(link.toPath(), File(f.root, "absent-synthetic").toPath())
            assertHeldWithHealthy(f, CaptureRecoveryIssue.UNSAFE_PATH, link.name)
            assertTrue(Files.isSymbolicLink(link.toPath()))
        }
    }

    @Test fun directoryNamedLikeEnvelopeIsNotTraversed() = runBlocking {
        Cold().use { f ->
            val directory = File(f.folder(), "60000000-0000-4000-8000-000000000009.pending")
            assertTrue(directory.mkdir())
            File(directory, "retained").writeBytes(byteArrayOf(11))
            assertHeldWithHealthy(f, CaptureRecoveryIssue.UNSAFE_PATH, directory.name)
            assertArrayEquals(byteArrayOf(11), File(directory, "retained").readBytes())
        }
    }

    @Test fun unreadableFileDoesNotPoisonHealthySiblings() = runBlocking {
        Cold().use { f ->
            val path = f.file(SECOND).toPath()
            val original = Files.readAllBytes(path)
            val permissions = Files.getPosixFilePermissions(path)
            Files.setPosixFilePermissions(path, emptySet())
            try {
                assertFalse("native fixture must actually deny reads", Files.isReadable(path))
                assertHeldWithHealthy(f, CaptureRecoveryIssue.UNREADABLE, path.fileName.toString())
            } finally { Files.setPosixFilePermissions(path, permissions) }
            assertArrayEquals(original, Files.readAllBytes(path))
        }
    }

    @Test fun unreadableDirectoryHasVisibleIncompleteResultAndOtherAccountProgresses() = runBlocking {
        Cold().use { f ->
            val journal = f.journal()
            val path = f.folder().toPath()
            val permissions = Files.getPosixFilePermissions(path)
            Files.setPosixFilePermissions(path, emptySet())
            try {
                val result = pages(journal)
                assertTrue(result.flatMap { it.verified }.isEmpty())
                assertTrue(result.flatMap { it.retained }.any { it.issue == CaptureRecoveryIssue.UNREADABLE })
                assertEquals(1, pages(f.journal(owner = OTHER)).flatMap { it.verified }.size)
            } finally { Files.setPosixFilePermissions(path, permissions) }
        }
    }

    @Test fun accountDirectoryReplacedWithSymlinkIsNotFollowed() = runBlocking {
        Cold().use { f ->
            val journal = f.journal()
            val account = f.folder().parentFile
            val moved = File(f.root, "retained-account")
            Files.move(account.toPath(), moved.toPath())
            Files.createSymbolicLink(account.toPath(), moved.toPath())
            val result = pages(journal)
            assertTrue(result.flatMap { it.verified }.isEmpty())
            assertTrue(result.flatMap { it.retained }.any { it.issue == CaptureRecoveryIssue.UNSAFE_PATH })
            assertTrue(File(moved, "capture-v1/$PENDING.pending").exists())
        }
    }

    @Test fun wrongOwnerBodyIsRetainedWithoutReturningForeignOwner() = runBlocking {
        Cold().use { f ->
            val wrong = f.file(THIRD)
            wrong.writeBytes(f.file(THIRD, owner = OTHER).readBytes())
            assertHeldWithHealthy(f, CaptureRecoveryIssue.OWNER_MISMATCH, wrong.name)
        }
    }

    @Test fun sameAccountDifferentSourceCannotFinalizeOldSource() = runBlocking {
        Cold().use { f ->
            val result = pages(f.journal(owner = OWNER.copy(sourceId = UUID.randomUUID())))
            assertTrue(result.flatMap { it.verified }.isEmpty())
            assertEquals(3, result.flatMap { it.retained }.count { it.issue == CaptureRecoveryIssue.OWNER_MISMATCH })
            assertTrue(f.file(PENDING, "pending").exists())
            assertFalse(f.file(PENDING).exists())
        }
    }

    @Test fun validBodyUnderDifferentUuidDoesNotChangeResourceIdentity() = runBlocking {
        Cold().use { f ->
            val wrong = f.file(UUID.randomUUID(), "pending")
            val original = f.file(FIRST).readBytes()
            wrong.writeBytes(original)
            assertHeldWithHealthy(f, CaptureRecoveryIssue.ID_MISMATCH, wrong.name)
            assertArrayEquals(original, wrong.readBytes())
        }
    }

    @Test fun fullEveryDataBudgetStillAllowsVerifiedRecoveryWithNoCompletionSlots() = runBlocking {
        Cold(CaptureLimits(payloadBytes = 1, resources = 1, members = 1, inFlightBytes = 1, inFlightReservations = 1)).use { f ->
            val journal = f.journal()
            val status = f.pool!!.recoveryStatus()!!
            assertTrue(status.observedCharge.fileBytes > 1)
            assertTrue(status.observedCharge.resources > 1)
            assertTrue(status.observedCharge.members > 1)
            blocked(CaptureBlocked.RECOVERY_ONLY) { journal.reserveRecord(PRODUCER, RECORD) }
            blocked(CaptureBlocked.RECOVERY_ONLY) { journal.reserveBatch(BATCH) }
            assertEquals(setOf(FIRST.toString(), SECOND.toString(), PENDING.toString()),
                pages(journal).flatMap { it.verified }.map { it.resource.captureId }.toSet())
            assertEquals(0, f.pool!!.inFlightReservationCount())
            assertTrue(f.pool!!.recoveryStatus()!!.admissionPaused)
        }
    }

    @Test fun startupChargesUnknownFilesConservativelyWithoutParsingTheirHeaders() = runBlocking {
        Cold().use { f ->
            val torn = f.file(PENDING, "pending")
            torn.writeBytes(byteArrayOf(0))
            f.journal()
            val status = f.pool!!.recoveryStatus()!!
            assertEquals(4, status.observedCharge.resources)
            assertEquals(4L * f.limits.batchMembers, status.observedCharge.members)
            assertEquals(f.folder().listFiles()!!.sumOf { it.length() } + f.folder(OTHER).listFiles()!!.sumOf { it.length() },
                status.observedCharge.fileBytes)
            assertTrue(status.inventoryIncomplete)
        }
    }

    @Test fun paginationBoundsWorkAndNeverTurnsExhaustionIntoFullInventory() = runBlocking {
        Cold().use { f ->
            repeat(130) { File(f.folder(), "unknown-$it").writeBytes(byteArrayOf(it.toByte())) }
            val result = pages(f.journal(), 2)
            assertTrue(result.size >= 67)
            assertEquals(130, result.flatMap { it.retained }.count { it.issue == CaptureRecoveryIssue.UNKNOWN_NAME })
            assertTrue(result.last().traversalExhausted)
            assertTrue(result.all { it.inventoryIncomplete && it.admissionPaused })
        }
    }

    @Test fun startupObservationCapDoesNotPreventWalkingHealthyEntriesBeyondIt() = runBlocking {
        Cold().use { f ->
            repeat(8_210) { File(f.folder(), "unknown-$it").writeBytes(byteArrayOf()) }
            val journal = f.journal()
            val status = f.pool!!.recoveryStatus()!!
            assertEquals(8_192, status.inspectedEntries)
            assertTrue(status.observationLimitReached)
            assertTrue(status.inventoryIncomplete)
            val result = pages(journal, 64)
            assertEquals(8_210, result.flatMap { it.retained }.count { it.issue == CaptureRecoveryIssue.UNKNOWN_NAME })
            assertEquals(setOf(FIRST.toString(), SECOND.toString(), PENDING.toString()),
                result.flatMap { it.verified }.map { it.resource.captureId }.toSet())
        }
    }

    @Test fun revokedGenerationCannotOpenOrContinueReader() = runBlocking {
        Cold().use { f ->
            val admission = Admission()
            val journal = f.journal(admission)
            val reader = journal.openRecovery()
            admission.current = false
            blocked(CaptureBlocked.STALE) { reader.nextPage() }
            blocked(CaptureBlocked.STALE) { journal.openRecovery() }
            reader.close()
        }
    }

    @Test fun revokeAfterIoPreventsReturningPageEvenWhenFinalizationAlreadyCompleted() = runBlocking {
        Cold().use { f ->
            val admission = Admission()
            val journal = f.journal(admission)
            journal.openRecovery().use { reader ->
                f.access.after = { admission.current = false }
                blocked(CaptureBlocked.STALE) { reader.nextPage() }
            }
        }
    }

    @Test fun retiredJournalReaderCannotBeBorrowedBySameAccountNewGeneration() = runBlocking {
        Cold().use { f ->
            val old = f.journal()
            old.openRecovery().use { reader ->
                assertTrue(f.pool!!.settle(old.beginRetirement()).await().settled)
                val next = f.journal()
                blocked(CaptureBlocked.STALE) { reader.nextPage() }
                assertTrue(pages(next).flatMap { it.verified }.isNotEmpty())
            }
        }
    }

    @Test fun concurrentMutationNeverProducesCompleteInventoryAndFreshPassFindsNewEntry() = runBlocking {
        Cold().use { f ->
            val journal = f.journal()
            journal.openRecovery().use { reader ->
                reader.nextPage(1)
                File(f.folder(), "added-while-paginating").writeBytes(byteArrayOf(8))
                val next = reader.nextPage(1)
                assertTrue(next.inventoryIncomplete)
                assertTrue(next.traversalChanged)
            }
            assertTrue(pages(journal).flatMap { it.retained }.any { it.entryName == "added-while-paginating" })
        }
    }

    @Test fun readerLimitIsIndependentOfDataCapacityAndCloseReleasesIt() = runBlocking {
        Cold(CaptureLimits(retainedDrains = 1)).use { f ->
            val journal = f.journal()
            journal.openRecovery().use {
                blocked(CaptureBlocked.SAME_PATH_BUSY) { journal.openRecovery() }
            }
            assertTrue(pages(journal).flatMap { it.verified }.isNotEmpty())
        }
    }

    @Test fun strictDefaultStillRejectsTornFileRatherThanSilentlyOmittingIt() = runBlocking {
        Cold().use { f ->
            f.file(PENDING, "pending").writeBytes(byteArrayOf(0))
            blocked(CaptureBlocked.CORRUPT) { CaptureRetirement.open(f.accounts, f.access).close() }
            assertHeldWithHealthy(f, CaptureRecoveryIssue.CORRUPT, f.file(PENDING, "pending").name)
        }
    }

    @Test fun oldStrictRecoveryRemainsStrictInsideRecoveryOnlyPool() = runBlocking {
        Cold().use { f ->
            File(f.folder(), "unknown").writeBytes(byteArrayOf(2))
            val journal = f.journal()
            try { journal.recoverPage(); fail("strict facade ignored unknown") } catch (_: IllegalArgumentException) { }
            assertTrue(pages(journal).flatMap { it.verified }.isNotEmpty())
        }
    }

    @Test fun boundedPageRejectsInvalidLimitsWithoutMutatingFiles() = runBlocking {
        Cold().use { f ->
            f.journal().openRecovery().use { reader ->
                for (limit in listOf(0, 65, Int.MAX_VALUE)) {
                    try { reader.nextPage(limit); fail("invalid limit") } catch (_: IllegalArgumentException) { }
                }
                assertTrue(f.file(PENDING, "pending").exists())
                assertTrue(reader.nextPage(1).inspectedEntries <= 1)
            }
        }
    }

    /** Native JVM fault injection into actual FileChannel opens, reset after every test. */
    @Suppress("DEPRECATION", "removal")
    private class BarrierFault(private val folder: File, private val id: UUID) : SecurityManager() {
        var failDirectory = false
        var failFile = false
        val directoryAttempts = AtomicInteger()
        val fileAttempts = AtomicInteger()
        private val selectedFile = ThreadLocal<Boolean>()
        override fun checkPermission(permission: Permission) = Unit
        override fun checkRead(file: String) {
            if (Thread.currentThread().stackTrace.none {
                it.className == "java.nio.channels.FileChannel" && it.methodName == "open"
            }) return
            if (file == folder.path) {
                if (selectedFile.get() == true) {
                    directoryAttempts.incrementAndGet()
                    if (failDirectory) throw SecurityException("synthetic directory-sync channel failure")
                }
            } else {
                val selected = file == File(folder, "$id.pending").path || file == File(folder, "$id.ncap").path
                selectedFile.set(selected)
                if (selected) {
                    fileAttempts.incrementAndGet()
                    if (failFile) throw SecurityException("synthetic exact-file-sync channel failure")
                }
            }
        }
    }

    @Suppress("DEPRECATION", "removal")
    @Test fun failedPostRenameBarrierStaysHeldAcrossPoolReopenUntilExactSuccessfulRetry() = runBlocking {
        Cold().use { f ->
            val pending = f.file(PENDING, "pending")
            val original = pending.readBytes()
            val expected = AccountCaptureJournal.readFile(pending, f.limits)
            val first = f.journal()
            val previous = System.getSecurityManager()
            val fault = BarrierFault(f.folder(), PENDING).also { it.failDirectory = true }
            try {
                System.setSecurityManager(fault)
                val initial = pages(first, 1)
                assertTrue(initial.flatMap { it.retained }.any {
                    it.entryName == pending.name && it.issue == CaptureRecoveryIssue.FINALIZATION_FAILED
                })
                assertFalse(initial.flatMap { it.verified }.any { it.resource.captureId == PENDING.toString() })
                assertEquals(setOf(FIRST.toString(), SECOND.toString()),
                    initial.flatMap { it.verified }.map { it.resource.captureId }.toSet())
                assertFalse(pending.exists())
                assertArrayEquals(original, f.file(PENDING).readBytes())
                assertEquals(1, pages(f.journal(owner = OTHER)).flatMap { it.verified }.size)
            } finally { System.setSecurityManager(previous) }
            // Destroy the entire pool as well as the reader: an in-memory debt flag cannot pass this.
            f.close()
            f.pool = null
            val reopened = f.journal()
            val attempts = fault.directoryAttempts.get()
            try {
                System.setSecurityManager(fault)
                val stillFailed = pages(reopened, 1)
                assertTrue(stillFailed.flatMap { it.retained }.any {
                    it.entryName == f.file(PENDING).name && it.issue == CaptureRecoveryIssue.FINALIZATION_FAILED
                })
                assertFalse(stillFailed.flatMap { it.verified }.any { it.resource.captureId == PENDING.toString() })
                assertTrue("reopen must retry the directory barrier", fault.directoryAttempts.get() > attempts)
                assertArrayEquals(original, f.file(PENDING).readBytes())
                fault.failDirectory = false
                val beforeSuccess = fault.directoryAttempts.get()
                val recovered = pages(reopened, 1).flatMap { it.verified }.first { it.resource.captureId == PENDING.toString() }
                assertTrue(fault.directoryAttempts.get() > beforeSuccess)
                assertEquals(expected.owner, recovered.owner)
                assertEquals(expected.resource, recovered.resource)
                assertEquals(expected.members, recovered.members)
                assertArrayEquals(expected.payload(0), recovered.payload(0))
                assertArrayEquals(original, f.file(PENDING).readBytes())
            } finally { System.setSecurityManager(previous) }
        }
    }

    @Suppress("DEPRECATION", "removal")
    @Test fun separateProducerHaltAfterRenameNeedsBothBarriersBeforeEligibility() = runBlocking {
        Cold(haltPoint = CaptureFilePoint.AFTER_RENAME).use { f ->
            val original = f.file(PENDING).readBytes()
            val expected = AccountCaptureJournal.readFile(f.file(PENDING), f.limits)
            val journal = f.journal()
            val previous = System.getSecurityManager()
            val fault = BarrierFault(f.folder(), PENDING).also { it.failDirectory = true }
            try {
                System.setSecurityManager(fault)
                val failed = pages(journal)
                assertTrue(failed.flatMap { it.retained }.any {
                    it.entryName == f.file(PENDING).name && it.issue == CaptureRecoveryIssue.FINALIZATION_FAILED
                })
                assertFalse(failed.flatMap { it.verified }.any { it.resource.captureId == PENDING.toString() })
                assertTrue(fault.fileAttempts.get() > 0)
                assertTrue(fault.directoryAttempts.get() > 0)
                fault.failDirectory = false
                val recovered = pages(journal).flatMap { it.verified }.first { it.resource.captureId == PENDING.toString() }
                assertEquals(expected.resource, recovered.resource)
                assertEquals(expected.owner, recovered.owner)
                assertEquals(expected.members, recovered.members)
                assertEquals(GENERATION.toString(), recovered.resource.generation)
                assertArrayEquals(original, f.file(PENDING).readBytes())
                assertFalse(f.file(PENDING, "pending").exists())
            } finally { System.setSecurityManager(previous) }
        }
    }

    @Suppress("DEPRECATION", "removal")
    @Test fun ncapFileBarrierFailureRetainsBytesAndHealthySiblingsContinue() = runBlocking {
        Cold().use { f ->
            val original = f.file(SECOND).readBytes()
            val journal = f.journal()
            val previous = System.getSecurityManager()
            val fault = BarrierFault(f.folder(), SECOND).also { it.failFile = true }
            try {
                System.setSecurityManager(fault)
                val failed = pages(journal)
                assertTrue(failed.flatMap { it.retained }.any {
                    it.entryName == f.file(SECOND).name && it.issue == CaptureRecoveryIssue.FINALIZATION_FAILED
                })
                assertFalse(failed.flatMap { it.verified }.any { it.resource.captureId == SECOND.toString() })
                assertTrue(failed.flatMap { it.verified }.any { it.resource.captureId == FIRST.toString() })
                assertTrue(fault.fileAttempts.get() > 0)
                assertEquals(0, fault.directoryAttempts.get())
                assertArrayEquals(original, f.file(SECOND).readBytes())
                fault.failFile = false
                assertTrue(pages(journal).flatMap { it.verified }.any { it.resource.captureId == SECOND.toString() })
                assertTrue(fault.directoryAttempts.get() > 0)
                assertArrayEquals(original, f.file(SECOND).readBytes())
            } finally { System.setSecurityManager(previous) }
        }
    }

    @Test fun cancelledAcquisitionAfterRegistrationReleasesOnlyItsReaderAndPoolCloses() = runBlocking {
        Cold().use { f ->
            val journal = f.journal()
            val other = f.journal(owner = OTHER)
            other.openRecovery().use { survivor ->
                val acquisition = async(start = CoroutineStart.LAZY) { journal.openRecovery() }
                f.access.after = { acquisition.cancel() }
                acquisition.start()
                try { acquisition.await(); fail("expected cancelled acquisition") } catch (_: CancellationException) { }
                f.access.after = {}
                // Cleanup must neither leave the cancelled slot nor clear another reader's registration.
                blocked(CaptureBlocked.SAME_PATH_BUSY) { other.openRecovery() }
                assertTrue(survivor.nextPage().verified.isNotEmpty())
                assertTrue(pages(journal).flatMap { it.verified }.isNotEmpty())
            }
            assertTrue(f.pool!!.settle(journal.beginRetirement()).await().settled)
            assertTrue(f.pool!!.settle(other.beginRetirement()).await().settled)
            f.close()
        }
    }

    @Test fun failedAcquisitionBeforeRegistrationCannotReleaseAnExistingReader() = runBlocking {
        Cold().use { f ->
            val journal = f.journal()
            journal.openRecovery().use { original ->
                repeat(3) { blocked(CaptureBlocked.SAME_PATH_BUSY) { journal.openRecovery() } }
                assertTrue(original.nextPage().verified.isNotEmpty())
                blocked(CaptureBlocked.SAME_PATH_BUSY) { journal.openRecovery() }
            }
            assertTrue(pages(journal).flatMap { it.verified }.isNotEmpty())
        }
    }

    @Test fun revokedAcquisitionAfterRegistrationLeavesNoUnreturnedReader() = runBlocking {
        Cold().use { f ->
            val admission = Admission()
            val old = f.journal(admission)
            f.access.after = { admission.current = false }
            blocked(CaptureBlocked.STALE) { old.openRecovery() }
            f.access.after = {}
            assertTrue(f.pool!!.settle(old.beginRetirement()).await().settled)
            val next = f.journal()
            assertTrue(pages(next).flatMap { it.verified }.isNotEmpty())
        }
    }

    @Suppress("DEPRECATION", "removal")
    @Test fun strictRecoveryFacadeAlsoRequiresNcapDurabilityBarrierOnEveryRetry() = runBlocking {
        Cold(haltPoint = CaptureFilePoint.AFTER_RENAME).use { f ->
            val original = f.file(PENDING).readBytes()
            val journal = f.journal()
            val previous = System.getSecurityManager()
            val fault = BarrierFault(f.folder(), PENDING).also { it.failDirectory = true }
            try {
                System.setSecurityManager(fault)
                repeat(2) {
                    val before = fault.directoryAttempts.get()
                    try { journal.recoverPage(); fail("strict recovery skipped required directory barrier") }
                    catch (_: SecurityException) { }
                    assertTrue(fault.directoryAttempts.get() > before)
                    assertArrayEquals(original, f.file(PENDING).readBytes())
                }
                fault.failDirectory = false
                assertTrue(journal.recoverPage().any { it.resource.captureId == PENDING.toString() })
                assertArrayEquals(original, f.file(PENDING).readBytes())
            } finally { System.setSecurityManager(previous) }
        }
    }

    @Test fun namespaceFailureAfterRegistrationCleansUnreturnedReaderWithoutGlobalReset() = runBlocking {
        Cold().use { f ->
            val journal = f.journal()
            val other = f.journal(owner = OTHER)
            other.openRecovery().use {
                f.access.after = { throw java.io.IOException("synthetic failed namespace handoff") }
                try { journal.openRecovery(); fail("expected failed acquisition") } catch (_: java.io.IOException) { }
                f.access.after = {}
                blocked(CaptureBlocked.SAME_PATH_BUSY) { other.openRecovery() }
                assertTrue(pages(journal).flatMap { it.verified }.isNotEmpty())
            }
        }
    }

    @Suppress("DEPRECATION", "removal")
    private fun strictFilenameMismatch(suffix: String) = runBlocking {
        Cold().use { f ->
            val bodyId = if (suffix == "pending") PENDING else SECOND
            val originalPath = f.file(bodyId, suffix)
            val original = originalPath.readBytes()
            // Sort first so no healthy envelope can hide an attempted barrier for the mismatch.
            val filenameId = UUID.fromString("60000000-0000-4000-8000-000000000000")
            val misplaced = f.file(filenameId, suffix)
            val counterpart = f.file(filenameId, if (suffix == "pending") "ncap" else "pending")
            Files.move(originalPath.toPath(), misplaced.toPath())
            val expected = AccountCaptureJournal.readFile(misplaced, f.limits)
            assertEquals(bodyId.toString(), expected.resource.captureId)
            repeat(2) {
                val journal = f.journal()
                val previous = System.getSecurityManager()
                val fault = BarrierFault(f.folder(), filenameId)
                try {
                    System.setSecurityManager(fault)
                    blocked(CaptureBlocked.CORRUPT) { journal.recoverPage() }
                    assertEquals("mismatched identity must not enter the file barrier", 0, fault.fileAttempts.get())
                    assertEquals("mismatched identity must not enter the directory barrier", 0, fault.directoryAttempts.get())
                } finally { System.setSecurityManager(previous) }
                assertArrayEquals(original, misplaced.readBytes())
                assertFalse(counterpart.exists())
                assertFalse(originalPath.exists())
                val structured = pages(journal, 1)
                assertTrue(structured.flatMap { it.retained }.any {
                    it.entryName == misplaced.name && it.issue == CaptureRecoveryIssue.ID_MISMATCH
                })
                assertFalse(structured.flatMap { it.verified }.any { it.resource.captureId == bodyId.toString() })
                assertTrue(structured.flatMap { it.verified }.any { it.resource.captureId == FIRST.toString() })
                val other = f.journal(owner = OTHER).recoverPage().single()
                assertEquals(OTHER, other.owner)
                assertEquals(THIRD.toString(), other.resource.captureId)
                assertArrayEquals(original, misplaced.readBytes())
                assertFalse(counterpart.exists())
                // Reopen the whole pool: retained bytes, not old RAM, must drive the same rejection.
                f.close()
                f.pool = null
            }
        }
    }

    @Test fun strictPendingFilenameMismatchRejectsBeforeBarrierAndPreservesBytesAcrossReopen() =
        strictFilenameMismatch("pending")

    @Test fun strictNcapFilenameMismatchRejectsBeforeBarrierAndPreservesBytesAcrossReopen() =
        strictFilenameMismatch("ncap")

    @Suppress("DEPRECATION", "removal")
    private fun strictMatchedFilename(haltPoint: CaptureFilePoint, suffix: String) = runBlocking {
        Cold(haltPoint = haltPoint).use { f ->
            val original = f.file(PENDING, suffix).readBytes()
            val expected = AccountCaptureJournal.readFile(f.file(PENDING, suffix), f.limits)
            repeat(2) {
                val journal = f.journal()
                val previous = System.getSecurityManager()
                val fault = BarrierFault(f.folder(), PENDING)
                try {
                    System.setSecurityManager(fault)
                    val recovered = journal.recoverPage().single { it.resource.captureId == PENDING.toString() }
                    assertEquals(expected.owner, recovered.owner)
                    assertEquals(expected.resource, recovered.resource)
                    assertEquals(expected.members, recovered.members)
                    assertArrayEquals(expected.payload(0), recovered.payload(0))
                    assertTrue(fault.fileAttempts.get() > 0)
                    assertTrue(fault.directoryAttempts.get() > 0)
                } finally { System.setSecurityManager(previous) }
                assertArrayEquals(original, f.file(PENDING).readBytes())
                assertFalse(f.file(PENDING, "pending").exists())
                assertEquals("capture-v1/$PENDING.ncap", expected.resource.relativePath)
                f.close()
                f.pool = null
            }
        }
    }

    @Test fun strictMatchedPendingFinalizesExactResourceAndReopensWithoutIdentityChange() =
        strictMatchedFilename(CaptureFilePoint.AFTER_FILE_SYNC, "pending")

    @Test fun strictMatchedNcapRepeatsBothBarriersAndReopensWithoutIdentityChange() =
        strictMatchedFilename(CaptureFilePoint.AFTER_RENAME, "ncap")

    companion object {
        internal val OWNER = CaptureOwner(AccountScope.create("https://capture.example.test", "10000000-0000-4000-8000-000000000001"), UUID.fromString("30000000-0000-4000-8000-000000000001"))
        internal val OTHER = CaptureOwner(AccountScope.create("https://capture.example.test", "10000000-0000-4000-8000-000000000002"), UUID.fromString("30000000-0000-4000-8000-000000000002"))
        internal val GENERATION: UUID = UUID.fromString("40000000-0000-4000-8000-000000000001")
        internal val FIRST: UUID = UUID.fromString("60000000-0000-4000-8000-000000000001")
        internal val SECOND: UUID = UUID.fromString("60000000-0000-4000-8000-000000000002")
        internal val THIRD: UUID = UUID.fromString("60000000-0000-4000-8000-000000000003")
        internal val PENDING: UUID = UUID.fromString("60000000-0000-4000-8000-000000000004")
        internal val PRODUCER = CaptureProducer("synthetic-strap", UUID.fromString("20000000-0000-4000-8000-000000000001"),
            UUID.fromString("50000000-0000-4000-8000-000000000001"), CaptureFormat.WHOOP_FRAME_V1)
        internal val RECORD = CaptureRecord(17, 1_000, byteArrayOf(4, 8, 12), listOf(
            CaptureRoute(CaptureNamespace.IMU_BOUNDED, "bounded", 2), CaptureRoute(CaptureNamespace.IMU_CONTINUOUS, "continuous", 2)))
        internal val BATCH = CaptureBatch(PRODUCER.deviceId, PRODUCER.serverDeviceId, PRODUCER.producerId, PRODUCER.format, listOf(RECORD))
    }
}

/** Separate JVM, halted at the selected real publication boundary with no RAM shared with recovery. */
object CaptureColdProcess {
    @JvmStatic fun main(args: Array<String>) { runBlocking {
        val access = object : CaptureNamespaceAccess {
            override fun <T> withLock(scope: AccountScope, block: () -> T): T = block()
        }
        val admission = object : CaptureAdmission {
            override fun <T> withCurrent(block: () -> T): T = block()
        }
        var stop = false
        val haltPoint = args.getOrNull(1)?.let(CaptureFilePoint::valueOf) ?: CaptureFilePoint.AFTER_FILE_SYNC
        require(haltPoint == CaptureFilePoint.AFTER_FILE_SYNC || haltPoint == CaptureFilePoint.AFTER_RENAME)
        val pool = CaptureRetirement.open(File(args[0], "accounts-v1"), access,
            faults = CaptureFileFaults { if (stop && it == haltPoint) Runtime.getRuntime().halt(86) })
        val ids = ArrayDeque(listOf(W2CaptureColdRecoveryNativeTest.FIRST, W2CaptureColdRecoveryNativeTest.SECOND, W2CaptureColdRecoveryNativeTest.PENDING))
        val first = AccountCaptureJournal.open(pool, W2CaptureColdRecoveryNativeTest.OWNER,
            W2CaptureColdRecoveryNativeTest.GENERATION, admission) { ids.removeFirst() }
        repeat(2) { first.commit(first.reserveBatch(W2CaptureColdRecoveryNativeTest.BATCH)) }
        val other = AccountCaptureJournal.open(pool, W2CaptureColdRecoveryNativeTest.OTHER,
            W2CaptureColdRecoveryNativeTest.GENERATION, admission) { W2CaptureColdRecoveryNativeTest.THIRD }
        other.commit(other.reserveBatch(W2CaptureColdRecoveryNativeTest.BATCH))
        stop = true
        first.commit(first.reserveBatch(W2CaptureColdRecoveryNativeTest.BATCH))
        error("producer did not halt")
    } }
}
