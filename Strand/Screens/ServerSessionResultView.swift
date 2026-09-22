import SwiftUI
import WhoopStore

/// Session values are a rendering of one immutable result, never a new analysis of the trace.
struct ServerSessionResultView: View {
    @ObservedObject var coordinator: ServerComputeSessionCoordinator
    let requestID: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let requestID, let result = coordinator.results[requestID] {
                Text(result.status.replacingOccurrences(of: "_", with: " ").capitalized)
                if let reason = result.reason { Text(reason).font(.caption) }
                ForEach(result.metrics.sorted(), id: \.self) { metric in
                    HStack {
                        Text(metric.replacingOccurrences(of: "_", with: " "))
                        Spacer()
                        Text(result.number(metric).map { String(format: "%.2f", $0) } ?? "—")
                    }
                }
                if let revision = result.resultRevision { Text("Result \(revision)").font(.caption2).textSelection(.enabled) }
                if let through = result.observedThrough { Text("Observed through \(through)").font(.caption2) }
            } else {
                Text("Server analysis pending")
                Text(coordinator.lastError ?? "Capture is retained for upload. No on-phone physiological estimate is used.")
                    .font(.caption)
            }
        }
        .accessibilityIdentifier("canonical-session-result")
    }
}
