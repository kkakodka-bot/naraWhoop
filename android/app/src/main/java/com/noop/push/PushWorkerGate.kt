package com.noop.push

/** Ordering seam: stale/disabled work exits before network, Keystore, Room, or HTTP are touched. */
internal object PushWorkerGate {
    sealed interface Outcome {
        data object DisabledOrInvalid : Outcome
        data object NetworkUnavailable : Outcome
        data object MissingFleetToken : Outcome
        data object MissingEnrollment : Outcome
        data class Executed(val retry: Boolean) : Outcome
    }

    suspend fun run(
        enabledEndpoint: () -> PushEndpointPolicy.ValidEndpoint?,
        networkAvailable: () -> Boolean,
        fleetToken: () -> String?,
        credential: () -> PushEnrollmentCredential?,
        execute: suspend (PushEndpointPolicy.ValidEndpoint, String, PushEnrollmentCredential) -> Boolean,
    ): Outcome {
        val endpoint = enabledEndpoint() ?: return Outcome.DisabledOrInvalid
        if (!networkAvailable()) return Outcome.NetworkUnavailable
        val fleet = fleetToken() ?: return Outcome.MissingFleetToken
        val enrollment = credential() ?: return Outcome.MissingEnrollment
        return Outcome.Executed(retry = execute(endpoint, fleet, enrollment))
    }
}
