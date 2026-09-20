package com.noop.push

import android.content.SharedPreferences
import com.noop.account.AccountStorageContext
import com.noop.analytics.Baselines
import com.noop.ble.PuffinExperiment
import com.noop.ui.HrvWindow
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import com.noop.ui.UnitPrefs
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.ZoneId

/** Hooks actual preference saves without replaying preexisting local-only defaults at launch. */
class ScoringSettingsSync(
    private val account: AccountStorageContext,
    private val inputs: ScoringInputRuntime,
    private val scope: CoroutineScope,
    private val source: () -> ScoringInputSource?,
    private val ready: () -> Boolean = { SelfHostedPushSettings.from(account).enabledEndpoint() != null },
    private val timezone: () -> String = { ZoneId.systemDefault().id },
) {
    private val prefs = NoopPrefs.of(account)
    private val experiments = account.getSharedPreferences(PuffinExperiment.PREFS, 0)
    private val serial = Mutex()
    @Volatile private var retired = false
    private var listening = false
    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()
    private val configurationKeys = setOf(NoopPrefs.KEY_BANISTER_EFFORT, UnitPrefs.KEY_HRV_WINDOW,
        Baselines.hrvBaselineEpochKey, Baselines.recoveryBaselineEpochKey,
        PuffinExperiment.KEY_EXPERIMENTAL_SLEEP_V2, PuffinExperiment.KEY_MOTION_AWARE_WAKE)
    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key in configurationKeys) changed(ProfileStore.from(account), true)
    }

    fun start() {
        if (retired || listening) return
        listening = true
        prefs.registerOnSharedPreferenceChangeListener(listener)
        experiments.registerOnSharedPreferenceChangeListener(listener)
    }

    fun changed(profile: ProfileStore, configuration: Boolean): Job? {
        if (retired || !account.isCurrent() || !ready()) return null
        val captured = runCatching { source() }.getOrNull()
            ?: run { _error.value = "Settings upload waiting for a captured device"; return null }
        val zone = timezone()
        val profileValue = profile.scoringProfile(zone)
        val configValue = if (configuration) config(profile, captured) else null
        return scope.launch(Dispatchers.IO) {
            serial.withLock {
                if (retired || !account.isCurrent()) return@withLock
                try {
                    if (configValue == null) inputs.captureProfile(profileValue, captured)
                    else inputs.captureConfig(configValue, zone, captured)
                    if (!retired && account.isCurrent()) _error.value = null
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { if (!retired && account.isCurrent()) _error.value = "Settings input could not be saved for upload" }
            }
        }
    }

    /** Local denial capture has no cloud, Terms, network or server-presentation gate. */
    fun captureConsent(): ScoringConsentCapture? {
        if (retired || !account.isCurrent()) return null
        val captured = source() ?: return null
        return ScoringConsentCapture.capture(captured, config(ProfileStore.from(account), captured), timezone())
    }

    private fun config(profile: ProfileStore, captured: ScoringInputSource) = ScoringConfigInput(
        profile.scoringMaxHR(), NoopPrefs.effortMethod(account).name,
        UnitPrefs.hrvWindow(account) == HrvWindow.DEEP_SLEEP, PuffinExperiment.from(account).experimentalSleepV2,
        PuffinExperiment.from(account).motionAwareWake, null,
        prefs.getLong(Baselines.hrvBaselineEpochKey, 0L), prefs.getLong(Baselines.recoveryBaselineEpochKey, 0L),
        captured.serverDeviceId)

    fun retire() {
        retired = true
        if (listening) {
            prefs.unregisterOnSharedPreferenceChangeListener(listener)
            experiments.unregisterOnSharedPreferenceChangeListener(listener)
        }
        listening = false
    }
}
