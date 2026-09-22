package com.noop.push

import android.app.Application
import android.content.Context
import android.net.Uri
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.response.InsertRecordsResponse
import com.noop.account.AccountAppRuntime
import com.noop.analytics.PhoneComputeRuntime
import com.noop.ingest.HealthConnectWriter
import com.noop.ui.CanonicalResultExport
import com.noop.ui.NoopPrefs
import com.noop.widget.WidgetSnapshot
import com.noop.widget.WidgetSnapshotStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.lang.reflect.Proxy
import java.time.LocalDate
import java.util.zip.ZipFile

/** The transport and external Health provider are synthetic; decoding, storage and consumers are real. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class,
    instrumentedPackages = ["com.noop.analytics.PhoneComputeRuntime"])
class CanonicalConsumersNativeTest {
    private enum class Race { READ_FAILURE, REVOCATION, ACCOUNT, DEVICE }

    private class OpeningProvider(private val target: File, private val whileOpening: () -> Unit) : android.content.ContentProvider() {
        var opened = 0
        override fun onCreate() = true
        override fun getType(uri: Uri) = "application/zip"
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?) = null
        override fun insert(uri: Uri, values: android.content.ContentValues?) = null
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun update(uri: Uri, values: android.content.ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun openFile(uri: Uri, mode: String): android.os.ParcelFileDescriptor {
            opened++
            whileOpening()
            return android.os.ParcelFileDescriptor.open(target, android.os.ParcelFileDescriptor.MODE_CREATE or
                android.os.ParcelFileDescriptor.MODE_READ_WRITE or android.os.ParcelFileDescriptor.MODE_TRUNCATE)
        }
    }

    private class Provider {
        val inserted = mutableListOf<Record>()
        val deleted = mutableListOf<String>()
        val client = Proxy.newProxyInstance(HealthConnectClient::class.java.classLoader,
            arrayOf(HealthConnectClient::class.java)) { _, method, args ->
            when (method.name) {
                "insertRecords" -> {
                    @Suppress("UNCHECKED_CAST") val records = args!![0] as List<Record>
                    inserted.addAll(records)
                    InsertRecordsResponse::class.java.getConstructor(List::class.java)
                        .newInstance(records.map { requireNotNull(it.metadata.clientRecordId) })
                }
                "deleteRecords" -> {
                    @Suppress("UNCHECKED_CAST") val ids = args!![2] as List<String>
                    deleted.addAll(ids)
                    Unit
                }
                else -> error("Unexpected provider operation: ${method.name}")
            }
        } as HealthConnectClient
    }

    private class Fixture : java.io.Closeable {
        val auth = W4NativeFixture()
        val account = auth.account()
        val day = LocalDate.now().toString()
        private val scope = CoroutineScope(Job().apply { cancel() } + Dispatchers.IO)
        lateinit var response: JSONObject
        var readFailure = false
        val runtime = AccountAppRuntime(account) { context, _ ->
            ServerScoreRepository(context, scope, ready = { true }, fetchSnapshot = { _, date, owner ->
                check(!readFailure) { "synthetic network failure" }
                ServerScoreClient.parseSnapshot(response.toString(), date, owner)
            })
        }
        val provider = Provider()
        val source get() = runtime.serverScoreRepository
        val revision = "sha256:" + "c".repeat(64)
        init {
            runtime.onActiveDeviceAdopted("whoop-consumer-a")
            val identity = requireNotNull(DeviceLinkStore.identity(account))
            DeviceLinkStore.from(account).record(identity, JSONObject().put("identity", JSONObject()
                .put("userId", identity.owner).put("sourceId", identity.source)
                .put("externalDeviceId", identity.device).put("deviceId", auth.device)).toString())
            response = envelope(identity)
            NoopPrefs.setHcWriteback(account, true)
        }
        fun family(key: String) = response.getJSONObject("server_scoring")
            .getJSONObject("compute").getJSONObject("families").getJSONObject(key)
        fun available(key: String, metric: String, value: Any, result: String = revision) {
            val resultFamily = family(key).put("status", "available").put("reason", JSONObject.NULL)
                .put("algorithm_version", "frwhoop-physiology-2").put("configuration_version", JSONObject.NULL)
                .put("manifest_hash", "a".repeat(64)).put("feature_manifest_hash", "b".repeat(64))
                .put("canonical_qualification", "signed_reference_approval").put("result_revision", result)
                .put("freshness", "current")
            resultFamily.getJSONObject("values").put(metric, value)
            val daily = response.getJSONObject("server_scoring").getJSONObject("daily")
            if (key == "night_hrv") resultFamily.getJSONObject("details")
                .put("summary", daily.opt("hrv_summary")).put("heart_rate_windows", daily.opt("heart_rate_windows"))
            if (key == "respiration") resultFamily.getJSONObject("details")
                .put("summary", daily.opt("respiration_summary"))
            mapOf("night_hrv" to "hrv", "current_hrv" to "hrv", "sleep" to "sleep", "respiration" to "respiration",
                "recovery" to "hrv", "strain_energy" to "hrv", "oxygen" to "hrv", "temperature" to "hrv")[key]?.let { featureID ->
                response.getJSONObject("server_scoring").getJSONObject("features").getJSONObject(featureID)
                    .put("status", "available").put("reason", JSONObject.NULL).put("device_id", auth.device)
                    .put("algorithm_version", "frwhoop-physiology-2").put("input_revision", 8)
                    .put("computed_at", "${day}T07:01:00Z").put("observed_through", "${day}T07:00:00Z")
                    .put("publication_status", "canonical").put("manifest_hash", "a".repeat(64))
                    .put("feature_manifest_hash", "b".repeat(64)).put("canonical_qualification", "signed_reference_approval")
            }
            val topValue = if (metric == "sleep_efficiency" && value is Number) value.toDouble() / 100.0 else value
            if (metric in setOf("hrv_rmssd_ms", "hrv_sdnn_ms", "resting_hr_bpm", "sleep_total_min", "sleep_in_bed_min",
                    "sleep_awake_min", "sleep_light_min", "sleep_deep_min", "sleep_rem_min", "sleep_efficiency",
                    "disturbances", "resp_rate_bpm", "recovery", "strain", "spo2_pct", "skin_temp_c", "skin_temp_dev_c")) {
                response.getJSONObject("server_scoring").getJSONObject("daily").put(metric, topValue)
            }
        }
        fun availableSleep() {
            val night = JSONObject().put("id", "sleep-a").put("device_id", auth.device)
                .put("user_id", auth.owner.userID).put("algorithm_version", "frwhoop-physiology-2")
                .put("start_at", "${day}T00:00:00Z").put("end_at", "${day}T01:00:00Z")
                .put("asleep_min", 0).put("stages", JSONArray())
            val top = JSONArray().put(night)
            available("sleep", "sleep_sessions", JSONArray(top.toString()))
            family("sleep").getJSONObject("details").put("nights", JSONArray(top.toString()))
                .put("sleep_overrides", JSONArray(response.getJSONObject("server_scoring")
                    .getJSONArray("sleep_overrides").toString()))
            val daily = response.getJSONObject("server_scoring").getJSONObject("daily")
            val dailyCopy = JSONObject(daily.toString())
            val compatibility = JSONObject()
            listOf("sleep_onset_at", "wake_onset_at", "sleep_unstaged_min", "state_unknown_min", "off_body_min",
                "main_sleep_group_id", "opportunity_kind", "full_day_sleep_epochs")
                .forEach { key -> compatibility.put(key, dailyCopy.get(key)) }
            family("sleep").getJSONObject("details").put("daily_compatibility", compatibility)
            response.getJSONObject("server_scoring").put("nights", top)
        }
        suspend fun refresh() {
            source.refreshDay(day)
            checkNotNull(source.overlay(day)?.compute) { source.lastError.value.orEmpty() }
        }
        suspend fun changeDuringAdmission(race: Race) {
            when (race) {
                Race.READ_FAILURE -> { readFailure = true; source.refreshDay(day) }
                Race.REVOCATION -> {
                    family("night_hrv").put("status", "revoked").put("canonical_qualification", JSONObject.NULL)
                    source.refreshDay(day)
                }
                Race.ACCOUNT -> auth.controller.clearSession()
                Race.DEVICE -> check(runtime.sourceCoordinator.reconcileActiveDevice("whoop-consumer-b"))
            }
        }
        suspend fun health() = HealthConnectWriter.writeCanonical(account, runtime.repository) { provider.client }
        fun widget(): WidgetSnapshot {
            WidgetSnapshotStore.save(account, WidgetSnapshot(recoveryPct = 99, restPct = 99, effortPct = 99))
            return WidgetSnapshotStore.load(account)
        }
        suspend fun export(): Map<String, JSONObject> {
            val file = File(account.cacheDir, "canonical-consumer-${java.util.UUID.randomUUID()}.zip")
            CanonicalResultExport.writeTo(account, Uri.fromFile(file))
            return ZipFile(file).use { zip -> zip.entries().asSequence().associate { entry ->
                entry.name to JSONObject(zip.getInputStream(entry).bufferedReader().use { it.readText() })
            } }
        }
        fun receipt(family: String): JSONObject? = account.getSharedPreferences("noop_health_compute_revisions", Context.MODE_PRIVATE)
            .getString("${auth.owner.projectURL}:${auth.owner.userID}:${auth.device}:$family:$day", null)?.let(::JSONObject)
        private fun envelope(identity: DeviceLinkStore.Identity): JSONObject {
            val families = JSONObject()
            ServerComputeContract.familyMetrics.forEach { (key, metrics) ->
                val values = JSONObject(); metrics.forEach { values.put(it, JSONObject.NULL) }
                families.put(key, JSONObject().put("owner", "server").put("metrics", JSONArray(metrics.toList()))
                    .put("project", auth.owner.projectURL).put("owner_id", auth.owner.userID)
                    .put("device_id", auth.device).put("source_id", identity.source).put("window", day)
                    .put("timezone_id", "UTC").put("status", "unsupported").put("reason", "qualified_producer_unavailable")
                    .put("algorithm_version", "vps-only-1").put("configuration_version", "vps-only-1")
                    .put("input_revision", 8).put("result_revision", "compute:17")
                    .put("computed_at", "${day}T07:01:00Z").put("observed_through", "${day}T07:00:00Z")
                    .put("freshness", "unavailable").put("values", values).put("details", JSONObject()))
            }
            val daily = JSONObject()
            listOf("hrv_rmssd_ms", "hrv_sdnn_ms", "resting_hr_bpm", "sleep_total_min", "sleep_in_bed_min",
                "sleep_awake_min", "sleep_light_min", "sleep_deep_min", "sleep_rem_min", "sleep_efficiency",
                "disturbances", "resp_rate_bpm", "recovery", "strain", "spo2_pct", "skin_temp_c", "skin_temp_dev_c",
                "sleep_onset_at", "wake_onset_at", "sleep_unstaged_min", "state_unknown_min", "off_body_min",
                "main_sleep_group_id", "opportunity_kind", "full_day_sleep_epochs", "hrv_summary",
                "heart_rate_windows", "respiration_summary")
                .forEach { daily.put(it, JSONObject.NULL) }
            val features = JSONObject(); listOf("hrv", "sleep", "respiration").forEach { featureID ->
                features.put(featureID, JSONObject().put("status", "unavailable").put("device_id", auth.device))
            }
            return JSONObject().put("server_scoring", JSONObject().put("schema_version", 2)
                .put("day", day).put("user_id", auth.owner.userID).put("algorithm_version", "per_feature")
                .put("features", features)
                .put("daily", daily).put("nights", JSONArray()).put("sleep_overrides", JSONArray())
                .put("measurements", JSONArray()).put("stale", false)
                .put("compute", JSONObject().put("mode", "final_hosted").put("policy_version", "vps-only-1")
                    .put("project", auth.owner.projectURL).put("owner_id", auth.owner.userID)
                    .put("device_id", auth.device).put("source_id", identity.source).put("day", day)
                    .put("families", families)))
        }
        override fun close() { runtime.close(); auth.close() }
    }

    @Test fun validZeroRetainsOneRevisionThroughWidgetExportAndHealth() = runBlocking(Dispatchers.IO) {
        PhoneComputeRuntime.installFinalHosted()
        Fixture().use { f ->
            f.available("night_hrv", "hrv_rmssd_ms", 0)
            f.available("recovery", "recovery", 0)
            f.available("sleep_history", "sleep_performance", 0)
            f.available("strain_energy", "strain", 0)
            f.refresh()
            val cache = requireNotNull(f.source.overlay(f.day))
            val ledger = requireNotNull(ServerMetricOwnershipStore(f.account).load())
            assertEquals(ServerComputeContract.metricIDs, ledger.metrics)
            assertEquals(0.0, ServerConsumerProjection.number(cache, "hrv_rmssd_ms")!!, 0.0)
            val widget = f.widget()
            assertEquals(0, widget.recoveryPct); assertEquals(0, widget.restPct); assertEquals(0, widget.effortPct)
            assertEquals(ServerConsumerProjection.revisions(cache), widget.resultRevisions)
            assertEquals(cache.rawSnapshotJSON, widget.canonicalJSON)
            val exported = f.export()
            assertEquals(JSONObject(cache.rawSnapshotJSON!!).toString(), exported.getValue("${f.day}.json").toString())
            val exportRevisions = exported.getValue("index.json").getJSONArray("results").getJSONObject(0).getJSONObject("result_revisions")
            assertEquals(f.revision, exportRevisions.getString("night_hrv"))
            assertEquals(0, f.health().written)
            assertTrue(f.provider.inserted.isEmpty())
            val receipt = f.receipt("night_hrv")!!
            assertEquals(f.revision, receipt.getString("result_revision"))
            assertEquals(0.0, receipt.getJSONObject("values").getDouble("hrv_rmssd_ms"), 0.0)
            assertEquals("unsupported", receipt.getString("health_export_state"))
            assertEquals("health_connect_record_not_representable", receipt.getJSONObject("health_export_unsupported").getString("hrv_rmssd_ms"))
            assertEquals(f.revision, widget.resultRevisions["night_hrv"])
            assertEquals(0, f.health().written)
            assertTrue(f.provider.inserted.isEmpty())
            assertTrue(PhoneComputeRuntime.evidence().isEmpty()); assertTrue(PhoneComputeRuntime.forbiddenAttempts().isEmpty())
            println("FINAL_HOSTED_CONSUMER_REVISIONS same_revision=true widget_save_load=true export_zip=true health_adapter=true valid_zero=true health_zero_unsupported_without_coercion=true admitted=0 forbidden=0")
        }
    }

    @Test fun rawSnapshotWidgetAndExportClearUnauthorizedCompatibilityValues() = runBlocking(Dispatchers.IO) {
        PhoneComputeRuntime.installFinalHosted()
        Fixture().use { f ->
            val overlay = f.response.getJSONObject("server_scoring")
            overlay.getJSONObject("daily").put("skin_temp_c", 34.5).put("hrv_rmssd_ms", 88)
            overlay.put("nights", JSONArray().put(JSONObject().put("id", "unauthorized-night")))
                .put("sleep_overrides", JSONArray().put(JSONObject().put("id", "unauthorized-override")))
                .put("measurements", JSONArray().put(JSONObject().put("feature", "hrv").put("observed_rmssd_ms", 99)))
            f.refresh()
            val cache = requireNotNull(f.source.overlay(f.day))
            val raw = JSONObject(cache.rawSnapshotJSON!!).getJSONObject("server_scoring")
            assertTrue(raw.isNull("daily"))
            assertEquals(0, raw.getJSONArray("nights").length())
            assertEquals(0, raw.getJSONArray("sleep_overrides").length())
            assertEquals(0, raw.getJSONArray("measurements").length())
            assertEquals(cache.rawSnapshotJSON, f.widget().canonicalJSON)
            val exported = f.export().getValue("${f.day}.json").getJSONObject("server_scoring")
            assertTrue(exported.isNull("daily"))
            assertEquals(0, exported.getJSONArray("nights").length())
            assertEquals(0, exported.getJSONArray("sleep_overrides").length())
            assertEquals(0, exported.getJSONArray("measurements").length())
            assertFalse(exported.toString().contains("34.5"))
            assertFalse(exported.toString().contains("unauthorized"))
        }
    }

    @Test fun sleepHealthReceiptAndRecordShareTheDecodedImmutableRevision() = runBlocking(Dispatchers.IO) {
        PhoneComputeRuntime.installFinalHosted()
        Fixture().use { f ->
            f.availableSleep()
            f.refresh()
            val result = f.health()
            assertTrue(result.ok); assertEquals(1, result.written)
            val record = f.provider.inserted.single() as SleepSessionRecord
            assertTrue(record.metadata.clientRecordId!!.contains(f.revision))
            assertEquals(java.time.Instant.parse("${f.day}T00:00:00Z"), record.startTime)
            assertEquals(java.time.Instant.parse("${f.day}T01:00:00Z"), record.endTime)
            val receipt = f.receipt("sleep")!!
            assertEquals(f.revision, receipt.getString("result_revision"))
            assertEquals(0.0, receipt.getJSONObject("values").getJSONArray("sleep_sessions")
                .getJSONObject(0).getDouble("asleep_min"), 0.0)
            assertEquals(1, receipt.getJSONArray("health_export_ids").length())
            assertEquals(record.metadata.clientRecordId,
                receipt.getJSONArray("health_export_ids").getJSONObject(0).getString("id"))
            assertEquals(0, f.health().written)
            assertEquals(1, f.provider.inserted.size)
            assertTrue(PhoneComputeRuntime.evidence().isEmpty()); assertTrue(PhoneComputeRuntime.forbiddenAttempts().isEmpty())
        }
    }

    @Test fun ownedNullAndSameRevisionRevocationRetractWithoutFallback() = runBlocking(Dispatchers.IO) {
        PhoneComputeRuntime.installFinalHosted()
        Fixture().use { f ->
            f.available("night_hrv", "hrv_rmssd_ms", 42); f.available("recovery", "recovery", 75)
            f.refresh(); assertEquals(1, f.health().written)
            assertEquals(42.0, (f.provider.inserted.single() as HeartRateVariabilityRmssdRecord).heartRateVariabilityMillis, 0.0)
            val oldId = f.provider.inserted.single().metadata.clientRecordId!!
            assertTrue(oldId.contains(f.revision))
            assertEquals(f.widget().resultRevisions["night_hrv"], f.receipt("night_hrv")!!.getString("result_revision"))
            assertEquals(f.revision, f.export().getValue("index.json").getJSONArray("results").getJSONObject(0)
                .getJSONObject("result_revisions").getString("night_hrv"))
            f.available("night_hrv", "hrv_rmssd_ms", JSONObject.NULL, "sha256:" + "d".repeat(64))
            f.available("recovery", "recovery", JSONObject.NULL, "sha256:" + "d".repeat(64))
            f.refresh()
            assertNull(f.widget().recoveryPct)
            assertEquals(0, f.health().written)
            assertEquals(listOf(oldId), f.provider.deleted)
            assertEquals(0, f.receipt("night_hrv")!!.getJSONArray("health_export_ids").length())
            f.available("night_hrv", "hrv_rmssd_ms", 48, "sha256:" + "e".repeat(64))
            f.available("recovery", "recovery", 76, "sha256:" + "e".repeat(64))
            f.refresh(); assertEquals(1, f.health().written)
            for (key in listOf("night_hrv", "recovery")) {
                val family = f.family(key).put("status", "revoked")
                    .put("canonical_qualification", JSONObject.NULL).put("input_revision", 1)
                val values = family.getJSONObject("values")
                values.keys().asSequence().toList().forEach { metric -> values.put(metric, JSONObject.NULL) }
            }
            f.refresh()
            assertNull(f.widget().recoveryPct)
            assertEquals(0, f.health().written)
            assertEquals(2, f.provider.deleted.size)
            assertEquals("unavailable", f.receipt("night_hrv")!!.getString("health_export_state"))
            val exported = f.export().getValue("${f.day}.json")
            val decoded = ServerScoreClient.parseSnapshot(exported.toString(), f.day, f.auth.owner.userID)
            assertNull(ServerConsumerProjection.number(decoded, "hrv_rmssd_ms"))
            assertEquals("revoked", decoded.compute!!.families.getValue("night_hrv").status)
            assertTrue(PhoneComputeRuntime.evidence().isEmpty()); assertTrue(PhoneComputeRuntime.forbiddenAttempts().isEmpty())
        }
    }

    @Test fun staleReadRetainsRevisionButDoesNotRepublishToHealth() = runBlocking(Dispatchers.IO) {
        PhoneComputeRuntime.installFinalHosted()
        Fixture().use { f ->
            f.available("night_hrv", "hrv_rmssd_ms", 42); f.available("recovery", "recovery", 75)
            f.refresh(); assertEquals(1, f.health().written)
            f.readFailure = true
            f.source.refreshDay(f.day)
            assertTrue(f.source.overlay(f.day)!!.stale)
            assertEquals(f.revision, f.widget().resultRevisions["night_hrv"])
            val exported = f.export().getValue("index.json").getJSONArray("results").getJSONObject(0)
            assertTrue(exported.getBoolean("stale"))
            assertEquals("server_read_failed", exported.getString("read_failure"))
            assertEquals(0, f.health().written)
            assertEquals(1, f.provider.inserted.size); assertTrue(f.provider.deleted.isEmpty())
            assertTrue(PhoneComputeRuntime.evidence().isEmpty()); assertTrue(PhoneComputeRuntime.forbiddenAttempts().isEmpty())
        }
    }

    @Test fun deviceChangeFencesEveryConsumerAndHealthAdmission() = runBlocking(Dispatchers.IO) {
        PhoneComputeRuntime.installFinalHosted()
        Fixture().use { f ->
            f.available("night_hrv", "hrv_rmssd_ms", 42); f.available("recovery", "recovery", 75)
            f.refresh()
            val raced = HealthConnectWriter.writeCanonical(f.account, f.runtime.repository) {
                runBlocking { assertTrue(f.runtime.sourceCoordinator.reconcileActiveDevice("whoop-consumer-b")) }
                f.provider.client
            }
            assertFalse(raced.ok); assertTrue(f.provider.inserted.isEmpty())
            assertNull(f.widget().recoveryPct)
            assertTrue(f.widget().resultRevisions.isEmpty())
            assertEquals("unavailable", f.export().getValue("index.json").getString("state"))
            assertTrue(PhoneComputeRuntime.evidence().isEmpty()); assertTrue(PhoneComputeRuntime.forbiddenAttempts().isEmpty())
        }
    }

    @Test fun accountChangeFencesEveryConsumerAndHealthAdmission() = runBlocking(Dispatchers.IO) {
        PhoneComputeRuntime.installFinalHosted()
        Fixture().use { f ->
            f.available("night_hrv", "hrv_rmssd_ms", 42); f.available("recovery", "recovery", 75)
            f.refresh()
            f.auth.controller.clearSession()
            try { f.export(); fail("Retired account exported canonical data") } catch (_: IllegalStateException) { }
            try { f.health(); fail("Retired account reached Health provider") } catch (_: kotlinx.coroutines.CancellationException) { }
            assertNull(f.widget().recoveryPct)
            assertTrue(f.provider.inserted.isEmpty()); assertTrue(f.provider.deleted.isEmpty())
            assertTrue(PhoneComputeRuntime.evidence().isEmpty()); assertTrue(PhoneComputeRuntime.forbiddenAttempts().isEmpty())
        }
    }

    @Test fun providerOpenRechecksAccountDeviceReadFailureAndRevocationBeforeAnyBytes() = runBlocking(Dispatchers.IO) {
        PhoneComputeRuntime.installFinalHosted()
        for (race in Race.entries) Fixture().use { f ->
            f.available("night_hrv", "hrv_rmssd_ms", 42); f.refresh()
            val before = f.source.overlay(f.day)!!
            val target = File(f.account.cacheDir, "provider-race-$race.zip")
            val authority = "com.noop.test.export.${java.util.UUID.randomUUID()}"
            val provider = OpeningProvider(target) { runBlocking { f.changeDuringAdmission(race) } }
            provider.attachInfo(f.account, android.content.pm.ProviderInfo().apply { this.authority = authority; exported = true })
            org.robolectric.shadows.ShadowContentResolver.registerProviderInternal(authority, provider)
            try {
                CanonicalResultExport.writeTo(f.account, Uri.parse("content://$authority/result.zip"))
                fail("Export admitted $race during provider open")
            } catch (_: IllegalStateException) { }
            assertEquals("$race callback ran", 1, provider.opened)
            assertTrue(target.exists()); assertEquals("$race leaked result bytes", 0L, target.length())
            if (race == Race.READ_FAILURE) {
                assertEquals(before.compute, f.source.overlay(f.day)!!.compute)
                assertEquals("server_read_failed", f.source.overlay(f.day)!!.readFailure)
            }
            if (race == Race.REVOCATION) assertEquals(before.compute!!.families.getValue("night_hrv").resultRevision,
                f.source.overlay(f.day)!!.compute!!.families.getValue("night_hrv").resultRevision)
            assertTrue(PhoneComputeRuntime.evidence().isEmpty()); assertTrue(PhoneComputeRuntime.forbiddenAttempts().isEmpty())
        }
    }

    @Test fun healthProviderCreationRechecksReadStateAndIdentityBeforeAnyWrites() = runBlocking(Dispatchers.IO) {
        PhoneComputeRuntime.installFinalHosted()
        for (race in Race.entries) Fixture().use { f ->
            f.available("night_hrv", "hrv_rmssd_ms", 42); f.refresh()
            var opened = false
            try {
                val result = HealthConnectWriter.writeCanonical(f.account, f.runtime.repository) {
                    opened = true
                    runBlocking { f.changeDuringAdmission(race) }
                    f.provider.client
                }
                assertFalse("Health admitted $race", result.ok)
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                assertEquals(Race.ACCOUNT, race)
            }
            assertTrue(opened)
            assertTrue("$race wrote records", f.provider.inserted.isEmpty())
            assertTrue("$race deleted records", f.provider.deleted.isEmpty())
            assertNull(f.receipt("night_hrv"))
            assertTrue(PhoneComputeRuntime.evidence().isEmpty()); assertTrue(PhoneComputeRuntime.forbiddenAttempts().isEmpty())
        }
    }
}
