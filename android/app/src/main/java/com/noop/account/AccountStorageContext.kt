package com.noop.account

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.noop.NoopApplication
import com.noop.push.AccountIdentitySnapshot
import com.noop.push.CloudAuthClient
import java.io.File

/** Context-local storage routes do not change when another account signs in. */
class AccountStorageContext(base: Context, val identity: AccountIdentitySnapshot) : ContextWrapper(base) {
    val namespace = identity.scope?.namespace ?: "unassigned-${identity.generation}"
    val root = File(base.filesDir, "accounts-v1/$namespace")
    internal var runtime: AccountAppRuntime? = null
    override fun getApplicationContext(): Context = this
    override fun getFilesDir(): File = directory(root)
    override fun getCacheDir(): File = directory(File(root, "cache"))
    override fun getNoBackupFilesDir(): File = directory(File(root, "no-backup"))
    override fun getExternalFilesDir(type: String?): File = directory(File(root, "exports/${type ?: "files"}"))
    override fun getDatabasePath(name: String): File {
        val requested = File(name)
        require(requested.name.isNotBlank() && requested.name != "." && requested.name != "..")
        val parent = directory(File(root, "databases")).canonicalFile
        val target = File(parent, requested.name).canonicalFile
        require(target.parentFile == parent)
        // FrameworkSQLiteOpenHelper returns Room's absolute name through this API again.
        require(if (requested.isAbsolute) requested.canonicalFile == target else requested.name == name)
        return target
    }
    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
        baseContext.getSharedPreferences("account.$namespace.$name", mode)
    fun isCurrent(): Boolean = identity.context?.let { CloudAuthClient.isCurrent(baseContext, it) }
        ?: (CloudAuthClient.identitySnapshot(baseContext) == identity)
    private fun directory(file: File): File {
        check(file.isDirectory || file.mkdirs()) { "Account storage unavailable" }
        return file
    }
    companion object {
        fun capture(context: Context): AccountStorageContext {
            if (context is AccountStorageContext) return context
            var cursor = context
            while (cursor is ContextWrapper) {
                if (cursor is AccountStorageContext) return cursor
                if (cursor is NoopApplication) return cursor.accountRuntime.context
                cursor = cursor.baseContext
            }
            (context.applicationContext as? NoopApplication)?.let { return it.accountRuntime.context }
            return AccountStorageContext(context.applicationContext, CloudAuthClient.identitySnapshot(context))
        }
        fun runtime(context: Context): AccountAppRuntime? = capture(context).runtime
        fun platform(context: Context): Context = if (context is AccountStorageContext) platform(context.baseContext)
            else context.applicationContext
    }
}
