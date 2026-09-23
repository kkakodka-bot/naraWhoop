package com.noop.push

internal class ServerResultPollBudget {
    private var identity: String? = null
    private var deadline: Long? = null

    @Synchronized fun interval(identity: String?, pending: Boolean, failed: Boolean, foreground: Boolean,
                               uptimeMs: Long, idleMs: Long): Long {
        if (this.identity != identity) { this.identity = identity; deadline = null }
        if (!foreground || !pending || failed) { deadline = null; return idleMs }
        if (deadline == null) deadline = uptimeMs + 60_000
        return if (uptimeMs < deadline!!) minOf(2_000, idleMs) else idleMs
    }
}
