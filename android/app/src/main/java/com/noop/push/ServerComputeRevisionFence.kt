package com.noop.push

import org.json.JSONObject

/** An identity cannot mutate physiology, and a late read cannot roll a selected input revision back. */
object ServerComputeRevisionFence {
    fun admits(previous: ServerScoreDayCache?, next: ServerScoreDayCache): Boolean {
        val old = previous?.compute ?: return true
        val fresh = next.compute ?: return false
        if (old.project != fresh.project || old.ownerId != fresh.ownerId || old.sourceId != fresh.sourceId) return false
        return old.families.all { (key, before) ->
            val after = fresh.families[key] ?: return@all false
            if (before.deviceId != after.deviceId || before.window != after.window) return@all false
            // Authorization is live read-time evidence: revocation/missingness must evict a formerly
            // admitted value even when the immutable stored result identity has not changed.
            if (!after.authorized) return@all true
            if (!before.authorized) return@all true
            if (before.algorithmVersion == after.algorithmVersion && before.inputRevision != null && after.inputRevision != null &&
                after.inputRevision < before.inputRevision) return@all false
            if (before.resultRevision == null || before.resultRevision != after.resultRevision) return@all true
            val prior = JSONObject(before.json); val candidate = JSONObject(after.json)
            // Availability is read-time state. All values, versions, evidence and details remain immutable.
            for (field in listOf("freshness", "status", "reason")) { prior.remove(field); candidate.remove(field) }
            canonical(prior) == canonical(candidate)
        }
    }
    private fun canonical(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(",", "{", "}") {
            JSONObject.quote(it) + ":" + canonical(value.opt(it))
        }
        is org.json.JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.opt(it)) }
        is String -> JSONObject.quote(value)
        is Number -> value.toDouble().toString()
        else -> value.toString()
    }
}
