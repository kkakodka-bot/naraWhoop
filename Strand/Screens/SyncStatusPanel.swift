import SwiftUI
import StrandDesign
import WhoopStore
import NoopPush

/// Shared compact status for Devices; Test Centre also includes the existing maintenance journal.
struct SyncStatusPanel: View {
    var showDiagnostics = true
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    @State private var owedJobs: [SyncJob] = []
    @State private var journal: [SyncJournalEntry] = []
    @State private var refreshToken = 0
    @State private var cloud: SyncPresentation.CloudSnapshot?
    @State private var budgetPause: SyncPresentation.Pause?
    @State private var cloudOwner: AccountSessionContext?
    @State private var debtOwner: AccountSessionContext?
    @State private var debtRevision: UInt64?
    @State private var debtLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("BACKGROUND SYNC")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)

            ReadoutRow(label: String(localized: "Strap history"), value: connectionLabel)
            if presentation.showsExperimentalHistoryNotice {
                Text("Connected; strap history sync is experimental on this strap")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ReadoutRow(label: String(localized: "Cloud export"), value: cloudLabel)
            if let reason = presentation.cloudPause {
                Text(pauseLabel(reason))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let chunks = presentation.confirmedChunks {
                ReadoutRow(label: String(localized: "Confirmed chunks"), value: chunks.formatted())
                ReadoutRow(label: String(localized: "Remaining history age"), value: "—")
            }
            ReadoutRow(label: String(localized: "Last strap sync"), value: dateLabel(presentation.lastStrapSync))
            ReadoutRow(label: String(localized: "Last verified cloud receipt"), value: dateLabel(presentation.lastVerifiedReceipt))
            if showDiagnostics, debtOwner == model.accountContext, model.isAccountRuntimeActive {
                ReadoutRow(
                    label: String(localized: "Last completed re-score"),
                    value: lastRescoreLabel
                )
                ReadoutRow(
                    label: String(localized: "Pending now"),
                    value: owedJobs.isEmpty
                        ? String(localized: "none")
                        : owedJobs.map(\.kind).joined(separator: ", ")
                )

                if !journal.isEmpty {
                    Divider().overlay(StrandPalette.hairline)
                    Text("RECENT SYNC PASSES")
                        .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    ForEach(journal, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(journalHeadline(entry))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                            if let note = entry.note, !note.isEmpty {
                                Text(note)
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                    }
                }
            }
        }
        .task(id: refreshToken) {
            while !Task.isCancelled {
                if !debtLoaded || debtRevision != live.syncStatusRevision || debtOwner != model.accountContext {
                    await reload()
                }
                await refreshCloud()
                // Visible presentation only; this timer never drives connection or upload progress.
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onAppear { refreshToken &+= 1 }
        .onChangeCompat(of: live.syncStatusRevision) { _ in refreshToken &+= 1 }
        .onChangeCompat(of: live.syncChunksThisSession) { _ in debtLoaded = false }
        .onChangeCompat(of: live.backfilling) { _ in debtLoaded = false }
        .onChangeCompat(of: live.postOffloadBurstInProgress) { _ in debtLoaded = false }
        .onReceive(NotificationCenter.default.publisher(for: ResourceBudget.changed).receive(on: RunLoop.main)) { _ in
            budgetPause = currentBudgetPause()
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudAuthClient.identityDidChange).receive(on: RunLoop.main)) { _ in
            cloud = nil; cloudOwner = nil; debtOwner = nil; debtRevision = nil; debtLoaded = false
            owedJobs = []; journal = []
            refreshToken &+= 1
        }
    }

    private var presentation: SyncPresentation {
        SyncPresentation.resolve(.init(accountIsCurrent:model.isAccountRuntimeActive,
            connectionPhase:live.connectionPhase, connected:live.connected,
            historyActive:live.backfilling || live.postOffloadBurstInProgress,
            historyPending:live.historyPendingSync, historyExperimental:live.historySyncExperimental,
            confirmedChunks:live.syncChunksThisSession,
            lastStrapSync:live.lastSyncedAt, cloudEnabled:CloudPushSettings.isEnabled,
            cloud:cloudOwner == model.accountContext ? cloud : nil,
            sourceCloudDebt:debtLoaded && debtRevision == live.syncStatusRevision && debtOwner == model.accountContext
                ? owedJobs.contains { $0.kind == "cloudPush" } : nil,
            budgetPause:budgetPause))
    }

    private func dateLabel(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }

    private var connectionLabel: String {
        switch presentation.connection {
        case .unavailable: "—"
        case .disconnected: String(localized:"Disconnected")
        case .intentionallyDisconnected: String(localized:"Disconnected by request")
        case .bluetoothUnavailable: String(localized:"Bluetooth unavailable")
        case .restoring: String(localized:"Restoring connection")
        case .pending: String(localized:"Reconnecting · pending")
        case .connecting: String(localized:"Connecting")
        case .discovering: String(localized:"Discovering services")
        case .subscribing: String(localized:"Subscribing")
        case .recovering: String(localized:"Recovering connection")
        case .connected: String(localized:"Connected")
        case .catchingUp: String(localized:"Catching up")
        case .historyPending: String(localized:"History pending")
        }
    }

    private var cloudLabel: String {
        switch presentation.cloud {
        case .unavailable: "—"
        case .disabled: String(localized:"Automatic export off")
        case .idle: String(localized:"No queued cloud uploads")
        case .pending: String(localized:"Locally safe, cloud pending")
        case .uploading: String(localized:"Sending")
        case .paused: String(localized:"Cloud paused")
        }
    }

    private func pauseLabel(_ reason: SyncPresentation.Pause) -> String {
        switch reason {
        case .authentication: String(localized:"Cloud authentication required")
        case .terminal: String(localized:"Cloud error needs resolution; local data retained")
        case .compatibleEncoding: String(localized:"Retained cloud data needs a compatible app upgrade")
        case .heat: String(localized:"New cloud work paused for heat")
        case .lowPower: String(localized:"New cloud work paused for Low Power Mode")
        case .network: String(localized:"Waiting for an allowed network")
        case .storage: String(localized:"Cloud preparation paused for storage")
        case .history, .fifo: String(localized:"Cloud preparation waits for strap history")
        case .backgroundDeadline: String(localized:"Cloud waiting for background time")
        case .cooldown: String(localized:"Cloud waiting to resume")
        case .queuedCloud: String(localized:"Cloud preparation waits for queued uploads")
        case .retry: String(localized:"Cloud retry scheduled")
        }
    }

    private var lastRescoreLabel: String {
        guard let seconds = RescoreBackgroundScheduler.lastCompletedPassSeconds else {
            return String(localized: "no completed pass yet")
        }
        return String(localized: "\(Int(seconds.rounded()))s last pass")
    }

    private func journalHeadline(_ entry: SyncJournalEntry) -> String {
        let when = Date(timeIntervalSince1970: TimeInterval(entry.ts))
            .formatted(date: .omitted, time: .shortened)
        let ran = entry.stagesRun.isEmpty ? "—" : entry.stagesRun
        let owed = entry.stagesOwed.isEmpty ? "—" : entry.stagesOwed
        return "\(when) · \(entry.wakeReason) · ran \(ran) · pending after pass \(owed) · \(entry.durationMs)ms"
    }

    private func reload() async {
        let revision = live.syncStatusRevision
        let chunks = live.syncChunksThisSession
        let context = model.accountContext
        guard model.isAccountRuntimeActive, ResourceBudget.shared.permits(.bulk) else { return }
        guard let store = await model.repo.storeHandle() else { return }
        guard !Task.isCancelled, ResourceBudget.shared.permits(.bulk) else { return }
        guard let jobs = try? await store.owedJobs() else { debtLoaded = false; return }
        let entries = showDiagnostics && ResourceBudget.shared.permits(.bulk)
            ? ((try? await store.recentSyncJournal(limit: 8)) ?? []) : []
        guard !Task.isCancelled, revision == live.syncStatusRevision,
              chunks == live.syncChunksThisSession, ResourceBudget.shared.permits(.bulk),
              model.isAccountRuntimeActive, model.accountContext == context else { return }
        owedJobs = jobs
        journal = entries
        debtOwner = context
        debtRevision = revision
        debtLoaded = true
    }

    private func currentBudgetPause() -> SyncPresentation.Pause? {
        ResourceBudget.shared.snapshot(for:.cloudPreparation).reason.map {
            switch $0 {
            case .history: .history
            case .fifo: .fifo
            case .heat: .heat
            case .lowPower: .lowPower
            case .backgroundDeadline: .backgroundDeadline
            case .storage: .storage
            case .network: .network
            case .queuedCloud: .queuedCloud
            case .cooldown: .cooldown
            }
        }
    }

    private func refreshCloud() async {
        budgetPause = currentBudgetPause()
        guard model.isAccountRuntimeActive, let context = model.accountContext,
              CloudAuthClient.isCurrent(context),
              let runtime = try? CloudPushBackgroundRuntime.current(for:context),
              let snapshot = try? await runtime.queue.presentationStatus(captured:context) else {
            cloud = nil
            cloudOwner = nil
            return
        }
        guard !Task.isCancelled, model.isAccountRuntimeActive,
              model.accountContext == context, CloudAuthClient.isCurrent(context) else { return }
        cloud = .init(pendingJobs:snapshot.pendingJobs, pendingSelections:snapshot.pendingSelections,
            transferringJobs:snapshot.transferringJobs,
            pause:snapshot.pausedReason.map {
                switch $0 {
                case .authentication: .authentication
                case .terminal: .terminal
                case .compatibleEncoding: .compatibleEncoding
                }
            },
            retryAt:snapshot.retryAt, lastVerifiedReceipt:snapshot.lastVerifiedReceipt)
        cloudOwner = context
    }
}
