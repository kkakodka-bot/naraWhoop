package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.SignalInventoryReader
import java.time.Instant
import java.time.LocalDate
import java.util.UUID

/** Separate read-only command; it does not initialize scoring, heartbeats, model workers or object writes. */
object SignalInventoryCommand {
    data class Request(val user: UUID, val device: UUID, val day: String, val window: Pair<Long, Long>?)

    fun request(environment: Map<String, String>): Request {
        fun required(key: String) = environment[key]?.takeIf { it.isNotBlank() } ?: error("$key required for --inventory-signals")
        val user = UUID.fromString(required("INVENTORY_USER_ID"))
        val device = UUID.fromString(required("INVENTORY_DEVICE_ID"))
        val day = LocalDate.parse(required("INVENTORY_DAY")).toString()
        val start = environment["INVENTORY_START"]
        val end = environment["INVENTORY_END"]
        require((start == null) == (end == null)) { "INVENTORY_START and INVENTORY_END must be supplied together" }
        val window = if (start == null) null else {
            val lo = Instant.parse(start); val hi = Instant.parse(end!!)
            require(lo.nano == 0 && hi.nano == 0 && hi > lo) { "inventory bounds must be increasing whole UTC seconds" }
            lo.epochSecond to hi.epochSecond
        }
        return Request(user, device, day, window)
    }

    fun run(environment: Map<String, String>) {
        val request = request(environment)
        val url = environment["DATABASE_URL"]?.takeIf { it.isNotBlank() } ?: error("DATABASE_URL required for --inventory-signals")
        PostgresClient(url).use { db ->
            println(SignalInventoryReader(db).report(request.user, request.device, request.day, request.window).toString(2))
        }
    }
}
