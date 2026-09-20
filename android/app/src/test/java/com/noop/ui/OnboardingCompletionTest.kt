package com.noop.ui

import com.noop.push.SelfHostedPushSettingsTest
import org.junit.Assert.*
import org.junit.Test

class OnboardingCompletionTest {
    @Test fun failedOrMissingDeviceAckKeepsSetupAndDoesNotCompleteOnboarding() {
        val prefs = SelfHostedPushSettingsTest.FakePushPrefs()
        prefs.edit().putBoolean(NoopPrefs.KEY_SETUP_FINISHED, true).commit()
        assertFalse(OnboardingCompletion.record(prefs, false, "test-version"))
        assertFalse(prefs.getBoolean(NoopPrefs.KEY_ONBOARDED, false))
        assertTrue(prefs.getBoolean(NoopPrefs.KEY_SETUP_FINISHED, false))
        assertFalse(prefs.contains(NoopPrefs.KEY_LAST_SEEN_CHANGELOG))
        assertTrue(OnboardingCompletion.record(prefs, true, "test-version"))
        assertTrue(prefs.getBoolean(NoopPrefs.KEY_ONBOARDED, false))
    }
}
