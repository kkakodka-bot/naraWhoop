import SwiftUI
import StrandDesign
import WhoopStore

/// Test Centre / diagnostics readout for post-offload sync debt and the sync journal.
struct SyncStatusPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    @State private var owedJobs: [SyncJob] = []
    @State private var journal: [SyncJournalEntry] = []
    @State private var refreshToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("BACKGROUND SYNC")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)

            ReadoutRow(
                label: String(localized: "Last successful offload"),
                value: lastOffloadLabel
            )
            ReadoutRow(
                label: String(localized: "Last completed re-score"),
                value: lastRescoreLabel
            )
            ReadoutRow(
                label: String(localized: "Last push success"),
                value: lastPushLabel
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
        .task(id: refreshToken) { await reload() }
        .onAppear { refreshToken &+= 1 }
        .onChangeCompat(of: live.syncStatusRevision) { _ in refreshToken &+= 1 }
    }

    private var lastOffloadLabel: String {
        guard let ts = live.lastSyncedAt else {
            return String(localized: "no offload yet")
        }
        return Date(timeIntervalSince1970: ts).formatted(date: .abbreviated, time: .shortened)
    }

    private var lastRescoreLabel: String {
        guard let seconds = RescoreBackgroundScheduler.lastCompletedPassSeconds else {
            return String(localized: "no completed pass yet")
        }
        return String(localized: "\(Int(seconds.rounded()))s last pass")
    }

    private var lastPushLabel: String {
        guard let at = CloudPushSettings.snapshot().lastSuccessAt else {
            return String(localized: "never")
        }
        return at.formatted(date: .abbreviated, time: .shortened)
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
        guard let store = await model.repo.storeHandle() else { return }
        let jobs = (try? await store.owedJobs()) ?? []
        let entries = (try? await store.recentSyncJournal(limit: 8)) ?? []
        guard !Task.isCancelled, revision == live.syncStatusRevision else { return }
        owedJobs = jobs
        journal = entries
    }
}
