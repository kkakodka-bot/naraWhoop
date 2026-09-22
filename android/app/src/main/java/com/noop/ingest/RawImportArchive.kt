package com.noop.ingest

import android.content.Context
import android.net.Uri
import com.noop.account.AccountStorageContext
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONObject

/** Source bytes remain durable even when their physiological aggregation is unavailable. */
internal object RawImportArchive {
    fun capture(context: Context, uri: Uri, source: String): File {
        require(source.matches(Regex("[a-z-]+")))
        val account = AccountStorageContext.capture(context)
        check(account.isCurrent()) { "Import account changed" }
        val directory = File(account.filesDir, "raw-imports/$source")
        check(directory.isDirectory || directory.mkdirs()) { "Import archive unavailable" }
        val partial = File(directory, "${UUID.randomUUID()}.partial")
        val digest = MessageDigest.getInstance("SHA-256")
        var size = 0L
        FileOutputStream(partial).use { output ->
            requireNotNull(account.contentResolver.openInputStream(uri)) { "Could not open source import" }.use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    check(account.isCurrent()) { "Import account changed" }
                    output.write(buffer, 0, count); digest.update(buffer, 0, count); size += count
                }
            }
            output.fd.sync()
        }
        check(account.isCurrent()) { "Import account changed" }
        val hash = digest.digest().joinToString("") { "%02x".format(it) }
        val archive = File(directory, "$hash.source")
        if (archive.isFile) check(partial.delete()) else check(partial.renameTo(archive))
        val receipt = JSONObject().put("source", source).put("sha256", hash).put("bytes", size)
            .put("captured_at", java.time.Instant.now().toString()).put("physiological_processing", "server_owned_unsupported")
        FileOutputStream(File(directory, "$hash.json")).use { output ->
            output.write(receipt.toString().toByteArray(Charsets.UTF_8)); output.fd.sync()
        }
        java.nio.channels.FileChannel.open(directory.toPath(), java.nio.file.StandardOpenOption.READ).use { it.force(true) }
        return archive
    }
}
