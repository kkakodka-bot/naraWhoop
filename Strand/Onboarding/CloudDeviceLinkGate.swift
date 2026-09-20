import SwiftUI
import StrandDesign

/// A previous server registration receipt permits offline use. A new strap must be confirmed once.
struct CloudDeviceLinkGate<Content: View>: View {
    @ObservedObject var repository: ServerScoreRepository
    @ViewBuilder var content: () -> Content

    var body: some View {
        if repository.deviceLinked {
            content()
        } else {
            VStack(alignment: .leading, spacing: 20) {
                Text("Linking your strap to your account").font(StrandFont.title2)
                Text("NARA needs one server confirmation for this strap and installation. Keep this device online. Your Bluetooth pairing and stored readings are preserved.").font(StrandFont.body)
                if let error = repository.lastError {
                    Text(error).foregroundStyle(StrandPalette.statusWarning)
                } else {
                    ProgressView("Waiting for confirmation…")
                }
                NoopButton("Retry", fullWidth: true) {
                    Task { await repository.refreshVisibleDays() }
                }
                Button("Sign out") { repository.signOut() }
            }
            .padding(28)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .task {
                while !Task.isCancelled && !repository.deviceLinked {
                    await repository.refreshVisibleDays()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }
}
