package com.noop.account

import com.noop.push.AccountScope
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext

/** The production adapter must serialize this block with identity revocation, not just check a Bool. */
interface CaptureAdmission {
    fun <T> withCurrent(block: () -> T): T
}

/** Shared with namespace restore/open. Called on IO without holding the quota or auth lock. */
interface CaptureNamespaceAccess {
    fun <T> withLock(scope: AccountScope, block: () -> T): T
}

data class CaptureLimits(
    val payloadBytes: Long = 1L shl 30,
    val resources: Int = 8_192,
    val members: Long = 524_288,
    val inFlightBytes: Long = 16L shl 20,
    val inFlightReservations: Int = 128,
    val retainedDrains: Int = 16,
    val batchBytes: Int = 4 shl 20,
    val batchRecords: Int = 4_096,
    val batchMembers: Int = 8_192,
) {
    init {
        require(payloadBytes > 0 && resources > 0 && members > 0)
        require(inFlightBytes > 0 && inFlightReservations > 0 && retainedDrains > 0)
        require(batchBytes in 1..(4 shl 20) && batchRecords in 1..4_096 && batchMembers in 1..8_192)
    }
}

data class CaptureUsage(val fileBytes: Long, val resources: Int, val members: Long) {
    // Logical allowance reserved when admitting data, not a claim that the filesystem cannot fail.
    val settlementAllowanceBytes: Long get() = resources * 8_192L + members * 1_024L
}

enum class CaptureBlocked { CAPACITY, STALE, SAME_PATH_BUSY, DRAIN_CAPACITY, CORRUPT, ID_CONFLICT, STORAGE, RECOVERY_ONLY }
class CaptureBlockedException(val reason: CaptureBlocked) : IllegalStateException("capture_${reason.name.lowercase()}")
enum class CaptureFilePoint { BEFORE_WRITE, AFTER_FILE_SYNC, AFTER_RENAME, AFTER_DIRECTORY_SYNC }
fun interface CaptureFileFaults { fun at(point: CaptureFilePoint) }

data class CaptureRetirementReport(
    val durableCaptureIds: List<String>,
    val unsettledCaptureIds: List<String>,
) {
    val settled: Boolean get() = unsettledCaptureIds.isEmpty()
}

class CaptureRetirementTicket internal constructor(internal val journal: AccountCaptureJournal) {
    internal var running: Deferred<CaptureRetirementReport>? = null
    internal var last: CaptureRetirementReport? = null
}

/** One application-owned pool. Disk quotas include all account capture folders, not just the login. */
class CaptureRetirement private constructor(
    internal val accountsDirectory: File,
    internal val namespaceAccess: CaptureNamespaceAccess,
    val limits: CaptureLimits,
    internal val dispatcher: CoroutineDispatcher,
    internal val faults: CaptureFileFaults,
    private val lockFile: RandomAccessFile,
    private val fileLock: FileLock,
) : AutoCloseable {
    internal val state = Any()
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val io = Semaphore(1)
    private val leases = mutableMapOf<String, AccountCaptureJournal>()
    private val inventory = mutableMapOf<String, CaptureUsage>()
    private var inventoryBytes = 0L
    private var inventoryMembers = 0L
    private var reservedBytes = 0L
    private var reservedResources = 0
    private var reservedMembers = 0L
    private var reservedCompletionSlots = 0
    private var closed = false
    private var recoveryStatus: CaptureRecoveryStatus? = null
    private val recoveryReaders = mutableSetOf<CaptureRecovery>()

    /** A recovery-only pool cannot grant fresh admission, even after a scoped iterator is exhausted. */
    fun recoveryStatus(): CaptureRecoveryStatus? = synchronized(state) { recoveryStatus }

    internal fun registerRecovery(reader: CaptureRecovery) = synchronized(state) {
        check(!closed && recoveryStatus != null)
        if (recoveryReaders.any { it.journal === reader.journal }) throw CaptureBlockedException(CaptureBlocked.SAME_PATH_BUSY)
        if (recoveryReaders.size >= minOf(limits.retainedDrains, 16)) throw CaptureBlockedException(CaptureBlocked.DRAIN_CAPACITY)
        recoveryReaders += reader
    }

    internal fun unregisterRecovery(reader: CaptureRecovery) = synchronized(state) { recoveryReaders.remove(reader) }

    internal fun attach(journal: AccountCaptureJournal) = synchronized(state) {
        check(!closed)
        if (leases.containsKey(journal.owner.scope.namespace)) throw CaptureBlockedException(CaptureBlocked.SAME_PATH_BUSY)
        // Each live writer reserves its future retirement slot before accepting a byte.
        if (leases.size >= limits.retainedDrains) throw CaptureBlockedException(CaptureBlocked.DRAIN_CAPACITY)
        leases[journal.owner.scope.namespace] = journal
    }

    internal fun abandonEmpty(journal: AccountCaptureJournal) = synchronized(state) {
        check(journal.pending.isEmpty() && journal.recordBatches.isEmpty())
        if (leases[journal.owner.scope.namespace] === journal) leases.remove(journal.owner.scope.namespace)
    }

    internal fun checkAdmission(journal: AccountCaptureJournal) = synchronized(state) {
        if (journal.retired) throw CaptureBlockedException(CaptureBlocked.STALE)
        check(!closed && leases[journal.owner.scope.namespace] === journal)
        if (recoveryStatus != null) throw CaptureBlockedException(CaptureBlocked.RECOVERY_ONLY)
        if (journal.storagePaused) throw CaptureBlockedException(CaptureBlocked.STORAGE)
    }

    private fun checkNewId(journal: AccountCaptureJournal, id: String) {
        if (inventory.containsKey(key(journal.owner.scope.namespace, id)) ||
            journal.pending.keys.any { it.captureId == id } || journal.recordBatches.any { it.captureId == id }) {
            throw CaptureBlockedException(CaptureBlocked.ID_CONFLICT)
        }
    }

    internal fun reserve(journal: AccountCaptureJournal, reservation: AccountCaptureJournal.Reservation, bytes: ByteArray) = synchronized(state) {
        checkAdmission(journal)
        val usage = usageLocked()
        val members = reservation.memberCount.toLong()
        if (bytes.size.toLong() > limits.payloadBytes - usage.fileBytes ||
            usage.resources >= limits.resources || members > limits.members - usage.members ||
            bytes.size.toLong() > limits.inFlightBytes - reservedBytes || reservedCompletionSlots >= limits.inFlightReservations) {
            throw CaptureBlockedException(CaptureBlocked.CAPACITY)
        }
        checkNewId(journal, reservation.captureId)
        reservedBytes += bytes.size
        reservedResources++
        reservedMembers += members
        reservedCompletionSlots++
        journal.pending[reservation] = bytes
    }

    internal fun reserveRecord(
        journal: AccountCaptureJournal,
        batch: AccountCaptureJournal.RecordBatch,
        record: CaptureRecord,
        recordBytes: Int,
        isNew: Boolean,
    ) = synchronized(state) {
        checkAdmission(journal)
        check(batch.journal === journal && !batch.sealed)
        if (isNew) checkNewId(journal, batch.captureId) else check(batch in journal.recordBatches)
        val extraBytes = recordBytes.toLong() + (if (isNew) batch.encodedBytes else 0)
        val extraResources = if (isNew) 1 else 0
        val usage = usageLocked()
        if (extraBytes > limits.payloadBytes - usage.fileBytes || extraResources > limits.resources - usage.resources ||
            record.routes.size.toLong() > limits.members - usage.members ||
            extraBytes > limits.inFlightBytes - reservedBytes || reservedCompletionSlots >= limits.inFlightReservations) {
            throw CaptureBlockedException(CaptureBlocked.CAPACITY)
        }
        reservedBytes += extraBytes
        reservedResources += extraResources
        reservedMembers += record.routes.size
        reservedCompletionSlots++
        if (isNew) journal.recordBatches += batch
        batch.records += record
        batch.memberCount += record.routes.size
        batch.encodedBytes += recordBytes
    }

    /** Encoding changes the representation, not the already-charged bytes, members or completion slots. */
    internal fun sealed(
        journal: AccountCaptureJournal,
        batch: AccountCaptureJournal.RecordBatch,
        reservation: AccountCaptureJournal.Reservation,
        bytes: ByteArray,
    ) = synchronized(state) {
        check(batch in journal.recordBatches && batch.sealed && batch.reservation == null)
        check(bytes.size == batch.encodedBytes && reservation.memberCount == batch.memberCount &&
            reservation.completionSlots == batch.records.size)
        journal.pending[reservation] = bytes
        batch.reservation = reservation
        batch.records.clear()
        journal.recordBatches.remove(batch)
    }

    internal fun published(journal: AccountCaptureJournal, reservation: AccountCaptureJournal.Reservation) = synchronized(state) {
        val bytes = journal.pending.remove(reservation) ?: return@synchronized
        reservedBytes -= bytes.size
        reservedResources--
        reservedMembers -= reservation.memberCount
        reservedCompletionSlots -= reservation.completionSlots
        inventory[key(journal.owner.scope.namespace, reservation.captureId)] =
            CaptureUsage(bytes.size.toLong(), 1, reservation.memberCount.toLong())
        inventoryBytes += bytes.size
        inventoryMembers += reservation.memberCount
        if (journal.pending.isEmpty() && journal.recordBatches.isEmpty()) journal.storagePaused = false
    }

    fun usage(): CaptureUsage = synchronized(state) { usageLocked() }
    fun inFlightUsage(): CaptureUsage = synchronized(state) { CaptureUsage(reservedBytes, reservedResources, reservedMembers) }
    fun retainedDrainCount(): Int = synchronized(state) { leases.size }
    /** A legacy complete batch occupies one slot; synchronous record admission occupies one per record. */
    fun inFlightReservationCount(): Int = synchronized(state) { reservedCompletionSlots }

    private fun usageLocked() = CaptureUsage(
        (recoveryStatus?.observedCharge?.fileBytes ?: inventoryBytes) + reservedBytes,
        (recoveryStatus?.observedCharge?.resources ?: inventory.size) + reservedResources,
        (recoveryStatus?.observedCharge?.members ?: inventoryMembers) + reservedMembers,
    )

    internal suspend fun <T> boundedIO(block: () -> T): T = withContext(dispatcher) { io.withPermit { block() } }
    internal suspend fun <T> fileIO(owner: CaptureOwner, block: () -> T): T =
        boundedIO { namespaceAccess.withLock(owner.scope, block) }

    /** No parent runtime Job: caller cancellation cannot destroy the retained reservations. */
    fun settle(ticket: CaptureRetirementTicket): Deferred<CaptureRetirementReport> = synchronized(state) {
        require(ticket.journal.pool === this && ticket.journal.retired)
        ticket.running?.takeIf { !it.isCompleted }?.let { return@synchronized it }
        ticket.last?.takeIf { it.settled }?.let { prior -> return@synchronized scope.async { prior } }
        scope.async {
            val journal = ticket.journal
            val (reservations, batches) = synchronized(state) {
                journal.pending.keys.toList() to journal.recordBatches.toList()
            }
            val succeeded = mutableListOf<String>()
            val failed = mutableListOf<String>()
            for (batch in batches) {
                try { journal.commit(journal.sealRecordBatch(batch)); succeeded += batch.captureId }
                catch (_: Exception) { failed += batch.captureId }
            }
            // Do not short-circuit: a failing file must not prevent another tail's publication.
            for (reservation in reservations) {
                try { journal.commit(reservation); succeeded += reservation.captureId }
                catch (_: Exception) { failed += reservation.captureId }
            }
            synchronized(state) {
                val remaining = journal.pending.keys.map { it.captureId } + journal.recordBatches.map { it.captureId }
                val report = CaptureRetirementReport(succeeded.toList(), (failed + remaining).distinct())
                ticket.last = report
                if (report.settled) abandonEmpty(journal)
                report
            }
        }.also { ticket.running = it }
    }

    override fun close() = synchronized(state) {
        check(recoveryReaders.isEmpty()) { "Close capture recovery readers first" }
        check(leases.isEmpty() && reservedResources == 0 && reservedCompletionSlots == 0) { "Capture writers or retirement debt remain" }
        if (!closed) {
            closed = true
            scope.cancel()
            fileLock.release()
            lockFile.close()
        }
    }

    companion object {
        private fun key(namespace: String, id: String) = "$namespace/$id"

        /** Off-main bounded inventory; no payload is returned from another account's directory. */
        suspend fun open(
            accountsDirectory: File,
            namespaceAccess: CaptureNamespaceAccess,
            limits: CaptureLimits = CaptureLimits(),
            dispatcher: CoroutineDispatcher = Dispatchers.IO,
            faults: CaptureFileFaults = CaptureFileFaults {},
        ): CaptureRetirement = openInternal(accountsDirectory, namespaceAccess, limits, dispatcher, faults, false)

        /** Bounded metadata observations only; no unknown bytes are opened, claimed or discarded. */
        suspend fun openForRecovery(
            accountsDirectory: File,
            namespaceAccess: CaptureNamespaceAccess,
            limits: CaptureLimits = CaptureLimits(),
            dispatcher: CoroutineDispatcher = Dispatchers.IO,
        ): CaptureRetirement = openInternal(accountsDirectory, namespaceAccess, limits, dispatcher, CaptureFileFaults {}, true)

        private suspend fun openInternal(
            accountsDirectory: File,
            namespaceAccess: CaptureNamespaceAccess,
            limits: CaptureLimits,
            dispatcher: CoroutineDispatcher,
            faults: CaptureFileFaults,
            recoveryOnly: Boolean,
        ): CaptureRetirement = withContext(dispatcher) {
            check(!java.nio.file.Files.isSymbolicLink(accountsDirectory.toPath()))
            check(accountsDirectory.isDirectory || accountsDirectory.mkdirs())
            val root = accountsDirectory.canonicalFile
            check(!java.nio.file.Files.isSymbolicLink(File(root, ".capture-v1.lock").toPath()))
            val lockFile = RandomAccessFile(File(root, ".capture-v1.lock"), "rw")
            val fileLock = try { lockFile.channel.tryLock() ?: throw CaptureBlockedException(CaptureBlocked.SAME_PATH_BUSY) }
                catch (failure: Exception) { lockFile.close(); throw failure }
            val pool = CaptureRetirement(root, namespaceAccess, limits, dispatcher, faults, lockFile, fileLock)
            try {
                if (recoveryOnly) {
                    pool.recoveryStatus = observeCaptureRecoveryInventory(root, limits)
                    return@withContext pool
                }
                var files = 0
                java.nio.file.Files.newDirectoryStream(root.toPath()).use { owners ->
                    for (ownerPath in owners) {
                        val name = ownerPath.fileName.toString()
                        if (!name.matches(Regex("[0-9a-f]{64}"))) continue
                        val folder = ownerPath.resolve("capture-v1").toFile()
                        if (!folder.exists()) continue
                        check(folder.canonicalFile.parentFile == ownerPath.toFile().canonicalFile && !java.nio.file.Files.isSymbolicLink(ownerPath))
                        java.nio.file.Files.newDirectoryStream(folder.toPath()).use { entries ->
                            for (entry in entries) {
                                if (++files > limits.resources) throw CaptureBlockedException(CaptureBlocked.CAPACITY)
                                val decoded = AccountCaptureJournal.readFile(entry.toFile(), limits)
                                if (decoded.owner.scope.namespace != name) throw CaptureBlockedException(CaptureBlocked.CORRUPT)
                                val id = decoded.resource.captureId
                                if (entry.fileName.toString() !in setOf("$id.ncap", "$id.pending")) throw CaptureBlockedException(CaptureBlocked.CORRUPT)
                                val resourceKey = key(name, id)
                                if (pool.inventory.put(resourceKey, CaptureUsage(decoded.resource.fileBytes, 1, decoded.resource.memberCount.toLong())) != null) {
                                    throw CaptureBlockedException(CaptureBlocked.ID_CONFLICT)
                                }
                                pool.inventoryBytes += decoded.resource.fileBytes
                                pool.inventoryMembers += decoded.resource.memberCount
                            }
                        }
                    }
                }
                val usage = pool.usage()
                if (usage.fileBytes > limits.payloadBytes || usage.members > limits.members) throw CaptureBlockedException(CaptureBlocked.CAPACITY)
                pool
            } catch (failure: Exception) { pool.close(); throw failure }
        }
    }
}
