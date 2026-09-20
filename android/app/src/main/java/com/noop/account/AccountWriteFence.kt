package com.noop.account

import android.content.ContentValues
import android.database.sqlite.SQLiteTransactionListener
import android.database.Cursor
import android.os.CancellationSignal
import androidx.sqlite.db.*
import com.noop.push.AccountAuthException
import com.noop.push.AuthFailure
import com.noop.push.CloudAuthClient

class AccountWriteRevokedException : IllegalStateException("Account write generation retired") {
    val failure = AuthFailure.STALE
}

/** The commit lock is shared with auth invalidation, not merely a pre-SQL cancellation check. */
class AccountWriteFence(private val account: AccountStorageContext) {
    private val lock = Any()
    private var retired = false
    fun retire() = synchronized(lock) { retired = true }
    fun admitsWrites(): Boolean = try { check(); true } catch (_: AccountWriteRevokedException) { false }
    fun check() = commit { Unit }
    fun <T> commit(body: () -> T): T {
        try {
            return CloudAuthClient.withIdentity(account, account.identity) {
                synchronized(lock) {
                    if (retired) throw AccountWriteRevokedException()
                    body()
                }
            }
        } catch (failure: AccountAuthException) {
            if (failure.failure == AuthFailure.STALE) throw AccountWriteRevokedException()
            throw failure
        }
    }
}

/** Delays SQLite's success mark until endTransaction so revocation can still roll back executed SQL. */
class AccountFencedOpenHelperFactory(
    private val fence: AccountWriteFence,
    private val delegate: SupportSQLiteOpenHelper.Factory = com.noop.data.CorruptionPreservingOpenHelperFactory(),
) : SupportSQLiteOpenHelper.Factory {
    override fun create(configuration: SupportSQLiteOpenHelper.Configuration): SupportSQLiteOpenHelper {
        val helper = delegate.create(configuration)
        return object : SupportSQLiteOpenHelper by helper {
            private var cached: Pair<SupportSQLiteDatabase, SupportSQLiteDatabase>? = null
            @Synchronized private fun wrap(db: SupportSQLiteDatabase): SupportSQLiteDatabase {
                cached?.takeIf { it.first === db }?.let { return it.second }
                return FencedDatabase(db, fence).also { cached = db to it }
            }
            // Room must still retrieve the handle in its finally block to roll back after retirement.
            override val writableDatabase: SupportSQLiteDatabase get() = wrap(helper.writableDatabase)
            override val readableDatabase: SupportSQLiteDatabase get() = wrap(helper.readableDatabase)
        }
    }
}

private class FencedDatabase(private val db: SupportSQLiteDatabase, private val fence: AccountWriteFence) : SupportSQLiteDatabase by db {
    private data class Transaction(var success: Boolean = false)
    private val transactions = ThreadLocal.withInitial { java.util.ArrayDeque<Transaction>() }
    private fun stack() = checkNotNull(transactions.get())
    override fun beginTransaction() { fence.check(); db.beginTransaction(); stack().addLast(Transaction()) }
    override fun beginTransactionNonExclusive() { fence.check(); db.beginTransactionNonExclusive(); stack().addLast(Transaction()) }
    override fun beginTransactionWithListener(transactionListener: SQLiteTransactionListener) =
        throw UnsupportedOperationException("Use fenced Room transactions")
    override fun beginTransactionWithListenerNonExclusive(transactionListener: SQLiteTransactionListener) =
        throw UnsupportedOperationException("Use fenced Room transactions")
    override fun setTransactionSuccessful() {
        val transaction = checkNotNull(stack().peekLast())
        check(!transaction.success); transaction.success = true
    }
    override fun endTransaction() {
        val transaction = checkNotNull(stack().pollLast())
        var ended = false
        try {
            if (transaction.success) fence.commit {
                db.setTransactionSuccessful()
                ended = true
                db.endTransaction()
            } else { ended = true; db.endTransaction() }
        } finally {
            // On revocation no success was forwarded, so SQLite rolls back, including nested work.
            if (!ended) db.endTransaction()
            if (stack().isEmpty()) transactions.remove()
        }
    }
    override fun yieldIfContendedSafely() = false
    override fun yieldIfContendedSafely(sleepAfterYieldDelayMillis: Long) = false
    private fun <T> write(body: () -> T): T {
        if (stack().isNotEmpty()) { fence.check(); return body() }
        // Do not hold the identity lock while waiting for SQLite's writer lock.
        beginTransactionNonExclusive()
        try { val result = body(); setTransactionSuccessful(); return result } finally { endTransaction() }
    }
    private fun statementSql(sql: String) {
        require(!Regex("(?is)^\\s*(?:/\\*.*?\\*/\\s*|--[^\\n]*\\n\\s*)*(BEGIN|END|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|ATTACH|DETACH)\\b").containsMatchIn(sql)) {
            "Transaction control must use the fenced API"
        }
    }
    private fun querySql(sql: String) {
        // SQLite query() can otherwise execute a write lazily when its cursor is stepped.
        require(Regex("(?is)^\\s*(SELECT|EXPLAIN|PRAGMA)\\b").containsMatchIn(sql) ||
            (Regex("(?is)^\\s*WITH\\b").containsMatchIn(sql) && !Regex("(?i)\\b(INSERT|UPDATE|DELETE|REPLACE)\\b").containsMatchIn(sql))) {
            "Mutation cursors are not supported by the fenced store"
        }
        if (sql.trimStart().startsWith("PRAGMA", true)) require(!sql.contains('='))
    }
    override fun query(query: String): Cursor { querySql(query); return db.query(query) }
    override fun query(query: String, bindArgs: Array<out Any?>): Cursor { querySql(query); return db.query(query, bindArgs) }
    override fun query(query: SupportSQLiteQuery): Cursor { querySql(query.sql); return db.query(query) }
    override fun query(query: SupportSQLiteQuery, cancellationSignal: CancellationSignal?): Cursor {
        querySql(query.sql); return db.query(query, cancellationSignal)
    }
    override fun execSQL(sql: String) { statementSql(sql); write { db.execSQL(sql) } }
    override fun execSQL(sql: String, bindArgs: Array<out Any?>) { statementSql(sql); write { db.execSQL(sql, bindArgs) } }
    override fun insert(table: String, conflictAlgorithm: Int, values: ContentValues): Long = write { db.insert(table, conflictAlgorithm, values) }
    override fun update(table: String, conflictAlgorithm: Int, values: ContentValues, whereClause: String?, whereArgs: Array<out Any?>?): Int =
        write { db.update(table, conflictAlgorithm, values, whereClause, whereArgs) }
    override fun delete(table: String, whereClause: String?, whereArgs: Array<out Any?>?): Int = write { db.delete(table, whereClause, whereArgs) }
    override fun compileStatement(sql: String): SupportSQLiteStatement {
        statementSql(sql)
        val statement = db.compileStatement(sql)
        return object : SupportSQLiteStatement by statement {
            override fun execute() = write { statement.execute() }
            override fun executeInsert(): Long = write { statement.executeInsert() }
            override fun executeUpdateDelete(): Int = write { statement.executeUpdateDelete() }
            override fun simpleQueryForLong(): Long = write { statement.simpleQueryForLong() }
            override fun simpleQueryForString(): String? = write { statement.simpleQueryForString() }
        }
    }
}
