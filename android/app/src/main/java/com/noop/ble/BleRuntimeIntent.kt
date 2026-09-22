package com.noop.ble

import android.Manifest
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.noop.account.AccountStorageContext
import com.noop.push.EnrollmentDataScope
import com.noop.push.SelfHostedPushSettings
import com.noop.ui.NoopPrefs

data class BleRuntimeTarget(val deviceId: String, val address: String, val model: WhoopModel)

/** Durable user intent, not a claim that the OS will grant execution. Session generation is
 * deliberately not persisted as authorization: an ordinary process restart creates a new one. */
class BleRuntimeIntent internal constructor(private val account: AccountStorageContext,
    private val permitted: () -> Boolean, private val latestUserStop: () -> Long?) {
    constructor(account: AccountStorageContext) : this(account,
        { EnrollmentDataScope.active(account) && permissions(account) },
        { if (Build.VERSION.SDK_INT >= 30) kotlin.runCatching {
            account.getSystemService(ActivityManager::class.java)?.getHistoricalProcessExitReasons(null, 0, 0)
                ?.filter { it.reason == ApplicationExitInfo.REASON_USER_REQUESTED }?.maxOfOrNull { it.timestamp }
        }.getOrNull() else null })
    private val prefs = account.getSharedPreferences("ble-runtime-v1", Context.MODE_PRIVATE)

    fun authorize(): Boolean {
        if (!eligible()) return false
        return prefs.edit().putBoolean("enabled", true).putBoolean("storageBlocked", false).putString("namespace", account.namespace)
            .putString("source", SelfHostedPushSettings.from(account).sourceId())
            .putLong("authorizedAt", System.currentTimeMillis()).commit()
    }

    fun stop(): Boolean = prefs.edit().putBoolean("enabled", false).commit()

    fun pauseForStorage(): Boolean = prefs.edit().putBoolean("storageBlocked", true).commit()

    fun mayRun(): Boolean {
        if (!eligible() || !prefs.getBoolean("enabled", false) || prefs.getBoolean("storageBlocked", false) ||
            prefs.getString("namespace", null) != account.namespace ||
            prefs.getString("source", null) != SelfHostedPushSettings.from(account).sourceId()) return false
        // Android force-stop suppresses jobs/receivers. Also honor Task Manager Stop when another
        // component later wakes the process; only a subsequent explicit Connect authorizes recovery.
        if (latestUserStop()?.let { it >= prefs.getLong("authorizedAt", 0) } == true) {
            stop() // Preserve the observed stop even after Android rotates its exit-history log.
            return false
        }
        return true
    }

    fun target(): BleRuntimeTarget? {
        if (!mayRun()) return null
        val id = prefs.getString("device", null)?.takeIf { it.isNotBlank() } ?: return null
        val address = prefs.getString("address", null)?.takeIf { BluetoothAdapter.checkBluetoothAddress(it) } ?: return null
        val model = prefs.getString("model", null)?.let { runCatching { WhoopModel.valueOf(it) }.getOrNull() } ?: return null
        return BleRuntimeTarget(id, address, model)
    }

    fun remember(target: BleRuntimeTarget): Boolean {
        if (!mayRun() || !BluetoothAdapter.checkBluetoothAddress(target.address)) return false
        return prefs.edit().putString("device", target.deviceId).putString("address", target.address)
            .putString("model", target.model.name).commit()
    }

    private fun eligible() = account.identity.scope != null && account.isCurrent() &&
        NoopPrefs.backgroundConnection(account) && permitted()

    companion object {
        fun permissions(context: Context): Boolean = Build.VERSION.SDK_INT < 31 ||
            listOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN).all {
                ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
            }
    }
}

/** These broadcasts are eligible background-start contexts, not a periodic start-service loop. */
class BleRecoveryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            WhoopConnectionService.start(context, userInitiated = false)
        }
    }
}
