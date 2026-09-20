package com.noop.account

import java.io.File
import java.nio.channels.FileChannel
import java.nio.file.DirectoryStream
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardOpenOption.READ
import java.nio.file.StandardOpenOption.WRITE
import java.nio.file.attribute.BasicFileAttributes
import java.util.Collections
import java.util.UUID

/** Observed charges are not an assertion that unvisited or unreadable storage fits the budget. */
data class CaptureRecoveryStatus internal constructor(
    val observedCharge: CaptureUsage,
    val inspectedEntries: Int,
    val observationLimitReached: Boolean,
    val unsafeOrUnreadableEntries: Int,
    val byteCountSaturated: Boolean,
) {
    val admissionPaused: Boolean get() = true
    val inventoryIncomplete: Boolean get() = true
}

enum class CaptureRecoveryIssue {
    UNKNOWN_NAME, CORRUPT, OWNER_MISMATCH, ID_MISMATCH, DUPLICATE_ID,
    UNSAFE_PATH, UNREADABLE, CHANGED, FINALIZATION_FAILED,
}

/** Only the authorized journal's relative filename is exposed, never another account's identity. */
data class RetainedCaptureEntry(
    val entryName: String?,
    val observedBytes: Long?,
    val issue: CaptureRecoveryIssue,
)

class CaptureRecoveryPage internal constructor(
    verified: List<DurableCapture>,
    retained: List<RetainedCaptureEntry>,
    val inspectedEntries: Int,
    val traversalExhausted: Boolean,
    val traversalChanged: Boolean,
) {
    val verified: List<DurableCapture> = Collections.unmodifiableList(verified.toList())
    val retained: List<RetainedCaptureEntry> = Collections.unmodifiableList(retained.toList())
    // A DirectoryStream is weakly consistent, including when this reader finalizes a pending file.
    val inventoryIncomplete: Boolean get() = true
    val admissionPaused: Boolean get() = true
}

/**
 * One stream per reader; at most 16 readers per pool. A page inspects at most 64 entries and
 * materializes at most one envelope (<= batchBytes). Neither quota nor a completion slot is needed.
 * Exhaustion means only that this iterator ended. Reopen to retry retained entries or rescan changes.
 */
class CaptureRecovery internal constructor(internal val journal: AccountCaptureJournal) : AutoCloseable {
    private val lock = Any()
    private var stream: DirectoryStream<Path>? = null
    private var iterator: Iterator<Path>? = null
    private var initialDirectory: BasicFileAttributes? = null
    private var ended = false
    private var changed = false
    private var closed = false

    suspend fun nextPage(limit: Int = 32): CaptureRecoveryPage {
        require(limit in 1..64)
        try {
            journal.checkRecoveryCurrent()
            val result = journal.pool.fileIO(journal.owner) {
                synchronized(lock) {
                    check(!closed) { "Capture recovery reader is closed" }
                    journal.checkRecoveryCurrent()
                    page(limit)
                }
            }
            journal.checkRecoveryCurrent()
            return result
        } catch (failure: Exception) {
            close()
            throw failure
        }
    }

    private fun page(limit: Int): CaptureRecoveryPage {
        val retained = mutableListOf<RetainedCaptureEntry>()
        val verified = mutableListOf<DurableCapture>()
        var inspected = 0
        if (!ended) {
            try {
                safeDirectory()
                val current = attributes(journal.directory.toPath())
                if (stream == null) {
                    initialDirectory = current
                    stream = Files.newDirectoryStream(journal.directory.toPath())
                    iterator = stream!!.iterator()
                } else if (!sameObservation(initialDirectory!!, current)) changed = true
                while (inspected < limit && verified.isEmpty()) {
                    journal.checkRecoveryCurrent()
                    if (!iterator!!.hasNext()) { ended = true; break }
                    val path = iterator!!.next()
                    inspected++
                    inspect(path, retained)?.let { verified += it }
                }
                if (!sameObservation(initialDirectory!!, attributes(journal.directory.toPath()))) changed = true
            } catch (failure: CaptureBlockedException) {
                // A revoked principal must not receive even previously verified data from this page.
                if (failure.reason == CaptureBlocked.STALE) throw failure
                retained += RetainedCaptureEntry(null, null, CaptureRecoveryIssue.UNSAFE_PATH)
                ended = true
                changed = true
            } catch (_: Exception) {
                retained += RetainedCaptureEntry(null, null, CaptureRecoveryIssue.UNREADABLE)
                ended = true
                changed = true
            }
        }
        if (ended) { stream?.close(); stream = null; iterator = null }
        return CaptureRecoveryPage(verified, retained, inspected, ended, changed)
    }

    private fun inspect(path: Path, retained: MutableList<RetainedCaptureEntry>): DurableCapture? {
        val name = path.fileName.toString()
        var observed: BasicFileAttributes? = null
        fun hold(issue: CaptureRecoveryIssue): DurableCapture? {
            retained += RetainedCaptureEntry(name, observed?.takeIf { it.isRegularFile }?.size(), issue)
            return null
        }
        try {
            safeDirectory()
            observed = attributes(path)
            if (!observed.isRegularFile || observed.isSymbolicLink) return hold(CaptureRecoveryIssue.UNSAFE_PATH)
            val id = captureFilenameId(name) ?: return hold(CaptureRecoveryIssue.UNKNOWN_NAME)
            val suffix = if (name.endsWith(".pending")) ".ncap" else ".pending"
            val counterpart = path.resolveSibling("$id$suffix")
            if (attributesOrNull(counterpart) != null) return hold(CaptureRecoveryIssue.DUPLICATE_ID)
            if (!Files.isReadable(path)) return hold(CaptureRecoveryIssue.UNREADABLE)
            val decoded = try { AccountCaptureJournal.readFile(path.toFile(), journal.pool.limits) }
                catch (_: CaptureBlockedException) { return hold(CaptureRecoveryIssue.CORRUPT) }
            if (decoded.owner != journal.owner) return hold(CaptureRecoveryIssue.OWNER_MISMATCH)
            if (decoded.resource.captureId != id) return hold(CaptureRecoveryIssue.ID_MISMATCH)
            safeDirectory()
            if (!sameObservation(observed, attributes(path))) return hold(CaptureRecoveryIssue.CHANGED)
            if (attributesOrNull(counterpart) != null) return hold(CaptureRecoveryIssue.DUPLICATE_ID)
            journal.checkRecoveryCurrent()
            try {
                completeCaptureRecoveryBarrier(journal, path, id, observed)
                if (name.endsWith(".pending")) changed = true
            } catch (failure: CaptureBlockedException) {
                if (failure.reason == CaptureBlocked.STALE) throw failure
                return hold(CaptureRecoveryIssue.FINALIZATION_FAILED)
            } catch (_: Exception) { return hold(CaptureRecoveryIssue.FINALIZATION_FAILED) }
            return decoded
        } catch (failure: CaptureBlockedException) {
            if (failure.reason == CaptureBlocked.STALE) throw failure
            return hold(CaptureRecoveryIssue.UNSAFE_PATH)
        } catch (_: Exception) { return hold(CaptureRecoveryIssue.UNREADABLE) }
    }

    private fun safeDirectory() = checkRecoveryDirectory(journal)

    override fun close() {
        try {
            synchronized(lock) {
                if (closed) return
                closed = true
                try { stream?.close() } finally { stream = null; iterator = null }
            }
        } finally { journal.pool.unregisterRecovery(this) }
    }
}

/** Called only after full envelope/owner validation, under the captured namespace lease. */
internal fun completeCaptureRecoveryBarrier(
    journal: AccountCaptureJournal,
    path: Path,
    id: String,
    observed: BasicFileAttributes,
) {
    val directory = journal.directory.toPath()
    val staged = directory.resolve("$id.pending")
    val target = directory.resolve("$id.ncap")
    require(path == staged || path == target)
    val counterpart = if (path == staged) target else staged
    fun checkFile(currentPath: Path) {
        checkRecoveryDirectory(journal)
        if (!observed.isRegularFile || observed.isSymbolicLink || !sameObservation(observed, attributes(currentPath))) {
            throw CaptureBlockedException(CaptureBlocked.CORRUPT)
        }
    }
    fun checkAbsent(otherPath: Path) {
        if (attributesOrNull(otherPath) != null) throw CaptureBlockedException(CaptureBlocked.ID_CONFLICT)
    }
    journal.checkRecoveryCurrent()
    checkFile(path)
    checkAbsent(counterpart)
    // A committed-looking name does not prove its earlier file/directory barriers completed.
    FileChannel.open(path, READ, WRITE, NOFOLLOW_LINKS).use { channel ->
        checkFile(path)
        if (channel.size() != observed.size()) throw CaptureBlockedException(CaptureBlocked.CORRUPT)
        channel.force(true)
    }
    checkFile(path)
    checkAbsent(counterpart)
    journal.checkRecoveryCurrent()
    if (path == staged) Files.move(staged, target, ATOMIC_MOVE)
    checkFile(target)
    val directoryObserved = attributes(directory)
    FileChannel.open(directory, READ, NOFOLLOW_LINKS).use { it.force(true) }
    checkFile(target)
    checkAbsent(staged)
    if (!sameObservation(directoryObserved, attributes(directory))) throw CaptureBlockedException(CaptureBlocked.CORRUPT)
    journal.checkRecoveryCurrent()
}

private fun checkRecoveryDirectory(journal: AccountCaptureJournal) {
    val root = journal.pool.accountsDirectory.toPath()
    val account = root.resolve(journal.owner.scope.namespace)
    for (path in listOf(root, account, journal.directory.toPath())) {
        val observed = attributes(path)
        if (!observed.isDirectory || observed.isSymbolicLink) throw CaptureBlockedException(CaptureBlocked.CORRUPT)
    }
}

/** No payload reads or unbounded per-entry collection during global startup. */
internal fun observeCaptureRecoveryInventory(root: File, limits: CaptureLimits): CaptureRecoveryStatus {
    val workLimit = 8_192
    var inspected = 0
    var files = 0
    var bytes = 0L
    var unsafe = 0
    var saturated = false
    var limitReached = false
    fun charge(path: Path) {
        files++
        try {
            val entry = attributes(path)
            if (!entry.isRegularFile || entry.isSymbolicLink) { unsafe++; return }
            val length = entry.size()
            if (length < 0 || length > Long.MAX_VALUE - bytes) { bytes = Long.MAX_VALUE; saturated = true }
            else bytes += length
        } catch (_: Exception) { unsafe++ }
    }
    try {
        Files.newDirectoryStream(root.toPath()).use { owners ->
            for (owner in owners) {
                if (inspected >= workLimit) { limitReached = true; break }
                inspected++
                if (!owner.fileName.toString().matches(Regex("[0-9a-f]{64}"))) continue
                try {
                    val ownerInfo = attributes(owner)
                    if (!ownerInfo.isDirectory || ownerInfo.isSymbolicLink) { unsafe++; continue }
                    val folder = owner.resolve("capture-v1")
                    val info = attributesOrNull(folder) ?: continue
                    if (!info.isDirectory || info.isSymbolicLink) { unsafe++; continue }
                    Files.newDirectoryStream(folder).use { entries ->
                        for (entry in entries) {
                            if (inspected >= workLimit) { limitReached = true; break }
                            inspected++
                            charge(entry)
                        }
                    }
                } catch (_: Exception) { unsafe++ }
                if (limitReached) break
            }
        }
    } catch (_: Exception) { unsafe++ }
    return CaptureRecoveryStatus(CaptureUsage(bytes, files, files.toLong() * limits.batchMembers),
        inspected, limitReached, unsafe, saturated)
}

private fun attributes(path: Path): BasicFileAttributes =
    Files.readAttributes(path, BasicFileAttributes::class.java, NOFOLLOW_LINKS)

private fun attributesOrNull(path: Path): BasicFileAttributes? = try { attributes(path) }
    catch (_: NoSuchFileException) { null }

private fun sameObservation(a: BasicFileAttributes, b: BasicFileAttributes): Boolean =
    a.fileKey() == b.fileKey() && a.size() == b.size() && a.lastModifiedTime() == b.lastModifiedTime() &&
        a.isRegularFile == b.isRegularFile && a.isDirectory == b.isDirectory && a.isSymbolicLink == b.isSymbolicLink

private fun captureFilenameId(name: String): String? {
    if (!name.endsWith(".ncap") && !name.endsWith(".pending")) return null
    val id = name.substringBeforeLast('.')
    return try { id.takeIf { UUID.fromString(it).toString() == it } } catch (_: IllegalArgumentException) { null }
}
