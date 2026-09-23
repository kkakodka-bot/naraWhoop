package com.noop.push

import androidx.work.ListenableWorker

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SelfHostedPushWorkerPolicyTest {
    @Test fun pushNetworkGateHonorsWifiOnlyPreference() {
        assertTrue(isPushNetworkAvailable(wifiOnly = true, isConnected = true, isWifi = true, isUnmetered = true))
        assertFalse(isPushNetworkAvailable(wifiOnly = true, isConnected = true, isWifi = true, isUnmetered = false))
        assertFalse(isPushNetworkAvailable(wifiOnly = true, isConnected = true, isWifi = false, isUnmetered = true))
        assertTrue(isPushNetworkAvailable(wifiOnly = false, isConnected = true, isWifi = false, isUnmetered = false))
        assertFalse(isPushNetworkAvailable(wifiOnly = false, isConnected = false, isWifi = false, isUnmetered = false))
    }

    @Test fun retryableFailureRotatesSchedulingWithoutCommittingReceiptProgress() {
        assertEquals(3, persistedDeviceIndex(startDeviceIndex = 2, nextDeviceIndex = 3, retryableFailure = true))
    }

    @Test fun successfulSliceAdvancesDeviceIndex() {
        assertEquals(3, persistedDeviceIndex(startDeviceIndex = 2, nextDeviceIndex = 3, retryableFailure = false))
    }

    @Test fun genuineFailureRetryIsBoundedOnTheSameWorkRequestAttemptCount() {
        assertTrue(shouldRetryPush(0))
        assertTrue(shouldRetryPush(PUSH_MAX_ATTEMPTS - 2))
        assertFalse(shouldRetryPush(PUSH_MAX_ATTEMPTS - 1))
    }

    @Test fun scheduledPendingSuccessorIsNotBlockedByCurrentTerminalFailure() {
        val result = resultAfterScheduledContinuation(ListenableWorker.Result.failure(), scheduled = true)
        assertTrue(result is ListenableWorker.Result.Success)
    }

    @Test fun enqueueFailureCannotWriteTerminalStatusWhenSuccessorAlreadyOwnsSignal() {
        assertTrue(successorOwnsEnqueueFailure(currentRequestCouldReserve = false))
        assertFalse(successorOwnsEnqueueFailure(currentRequestCouldReserve = true))
    }

    @Test fun triggerAfterReacquireStillSchedulesSuccessorAtTerminalAttempt() {
        assertTrue(shouldScheduleLatePendingSuccessor(willRetry = false, settlementPending = true))
        assertFalse(shouldScheduleLatePendingSuccessor(willRetry = true, settlementPending = true))
        assertFalse(shouldScheduleLatePendingSuccessor(willRetry = false, settlementPending = false))
    }

    @Test fun capabilitiesMustEchoEnrolledUserAndSource() {
        val credential = credential()
        val matching = PushCapabilities(
            appendTables = emptySet(),
            mutableTables = emptySet(),
            userId = credential.userId,
            sourceId = credential.sourceId,
        )

        assertTrue(capabilitiesMatchEnrollment(matching, credential))
        assertFalse(capabilitiesMatchEnrollment(matching.copy(userId = OTHER_USER_ID), credential))
        assertFalse(capabilitiesMatchEnrollment(matching.copy(sourceId = OTHER_SOURCE_ID), credential))
    }

    @Test fun tokenRotationFencesOldWorkerWithoutResettingIdentityNamespace() {
        val endpoint = (PushEndpointPolicy.validate("https://receiver.example/push") as PushEndpointPolicy.Result.Valid).endpoint
        val captured = credential(uploadToken = UPLOAD_TOKEN)
        val rotated = credential(uploadToken = ROTATED_UPLOAD_TOKEN)
        val settings = SelfHostedPushSettings.forTest(SelfHostedPushSettingsTest.FakePushPrefs())

        assertFalse(pushIdentityStillCurrent(endpoint, endpoint, captured, rotated))
        assertTrue(pushIdentityStillCurrent(endpoint, endpoint, rotated, rotated))
        assertEquals(
            settings.progressNamespace(captured.userId, captured.sourceId, endpoint),
            settings.progressNamespace(rotated.userId, rotated.sourceId, endpoint),
        )
    }

    private fun credential(uploadToken: String = UPLOAD_TOKEN) = PushEnrollmentCredential(
        userId = USER_ID,
        sourceId = SOURCE_ID,
        tokenId = TOKEN_ID,
        uploadToken = uploadToken,
    )

    private companion object {
        const val USER_ID = "00000000-0000-4000-8000-000000000010"
        const val OTHER_USER_ID = "00000000-0000-4000-8000-000000000011"
        const val SOURCE_ID = "00000000-0000-4000-8000-000000000012"
        const val OTHER_SOURCE_ID = "00000000-0000-4000-8000-000000000013"
        const val TOKEN_ID = "00000000-0000-4000-8000-000000000014"
        const val UPLOAD_TOKEN = "noop_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        const val ROTATED_UPLOAD_TOKEN = "noop_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
}
