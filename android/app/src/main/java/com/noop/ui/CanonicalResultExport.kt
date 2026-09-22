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
    private fun entries(account: AccountStorageContext, days: Map<String, com.noop.push.ServerScoreDayCache>): List<Pair<String, ByteArray>> {
        val entries = days.mapNotNull { (day, cache) -> cache.rawSnapshotJSON?.let { "$day.json" to it.toByteArray() } }
        val compute = days.values.firstNotNullOfOrNull { it.compute }
        val index = JSONObject().put("format", "noop-canonical-compute-1")
            .put("project", account.identity.scope?.projectURL ?: compute?.project ?: JSONObject.NULL)
            .put("owner_id", account.identity.scope?.userID ?: compute?.ownerId ?: JSONObject.NULL)
            .put("families", JSONArray(com.noop.push.ServerComputeContract.familyIDs.sorted()))
            .put("state", if (entries.isEmpty()) "unavailable" else "immutable_cached_results")
            .put("results", JSONArray(days.map { (day, cache) -> JSONObject().put("day", day)
                .put("stale", cache.stale).put("read_failure", cache.readFailure ?: JSONObject.NULL)
                .put("result_revisions", JSONObject(com.noop.push.ServerConsumerProjection.revisions(cache))) }))
        return listOf("index.json" to index.toString(2).toByteArray()) + entries
    }

    suspend fun writeTo(context: Context, uri: android.net.Uri): String {
        val account = AccountStorageContext.capture(context)
        check(account.isCurrent())
        val source = requireNotNull(account.runtime?.serverScoreRepository)
        val days = source.canonicalDays.value.toSortedMap()
        val buffer = java.io.ByteArrayOutputStream()
        java.util.zip.ZipOutputStream(buffer).use { zip ->
            entries(account, days).forEach { (name, bytes) ->
                zip.putNextEntry(java.util.zip.ZipEntry(name)); zip.write(bytes); zip.closeEntry()
            }
        }
        check(account.isCurrent() && days.all { (day, saved) -> source.overlay(day)?.compute == saved.compute })
        requireNotNull(account.contentResolver.openOutputStream(uri)).use { output -> output.write(buffer.toByteArray()) }
        return "Exported ${days.size} immutable server result envelopes with ownership and revision metadata."
    }

    suspend fun share(context: Context, vm: AppViewModel) {
        val account = AccountStorageContext.capture(context)
        check(account.isCurrent())
        val days = vm.serverScores.canonicalDays.value.toSortedMap()
        LogExport.exportBundle(account, entries(account, days),
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
