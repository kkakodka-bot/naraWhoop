import SwiftUI
import StrandDesign
import WhoopStore

/// Explains availability without turning missing evidence into a measurement or changing its status.
enum PhysiologyAvailabilityCopy {
    static func explanation(for reason: String) -> String? {
        switch reason {
        case "newer_input_pending":
            return String(localized: "Showing an older completed server result. Newer data is waiting to be scored.")
        case "no_observations":
            return String(localized: "No beat-interval records were included in this server window. Heart-rate samples alone do not supply HRV.")
        case "timing_coverage_unverified":
            return String(localized: "Beat-interval records are present, but their timing coverage has not been verified. More frequent scoring cannot resolve this input limitation.")
        case "timing_unverified":
            return String(localized: "Verified beat timing is unavailable for this window. A respiratory-rate estimate cannot be calculated from these inputs.")
        case "continuity_unverified":
            return String(localized: "Beat-interval records are present, but consecutive original beats have not been established.")
        case "no_quality_eligible_windows":
            return String(localized: "No windows met the signal and timing requirements for a respiratory-rate estimate.")
        case "sleep_context_unavailable":
            return String(localized: "No qualified sleep period was available for this overnight respiratory estimate.")
        case "window_missing":
            return String(localized: "No server result was returned for this five-minute interval.")
        default:
            return nil
        }
    }
}

/// Five-minute server measurements stay separate from the local daily trend.
struct ServerHrvSeriesView: View {
    @ObservedObject var scores: ServerScoreRepository
    @State private var dayOffset = 0
    private var day: String {
        Repository.dayString(Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date())
    }

    var body: some View {
        let ready = ServerScoringSettings.ready
        let cache = ready && scores.signedIn ? scores.overlay(for: day) : nil
        let series = ServerHrvSeries.from(cache, day: day)
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Five-minute HRV").font(StrandFont.subhead)
                Text("Server RMSSD windows; missing readings are not zero.")
                HStack {
                    Button { dayOffset += 1 } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous day")
                    Spacer()
                    Text(day)
                    Spacer()
                    Button { dayOffset = max(0, dayOffset - 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(dayOffset == 0).accessibilityLabel("Next day")
                    Button { Task { await scores.refreshVisibleDays(todayKey: day) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.accessibilityLabel("Refresh")
                }
                if !ready {
                    Text("Configure the server connection to view physiology.")
                } else if !scores.signedIn {
                    Text("Sign in to view server physiology.")
                } else {
                    metadata(series)
                    if let error = scores.lastError { Text(error).foregroundStyle(StrandPalette.statusCritical) }
                    if series.windows.isEmpty {
                        Text("No five-minute HRV windows are available for this day.")
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(series.windows) { window in
                                    windowRow(window)
                                    Divider()
                                }
                            }
                        }.frame(maxHeight: 420)
                    }
                }
            }.font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }.task(id: "\(day)|\(ready)|\(scores.signedIn)") {
            if ready && scores.signedIn { await scores.refreshVisibleDays(todayKey: day) }
        }
    }

    private func metadata(_ series: ServerHrvSeries) -> some View {
        let value = series.featureStatus ?? "unavailable"
        let status = series.stale && value != "stale" ? String(localized: "Stale · \(value)") : value
        return VStack(alignment: .leading, spacing: 4) {
            Text("Server status: \(status)")
            Text("Device: \(series.deviceId ?? "—")")
            Text("Model: \(series.algorithmVersion ?? "—")")
            Text("Observed through: \(series.observedThrough ?? "—")")
            if let reason = series.featureReason {
                if let explanation = PhysiologyAvailabilityCopy.explanation(for: reason) { Text(explanation) }
                Text(reason)
            }
        }
    }

    private func windowRow(_ window: ServerHrvSeries.Window) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(utc(window.start)) – \(utc(window.end)) UTC").monospacedDigit()
            if let value = window.rmssdMs {
                Text("\(decimal(value)) ms").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            } else {
                Text("Unavailable").font(StrandFont.subhead)
            }
            Text("Context: \(window.context)")
            Text("Source: \(window.source ?? "—") · \(window.modality ?? "—")")
            Text("Model: \(window.methodVersion ?? "—")")
            Text("Verified timing coverage: \(window.observedTimeFraction.map { decimal($0 * 100) + "%" } ?? "—")")
            Text("Baseline comparison: \(window.baselineEligible ? String(localized: "Eligible") : String(localized: "Excluded")) · n=\(window.baselineEffectiveSampleCount.map(String.init) ?? "—")")
            if let value = window.baselineRobustZ { Text("Baseline deviation: \(decimal(value))") }
            if let reason = window.reason {
                if let explanation = PhysiologyAvailabilityCopy.explanation(for: reason) { Text(explanation) }
                Text(reason)
            }
            if let reason = window.baselineReason, reason != window.reason { Text(reason) }
        }.accessibilityElement(children: .combine)
    }

    private func decimal(_ value: Double) -> String { String(format: "%.1f", locale: .current, value) }
    private func utc(_ timestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
    }
}
