package com.noop.data

import androidx.sqlite.db.SimpleSQLiteQuery
import androidx.sqlite.db.SupportSQLiteDatabase
import com.noop.account.AccountCaptureJournal
import com.noop.account.AccountStorageContext
import com.noop.account.CaptureAdmission
import com.noop.account.CaptureBatch
import com.noop.account.CaptureFormat
import com.noop.account.CaptureNamespace
import com.noop.account.CaptureNamespaceAccess
import com.noop.account.CaptureOwner
import com.noop.account.CaptureRecord
import com.noop.account.CaptureRetirement
import com.noop.account.CaptureRoute
import com.noop.account.DurableCapture
import com.noop.push.AccountAuthTransport
import com.noop.push.AccountConfiguration
import com.noop.push.AccountCredentialStore
import com.noop.push.AccountReply
import com.noop.push.AccountScope
import com.noop.push.AccountSession
import com.noop.push.AccountSessionController
import com.noop.push.CloudAuthClient
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.robolectric.RuntimeEnvironment

/** Disposable real Room/SQLite, synthetic credentials, and real immutable capture files. */
internal class CaptureIndexNativeFixture(createIndex: Boolean = true) : AutoCloseable {
    val owner = CaptureOwner(AccountScope.create("https://capture-index.example.test", UUID.randomUUID().toString()), UUID.randomUUID())
    var nextUserID = owner.scope.userID
    val controller = AccountSessionController(object : AccountCredentialStore {
        var stored: AccountSession? = AccountSession(owner.scope, "synthetic-access", "synthetic-refresh", Long.MAX_VALUE)
        override fun load(projectURL: String) = stored
        override fun save(session: AccountSession) { stored = session }
        override fun clear(projectURL: String) { stored = null }
    }, AccountAuthTransport { _, _ ->
        AccountReply(200, """{"access_token":"synthetic-next","refresh_token":"synthetic-refresh","expires_in":3600,"user":{"id":"$nextUserID"}}""")
    }).apply { configure(AccountConfiguration(owner.scope.projectURL, "synthetic-anon")) }
    private val installation = CloudAuthClient.installTestController(controller)
    fun account() = AccountStorageContext(RuntimeEnvironment.getApplication(), controller.identitySnapshot())
    val initialAccount = account()
    val room = WhoopDatabase.get(initialAccount)
    val db: SupportSQLiteDatabase = room.openHelper.writableDatabase
    private val fence = checkNotNull(room.accountWriteFence)
    val admission = object : CaptureAdmission {
        override fun <T> withCurrent(block: () -> T): T = fence.commit(block)
    }
    private val accounts = Files.createTempDirectory("capture-index-native-").resolve("accounts-v1").toFile()
    private val namespaceLock = Any()
    private val pool = runBlocking { CaptureRetirement.open(accounts, object : CaptureNamespaceAccess {
        override fun <T> withLock(scope: AccountScope, block: () -> T): T = synchronized(namespaceLock, block)
    }) }
    val journal = runBlocking { AccountCaptureJournal.open(pool, owner, initialAccount.identity.generation, admission) }
    val store = store()

    init {
        // Proposed tables only. This is NOT a registered Room42 -> 43 migration.
        if (createIndex) LocalCaptureSchema.create(db) else {
            // Keep the missing-registration negative control meaningful after root registers Room43.
            db.execSQL("DROP TABLE IF EXISTS localCaptureMember")
            db.execSQL("DROP TABLE IF EXISTS localCaptureResource")
        }
        db.execSQL("""CREATE TABLE captureProjectionFixture (
            captureId TEXT NOT NULL, recordOrdinal INTEGER NOT NULL, routeOrdinal INTEGER NOT NULL,
            projectURL TEXT NOT NULL, userID TEXT NOT NULL, sourceID TEXT NOT NULL,
            deviceID TEXT NOT NULL, serverDeviceID TEXT NOT NULL, namespace TEXT NOT NULL,
            sessionID TEXT NOT NULL, bucket INTEGER, payload BLOB NOT NULL,
            PRIMARY KEY(captureId,recordOrdinal,routeOrdinal))""")
    }

    fun store(beforeCommit: () -> Unit = {}) = LocalCaptureStore(owner, admission, { db }, beforeCommit = beforeCommit)

    suspend fun capture(count: Int = 1, twoRoutes: Boolean = false): DurableCapture {
        val records = List(count) { ordinal -> CaptureRecord(ordinal.toLong(), 1_000, byteArrayOf(ordinal.toByte(), 42), buildList {
            add(CaptureRoute(CaptureNamespace.IMU_BOUNDED, "bounded-session", 0))
            if (twoRoutes) add(CaptureRoute(CaptureNamespace.IMU_CONTINUOUS, "continuous-session", 0))
        }) }
        return journal.commit(journal.reserveBatch(CaptureBatch("synthetic-strap", DEVICE, PRODUCER, CaptureFormat.WHOOP_FRAME_V1, records)))
    }

    fun file(capture: DurableCapture) = File(File(accounts, owner.scope.namespace), capture.resource.relativePath)
    fun count(table: String): Long {
        require(table in setOf("localCaptureResource", "localCaptureMember", "captureProjectionFixture"))
        return db.query("SELECT count(*) FROM $table").use { check(it.moveToFirst()); it.getLong(0) }
    }
    fun state(key: CaptureMemberKey): Int = db.query(SimpleSQLiteQuery(
        "SELECT projectionState FROM localCaptureMember WHERE captureId=? AND recordOrdinal=? AND routeOrdinal=?",
        arrayOf(key.captureId, key.recordOrdinal, key.routeOrdinal),
    )).use { check(it.moveToFirst()); it.getInt(0) }

    override fun close() = runBlocking {
        try {
            assertTrue(pool.settle(journal.beginRetirement()).await().settled)
            pool.close()
        } finally { WhoopDatabase.close(); installation.close() }
    }

    companion object {
        val DEVICE: UUID = UUID.fromString("20000000-0000-4000-8000-000000000001")
        val PRODUCER: UUID = UUID.fromString("50000000-0000-4000-8000-000000000001")
        fun key(capture: DurableCapture, record: Int = 0, route: Int = 0) = CaptureMemberKey(capture.resource.captureId, record, route)
        fun digest(file: File): String = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
    }
}

/** Exact synthetic destination, deliberately separate from production IMU/HR projections. */
internal class CaptureFixtureProjection(
    private val decision: CaptureProjectionDecision = CaptureProjectionDecision.RECORDED,
    private val corruptDevice: Boolean = false,
    private val throwAfterWrite: Boolean = false,
) : CaptureMemberProjection {
    var writes = 0
    var verifications = 0
    override fun write(database: SupportSQLiteDatabase, input: CaptureProjectionInput): CaptureProjectionDecision {
        writes++
        if (!destinationMatches(database, input)) {
            val r = input.indexed.resource; val m = input.indexed.member
            database.execSQL("INSERT INTO captureProjectionFixture VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", arrayOf(
                r.captureId, m.recordOrdinal, m.routeOrdinal, r.projectURL, r.userID, r.sourceID,
                if (corruptDevice) "wrong-device" else r.deviceID, r.serverDeviceID, m.namespace, m.sessionID, m.bucket, input.payload(),
            ))
        }
        if (throwAfterWrite) throw IllegalStateException("synthetic projection failure")
        return decision
    }

    override fun destinationMatches(database: SupportSQLiteDatabase, input: CaptureProjectionInput): Boolean {
        verifications++
        val r = input.indexed.resource; val m = input.indexed.member
        return database.query(SimpleSQLiteQuery("SELECT projectURL,userID,sourceID,deviceID,serverDeviceID,namespace,sessionID,bucket,payload " +
            "FROM captureProjectionFixture WHERE captureId=? AND recordOrdinal=? AND routeOrdinal=?",
            arrayOf(r.captureId, m.recordOrdinal, m.routeOrdinal))).use { row ->
            row.moveToFirst() && row.getString(0) == r.projectURL && row.getString(1) == r.userID && row.getString(2) == r.sourceID &&
                row.getString(3) == r.deviceID && row.getString(4) == r.serverDeviceID && row.getString(5) == m.namespace &&
                row.getString(6) == m.sessionID && (if (row.isNull(7)) null else row.getLong(7)) == m.bucket &&
                row.getBlob(8).contentEquals(input.payload()) && !row.moveToNext()
        }
    }
}
