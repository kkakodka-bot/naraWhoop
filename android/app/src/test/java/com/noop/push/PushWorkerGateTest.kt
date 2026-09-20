package com.noop.push

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class PushWorkerGateTest {
    @Test fun staleDisabledWorkReturnsWithoutNetworkTokenDatabaseOrHttp() = runBlocking {
        var networkCalls = 0
        var fleetCalls = 0
        var credentialCalls = 0
        var executeCalls = 0

        val outcome = PushWorkerGate.run(
            enabledEndpoint = { null },
            networkAvailable = { networkCalls++; true },
            fleetToken = { fleetCalls++; "fleet-secret" },
            credential = { credentialCalls++; credential() },
            execute = { _, _, _ -> executeCalls++; false },
        )

        assertEquals(PushWorkerGate.Outcome.DisabledOrInvalid, outcome)
        assertEquals(0, networkCalls)
        assertEquals(0, fleetCalls)
        assertEquals(0, credentialCalls)
        assertEquals(0, executeCalls)
    }

    @Test fun disallowedNetworkStopsBeforeKeystoreDatabaseAndHttp() = runBlocking {
        val endpoint = (PushEndpointPolicy.validate("https://example.com/") as PushEndpointPolicy.Result.Valid).endpoint
        var fleetCalls = 0
        var credentialCalls = 0
        var executeCalls = 0

        val outcome = PushWorkerGate.run(
            enabledEndpoint = { endpoint },
            networkAvailable = { false },
            fleetToken = { fleetCalls++; "fleet-secret" },
            credential = { credentialCalls++; credential() },
            execute = { _, _, _ -> executeCalls++; false },
        )

        assertEquals(PushWorkerGate.Outcome.NetworkUnavailable, outcome)
        assertEquals(0, fleetCalls)
        assertEquals(0, credentialCalls)
        assertEquals(0, executeCalls)
    }

    @Test fun missingEnrollmentStopsBeforeDatabaseAndHttp() = runBlocking {
        val endpoint = (PushEndpointPolicy.validate("https://example.com/") as PushEndpointPolicy.Result.Valid).endpoint
        var executeCalls = 0

        val outcome = PushWorkerGate.run(
            enabledEndpoint = { endpoint },
            networkAvailable = { true },
            fleetToken = { "fleet-secret" },
            credential = { null },
            execute = { _, _, _ -> executeCalls++; false },
        )

        assertEquals(PushWorkerGate.Outcome.MissingEnrollment, outcome)
        assertEquals(0, executeCalls)
    }

    private fun credential() = PushEnrollmentCredential(
        userId = "00000000-0000-4000-8000-000000000010",
        sourceId = "00000000-0000-4000-8000-000000000011",
        tokenId = "00000000-0000-4000-8000-000000000012",
        uploadToken = "noop_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    )
}
