package com.noop.data

/** The sole upgrade copy allowlist. Samples, jobs, analysis, and ownership are never transferred. */
internal object EnrollmentPairingMetadata {
    private val columns = linkedMapOf(
        "pairedDevice" to setOf("id", "brand", "model", "nickname", "peripheralId", "sourceKind", "capabilities", "status", "addedAt", "lastSeenAt"),
        "device" to setOf("id", "mac", "name", "firstSeen", "lastSeen"),
    )

    fun copy(read: (String) -> List<Map<String, Any?>>, write: (String, Array<Any?>) -> Unit) {
        val present = read("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('pairedDevice','device')")
            .mapNotNull { it["name"] as? String }.toSet()
        for ((table, allowed) in columns) {
            if (table !in present) continue
            val rows = read("SELECT * FROM `$table`")
            if (rows.isEmpty()) continue
            if (table == "pairedDevice") write("DELETE FROM pairedDevice", emptyArray())
            for (row in rows) {
                val names = row.keys.filter { it in allowed }
                require("id" in names) { "Missing legacy pairing identity" }
                val sql = "INSERT OR REPLACE INTO `$table` (${names.joinToString { "`$it`" }}) VALUES (${names.joinToString { "?" }})"
                write(sql, names.map { row[it] }.toTypedArray())
            }
        }
    }
}
