import SwiftUI
import StrandDesign
import WhoopStore

/// A presentation-only surface over the same immutable ledger used by background consumers.
/// Missing ledger entries are server-unavailable, never a request to reconstruct physiology.
struct CanonicalPhysiologySection: View {
    @EnvironmentObject private var repo: Repository
    let families: [String]
    var day: String? = nil
    var history = false

    private var windows: [String] {
        if let day { return [day] }
        let current = repo.serverPresentation.currentDay
        let today = current.isEmpty ? Repository.localDayKey(Date()) : current
        return history ? Array(Set(repo.serverPresentation.canonicalDays.keys).union([today])).sorted(by: >) : [today]
    }

    var body: some View {
        ForEach(windows, id: \.self) { window in
            ForEach(families, id: \.self) { family in
                let result = repo.serverPresentation.canonicalDays[window]?.families[family]
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                        Text(family.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text("\(window) · Server · \(result?.status ?? "unavailable")")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        if repo.serverPresentation.days[window]?.phase == .failed {
                            Text("Server read failed · cached result is not current")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        } else if repo.serverPresentation.days[window]?.cached == true {
                            Text("Cached server revision")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                        if let result {
                            ForEach(result.metrics.sorted(), id: \.self) { metric in
                                HStack(alignment: .top) {
                                    Text(metric.replacingOccurrences(of: "_", with: " "))
                                    Spacer(minLength: 12)
                                    Text(repo.serverPresentation.days[window]?.phase == .failed
                                         ? "—" : Self.display(result: result, metric: metric))
                                        .multilineTextAlignment(.trailing)
                                }
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            }
                            if let reason = result.reason {
                                Text(reason).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            }
                            Text(result.resultRevision.map { "Result revision: \($0)" } ?? "No published result revision")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            if let through = result.observedThrough {
                                Text("Observed through: \(through)")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                        } else {
                            Text(repo.serverPresentation.pendingCanonicalDays[window]?.reason
                                 ?? "Awaiting an authorized server result for this device and day.")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
            }
        }
    }

    /// Formatting only. No default numbers, score reconstruction, baseline, or local ranking.
    static func display(result: ServerCanonicalFamilyResult, metric: String) -> String {
        guard result.metrics.contains(metric), result.hasCanonicalAuthorization,
              ["available", "stale"].contains(result.status), let value = result.values[metric]
        else { return "—" }
        return display(value)
    }

    private static func display(_ value: ServerJSONValue) -> String {
        switch value {
        case .null: return "—"
        case .number(let number): return number.formatted(.number.precision(.fractionLength(0...2)))
        case .string(let string): return string
        case .bool(let flag): return flag ? "Yes" : "No"
        case .array(let values): return values.map(display).joined(separator: "\n")
        case .object(let fields):
            return fields.keys.sorted().map { "\($0): \(display(fields[$0]!))" }.joined(separator: "\n")
        }
    }
}

/// Direct wearable observation, deliberately distinct from inferred PPG or RR heart rate.
struct DeviceReportedHeartRateSection: View {
    @EnvironmentObject private var live: LiveState
    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Device-reported heart rate").font(StrandFont.headline)
                Text(live.heartRate.flatMap { $0 > 0 ? "\($0) bpm" : nil } ?? "—")
                    .font(StrandFont.title2)
                Text("Direct wearable observation · not inferred from PPG or RR on this phone")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}
