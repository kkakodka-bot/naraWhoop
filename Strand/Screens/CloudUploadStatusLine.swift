import SwiftUI
import StrandDesign

/// "Uploading to cloud · 63%" with a determinate bar and the rows still waiting. Shared by the Live
/// Bluetooth diagnostic card and the strap-history sync note so both read the same measurement.
/// Percent is real here (rows past the push cursor over rows in the store); the strap-history line
/// next to it keeps its chunk count because the strap never reports a total.
struct CloudUploadStatusLine: View {
    let progress: CloudUploadProgress
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
            HStack(spacing: NoopMetrics.space2) {
                StatePill(title, tone: tone, pulsing: progress.phase == .uploading)
                if let backlog = progress.backlog {
                    Text(backlog.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(StrandFont.captionNumber)
                        .monospacedDigit()
                    Text("\(backlog.pendingRows) rows left")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .monospacedDigit()
                }
            }
            if let backlog = progress.backlog {
                ProgressView(value: backlog.fraction)
                    .tint(barTint)
                    .frame(maxWidth: compact ? 220 : .infinity)
                    .accessibilityLabel(Text("Cloud upload"))
                    .accessibilityValue(Text(backlog.fraction, format: .percent.precision(.fractionLength(0))))
            }
        }
    }

    private var title: LocalizedStringKey {
        switch progress.phase {
        case .uploading: return "Uploading to cloud…"
        case .retrying: return "Cloud upload paused, will retry"
        case .queued: return "Cloud upload queued"
        case .complete: return "Cloud upload complete"
        case .failed: return "Cloud upload needs attention"
        case .idle: return "Cloud upload idle"
        }
    }

    private var tone: StrandTone {
        switch progress.phase {
        case .failed: return .warning
        case .complete: return .positive
        default: return .accent
        }
    }

    private var barTint: Color {
        progress.phase == .failed ? StrandPalette.statusWarning : StrandPalette.statusPositive
    }
}
