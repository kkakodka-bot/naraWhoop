package com.noop.analytics

import com.noop.NoopApplication
import com.noop.ui.AppViewModel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** Actual shipped application installs policy before constructing any account/BLE/UI runtime. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = NoopApplication::class,
    instrumentedPackages = ["com.noop.analytics.PhoneComputeRuntime"])
class FinalHostedPhonePathsNativeTest {
    @Test fun coldApplicationAndViewModelRemainCaptureOnly() {
        val app = RuntimeEnvironment.getApplication() as NoopApplication
        assertTrue(PhoneComputeRuntime.finalHosted)
        val vm = AppViewModel(app)
        assertNotNull(vm.ble)
        assertNotNull(vm.repo)
        assertNull(vm.serverScores.overlay("2026-09-21"))
        vm.setBanisterEffort(true)
        vm.setNapDetectionEnabled(true)
        vm.setCycleTrackingEnabled(true)
        vm.setIllnessWatchEnabled(true)
        vm.setDetailedCapture(true)
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        kotlinx.coroutines.runBlocking {
            assertFalse(IntelligenceEngine.recomputeFitnessAgeOnly(vm.repo,
                com.noop.ui.ProfileStore.from(app.accountRuntime.context).toUserProfile(), vm.activeStrapId))
        }
        assertTrue(PhoneComputeRuntime.evidence().isEmpty())
        assertTrue(PhoneComputeRuntime.forbiddenAttempts().isEmpty())
        androidx.lifecycle.ViewModelStore().apply { put("hosted-test", vm); clear() }
        app.accountRuntime.close()
        println("FINAL_HOSTED_COLD_LAUNCH admitted=0 forbidden=0 application_and_viewmodel=true preferences_and_diagnostics=true profile_fitness=true")
    }
}
