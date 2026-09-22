package com.noop.push

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ListenableWorker
import androidx.work.WorkerParameters
import com.noop.R
import com.noop.data.WhoopDatabase
import androidx.sqlite.db.SimpleSQLiteQuery
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.WeakHashMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.CancellationException

internal fun persistedDeviceIndex(startDeviceIndex: Int, nextDeviceIndex: Int, retryableFailure: Boolean): Int =
    if (retryableFailure) startDeviceIndex else nextDeviceIndex
internal const val PUSH_MAX_ATTEMPTS = 32
internal fun shouldRetryPush(runAttemptCount: Int): Boolean = runAttemptCount + 1 < PUSH_MAX_ATTEMPTS
internal fun resultAfterScheduledContinuation(
    current: ListenableWorker.Result,
    scheduled: Boolean,
): ListenableWorker.Result = if (scheduled) ListenableWorker.Result.success() else current
internal fun successorOwnsEnqueueFailure(currentRequestCouldReserve: Boolean): Boolean =
    !currentRequestCouldReserve
internal fun shouldScheduleLatePendingSuccessor(willRetry: Boolean, settlementPending: Boolean): Boolean =
    !willRetry && settlementPending
internal fun isPushNetworkAvailable(
    wifiOnly: Boolean,
    isConnected: Boolean,
    isWifi: Boolean,
    isUnmetered: Boolean,
): Boolean = isConnected && (!wifiOnly || (isWifi && isUnmetered))
internal fun isPushNetworkAvailable(context: Context, wifiOnly: Boolean): Boolean {
    val connectivity = context.getSystemService(ConnectivityManager::class.java) ?: return false
    val network = connectivity.activeNetwork ?: return false
    val capabilities = connectivity.getNetworkCapabilities(network) ?: return false
    return isPushNetworkAvailable(
        wifiOnly = wifiOnly,
        isConnected = true,
        isWifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI),
        isUnmetered = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
    )
}

/** One bounded coordinator run. Unique WorkManager work and the trigger lease keep it serial. */
class SelfHostedPushWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    private val storageContext by lazy { com.noop.account.AccountStorageContext.capture(applicationContext) }
    private data class Decision(
        val result: Result,
        val willRetry: Boolean,
        val continueNormally: Boolean = false,
        val status: Status = Status.NONE,
        val message: String? = null,
    )

    private data class ExecutionOutcome(
        val state: Execution,
        val failure: PushFailure? = null,
    )

    private enum class Execution {
        COMPLETE,
        CONTINUE,
        RETRY_FAILURE,
        CAPABILITY_TERMINAL_FAILURE,
        TERMINAL_FAILURE,
    }
    private enum class Status { NONE, SUCCESS, CONTINUING, RETRYING, FAILED }

    override suspend fun doWork(): Result {
        val current = CloudAuthClient.identitySnapshot(applicationContext).context ?: return Result.success()
        if (!AccountPushJobAdmission.matches(current, inputData.getString(AccountPushJobAdmission.NAMESPACE),
                inputData.getString(AccountPushJobAdmission.GENERATION))) return Result.success()
        val settings = SelfHostedPushSettings.from(storageContext)
        // Disabled work performs no DB scans or network requests.
        val requestId = id.toString()
        if (settings.enabledEndpoint() == null) {
            PushRunSignal.releaseReservation(storageContext, requestId)
            return Result.success()
        }
        val captured = settings.capturedContext ?: return Result.retry()
        if (!AccountPushJobAdmission.matches(captured,
                inputData.getString(AccountPushJobAdmission.NAMESPACE),
                inputData.getString(AccountPushJobAdmission.GENERATION))) return Result.success()
        val binding = try {
            AccountPushCaptureBindings.binding(captured) ?: withContext(Dispatchers.IO) {
                val database = WhoopDatabase.get(storageContext)
                database.openHelper.writableDatabase
                AccountPushCaptureBindings.bind(database, captured.scope, settings.sourceId(),
                    com.noop.testcentre.ImuSessionFileStore(storageContext))
                AccountPushCaptureBindings.binding(captured)
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { return Result.retry() }
        if (binding == null) return Result.retry()
        try { AccountPushCaptureBindings.validateOwner(binding) } catch (_: AccountAuthException) { return Result.retry() }
        if (!CloudAuthClient.isCurrent(storageContext, captured)) return Result.retry()
        var ownerFinished = false
        try {
            PushRunSignal.begin(storageContext, requestId)
            settings.recordRunning()
            var execution = ExecutionOutcome(Execution.COMPLETE)
            var decision = try {
                when (val outcome = PushWorkerGate.run(
                    enabledEndpoint = settings::enabledEndpoint,
                    networkAvailable = {
                        isPushNetworkAvailable(storageContext, wifiOnly = settings.wifiOnly())
                    },
                    token = settings::token,
                    execute = { endpoint, _ ->
                        execution = executeOnce(settings, endpoint, captured, binding)
                        execution.state == Execution.RETRY_FAILURE
                    },
                )) {
                    PushWorkerGate.Outcome.DisabledOrInvalid -> Decision(Result.success(), false)
                    PushWorkerGate.Outcome.MissingToken -> Decision(
                        Result.retry(), true, status = Status.FAILED,
                        message = storageContext.getString(R.string.push_error_missing_token),
                    )
                    PushWorkerGate.Outcome.NetworkUnavailable -> retryOrStop(
                        storageContext.getString(R.string.push_error_network),
                    )
                    is PushWorkerGate.Outcome.Executed -> when {
                        outcome.retry -> retryOrStop(failureMessage(execution.failure))
                        execution.state == Execution.CONTINUE -> Decision(
                            Result.success(), false, continueNormally = true, status = Status.CONTINUING,
                        )
                        execution.state == Execution.CAPABILITY_TERMINAL_FAILURE -> Decision(
                            Result.failure(), false, status = Status.FAILED,
                            message = failureMessage(execution.failure),
                        )
                        execution.state == Execution.TERMINAL_FAILURE -> Decision(
                            Result.failure(), false, status = Status.FAILED,
                            message = failureMessage(execution.failure),
                        )
                        else -> Decision(Result.success(), false, status = Status.SUCCESS)
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: AccountAuthException) {
                Decision(Result.retry(), true, status = Status.RETRYING,
                    message = "Upload is waiting for its authenticated capture owner.")
            } catch (_: Throwable) {
                // Deliberately generic: exception strings from TLS/HTTP stacks may include destination data.
                retryOrStop(storageContext.getString(R.string.push_error_start))
            }
            if (!CloudAuthClient.isCurrent(storageContext, captured)) {
                PushRunSignal.finish(storageContext, requestId, willRetry = true)
                ownerFinished = true
                return Result.retry()
            }
            val settlement = PushRunSignal.settle(
                storageContext, requestId, willRetry = decision.willRetry,
            ) { pending -> recordSettledStatus(settings, decision, pending) }
            ownerFinished = true
            // Healthy pagination/device rotation is a fresh successful work item. This deliberately
            // avoids WorkManager retry/backoff, which is reserved for real network/HTTP failures.
            val needsContinuation = !decision.willRetry && (decision.continueNormally || settlement.pending)
            if (needsContinuation && !SelfHostedPushScheduler.enqueueContinuation(storageContext)) {
                // The append Operation itself failed asynchronously. Re-arm THIS WorkRequest so
                // WorkManager's bounded runAttemptCount/backoff handles the infrastructure failure.
                val enqueueRetry = retryOrStop(storageContext.getString(R.string.push_error_queue))
                val currentCouldReserve = PushRunSignal.reserve(storageContext, requestId)
                if (successorOwnsEnqueueFailure(currentCouldReserve)) {
                    // The preserved pending trigger already owns QUEUED work. Do not let this old
                    // failure (especially terminal attempt 31) overwrite its status or block it.
                    return Result.success()
                }
                PushRunSignal.begin(storageContext, requestId)
                val enqueueFailureSettlement = PushRunSignal.settle(
                    storageContext, requestId, willRetry = enqueueRetry.willRetry,
                ) { pending -> recordSettledStatus(settings, enqueueRetry, pending) }
                if (shouldScheduleLatePendingSuccessor(
                        enqueueRetry.willRetry,
                        enqueueFailureSettlement.pending,
                    )
                ) {
                    val scheduled = SelfHostedPushScheduler.enqueueContinuation(
                        storageContext,
                        preserveTriggerOnFailure = true,
                    )
                    // A terminal attempt must succeed only when its APPEND prerequisite was actually
                    // installed (or another owner won inside enqueueContinuation). No retry reset.
                    return resultAfterScheduledContinuation(enqueueRetry.result, scheduled)
                }
                return enqueueRetry.result
            }
            // APPEND successors depend on this WorkSpec succeeding. A fresh pending trigger must not
            // be left BLOCKED behind a terminal failure from the snapshot that preceded that trigger.
            return resultAfterScheduledContinuation(decision.result, scheduled = needsContinuation)
        } finally {
            if (!ownerFinished) runCatching {
                PushRunSignal.finish(storageContext, requestId, willRetry = false)
            }
        }
    }

    private suspend fun executeOnce(
        settings: SelfHostedPushSettings,
        endpoint: PushEndpointPolicy.ValidEndpoint,
        captured: AccountSessionContext,
        binding: AccountPushCaptureBindings.Binding,
    ): ExecutionOutcome {
        val authorization = CloudAuthClient.authorizedSession(storageContext)
        if (authorization.context != captured) throw AccountAuthException(AuthFailure.STALE)
        AccountPushCaptureBindings.validateOwner(binding)
        val sourceId = binding.sourceID
        val admission = AccountPushAdmission(captured, binding.scope, sourceId) {
            CloudAuthClient.isCurrent(storageContext, it) && settings.enabledEndpoint() == endpoint
        }
        if (endpoint.url.trimEnd('/') != captured.scope.projectURL + "/functions/v1/push") {
            throw AccountAuthException(AuthFailure.INVALID_IDENTITY)
        }
        // Derive progress from the exact endpoint captured by the stale-work gate. Re-reading prefs
        // here could otherwise pair an E1 HTTP request with E2 cursor state during a concurrent edit.
        val baseTransport = PushHttpTransport(endpoint, authorization.accessToken) { batch ->
            if (settings.isCurrent()) settings.recordCurrentStream(batch.table.wireName)
        }
        val transport = AccountFencedTransport(baseTransport, admission) {
            readOwnerCapabilities(endpoint, authorization.accessToken, captured.scope)
        }
        val capabilities = when (val result = transport.capabilities()) {
            is PushCapabilitiesResult.Available -> result.capabilities
            is PushCapabilitiesResult.Rejected -> {
                return if (result.retryable) {
                    ExecutionOutcome(
                        Execution.RETRY_FAILURE,
                        result.failure ?: PushFailure(PushFailureCode.NETWORK_IO),
                    )
                } else {
                    ExecutionOutcome(
                        Execution.CAPABILITY_TERMINAL_FAILURE,
                        result.failure ?: PushFailure(PushFailureCode.CAPABILITIES_INVALID),
                    )
                }
            }
        }
        runCatching { settings.recordCapabilities(endpoint, capabilities) }
        val namespace = settings.progressNamespace(
            sourceId,
            endpoint,
            capabilities.protocolVersion,
            capabilities.receiverStateId,
        )
        // Capability discovery deliberately precedes Room: unsupported streams cause no table scan,
        // snapshot allocation, encoding, or POST. An empty allowlist is a valid caught-up receiver.
        if (capabilities.isEmpty) {
            settings.saveNextDeviceIndex(namespace, 0)
            settings.saveCycleNeedsAnotherPass(namespace, false)
            settings.saveCycleHadRejection(namespace, false)
            settings.saveCycleFailure(namespace, null)
            return ExecutionOutcome(Execution.COMPLETE)
        }
        // The runtime supplied this fixed writer; the global legacy database is never opened here.
        val dao = AccountFencedSnapshot(binding.database.pushDao(binding.imuSource), admission)
        val progress = AccountFencedProgress(EndpointScopedProgressStore(
            SharedPrefsPushProgressStore.from(storageContext), namespace,
        ), admission)
        val startDeviceIndex = settings.nextDeviceIndex(namespace)
        val run = PushCoordinator(
            source = dao,
            transport = transport,
            progress = progress,
            sourceId = sourceId,
            // The real clock and zone live HERE, at the one caller that wants them, rather than as
            // defaults 35 test constructions could inherit without saying so (#1787).
            today = { LocalDate.now() },
            zoneId = ZoneId.systemDefault(),
            destinationStillCurrent = { runCatching { admission.check() }.isSuccess },
        ).pushKnownDevices(startDeviceIndex, MAX_DEVICES_PER_RUN, capabilities, settings.binaryObjectsEnabled())
        admission.check()
        settings.recordAcceptedBatches(
            run.acceptedBatches,
            records = run.acceptedRecords.toLong(),
        )
        if (run.hasRetryableFailure) {
            // Do not rotate away from a failing device: this WorkRequest retries the exact same
            // device with its bounded runAttemptCount. Already-acked tables remain idempotent.
            return ExecutionOutcome(
                Execution.RETRY_FAILURE,
                run.failure ?: PushFailure(PushFailureCode.NETWORK_IO),
            )
        }
        settings.saveNextDeviceIndex(
            namespace,
            persistedDeviceIndex(startDeviceIndex, run.nextDeviceIndex, retryableFailure = false),
        )
        val cycleNeedsAnotherPass = settings.cycleNeedsAnotherPass(namespace) ||
            run.hasMoreAppendRows || run.hasMoreBinaryRows
        val runHadTerminalRejection = run.rejectedBatches > 0 && !run.hasRetryableFailure
        val cycleHadRejection = settings.cycleHadRejection(namespace) || runHadTerminalRejection
        val cycleFailure = settings.cycleFailure(namespace) ?: run.failure.takeIf { runHadTerminalRejection }
        val cycleCompleted = run.nextDeviceIndex == 0
        settings.saveCycleNeedsAnotherPass(namespace, if (cycleCompleted) false else cycleNeedsAnotherPass)
        // If append pagination starts another cycle, carry any terminal rejection through that cycle;
        // otherwise a rejected table alongside a full append page could later be reported as success.
        settings.saveCycleHadRejection(
            namespace,
            if (cycleCompleted && !cycleNeedsAnotherPass) false else cycleHadRejection,
        )
        settings.saveCycleFailure(
            namespace,
            if (cycleCompleted && !cycleNeedsAnotherPass) null else cycleFailure,
        )

        return when {
            !cycleCompleted || cycleNeedsAnotherPass -> {
                ExecutionOutcome(Execution.CONTINUE)
            }
            cycleHadRejection -> {
                ExecutionOutcome(
                    Execution.TERMINAL_FAILURE,
                    cycleFailure ?: PushFailure(PushFailureCode.HTTP_PROTOCOL_REJECTED),
                )
            }
            else -> {
                ExecutionOutcome(Execution.COMPLETE)
            }
        }
    }

    private fun retryOrStop(message: String): Decision =
        if (!shouldRetryPush(runAttemptCount)) {
            Decision(
                Result.failure(), false, status = Status.FAILED,
                message = storageContext.getString(R.string.push_error_paused, message),
            )
        } else {
            Decision(
                Result.retry(), true, status = Status.RETRYING,
                message = storageContext.getString(R.string.push_error_retrying, message),
            )
        }

    private fun failureMessage(failure: PushFailure?): String = pushFailureMessage(
        storageContext,
        failure ?: PushFailure(PushFailureCode.NETWORK_IO),
    )

    private fun recordSettledStatus(
        settings: SelfHostedPushSettings,
        decision: Decision,
        pending: Boolean,
    ) {
        when {
            pending && !decision.willRetry -> settings.recordContinuation()
            decision.status == Status.SUCCESS -> settings.recordSuccess()
            decision.status == Status.CONTINUING -> settings.recordContinuation()
            decision.status == Status.RETRYING -> settings.recordRetrying(decision.message.orEmpty())
            decision.status == Status.FAILED -> settings.recordError(decision.message.orEmpty())
            else -> Unit
        }
    }

    companion object {
        private const val MAX_DEVICES_PER_RUN = 1
        fun accountInput(context: AccountSessionContext): Data = Data.Builder()
            .putString(AccountPushJobAdmission.NAMESPACE, context.scope.namespace)
            .putString(AccountPushJobAdmission.GENERATION, context.generation.toString())
            .build()
    }
}


/** Registration comes only from the immutable account runtime; no global/legacy database fallback. */
object AccountPushCaptureBindings {
    data class Binding(val database: WhoopDatabase, val scope: AccountScope, val sourceID: String,
                       val imuSource: ImuSessionPushSource?)
    private data class Owner(val scope: AccountScope, val sourceID: String, val imu: ImuSessionPushSource?)
    private val writers = WeakHashMap<WhoopDatabase, Owner>()
    @Synchronized fun bind(database: WhoopDatabase, scope: AccountScope, sourceID: String,
                           imuSource: ImuSessionPushSource? = null) {
        require(UUID.fromString(sourceID).toString() == sourceID.lowercase())
        val old = writers[database]
        if (old != null) {
            if (old.scope != scope || old.sourceID != sourceID) throw AccountAuthException(AuthFailure.UNBOUND_CAPTURE)
            return
        }
        writers[database] = Owner(scope, sourceID, imuSource)
    }
    @Synchronized fun binding(context: AccountSessionContext): Binding? = writers.entries.lastOrNull {
        it.value.scope == context.scope && it.key.accountIdentity?.context == context && it.key.accountWriteFence?.admitsWrites() == true
    }
        ?.let { Binding(it.key, it.value.scope, it.value.sourceID, it.value.imu) }

    suspend fun validateOwner(binding: Binding) = withContext(Dispatchers.IO) {
        try {
            binding.database.query(SimpleSQLiteQuery(
                "SELECT projectURL,userID FROM localAccountOwner WHERE singleton=1"
            )).use { cursor ->
                if (!cursor.moveToFirst()) throw AccountAuthException(AuthFailure.UNBOUND_CAPTURE)
                AccountPushAdmission.verifyOwner(binding.scope, cursor.getString(0), cursor.getString(1))
            }
        } catch (_: Exception) { throw AccountAuthException(AuthFailure.UNBOUND_CAPTURE) }
    }
}

private suspend fun readOwnerCapabilities(endpoint: PushEndpointPolicy.ValidEndpoint, token: String,
                                          scope: AccountScope): PushCapabilitiesResult = withContext(Dispatchers.IO) {
    val connection = URL(endpoint.url).openConnection() as HttpURLConnection
    try {
        connection.instanceFollowRedirects = false
        connection.connectTimeout = 20_000; connection.readTimeout = 30_000
        connection.setRequestProperty("Authorization", "Bearer " + token)
        connection.setRequestProperty("Accept", "application/json")
        connection.setRequestProperty("NOOP-Push-Accept-Version", PushProtocol.CAPABILITIES_ACCEPT_VERSIONS)
        val status = connection.responseCode
        if (status !in 200..299) {
            val failure = PushFailure.http(status)
            return@withContext PushCapabilitiesResult.Rejected(failure.safeCode, failure.retryable, failure)
        }
        val bytes = connection.inputStream.use { input ->
            val buffer = ByteArray(PushProtocol.MAX_ACK_BYTES + 1)
            var count = 0
            while (count < buffer.size) {
                val read = input.read(buffer, count, buffer.size - count)
                if (read < 0) break
                count += read
            }
            buffer.copyOf(count)
        }
        PushCapabilitiesResult.Available(AccountPushAdmission.capabilities(bytes, scope))
    } finally { connection.disconnect() }
}

// W2_ADMISSION_BEGIN
object AccountPushJobAdmission {
    const val NAMESPACE = "noop.account.namespace"
    const val GENERATION = "noop.account.generation"
    fun matches(context: AccountSessionContext, namespace: String?, generation: String?): Boolean =
        namespace == context.scope.namespace && generation == context.generation.toString()
}

class AccountPushAdmission(
    val context: AccountSessionContext,
    captureScope: AccountScope,
    val sourceID: String,
    private val current: (AccountSessionContext) -> Boolean,
) {
    init {
        if (context.scope != captureScope) throw AccountAuthException(AuthFailure.UNBOUND_CAPTURE)
        require(UUID.fromString(sourceID).toString() == sourceID.lowercase())
        check()
    }
    fun check() {
        if (!current(context)) throw AccountAuthException(AuthFailure.STALE)
    }
    suspend fun <T> fenced(body: suspend () -> T): T {
        check()
        val value = body()
        check()
        return value
    }
    companion object {
        fun verifyOwner(expected: AccountScope, projectURL: String?, userID: String?) {
            val actual = runCatching { AccountScope.create(projectURL!!, userID!!) }.getOrNull()
            if (actual != expected) throw AccountAuthException(AuthFailure.UNBOUND_CAPTURE)
        }
        fun capabilities(bytes: ByteArray, scope: AccountScope): PushCapabilities {
            if (bytes.size > PushProtocol.MAX_ACK_BYTES) throw AccountAuthException(AuthFailure.INVALID_RESPONSE)
            val owner = runCatching {
                UUID.fromString(JSONObject(String(bytes, Charsets.UTF_8)).getString("userId")).toString()
            }.getOrNull()
            if (owner != scope.userID) throw AccountAuthException(AuthFailure.INVALID_IDENTITY)
            return PushCapabilities.parse(bytes)
        }
    }
}
class AccountFencedTransport(private val base: PushTransport, private val admission: AccountPushAdmission,
                             private val capabilitiesRead: suspend () -> PushCapabilitiesResult) : PushTransport {
    override suspend fun capabilities() = admission.fenced { capabilitiesRead() }
    override suspend fun post(batch: PushBatch) = admission.fenced { base.post(batch) }
    override suspend fun postBinary(batch: PushBinaryBatch) = admission.fenced { base.postBinary(batch) }
    override suspend fun createObjectIntent(manifest: PushObjectManifest, lane: PushObjectLane) =
        admission.fenced { base.createObjectIntent(manifest, lane) }
    override suspend fun uploadObject(intent: PushObjectIntent, body: ByteArray) =
        admission.fenced { base.uploadObject(intent, body) }
    override suspend fun completeObject(objectId: String, lane: PushObjectLane) =
        admission.fenced { base.completeObject(objectId, lane) }
}
class AccountFencedSnapshot(private val base: PushSnapshotSource, private val admission: AccountPushAdmission) : PushSnapshotSource {
    override suspend fun knownDeviceIds(capabilities: PushCapabilities) = admission.fenced { base.knownDeviceIds(capabilities) }
    override suspend fun appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Long) =
        admission.fenced { base.appendRecordAt(table, deviceId, rowId) }
    override suspend fun appendRows(table: PushAppendTable, deviceId: String, afterRowId: Long, limit: Int) =
        admission.fenced { base.appendRows(table, deviceId, afterRowId, limit) }
    override suspend fun mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) =
        admission.fenced { base.mutableRows(table, deviceId, window, limit) }
    override suspend fun binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Long) =
        admission.fenced { base.binaryRecordAt(table, deviceId, rowId) }
    override suspend fun binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Long, limit: Int) =
        admission.fenced { base.binaryRows(table, deviceId, afterRowId, limit) }
    override suspend fun acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: List<PushBinaryRow>) =
        admission.fenced { base.acknowledgeBinary(table, deviceId, rows) }
}
class AccountFencedProgress(private val base: PushProgressStore, private val admission: AccountPushAdmission) : PushProgressStore {
    override suspend fun knownDeviceIds() = admission.fenced { base.knownDeviceIds() }
    override suspend fun rememberDeviceId(deviceId: String) = admission.fenced { base.rememberDeviceId(deviceId) }
    override suspend fun cursor(table: PushAppendTable, deviceId: String) = admission.fenced { base.cursor(table, deviceId) }
    override suspend fun saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) =
        admission.fenced { base.saveCursor(table, deviceId, cursor) }
    override suspend fun binaryCursor(table: PushBinaryTable, deviceId: String) = admission.fenced { base.binaryCursor(table, deviceId) }
    override suspend fun saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) =
        admission.fenced { base.saveBinaryCursor(table, deviceId, cursor) }
    override suspend fun window(table: PushMutableTable, deviceId: String) = admission.fenced { base.window(table, deviceId) }
    override suspend fun saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) =
        admission.fenced { base.saveWindow(table, deviceId, progress) }
    override suspend fun inFlightObject(table: PushBinaryTable, deviceId: String) =
        admission.fenced { base.inFlightObject(table, deviceId) }
    override suspend fun saveInFlightObject(table: PushBinaryTable, deviceId: String, inFlight: PushInFlightObject?) =
        admission.fenced { base.saveInFlightObject(table, deviceId, inFlight) }
    override suspend fun preparedBoundary(table: PushBinaryTable, deviceId: String) =
        admission.fenced { base.preparedBoundary(table, deviceId) }
    override suspend fun savePreparedBoundary(table: PushBinaryTable, deviceId: String, prepared: PushPreparedBoundary?) =
        admission.fenced { base.savePreparedBoundary(table, deviceId, prepared) }
}
// W2_ADMISSION_END
