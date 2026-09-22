package com.frwhoop.scoring.db

/** Budget includes all lanes and replicas, with a separate reserve for Edge, administration and restore. */
data class ConnectionBudget(val poolSize: Int, val replicas: Int, val databaseBudget: Int, val reserve: Int) {
    init {
        require(poolSize in 4..32 && replicas in 1..128 && reserve >= 0)
        require(poolSize.toLong() * replicas + reserve <= databaseBudget) { "Scoring connection budget exceeded" }
    }
    companion object {
        fun fromEnvironment(env: Map<String, String> = System.getenv()): ConnectionBudget {
            fun setting(name: String, default: Int): Int = env[name]?.let {
                requireNotNull(it.toIntOrNull()) { "Invalid $name" }
            } ?: default
            return ConnectionBudget(setting("SCORING_DB_POOL_SIZE", 4), setting("SCORING_TOTAL_REPLICAS", 1),
                setting("SCORING_DB_CONNECTION_BUDGET", 20), setting("SCORING_DB_CONNECTION_RESERVE", 8))
        }
    }
}
