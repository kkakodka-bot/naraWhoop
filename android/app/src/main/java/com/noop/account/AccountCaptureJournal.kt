package com.noop.account

import com.noop.data.LocalCaptureMember
import com.noop.data.LocalCaptureResource
import com.noop.push.AccountScope
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.charset.CodingErrorAction
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest
import java.util.Collections
import java.util.UUID

data class CaptureOwner(val scope: AccountScope, val sourceId: UUID)
enum class CaptureFormat { STANDARD_HR_V1, WHOOP_FRAME_V1 }
enum class CaptureNamespace { STANDARD_HR, IMU_BOUNDED, IMU_CONTINUOUS, WHOOP_HISTORY }

data class CaptureRoute(val namespace: CaptureNamespace, val sessionId: String, val bucket: Long? = null) {
    init { captureText(sessionId, 128) }
}

data class CaptureProducer(
    val deviceId: String,
    val serverDeviceId: UUID,
    val producerId: UUID,
    val format: CaptureFormat,
) {
    init { captureText(deviceId, 256) }
}

class CaptureRecord(
    val encounterOrdinal: Long,
    val receivedAtMs: Long,
    bytes: ByteArray,
    routes: List<CaptureRoute>,
) {
    private val payload = bytes.copyOf()
    val routes: List<CaptureRoute> = Collections.unmodifiableList(routes.toList())
    internal val size: Int get() = payload.size
    internal val encodedSize: Int get() = 24 + size + routes.sumOf {
        captureTextSize(it.namespace.name, 64) + captureTextSize(it.sessionId, 128) +
            1 + (if (it.bucket == null) 0 else 8)
    }
    internal fun writePayload(out: DataOutputStream) = out.write(payload)
    init {
        require(encounterOrdinal >= 0 && receivedAtMs >= 0 && bytes.size in 1..(1 shl 20))
        require(routes.size in 1..16 && routes.distinct().size == routes.size)
    }
}

/** One batch can hold thousands of notifications. This API never creates a file per callback. */
class CaptureBatch(
    val deviceId: String,
    val serverDeviceId: UUID,
    val producerId: UUID,
    val format: CaptureFormat,
    records: List<CaptureRecord>,
) {
    val records: List<CaptureRecord> = Collections.unmodifiableList(records.toList())
    init {
        captureText(deviceId, 256)
        require(records.size in 1..4_096)
        require(records.zipWithNext().all { (a, b) -> a.encounterOrdinal < b.encounterOrdinal })
    }
}

class DurableCapture internal constructor(
    val owner: CaptureOwner,
    val resource: LocalCaptureResource,
    members: List<LocalCaptureMember>,
    private val serialized: ByteArray,
) {
    val members: List<LocalCaptureMember> = Collections.unmodifiableList(members.toList())
    fun payload(recordOrdinal: Int): ByteArray {
        val member = members.firstOrNull { it.recordOrdinal == recordOrdinal } ?: throw IllegalArgumentException("capture_record")
        return serialized.copyOfRange(member.payloadOffset.toInt(), member.payloadOffset.toInt() + member.payloadBytes)
    }
}

/** No auth globals, device commands, Room writes, wire negotiation or deletion in this file. */
class AccountCaptureJournal private constructor(
    internal val pool: CaptureRetirement,
    val owner: CaptureOwner,
    val generation: UUID,
    private val admission: CaptureAdmission,
    private val newId: () -> UUID,
) {
    internal val directory = File(File(pool.accountsDirectory, owner.scope.namespace), "capture-v1")
    internal val pending = linkedMapOf<Reservation, ByteArray>()
    internal val recordBatches = mutableListOf<RecordBatch>()
    internal var retired = false
    internal var storagePaused = false
    private var retirement: CaptureRetirementTicket? = null

    class Reservation internal constructor(
        internal val journal: AccountCaptureJournal,
        val captureId: String,
        internal val fileSha256: String,
        internal val memberCount: Int,
        internal val completionSlots: Int = 1,
    )

    internal class RecordBatch(
        val journal: AccountCaptureJournal,
        val captureId: String,
        val producer: CaptureProducer,
        var encodedBytes: Int,
    ) {
        val records = mutableListOf<CaptureRecord>()
        var memberCount = 0
        var sealed = false
        var reservation: Reservation? = null
    }

    /** RAM admission only. This ticket never acknowledges file publication or a projected row. */
    class RecordReservation internal constructor(
        internal val batch: RecordBatch,
        val recordOrdinal: Int,
        val encounterOrdinal: Long,
    ) {
        val captureId: String get() = batch.captureId
    }

    /** No file access, payload encoding/hashing or coroutine dispatch on the producer callback. */
    fun reserveRecord(producer: CaptureProducer, record: CaptureRecord): RecordReservation = admission.withCurrent {
        synchronized(pool.state) {
            pool.checkAdmission(this)
            val open = recordBatches.lastOrNull { !it.sealed && it.producer == producer }
            require(open == null || record.encounterOrdinal > open.records.last().encounterOrdinal)
            val recordBytes = record.encodedSize
            val extend = open?.takeIf {
                it.records.size < pool.limits.batchRecords &&
                    record.routes.size <= pool.limits.batchMembers - it.memberCount &&
                    recordBytes <= pool.limits.batchBytes - it.encodedBytes
            }
            val batch = extend ?: newId().toString().let { id ->
                RecordBatch(this, id, producer, headerSize(owner, generation, id, producer))
            }
            if (recordBytes > pool.limits.batchBytes - batch.encodedBytes ||
                record.routes.size > pool.limits.batchMembers) throw CaptureBlockedException(CaptureBlocked.CAPACITY)
            pool.reserveRecord(this, batch, record, recordBytes, extend == null)
            if (extend == null) open?.sealed = true
            RecordReservation(batch, batch.records.lastIndex, record.encounterOrdinal)
        }
    }

    /** Closes the containing batch, then encodes only admitted records off-main. Still not durable. */
    suspend fun sealRecords(record: RecordReservation): Reservation {
        require(record.batch.journal === this)
        return sealRecordBatch(record.batch)
    }

    internal suspend fun sealRecordBatch(batch: RecordBatch): Reservation {
        require(batch.journal === this)
        synchronized(pool.state) {
            batch.reservation?.let { return it }
            check(batch in recordBatches && batch.records.isNotEmpty())
            batch.sealed = true
        }
        return pool.boundedIO {
            synchronized(pool.state) { batch.reservation }?.let { return@boundedIO it }
            try {
                val input = synchronized(pool.state) {
                    CaptureBatch(batch.producer.deviceId, batch.producer.serverDeviceId,
                        batch.producer.producerId, batch.producer.format, batch.records)
                }
                val bytes = encode(owner, generation, batch.captureId, input, pool.limits)
                check(bytes.size == batch.encodedBytes)
                val reservation = Reservation(this, batch.captureId, sha256(bytes), batch.memberCount, input.records.size)
                pool.sealed(this, batch, reservation, bytes)
                reservation
            } catch (failure: Exception) {
                synchronized(pool.state) { storagePaused = true }
                throw failure
            }
        }
    }

    /** Copies are already immutable; encoding is serialized and off-main before the short auth fence. */
    suspend fun reserveBatch(batch: CaptureBatch): Reservation = pool.boundedIO {
        require(batch.records.size <= pool.limits.batchRecords)
        val members = batch.records.sumOf { it.routes.size }
        require(members <= pool.limits.batchMembers)
        val id = newId().toString()
        val bytes = encode(owner, generation, id, batch, pool.limits)
        val reservation = Reservation(this, id, sha256(bytes), members)
        admission.withCurrent { pool.reserve(this, reservation, bytes) }
        reservation
    }

    /** The only stale-generation permission: finish exactly this journal's pre-existing reservation. */
    suspend fun commit(reservation: Reservation): DurableCapture {
        require(reservation.journal === this)
        return pool.fileIO(owner) {
            val bytes = synchronized(pool.state) { pending[reservation] }
            if (bytes == null) {
                return@fileIO verified(resourceFile(reservation.captureId), reservation.fileSha256)
            }
            try {
                val result = publish(reservation.captureId, bytes, reservation.fileSha256)
                pool.published(this, reservation)
                result
            } catch (failure: Exception) {
                synchronized(pool.state) { storagePaused = true }
                throw failure
            }
        }
    }

    fun beginRetirement(): CaptureRetirementTicket = synchronized(pool.state) {
        retirement ?: CaptureRetirementTicket(this).also {
            retired = true
            recordBatches.forEach { batch -> batch.sealed = true }
            retirement = it
        }
    }

    /** Complete pending files from a previous process are recoverable; partial files fail closed. */
    suspend fun recoverPage(afterCaptureId: String? = null, limit: Int = 32): List<DurableCapture> {
        require(limit in 1..64)
        afterCaptureId?.let(::canonicalUuid)
        admission.withCurrent { checkActive() }
        val result = pool.fileIO(owner) {
            val ids = mutableListOf<String>()
            Files.newDirectoryStream(directory.toPath()).use { entries ->
                for (entry in entries) {
                    if (ids.size >= pool.limits.resources) throw CaptureBlockedException(CaptureBlocked.CAPACITY)
                    val name = entry.fileName.toString()
                    val id = name.substringBeforeLast('.')
                    canonicalUuid(id)
                    if (name != "$id.ncap" && name != "$id.pending") throw CaptureBlockedException(CaptureBlocked.CORRUPT)
                    ids += id
                }
            }
            if (ids.distinct().size != ids.size) throw CaptureBlockedException(CaptureBlocked.ID_CONFLICT)
            ids.sorted().filter { afterCaptureId == null || it > afterCaptureId }.take(limit).map { id ->
                val target = resourceFile(id)
                val file = if (target.exists()) target else pendingFile(id)
                val observed = Files.readAttributes(file.toPath(), BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
                val decoded = verified(file)
                if (decoded.resource.captureId != id) throw CaptureBlockedException(CaptureBlocked.CORRUPT)
                completeCaptureRecoveryBarrier(this, file.toPath(), id, observed)
                decoded
            }
        }
        admission.withCurrent { checkActive() }
        return result
    }

    /** Explicit retained-unknown mode. The caller owns and must close the bounded directory reader. */
    suspend fun openRecovery(): CaptureRecovery {
        check(pool.recoveryStatus() != null) { "Use CaptureRetirement.openForRecovery" }
        checkRecoveryCurrent()
        val reader = CaptureRecovery(this)
        try {
            pool.fileIO(owner) {
                checkRecoveryCurrent()
                pool.registerRecovery(reader)
            }
            checkRecoveryCurrent()
            return reader
        } catch (failure: Throwable) {
            try { reader.close() } catch (cleanup: Throwable) { failure.addSuppressed(cleanup) }
            throw failure
        }
    }

    internal fun checkRecoveryCurrent() = admission.withCurrent { checkActive() }

    private fun checkActive() = synchronized(pool.state) {
        if (retired) throw CaptureBlockedException(CaptureBlocked.STALE)
    }

    private fun publish(id: String, bytes: ByteArray, expectedHash: String): DurableCapture {
        val target = resourceFile(id)
        if (target.exists()) {
            val existing = verified(target, expectedHash)
            syncFile(target)
            syncDirectory(directory)
            return existing
        }
        val staged = pendingFile(id)
        pool.faults.at(CaptureFilePoint.BEFORE_WRITE)
        val allowance = pool.usage().settlementAllowanceBytes
        if (directory.usableSpace < bytes.size + allowance) throw IOException("capture_storage_pressure")
        if (Files.isSymbolicLink(staged.toPath())) throw CaptureBlockedException(CaptureBlocked.CORRUPT)
        RandomAccessFile(staged, "rw").use { file ->
            val existing = file.length()
            if (existing > bytes.size) throw CaptureBlockedException(CaptureBlocked.ID_CONFLICT)
            val prefix = ByteArray(existing.toInt())
            file.readFully(prefix)
            if (!prefix.contentEquals(bytes.copyOfRange(0, prefix.size))) throw CaptureBlockedException(CaptureBlocked.ID_CONFLICT)
            file.seek(existing)
            file.write(bytes, existing.toInt(), bytes.size - existing.toInt())
            file.fd.sync()
        }
        pool.faults.at(CaptureFilePoint.AFTER_FILE_SYNC)
        Files.move(staged.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
        pool.faults.at(CaptureFilePoint.AFTER_RENAME)
        syncDirectory(directory)
        pool.faults.at(CaptureFilePoint.AFTER_DIRECTORY_SYNC)
        return verified(target, expectedHash)
    }

    private fun verified(file: File, expectedHash: String? = null): DurableCapture {
        val result = readFile(file, pool.limits)
        if (result.owner != owner || (expectedHash != null && result.resource.fileSha256 != expectedHash)) {
            throw CaptureBlockedException(CaptureBlocked.ID_CONFLICT)
        }
        return result
    }

    private fun resourceFile(id: String): File { canonicalUuid(id); return File(directory, "$id.ncap") }
    private fun pendingFile(id: String): File { canonicalUuid(id); return File(directory, "$id.pending") }

    companion object {
        private val MAGIC = "NCAP0001".toByteArray(Charsets.US_ASCII)

        private fun headerSize(owner: CaptureOwner, generation: UUID, id: String, producer: CaptureProducer): Int =
            MAGIC.size + 32 + 8 + captureTextSize(owner.scope.projectURL, 1_024) +
                captureTextSize(owner.scope.userID, 64) + captureTextSize(owner.sourceId.toString(), 64) +
                captureTextSize(generation.toString(), 64) + captureTextSize(id, 64) +
                captureTextSize(producer.deviceId, 256) + captureTextSize(producer.serverDeviceId.toString(), 64) +
                captureTextSize(producer.producerId.toString(), 64) + captureTextSize(producer.format.name, 64)

        suspend fun open(
            pool: CaptureRetirement,
            owner: CaptureOwner,
            generation: UUID,
            admission: CaptureAdmission,
            newId: () -> UUID = UUID::randomUUID,
        ): AccountCaptureJournal {
            val journal = AccountCaptureJournal(pool, owner, generation, admission, newId)
            admission.withCurrent { pool.attach(journal) }
            try {
                pool.fileIO(owner) {
                    val accountRoot = journal.directory.parentFile!!
                    check(!Files.isSymbolicLink(accountRoot.toPath()) && !Files.isSymbolicLink(journal.directory.toPath()))
                    check(accountRoot.isDirectory || accountRoot.mkdir())
                    syncDirectory(pool.accountsDirectory)
                    check(journal.directory.isDirectory || journal.directory.mkdir())
                    syncDirectory(accountRoot)
                    check(journal.directory.canonicalFile.parentFile == accountRoot.canonicalFile)
                }
                admission.withCurrent { Unit }
                return journal
            } catch (failure: Exception) { pool.abandonEmpty(journal); throw failure }
        }

        internal fun readFile(file: File, limits: CaptureLimits): DurableCapture {
            try {
                if (!file.isFile || Files.isSymbolicLink(file.toPath()) || file.length() !in 1..limits.batchBytes.toLong()) {
                    throw CaptureBlockedException(CaptureBlocked.CORRUPT)
                }
                val bytes = java.nio.channels.Channels.newInputStream(Files.newByteChannel(
                    file.toPath(), setOf(StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS),
                )).use { input ->
                    val out = ByteArrayOutputStream()
                    val buffer = ByteArray(8_192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (out.size() + count > limits.batchBytes) throw CaptureBlockedException(CaptureBlocked.CORRUPT)
                        out.write(buffer, 0, count)
                    }
                    out.toByteArray()
                }
                if (bytes.size <= MAGIC.size + 32) throw CaptureBlockedException(CaptureBlocked.CORRUPT)
                val bodyLength = bytes.size - 32
                val digest = MessageDigest.getInstance("SHA-256").digest(bytes.copyOfRange(0, bodyLength))
                if (!digest.contentEquals(bytes.copyOfRange(bodyLength, bytes.size))) throw CaptureBlockedException(CaptureBlocked.CORRUPT)
                val stream = ByteArrayInputStream(bytes, 0, bodyLength)
                val input = DataInputStream(stream)
                val magic = ByteArray(MAGIC.size); input.readFully(magic); require(magic.contentEquals(MAGIC))
                val project = input.text(1_024)
                val user = input.text(64)
                val accountScope = AccountScope.create(project, user)
                require(accountScope.projectURL == project && accountScope.userID == user)
                val source = canonicalUuid(input.text(64))
                val generation = canonicalUuid(input.text(64)).toString()
                val id = canonicalUuid(input.text(64)).toString()
                val device = input.text(256)
                val serverDevice = canonicalUuid(input.text(64)).toString()
                val producer = canonicalUuid(input.text(64)).toString()
                val format = CaptureFormat.valueOf(input.text(64))
                require(input.readInt() == 1)
                val count = input.readInt(); require(count in 1..limits.batchRecords)
                val members = mutableListOf<LocalCaptureMember>()
                var payloadBytes = 0L
                var lastOrdinal = -1L
                repeat(count) { recordIndex ->
                    val encounter = input.readLong(); require(encounter > lastOrdinal); lastOrdinal = encounter
                    val received = input.readLong(); require(received >= 0)
                    val routeCount = input.readInt(); require(routeCount in 1..16)
                    require(routeCount <= limits.batchMembers - members.size)
                    val routes = List(routeCount) {
                        val namespace = CaptureNamespace.valueOf(input.text(64))
                        val session = input.text(128)
                        val flag = input.readUnsignedByte(); require(flag in 0..1)
                        CaptureRoute(namespace, session, if (flag == 1) input.readLong() else null)
                    }
                    require(routes.distinct().size == routes.size)
                    val length = input.readInt(); require(length in 1..(1 shl 20) && length <= stream.available())
                    val offset = bodyLength - stream.available()
                    val payload = ByteArray(length); input.readFully(payload)
                    val payloadHash = sha256(payload)
                    routes.forEachIndexed { routeIndex, route ->
                        members += LocalCaptureMember(id, recordIndex, routeIndex, encounter, received,
                            route.namespace.name, route.sessionId, route.bucket, offset.toLong(), length, payloadHash)
                    }
                    payloadBytes += length
                }
                require(stream.available() == 0)
                val resource = LocalCaptureResource(id, project, user, source.toString(), generation, device,
                    serverDevice, producer, format.name, 1, "capture-v1/$id.ncap", sha256(bytes), bytes.size.toLong(),
                    payloadBytes, count, members.size)
                return DurableCapture(CaptureOwner(accountScope, source), resource, members, bytes)
            } catch (failure: CaptureBlockedException) { throw failure }
            catch (_: Exception) { throw CaptureBlockedException(CaptureBlocked.CORRUPT) }
        }

        private fun encode(owner: CaptureOwner, generation: UUID, id: String, batch: CaptureBatch, limits: CaptureLimits): ByteArray {
            val output = object : ByteArrayOutputStream() {
                override fun write(b: Int) { require(count < limits.batchBytes - 32); super.write(b) }
                override fun write(b: ByteArray, off: Int, len: Int) {
                    require(len <= limits.batchBytes - 32 - count); super.write(b, off, len)
                }
            }
            DataOutputStream(output).use { out ->
                out.write(MAGIC)
                out.text(owner.scope.projectURL, 1_024); out.text(owner.scope.userID, 64)
                out.text(owner.sourceId.toString(), 64); out.text(generation.toString(), 64); out.text(id, 64)
                out.text(batch.deviceId, 256); out.text(batch.serverDeviceId.toString(), 64)
                out.text(batch.producerId.toString(), 64); out.text(batch.format.name, 64); out.writeInt(1)
                out.writeInt(batch.records.size)
                for (record in batch.records) {
                    out.writeLong(record.encounterOrdinal); out.writeLong(record.receivedAtMs); out.writeInt(record.routes.size)
                    for (route in record.routes) {
                        out.text(route.namespace.name, 64); out.text(route.sessionId, 128)
                        out.writeByte(if (route.bucket == null) 0 else 1); route.bucket?.let(out::writeLong)
                    }
                    out.writeInt(record.size); record.writePayload(out)
                }
            }
            val body = output.toByteArray()
            return body + MessageDigest.getInstance("SHA-256").digest(body)
        }

        private fun DataOutputStream.text(value: String, max: Int) {
            captureText(value, max)
            val bytes = value.toByteArray(Charsets.UTF_8); writeInt(bytes.size); write(bytes)
        }
        private fun DataInputStream.text(max: Int): String {
            val length = readInt(); require(length in 1..max)
            val bytes = ByteArray(length); readFully(bytes)
            val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
            captureText(text, max)
            return text
        }
        private fun syncFile(file: File) = RandomAccessFile(file, "rw").use { it.fd.sync() }
        private fun syncDirectory(file: File) = FileChannel.open(file.toPath(), StandardOpenOption.READ).use { it.force(true) }
        internal fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
    }
}

private fun captureText(value: String, max: Int) {
    require(value.isNotBlank() && value.toByteArray(Charsets.UTF_8).size <= max)
    require(value.none { it.isISOControl() || it in '\uD800'..'\uDFFF' })
}
private fun captureTextSize(value: String, max: Int): Int {
    captureText(value, max)
    return 4 + value.toByteArray(Charsets.UTF_8).size
}
private fun canonicalUuid(value: String): UUID = UUID.fromString(value).also { require(it.toString() == value) }
