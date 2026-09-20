import SwiftUI
import StrandDesign

struct CloudAccountView: View {
    @EnvironmentObject private var model: AppModel
    @State private var credential = CloudEnrollment.currentCredential()
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Account") {
                Text(credential == nil ? "Not enrolled" : "Tester account linked")
                Text("This installation uses the same account for uploads and server results. A replacement phone needs a new enrollment code for this account.")
                    .font(.footnote)
            }
            Section("Cloud and Bluetooth") {
                CloudDeviceLinkStatus(repository: model.serverScores)
                Text("The phone stores a buffer while offline. New server results require an internet connection and usable sensor input.")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(StrandPalette.statusWarning) }
            Button("Sign out", role: .destructive) {
                do {
                    try CloudEnrollment.clear()
                    credential = nil
                } catch {
                    errorMessage = "The account could not be signed out. Try again."
                }
            }
            .disabled(credential == nil)
        }
        .navigationTitle("NARA account")
        .onReceive(NotificationCenter.default.publisher(for: .cloudEnrollmentDidChange)) { _ in
            credential = CloudEnrollment.currentCredential()
        }
    }
}

private struct CloudDeviceLinkStatus: View {
    @ObservedObject var repository: ServerScoreRepository
    var body: some View {
        Text(repository.deviceLinked
             ? "The server confirmed that your selected strap is linked to this account."
             : "Waiting for the server to confirm the selected strap. Keep NARA online to complete the link.")
    }
}
