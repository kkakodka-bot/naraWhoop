import Foundation
import WhoopStore

/// Pure decision rules for which post-offload stages a sync drain should run.
///
/// Keeps the orchestration testable without a store, background tasks, or BLE. The engine reads
/// outstanding debts and the wake reason, then asks here whether each stage in order should start.
enum SyncDrainPolicy {

    /// Why the process woke to drain post-offload work.
    enum WakeReason: String, CaseIterable, Sendable {
        case bleEvent
        case foreground
        case backgroundTask
        case stateRestoration
        case offloadComplete
        case manual
    }

    /// Raw transport runs through independent owner/transport admission before the backlog-gated
    /// derived tail; rescore readiness below gates only Health/widget exports.
    static let stageOrder: [SyncJobKind] = [
        .cloudPush, .rescore, .healthWriteback, .widgetPublish,
    ]

    /// A wake may see debt from an intermediate chunk. Wait until the BLE burst reaches its terminal
    /// continuation decision; a disconnect clears the process-local flag and leaves the debt resumable.
    static func shouldStartDrain(backlogBurstInProgress: Bool) -> Bool {
        !backlogBurstInProgress
    }

    /// Whether [stage] should run for this wake. Productive chunks stamp every applicable debt before
    /// trim ack, so wake reason alone is never evidence of work; this keeps empty/frozen terminal sessions
    /// from re-running the whole pipeline.
    static func shouldRun(stage: SyncJobKind,
                          owedKinds: Set<SyncJobKind>,
                          reason: WakeReason) -> Bool {
        owedKinds.contains(stage)
    }

    /// Export surfaces depend on the newly-scored rows. A failed/deferred rescore ends this drain and
    /// leaves all downstream tokens owed for the next foreground or processing wake.
    static func shouldContinue(after stage: SyncJobKind, succeeded: Bool,
                               rescoreStillOwed: Bool) -> Bool {
        if stage == .cloudPush { return true }
        guard !rescoreStillOwed else { return false }
        if stage == .rescore { return succeeded }
        return true
    }
}

/// Pure handoff policy between one historical-offload session and the post-offload pipeline.
///
/// A deep oldest-first backlog can span many timeout or HISTORY_COMPLETE sessions. Only the terminal
/// session may wake the expensive refresh/score/export tail; a dropped link leaves the already-persisted
/// `syncJob` rows for a later foreground or background-maintenance wake.
enum BacklogBurstDrainPolicy {
    enum Action: Equatable {
        case continueBurst
        case finishBurst
        case deferUntilWake
    }

    /// Select the burst action after the continuation predicate has gathered its store frontier.
    static func action(linkUsable: Bool, anotherSessionInFlight: Bool,
                       continuationAllowed: Bool) -> Action {
        guard linkUsable else { return .deferUntilWake }
        if anotherSessionInFlight || continuationAllowed { return .continueBurst }
        return .finishBurst
    }

    /// Whether the existing runner should start at a session boundary. The durable owed row survives an
    /// empty caught-up tail, while a duplicate/phantom session with no inserted work remains a no-op.
    static func shouldDrain(hasOwedWork: Bool, willAutoContinue: Bool) -> Bool {
        hasOwedWork && action(
            linkUsable: true,
            anotherSessionInFlight: false,
            continuationAllowed: willAutoContinue) == .finishBurst
    }

    /// A disconnect is terminal for the current link. Publish once only when it interrupted a burst;
    /// the consumer will find any productive work through its already-durable tokens.
    static func shouldPublishAfterDisconnect(burstInProgress: Bool) -> Bool {
        burstInProgress
    }

    /// Whether an exit proves that rows were committed even without HISTORY_COMPLETE.
    /// Keeps the display timestamp's strict completion meaning separate from downstream durability.
    static func committedDataExit(historyComplete: Bool, timedOut: Bool,
                                  persistedSensorRows: Bool) -> Bool {
        historyComplete || (timedOut && persistedSensorRows)
    }
}
