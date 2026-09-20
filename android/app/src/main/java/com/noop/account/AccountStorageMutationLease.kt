package com.noop.account

import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

class AccountStorageBusyException : IllegalStateException("Account database transactions did not quiesce")

/** One file-opening lease per namespace; one retirement fence per captured generation. */
class AccountStorageMutationLease private constructor(
    private val storage: Storage,
    private val generation: Generation,
    private val fence: AccountWriteFence,
) {
    private class Storage {
        val openingLock = Any()
        val generations = mutableMapOf<java.util.UUID, Generation>()
        val transactionLock = ReentrantLock()
        val drained = transactionLock.newCondition()
        val onThread = ThreadLocal.withInitial { 0 }
        var transactions = 0
        var quiescing = false
    }
    private class Generation {
        var lease = java.lang.ref.WeakReference<AccountStorageMutationLease>(null)
        var retired = false
    }

    fun retire() {
        fence.retire()
        synchronized(storageByPath) { generation.retired = true }
    }
    fun admitsWrites(): Boolean = fence.admitsWrites()
    fun <T> commit(body: () -> T): T = fence.commit(body)
    internal fun <T> withStorageLock(body: () -> T): T = synchronized(storage.openingLock) { body() }

    internal fun beginQuiescence() = storage.transactionLock.withLock {
        if (storage.onThread.get() != 0 || storage.quiescing) throw AccountStorageBusyException()
        storage.quiescing = true
    }

    internal fun awaitTransactions() = storage.transactionLock.withLock {
        var remaining = TimeUnit.SECONDS.toNanos(10)
        while (storage.transactions != 0) {
            if (remaining <= 0) throw AccountStorageBusyException()
            remaining = storage.drained.awaitNanos(remaining)
        }
    }

    internal fun endQuiescence() = storage.transactionLock.withLock { storage.quiescing = false }

    private fun transactionStarting() = storage.transactionLock.withLock {
        if (storage.quiescing) throw AccountWriteRevokedException()
        storage.transactions++
        storage.onThread.set(storage.onThread.get() + 1)
    }

    private fun transactionEnded() = storage.transactionLock.withLock {
        check(storage.transactions > 0 && storage.onThread.get() > 0)
        storage.transactions--
        val remaining = storage.onThread.get() - 1
        if (remaining == 0) storage.onThread.remove() else storage.onThread.set(remaining)
        if (storage.transactions == 0) storage.drained.signalAll()
    }

    private fun tracked(database: SupportSQLiteDatabase): SupportSQLiteDatabase = object : SupportSQLiteDatabase by database {
        private fun begin(body: () -> Unit) {
            transactionStarting()
            try { body() } catch (failure: Throwable) { transactionEnded(); throw failure }
        }
        override fun beginTransaction() = begin { database.beginTransaction() }
        override fun beginTransactionNonExclusive() = begin { database.beginTransactionNonExclusive() }
        override fun endTransaction() {
            try { database.endTransaction() } finally { transactionEnded() }
        }
    }

    internal fun openHelperFactory(
        databaseFence: AccountWriteFence,
        delegate: SupportSQLiteOpenHelper.Factory = com.noop.data.CorruptionPreservingOpenHelperFactory(),
    ): SupportSQLiteOpenHelper.Factory = object : SupportSQLiteOpenHelper.Factory {
        override fun create(configuration: SupportSQLiteOpenHelper.Configuration): SupportSQLiteOpenHelper {
            // Inside the write fence so implicit execSQL/statement transactions are counted too.
            val monitored = object : SupportSQLiteOpenHelper.Factory {
                override fun create(configuration: SupportSQLiteOpenHelper.Configuration): SupportSQLiteOpenHelper {
                    val raw = delegate.create(configuration)
                    return object : SupportSQLiteOpenHelper by raw {
                        private var cached: Pair<SupportSQLiteDatabase, SupportSQLiteDatabase>? = null
                        @Synchronized private fun wrap(database: SupportSQLiteDatabase): SupportSQLiteDatabase {
                            cached?.takeIf { it.first === database }?.let { return it.second }
                            return tracked(database).also { cached = database to it }
                        }
                        override val writableDatabase get() = wrap(raw.writableDatabase)
                        override val readableDatabase get() = wrap(raw.readableDatabase)
                    }
                }
            }
            val helper = AccountFencedOpenHelperFactory(databaseFence, monitored).create(configuration)
            return object : SupportSQLiteOpenHelper by helper {
                @Volatile private var opened: SupportSQLiteDatabase? = null

                private fun database(writable: Boolean): SupportSQLiteDatabase {
                    // Room retrieves this handle again to finish/roll back an already-running transaction.
                    // Do not make that path wait behind restore's transaction drain.
                    opened?.takeIf { it.isOpen }?.let { return it }
                    return withStorageLock {
                        opened?.takeIf { it.isOpen } ?: run {
                            fence.check()
                            databaseFence.check()
                            (if (writable) helper.writableDatabase else helper.readableDatabase).also { opened = it }
                        }
                    }
                }

                override val writableDatabase: SupportSQLiteDatabase get() = database(true)
                override val readableDatabase: SupportSQLiteDatabase get() = database(false)
            }
        }
    }

    companion object {
        private val storageByPath = mutableMapOf<String, Storage>()

        fun capture(account: AccountStorageContext): AccountStorageMutationLease = synchronized(storageByPath) {
            val storage = storageByPath.getOrPut(account.root.absolutePath) { Storage() }
            val generation = storage.generations.getOrPut(account.identity.generation) { Generation() }
            generation.lease.get() ?: run {
                val fence = AccountWriteFence(account)
                if (generation.retired) fence.retire()
                AccountStorageMutationLease(storage, generation, fence).also {
                    // Keep the retirement tombstone, not an old Context/runtime graph, for the process lifetime.
                    generation.lease = java.lang.ref.WeakReference(it)
                }
            }
        }
    }
}
