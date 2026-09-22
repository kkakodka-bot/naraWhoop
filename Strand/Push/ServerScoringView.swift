import SwiftUI
import StrandDesign

/// Test Centre / developer controls for server HRV/sleep readback (Phase 4).
struct ServerScoringView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var serverScores: ServerScoreRepository
    @EnvironmentObject private var repo: Repository
    @State private var enabled = ServerScoringSettings.isEnabled
    @State private var email = ServerScoringSettings.authEmail
    @State private var password = ""
    @State private var working = false
    private var capableVitals: Set<ServerScoreMetric> { ServerScoreMetric.vitals.intersection(serverScores.state.capabilities) }
    private var capableSleep: Set<ServerScoreMetric> { ServerScoreMetric.sleep.intersection(serverScores.state.capabilities) }

    var body: some View {
        ScreenScaffold(
            title: "Server scoring",
            subtitle: "Read cached server scores and history"
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                settingsCard
                authCard
                ScoringContextSharingView()
                ScoringInputConflictReviewView()
                statusCard
            }
        }
    }

    private var settingsCard: some View {
        pushSection(
            icon: "server.rack",
            title: "Display",
            blurb: "Enable readback, then choose which supported fields use server results. Live HR and unmigrated scores stay on-device."
        ) {
            pushToggle(
                title: String(localized: "Use server scores"),
                detail: String(localized: "Requires a Supabase account. Field ownership is selected below."),
                isOn: enabled
            ) { requested in
                ServerScoringSettings.setEnabled(requested)
                enabled = requested
                if requested {
                    serverScores.setForeground(true)
                } else {
                    serverScores.stopPolling()
                }
            }
            pushToggle(title: "Server nightly vitals", detail: "HRV, SDNN, resting HR and respiration. Missing server values stay empty.",
                       isOn: !capableVitals.isEmpty && capableVitals.isSubset(of: serverScores.state.activated)) {
                serverScores.setActivated(capableVitals, enabled: $0)
            }
            .disabled(!serverScores.state.configured || capableVitals.isEmpty)
            pushToggle(title: "Server sleep sessions and totals", detail: "Uses server sessions and stages. Sleep editing is unavailable until edit sync is supported.",
                       isOn: !capableSleep.isEmpty && capableSleep.isSubset(of: serverScores.state.activated)) {
                serverScores.setActivated(capableSleep, enabled: $0)
            }
            .disabled(!serverScores.state.configured || capableSleep.isEmpty)
            extensionToggle("Server Charge", metrics: [.recovery])
            extensionToggle("Server temperature and oxygen", metrics: ServerScoreMetric.temperatureOxygen)
            extensionToggle("Server activity", metrics: ServerScoreMetric.activity)
            extensionToggle("Server sleep scores and history", metrics: ServerScoreMetric.sleepHistory)
            extensionToggle("Server fitness and vitality", metrics: ServerScoreMetric.longevity)
            extensionToggle("Server day stress", metrics: [.stress])
        }
    }

    @ViewBuilder
    private func extensionToggle(_ title: String, metrics: Set<ServerScoreMetric>) -> some View {
        let capable = metrics.intersection(serverScores.state.capabilities)
        if !capable.isEmpty {
            pushToggle(title: title, detail: "Uses only advertised fields. Missing values stay empty; unavailable details are not rebuilt locally.",
                       isOn: capable.isSubset(of: serverScores.state.activated)) {
                serverScores.setActivated(capable, enabled: $0)
            }
            .disabled(!serverScores.state.configured || !serverScores.state.authenticated)
        }
    }

    private var authCard: some View {
        pushSection(
            icon: "person.badge.key.fill",
            title: "Sign in",
            blurb: "Uses your Supabase JWT — not the push ingest token."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                TextField("Email", text: $email)
                    #if os(iOS)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    #endif
                SecureField("Password", text: $password)
                HStack(spacing: NoopMetrics.space3) {
                    NoopButton(working ? "Signing in…" : "Sign in", kind: .secondary, fullWidth: true) {
                        signIn()
                    }
                    .disabled(working || email.isEmpty || password.isEmpty)
                    if serverScores.signedIn || serverScores.signOutNeedsRetry {
                        NoopButton(serverScores.signOutNeedsRetry ? "Retry sign-out" : "Sign out", kind: .tertiary, fullWidth: true) {
                            serverScores.signOut()
                            password = ""
                        }
                    }
                }
            }
        }
    }

    private var statusCard: some View {
        pushSection(
            icon: "clock.arrow.circlepath",
            title: "Status",
            blurb: "Reads versioned snapshots immediately and every \(ServerScoringSettings.pollIntervalSeconds)s while active."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                row("Signed in", serverScores.signOutNeedsRetry ? "Stopped; sign-out not saved" : (serverScores.signedIn ? "Yes" : "No"))
                row("Activated fields", "\(serverScores.state.activated.count)")
                ServerScoreStatusNote(state: serverScores.state, day: serverScores.currentDay)
                ServerScoreInputStatusNote(pending: repo.serverInputPending, hasError: repo.serverInputError != nil)
                if let at = serverScores.lastFetchedAt {
                    row("Last fetch", at.formatted(date: .abbreviated, time: .shortened))
                }
                if let err = serverScores.lastError {
                    Text(err)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                }
            }
        }
    }

    private func signIn() {
        working = true
        Task {
            await serverScores.signIn(email: email, password: password)
            password = ""
            working = false
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value).font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    @ViewBuilder
    private func pushSection<Content: View>(
        icon: String,
        title: String,
        blurb: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        StrandCard(padding: NoopMetrics.space5) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack(spacing: NoopMetrics.space2 + 2) {
                    Image(systemName: icon).foregroundStyle(StrandPalette.accent)
                    Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                }
                Text(blurb)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    @ViewBuilder
    private func pushToggle(
        title: String,
        detail: String,
        isOn: Bool,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: onChange)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(detail).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .tint(StrandPalette.accent)
    }
}
