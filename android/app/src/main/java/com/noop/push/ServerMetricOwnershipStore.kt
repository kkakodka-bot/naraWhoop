package com.noop.push

import android.content.Context
import com.noop.account.AccountStorageContext

class ServerMetricOwnershipStore(context: Context) {
    private val context = AccountStorageContext.capture(context)
    private val prefs = this.context.getSharedPreferences("noop_compute_ownership", Context.MODE_PRIVATE)

    private fun scope(): ServerMetricOwnership? {
        if (!context.isCurrent()) return null
        val identity = DeviceLinkStore.identity(context) ?: return null
        val device = DeviceLinkStore.from(context).confirmed(identity) ?: return null
        val project = identity.endpoint.removeSuffix("/functions/v1/push").trimEnd('/')
        return ServerMetricOwnership(project, identity.owner.lowercase(), device)
    }

    private fun key(scope: ServerMetricOwnership) = EnrollmentDataScope.digest(
        "${scope.project}\u0000${scope.ownerId}\u0000${scope.deviceId}")

    fun load(): ServerMetricOwnership? = synchronized(lock) {
        val scope = scope() ?: return@synchronized null
        ServerMetricOwnership.restore(prefs.getString(key(scope), null), scope.project, scope.ownerId, scope.deviceId)
    }

    fun observe(cache: ServerScoreDayCache): ServerMetricOwnership? = synchronized(lock) {
        val identity = DeviceLinkStore.identity(context)
        cache.compute?.let { compute ->
            if (identity != null && context.isCurrent() && compute.ownerId.equals(identity.owner, true) &&
                compute.sourceId == identity.source && compute.project == identity.endpoint.removeSuffix("/functions/v1/push").trimEnd('/')) {
                val policy = org.json.JSONObject().put("project", compute.project).put("owner", compute.ownerId)
                    .put("source", compute.sourceId).put("externalDevice", identity.device).put("policyVersion", "vps-only-1")
                    .put("families", org.json.JSONArray(compute.families.keys.sorted()))
                check(prefs.edit().putString("policy:${identity.key}", policy.toString()).commit()) { "Pending ownership not durable" }
            }
        }
        val before = load() ?: return@synchronized null
        val next = before.observe(cache)
        if (next != before && context.isCurrent()) {
            check(prefs.edit().putString(key(next), next.encode()).commit()) { "Ownership could not be persisted" }
        }
        next
    }

    fun presentation(cache: ServerScoreDayCache?, day: String, readFailed: Boolean = false): ServerScoreDayCache? {
        val ownership = load() ?: return cache
        val presented = ownership.presentation(cache, day, readFailed)
        return if (com.noop.analytics.PhoneComputeRuntime.finalHosted) presented?.copy(ownedMetrics = ServerComputeContract.metricIDs)
            else presented
    }

    companion object { private val lock = Any() }
}
