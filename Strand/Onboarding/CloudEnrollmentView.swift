import SwiftUI
import StrandDesign

/// Shared by first launch and upgrades. It never starts strap pairing or a storage reset.
struct CloudEnrollmentView: View {
    @State private var code = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var linked = CloudEnrollment.currentCredential() != nil
    @State private var consent = false
    @State private var retirementPending = CloudEnrollment.retirementPending
    @State private var restartRequired = CloudEnrollment.requiresRestart

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                BrandMark(size: 72)
                Text(linked ? "Account linked" : "Link your NARA account")
                    .font(StrandFont.title2)
                if retirementPending {
                    Text("Retirement is pending. Collection is paused and previous records retain their original owner.")
                    NoopButton(busy ? "Retiring…" : "Retry retirement", fullWidth: true) {
                        busy = true
                        Task { @MainActor in
                            defer { busy = false }
                            do { try await CloudEnrollment.retireInstallation(); errorMessage = nil }
                            catch { errorMessage = "Retirement could not finish. Check your connection and retry." }
                        }
                    }.disabled(busy)
                    if let errorMessage { Text(errorMessage).foregroundStyle(StrandPalette.statusWarning) }
                } else if restartRequired {
                    Text("This installation is retired. Close and reopen NARA before enrolling another account. Previous records remain in the original account's storage.")
                } else if linked {
                    Text("Close and reopen NARA to activate your account on this phone.")
                        .font(StrandFont.body)
                    Text("Your pairing is preserved. Existing local history stays on this phone; it is not reassigned to an account. Your account's available server results will load after reopening.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    Text("Enter the tester code you received. It links this installation to your account, so uploads and server results belong to the same person.")
                        .font(StrandFont.body)
                    SecureField("Tester enrollment code", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .disabled(busy)
                        .accessibilityIdentifier("cloudEnrollment.code")
                    Toggle("I agree to send my strap readings to NARA's cloud for storage and analysis.", isOn: $consent)
                        .disabled(busy)
                    Text("Bluetooth and a temporary upload buffer stay on your phone. Internet access is needed to link the account and receive new results. A replacement phone needs a new code for your existing account.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .accessibilityIdentifier("cloudEnrollment.error")
                    }
                    NoopButton(busy ? "Linking account…" : "Link account", fullWidth: true) {
                        enroll()
                    }
                    .disabled(busy || !consent || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("cloudEnrollment.submit")
                    Text("Need a code? Contact the person who invited you to test NARA.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: .cloudEnrollmentDidChange)) { _ in
            linked = CloudEnrollment.currentCredential() != nil
            retirementPending = CloudEnrollment.retirementPending
            restartRequired = CloudEnrollment.requiresRestart
        }
    }

    private func enroll() {
        busy = true
        errorMessage = nil
        let submittedCode = code
        code = ""
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await CloudEnrollment.enroll(code: submittedCode)
                linked = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
