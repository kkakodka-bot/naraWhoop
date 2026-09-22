package com.noop

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.annotation.PluralsRes
import androidx.annotation.StringRes
import androidx.glance.appwidget.updateAll
import kotlinx.coroutines.*
import com.noop.account.AccountAppRuntime
import com.noop.account.AccountStorageContext
import com.noop.ble.WhoopConnectionService
import com.noop.push.CloudAuthClient
import com.noop.push.SelfHostedPushScheduler
import com.noop.ui.AppLanguagePrefs
import java.util.concurrent.CopyOnWriteArrayList

class NoopApplication : Application() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val runtimeListeners = CopyOnWriteArrayList<() -> Unit>()
    private val presentationScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    @Volatile private var runtimeValue: AccountAppRuntime? = null
    val accountRuntime: AccountAppRuntime get() = checkNotNull(runtimeValue)
    val repository get() = accountRuntime.repository
    val deviceRegistry get() = accountRuntime.deviceRegistry
    val ble get() = accountRuntime.ble
    val sourceCoordinator get() = accountRuntime.sourceCoordinator
    val serverScoreRepository get() = accountRuntime.serverScoreRepository
    val activeDeviceId get() = accountRuntime.activeDeviceId
    fun onActiveDeviceAdopted(newId: String) = accountRuntime.onActiveDeviceAdopted(newId)

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(AppLanguagePrefs.wrap(base))
        instance = this
    }
    override fun onCreate() {
        super.onCreate()
        CrashCapture.install(this)
        switchRuntime()
        CloudAuthClient.observeIdentity {
            // Auth changes are already fenced synchronously by their session generation.
            if (Looper.myLooper() == Looper.getMainLooper()) switchRuntime()
            else mainHandler.post { switchRuntime() }
        }
    }
    private fun switchRuntime() {
        val identity = CloudAuthClient.identitySnapshot(this)
        val previous = runtimeValue
        if (previous?.identity == identity) return
        previous?.close()
        runCatching { stopService(Intent(this, WhoopConnectionService::class.java)) }
        previous?.identity?.context?.let { runCatching { SelfHostedPushScheduler.cancelSession(this, it) } }
        previous?.context?.let { runCatching { com.noop.account.AccountWorkContext.cancel(it) } }
        runtimeValue = AccountAppRuntime(AccountStorageContext(this, identity))
        // Remove old account content from already-published Android surfaces on every transition.
        getSystemService(android.app.NotificationManager::class.java)?.cancelAll()
        runtimeListeners.forEach { it() }
        accountRuntime.start()
        presentationScope.launch {
            runCatching { com.noop.widget.NoopGlanceWidget().updateAll(this@NoopApplication) }
            runCatching { com.noop.widget.NoopCompactGlanceWidget().updateAll(this@NoopApplication) }
            runCatching { com.noop.widget.CoachBriefGlanceWidget().updateAll(this@NoopApplication) }
        }
    }
    fun observeRuntime(listener: () -> Unit): AutoCloseable {
        runtimeListeners.add(listener)
        return AutoCloseable { runtimeListeners.remove(listener) }
    }

    companion object {
        @Volatile private var instance: NoopApplication? = null

        /** Resolve app-owned UI copy from composable and non-composable presentation helpers alike. */
        fun localizedString(@StringRes id: Int, vararg formatArgs: Any): String {
            val app = checkNotNull(instance) { "NoopApplication is not attached" }
            return if (formatArgs.isEmpty()) app.getString(id) else app.getString(id, *formatArgs)
        }

        /** Quantity-aware twin of [localizedString]: resolves a `<plurals>` for [count] under the active
         *  locale's own plural rules. Same Application-resources path, so it stays locale-aware off the
         *  composition. */
        fun localizedPlural(@PluralsRes id: Int, count: Int, vararg formatArgs: Any): String {
            val app = checkNotNull(instance) { "NoopApplication is not attached" }
            return app.resources.getQuantityString(id, count, *formatArgs)
        }
    }
}
