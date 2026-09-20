package com.frwhoop.scoring

import com.frwhoop.scoring.scoring.ScoringPoller

/** Executable boundary only: the poller has already stopped renewal and attempted fenced backoff. */
internal object ScoringWorkerProcess {
    const val FATAL_EXIT_CODE = 70

    fun run(action: () -> Unit) {
        try { action() }
        catch (_: ScoringPoller.UnresponsiveAttempt) {
            // Non-daemon library threads and shutdown hooks must not keep an abandoned worker alive.
            // No synchronous logging here: a blocked appender must not prevent termination.
            // The OS closes its remaining connections; durable revisions/results are never rewritten.
            Runtime.getRuntime().halt(FATAL_EXIT_CODE)
        }
    }
}
