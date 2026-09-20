package com.noop.push

import android.content.Context
import com.noop.BuildConfig

/** Non-UI enrollment API that performs the exchange and persists only the resulting credential. */
class PushEnrollmentManager internal constructor(
    private val settings: SelfHostedPushSettings,
    private val store: PushEnrollmentStore,
    private val clientFactory: (PushEndpointPolicy.ValidEndpoint, String, String) -> PushEnrollmentClient,
    private val appVersion: String,
    private val onCredentialChanged: () -> Unit,
    private val onEnrolled: () -> Unit = {},
) {
    suspend fun enroll(code: String): PushEnrollmentResult {
        val endpoint = settings.configuredEndpoint()
            ?: return PushEnrollmentResult.Failure(PushEnrollmentFailureCode.NOT_CONFIGURED)
        val fleetToken = settings.fleetToken()
            ?: return PushEnrollmentResult.Failure(PushEnrollmentFailureCode.NOT_CONFIGURED)
        val sourceId = settings.sourceId()
        // Settle invalid/mismatched remnants before capturing the credential epoch.
        store.load(sourceId)
        val generation = store.generation()
        val result = clientFactory(endpoint, fleetToken, appVersion).enroll(code, sourceId)
        if (result !is PushEnrollmentResult.Success) return result

        val existing = store.load(sourceId)
        if (store.boundUserId()?.let { it != result.credential.userId } == true ||
            (existing != null && existing.userId != result.credential.userId)) {
            return PushEnrollmentResult.Failure(PushEnrollmentFailureCode.IDENTITY_CONFLICT)
        }
        val persisted = synchronized(store) {
            try {
                if (!store.saveIfCurrent(generation, sourceId, result.credential)) {
                    return@synchronized PushEnrollmentResult.Failure(PushEnrollmentFailureCode.IDENTITY_CONFLICT)
                }
                settings.recordEnrollmentBinding(result.credential)
                check(settings.setEnabled(true)) { "Could not enable enrolled upload" }
                onEnrolled()
                result
            } catch (_: Throwable) {
                runCatching { store.clearIfCurrent(result.credential) }
                runCatching { settings.clearEnrollmentBinding() }
                PushEnrollmentResult.Failure(PushEnrollmentFailureCode.STORAGE)
            }
        }
        if (persisted is PushEnrollmentResult.Success) runCatching(onCredentialChanged)
        return persisted
    }

    fun currentCredential(): PushEnrollmentCredential? = synchronized(store) {
        val credential = store.load(settings.sourceId())
        if (credential == null) runCatching { settings.clearEnrollmentBinding() }
        return credential
    }

    fun clearIfCurrent(credential: PushEnrollmentCredential): Boolean {
        synchronized(store) {
            if (!store.clearIfCurrent(credential)) return false
            settings.clearEnrollmentBinding()
        }
        runCatching(onCredentialChanged)
        return true
    }

    fun clear() {
        synchronized(store) {
            store.clear()
            settings.clearEnrollmentBinding()
        }
        runCatching(onCredentialChanged)
    }

    companion object {
        fun from(context: Context): PushEnrollmentManager {
            val app = context.applicationContext
            return PushEnrollmentManager(
                settings = SelfHostedPushSettings.from(app),
                store = PushEnrollmentStore.from(app),
                clientFactory = { endpoint, fleetToken, appVersion ->
                    PushEnrollmentClient(endpoint, fleetToken, appVersion)
                },
                appVersion = BuildConfig.VERSION_NAME,
                onCredentialChanged = {
                    SelfHostedPushScheduler.credentialChanged(app)
                    if (EnrollmentDataScope.active(app)) {
                        (app as? com.noop.NoopApplication)?.serverScoreRepository
                            ?.startPolling(java.time.LocalDate.now().toString())
                    }
                },
                onEnrolled = { ServerScoringSettings.setEnabled(app, true) },
            )
        }
    }
}
