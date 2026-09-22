package com.noop.ui

import android.content.Context
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import com.noop.account.AccountStorageContext
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/** An export is an exact immutable envelope, not a locally reconstructed trends report. */
object CanonicalResultExport {
    suspend fun share(context: Context, vm: AppViewModel) {
        val account = AccountStorageContext.capture(context)
        check(account.isCurrent())
        val identity = account.identity
        val days = vm.serverScores.canonicalDays.value.toSortedMap()
        val entries = days.mapNotNull { (day, cache) -> cache.rawSnapshotJSON?.let { "$day.json" to it.toByteArray() } }
        val index = JSONObject().put("format", "noop-canonical-compute-1")
            .put("project", identity.scope?.projectURL ?: JSONObject.NULL)
            .put("owner_id", identity.scope?.userID ?: JSONObject.NULL)
            .put("families", JSONArray(com.noop.push.ServerComputeContract.familyIDs.sorted()))
            .put("state", if (entries.isEmpty()) "unavailable" else "immutable_cached_results")
            .put("results", JSONArray(days.map { (day, cache) -> JSONObject().put("day", day)
                .put("stale", cache.stale).put("read_failure", cache.readFailure ?: JSONObject.NULL)
                .put("result_revisions", JSONObject(com.noop.push.ServerConsumerProjection.revisions(cache))) }))
        LogExport.exportBundle(account, listOf("index.json" to index.toString(2).toByteArray()) + entries,
            "noop-canonical-results-${LogExport.timestamp()}.zip", admit = {
                check(account.isCurrent()) { "Account changed during export" }
                check(days.all { (day, saved) -> vm.serverScores.overlay(day)?.compute == saved.compute }) {
                    "Canonical revision changed during export; retry"
                }
            })
    }
}

@Composable
fun CanonicalExportButton(vm: AppViewModel, context: Context) {
    val scope = rememberCoroutineScope()
    TextButton(onClick = { scope.launch { CanonicalResultExport.share(context, vm) } }) { Text("Export canonical results") }
}
