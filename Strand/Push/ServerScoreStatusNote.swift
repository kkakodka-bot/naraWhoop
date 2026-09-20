import SwiftUI
import StrandDesign

struct ServerScoreStatusNote: View {
    let state: ServerScoreViewState
    let day: String

    var body: some View {
        if state.hasServerOwnership {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.days[day]?.note ?? "Waiting for server scores")
                Text("Server authority applies only to selected fields.")
                if let result = state.days[day]?.snapshot {
                    Text("Source \(result.sourceDeviceId.prefix(8)) · \(result.algorithmVersion) · revision \(result.resultRevision)")
                    if let through = result.dataThrough, let date = ServerScoreDate.parse(through) {
                        Text("Data through \(date.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .accessibilityElement(children: .combine)
        }
    }
}

struct ServerScoreInputStatusNote: View {
    let pending: Int
    let hasError: Bool

    var body: some View {
        if pending > 0 || hasError {
            VStack(alignment: .leading, spacing: 2) {
                if pending > 0 {
                    Text("\(pending) changes waiting for server sync. Scores may not reflect them yet.")
                }
                if hasError {
                    // The transport error can contain response text; never display raw input or RPC bodies.
                    Text("Server input sync failed. Pending changes have not been confirmed by the server.")
                }
            }
            .font(StrandFont.footnote)
            .foregroundStyle(hasError ? StrandPalette.statusWarning : StrandPalette.textSecondary)
            .accessibilityElement(children: .combine)
        }
    }
}

@MainActor
private struct ServerScoreContentReadyModifier: ViewModifier {
    let identity: ServerScoreContentReadyTrace.Identity
    let ready: Bool
    @StateObject private var trace = ServerScoreContentReadyTrace()

    func body(content: Content) -> some View {
        content
            .onAppear { trace.appear(identity: identity, ready: ready) }
            .onChangeCompat(of: identity) { newIdentity in trace.update(identity: newIdentity, ready: ready) }
            .onChangeCompat(of: ready) { isReady in trace.update(identity: identity, ready: isReady) }
            .onDisappear { trace.disappear() }
    }
}

extension View {
    @MainActor
    func serverScoreContentReady(state: ServerScoreViewState, day: String, ready: Bool) -> some View {
        modifier(ServerScoreContentReadyModifier(identity: .init(generation: state.generation,
            day: day, timezone: state.timezone), ready: ready))
    }
}
