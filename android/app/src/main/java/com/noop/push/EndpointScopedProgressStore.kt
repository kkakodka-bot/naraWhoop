package com.noop.push

/** Keeps cursor/window progress independent per normalized endpoint without exposing the URL to Room. */
class EndpointScopedProgressStore(
    private val delegate: PushProgressStore,
    private val endpointNamespace: String,
) : PushProgressStore {
    private fun scoped(deviceId: String) = "$endpointNamespace:$deviceId"
    private val prefix = "$endpointNamespace:"

    override suspend fun knownDeviceIds(): Set<String> = delegate.knownDeviceIds()
        .filterTo(mutableSetOf()) { it.startsWith(prefix) }
        .mapTo(mutableSetOf()) { it.removePrefix(prefix) }

    override suspend fun rememberDeviceId(deviceId: String) = delegate.rememberDeviceId(scoped(deviceId))

    override suspend fun cursor(table: PushAppendTable, deviceId: String): PushCursor? =
        delegate.cursor(table, scoped(deviceId))

    override suspend fun saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) =
        delegate.saveCursor(table, scoped(deviceId), cursor)

    override suspend fun binaryCursor(table: PushBinaryTable, deviceId: String): PushCursor? =
        delegate.binaryCursor(table, scoped(deviceId))

    override suspend fun saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) =
        delegate.saveBinaryCursor(table, scoped(deviceId), cursor)

    override suspend fun window(table: PushMutableTable, deviceId: String): PushWindowProgress? =
        delegate.window(table, scoped(deviceId))

    override suspend fun saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) =
        delegate.saveWindow(table, scoped(deviceId), progress)

    override suspend fun inFlightObject(table: PushBinaryTable, deviceId: String): PushInFlightObject? =
        delegate.inFlightObject(table, scoped(deviceId))

    override suspend fun saveInFlightObject(table: PushBinaryTable, deviceId: String, inFlight: PushInFlightObject?) =
        delegate.saveInFlightObject(table, scoped(deviceId), inFlight)

    override suspend fun preparedBoundary(table: PushBinaryTable, deviceId: String) =
        delegate.preparedBoundary(table, scoped(deviceId))

    override suspend fun savePreparedBoundary(table: PushBinaryTable, deviceId: String, prepared: PushPreparedBoundary?) =
        delegate.savePreparedBoundary(table, scoped(deviceId), prepared)
}
