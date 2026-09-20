package com.noop.data

import android.util.AtomicFile
import android.util.Base64
import org.json.JSONObject
import java.io.File
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption

class V18AuxIdentityConflict : IllegalStateException("Conflicting auxiliary input retained; chunk not acknowledged")

/** This is local quarantine, not an uploaded frame, remote receipt or permission to evict raw data. */
internal class V18AuxConflictArchive(private val db: WhoopDatabase) {
    fun retain(existing: V18AuxSampleEntity, incoming: V18AuxSampleEntity) {
        val owner = requireNotNull(db.accountIdentity?.scope) { "Unassigned capture cannot acquire an owner" }
        val fence = requireNotNull(db.accountWriteFence)
        fence.commit {
            val database = File(requireNotNull(db.openHelper.databaseName)).canonicalFile
            val directory = File(database.parentFile!!.parentFile, "quarantine/v18-conflicts")
            check(directory.isDirectory || directory.mkdirs())
            val bytes = JSONObject().put("schemaVersion", 1).put("projectURL", owner.projectURL).put("userID", owner.userID)
                .put("deviceId", incoming.deviceId).put("ts", incoming.ts).put("recordIndex", incoming.recordIndex)
                .put("originalResourceKey", existing.resourceKey)
                .put("originalFields", Base64.encodeToString(existing.fields, Base64.NO_WRAP))
                .put("incomingFields", Base64.encodeToString(incoming.fields, Base64.NO_WRAP)).toString().toByteArray(Charsets.UTF_8)
            val file = File(directory, V18AuxIdentityMigration.sha256(bytes) + ".json")
            if (file.exists()) check(file.readBytes().contentEquals(bytes))
            else {
                val atomic = AtomicFile(file)
                val stream = atomic.startWrite()
                try { stream.write(bytes); stream.fd.sync(); atomic.finishWrite(stream) }
                catch (failure: Throwable) { atomic.failWrite(stream); throw failure }
            }
            // Checked directory durability, including newly created quarantine subdirectories.
            for (parent in listOf(directory, directory.parentFile!!, directory.parentFile!!.parentFile!!)) {
                FileChannel.open(parent.toPath(), StandardOpenOption.READ).use { it.force(true) }
            }
            check(file.readBytes().contentEquals(bytes))
        }
    }
}
