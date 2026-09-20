import SwiftUI
import StrandDesign
import WhoopStore

/// Keeps the selected server method, coverage and unavailable state beside its rate.
struct ServerRespirationSummaryView: View {
    @ObservedObject var scores: ServerScoreRepository
    @State private var dayOffset = 0
    private var day: String {
        Repository.dayString(Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date())
    }

    var body: some View {
        let ready = ServerScoringSettings.ready
        let cache = ready && scores.signedIn ? scores.overlay(for: day) : nil
        let feature = cache?.features["respiration"]
        let summary = ServerRespirationSummary.project(cache, day: day)
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Server respiratory rate").font(StrandFont.subhead)
                HStack {
                    Button { dayOffset += 1 } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous day")
                    Spacer()
                    Text(day).font(StrandFont.footnote)
                    Spacer()
                    Button { dayOffset = max(0, dayOffset - 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(dayOffset == 0).accessibilityLabel("Next day")
                }
                if !ready {
                    Text("Configure the server connection to view respiratory rate.")
                } else if !scores.signedIn {
                    Text("Sign in to view server respiratory rate.")
                } else {
                    Text("\(decimal(summary?.breathsPerMinute)) breaths/min").font(StrandFont.subhead)
                    Text("State: \(feature?.status ?? "unavailable") · \(feature?.processingStatus ?? "unavailable")")
                    Text("Source: \(feature?.deviceId ?? "—") · \(feature?.algorithmVersion ?? "—")")
                    Text("Observed through: \(feature?.observedThrough ?? "—")")
                    Text("Computed: \(feature?.computedAt ?? "—")")
                    if let summary {
                        if summary.legacy {
                            Text("Legacy baseline · quality and evidence coverage unavailable")
                        } else {
                            Text("Primary statistic: median of eligible main-sleep windows")
                            Text("Mean: \(decimal(summary.breathsPerMinute == nil ? nil : summary.mean)) breaths/min")
                            Text("Accepted time: \(decimal(summary.acceptedSeconds.map { $0 / 60 })) min · coverage: \(decimal(summary.coverage.map { $0 * 100 }))%")
                            Text("Accepted windows: \(summary.acceptedWindows.map(String.init) ?? "—") / \(summary.totalWindows.map(String.init) ?? "—")")
                            if summary.breathsPerMinute != nil, let first = summary.distribution.first, let last = summary.distribution.last {
                                Text("Accepted-window range: \(decimal(first))–\(decimal(last)) breaths/min")
                            }
                            Text("Method: \(summary.method ?? "—") · \(summary.calibrationStatus ?? "—")")
                        }
                    }
                    if let reason = summary?.reason ?? feature?.reason {
                        if let explanation = PhysiologyAvailabilityCopy.explanation(for: reason) { Text(explanation) }
                        Text(reason)
                    }
                    if let reason = summary?.measurementReason, reason != (summary?.reason ?? feature?.reason) {
                        if let explanation = PhysiologyAvailabilityCopy.explanation(for: reason) { Text(explanation) }
                        Text(reason)
                    }
                    if let error = scores.lastError { Text(error).foregroundStyle(StrandPalette.statusCritical) }
                    Text("This server result is separate from local history below.")
                }
            }.font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }.task(id: "\(day)|\(ready)|\(scores.signedIn)") {
            if ready && scores.signedIn { await scores.refreshVisibleDays(todayKey: day) }
        }
    }

    private func decimal(_ value: Double?) -> String {
        value.map { String(format: "%.1f", locale: .current, $0) } ?? "—"
    }
}
