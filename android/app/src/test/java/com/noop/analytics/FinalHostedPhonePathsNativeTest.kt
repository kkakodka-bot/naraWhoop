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
    @Test
    // The intentional violation has its own production class loader; policy/counters are never reset.
    @Config(application = android.app.Application::class, instrumentedPackages = [
        "com.noop.analytics.PhoneComputeRuntime", "com.noop.NoopApplication", "com.noop.analytics.HrvAnalyzer"])
    fun attachedApplicationBlocksProviderInferenceBeforeOnCreate() {
        assertFalse(PhoneComputeRuntime.finalHosted)
        val app = NoopApplication()
        org.robolectric.util.ReflectionHelpers.callInstanceMethod<Void>(app, "attachBaseContext",
            org.robolectric.util.ReflectionHelpers.ClassParameter.from(android.content.Context::class.java,
                RuntimeEnvironment.getApplication()))
        assertTrue(PhoneComputeRuntime.finalHosted)
        assertThrows(IllegalStateException::class.java) { app.accountRuntime }
        var providerCreated = false
        val provider = object : android.content.ContentProvider() {
            override fun onCreate(): Boolean {
                providerCreated = true
                assertThrows(IllegalStateException::class.java) { app.accountRuntime }
                assertNull(CurrentHrv.derive(emptyList(), 1_700_000_000))
                assertTrue(PhoneComputeRuntime.evidence().isEmpty())
                assertTrue(PhoneComputeRuntime.forbiddenAttempts().isEmpty())
                println("FINAL_HOSTED_PROVIDER_STARTUP admitted=0 forbidden=0 attach_only=true provider_callback=true")
                assertThrows(IllegalStateException::class.java) {
                    HrvAnalyzer.rmssdRaw(listOf(800.0, 810.0, 805.0))
                }
                assertTrue(PhoneComputeRuntime.evidence().isEmpty())
                assertEquals(mapOf("HrvAnalyzer.rmssdRaw" to 1L), PhoneComputeRuntime.forbiddenAttempts())
                println("FINAL_HOSTED_PROVIDER_NEGATIVE_CONTROL admitted=0 forbidden=1 blocked_before_body=true")
                return true
            }
            override fun getType(uri: android.net.Uri) = null
            override fun query(uri: android.net.Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?) = null
            override fun insert(uri: android.net.Uri, values: android.content.ContentValues?) = null
            override fun delete(uri: android.net.Uri, selection: String?, selectionArgs: Array<out String>?) = 0
            override fun update(uri: android.net.Uri, values: android.content.ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
        }
        provider.attachInfo(app, android.content.pm.ProviderInfo().apply { authority = "com.noop.test.hosted-startup" })
        assertTrue(providerCreated)
        assertThrows(IllegalStateException::class.java) { app.accountRuntime }
    }

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
