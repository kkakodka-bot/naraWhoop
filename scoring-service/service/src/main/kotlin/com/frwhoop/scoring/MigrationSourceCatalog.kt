package com.frwhoop.scoring

import org.json.JSONArray
import java.sql.Connection

/** The deployment planner and runtime preflight share this immutable, source-hashed catalog. */
internal object MigrationSourceCatalog {
    val hashes: Map<String, String> by lazy {
        val input = requireNotNull(javaClass.getResourceAsStream("/scoring-migration-catalog.json"))
        val rows = input.bufferedReader(Charsets.UTF_8).use { JSONArray(it.readText()) }
        buildMap {
            for (index in 0 until rows.length()) {
                val row = rows.getJSONObject(index)
                val basename = row.getString("basename")
                val sha256 = row.getString("sha256")
                require(Regex("[0-9]{14}_[a-z0-9_]+\\.sql").matches(basename))
                require(Regex("[0-9a-f]{64}").matches(sha256))
                require(put(basename, sha256) == null)
            }
            require(isNotEmpty())
        }
    }

    /** Timestamp-only rows are usable only when they identify exactly one catalog entry. */
    private fun identity(version: String, name: String?): String {
        val basename = if (Regex("[0-9]{14}").matches(version)) {
            val candidates = hashes.keys.filter { it.startsWith("${version}_") }
            if (name != null) {
                val named = if (name.endsWith(".sql")) name else "${version}_${name}.sql"
                require(named in candidates)
                named
            } else candidates.single()
        } else version
        require(basename in hashes)
        if (name != null && !Regex("[0-9]{14}").matches(version)) {
            val named = if (name.endsWith(".sql")) name else "${version.take(14)}_${name}.sql"
            require(named == basename)
        }
        return basename
    }

    /** Read-only: never creates ledger rows, infers historical hashes, or renames an applied version. */
    fun verify(connection: Connection) {
        fun exists(table: String): Boolean = connection.prepareStatement("select to_regclass(?) is not null").use {
            it.queryTimeout = 10
            it.setString(1, table)
            it.executeQuery().use { rows -> rows.next() && rows.getBoolean(1) }
        }
        val attestations = linkedMapOf<String, String>()
        if (exists("supabase_migrations.scoring_source_identities")) {
            connection.createStatement().use { statement ->
                statement.queryTimeout = 10
                statement.executeQuery("select basename,sha256 from supabase_migrations.scoring_source_identities").use { rows ->
                    while (rows.next()) {
                        val basename = rows.getString(1)
                        val hash = rows.getString(2)
                        require(basename in hashes && hash == hashes[basename])
                        require(attestations.put(basename, hash) == null)
                    }
                }
            }
        }
        val applied = linkedMapOf<String, String>()
        if (exists("supabase_migrations.schema_migrations")) {
            connection.createStatement().use { statement ->
                statement.queryTimeout = 10
                // Optional columns differ between Supabase's ledger and the self-hosted runner.
                statement.executeQuery("""select version,to_jsonb(m)->>'name',
                    to_jsonb(m)->>'source_sha256',to_jsonb(m)->>'sha256'
                    from supabase_migrations.schema_migrations m""").use { rows ->
                    while (rows.next()) {
                        val basename = identity(rows.getString(1), rows.getString(2))
                        val sourceHash = rows.getString(3)
                        val exportHash = rows.getString(4)
                        require(sourceHash == null || exportHash == null || sourceHash == exportHash)
                        val hash = sourceHash ?: exportHash ?: attestations[basename]
                        require(hash != null && hash == hashes[basename])
                        require(applied.put(basename, hash) == null)
                    }
                }
            }
        }
        require((applied.keys + attestations.keys).containsAll(hashes.keys))
    }
}
