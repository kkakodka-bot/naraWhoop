#if os(iOS)
import SwiftUI
import StrandDesign
import NoopPush

/// Fleet cloud-push status and controls. The destination (Supabase Edge Function) and bearer
/// token are baked into the build — there is no per-user endpoint to configure.
struct CloudPushView: View {
    @EnvironmentObject private var model: AppModel

    @State private var snapshot = CloudPushSettings.snapshot()
    @State private var cloudPaused = false
    @State private var lastVerifiedReceipt: Date?
    @State private var resolvingPause = false
    @State private var resolutionError: String?

    var body: some View {
        ScreenScaffold(
            title: "Cloud export",
            subtitle: "Research backend"
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                exportCard
                statusCard
            }
        }
        .task {
            while !Task.isCancelled {
                snapshot = CloudPushSettings.snapshot()
                if let context = CloudAuthClient.currentContext(),
                   let runtime = try? CloudPushBackgroundRuntime.current(for: context) {
                    let paused = (try? await runtime.queue.pausedMessage(captured: context)) != nil
                    let receipt = try? await runtime.queue.lastVerifiedReceiptDate(captured: context)
                    if CloudAuthClient.isCurrent(context) {
                        cloudPaused = paused
                        lastVerifiedReceipt = receipt
                    }
                } else {
                    cloudPaused = false
                    lastVerifiedReceipt = nil
                }
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    private var exportCard: some View {
        pushSection(
            icon: "icloud.and.arrow.up.fill",
            title: "Export",
            blurb: "When enabled, NOOP sends raw health records from this phone to the research backend. That means data explicitly leaves the device."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("One-way export only. NOOP cannot restore from the backend.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)

                capabilitySummary

                pushToggle(
                    title: String(localized: "Wi‑Fi only"),
                    detail: String(localized: "Exports use unmetered Wi‑Fi only. Turn off to allow cellular and other connected networks."),
                    isOn: snapshot.wifiOnly
                ) { requested in
                    CloudPushSettings.setWifiOnly(requested)
                    snapshot = CloudPushSettings.snapshot()
                    Task {
                        guard let writer = await model.repo.registryWriterForPush() else { return }
                        CloudPushScheduler.networkPolicyChanged(db: writer)
                    }
                }

                pushToggle(
                    title: String(localized: "Export waveform and raw batches"),
                    detail: String(localized: "Also upload large binary streams (PPG waveforms, 100 Hz motion, v18 auxiliary fields, and pre-decode frame batches). On by default; these objects are much larger than ordinary health records."),
                    isOn: snapshot.binaryObjectsEnabled
                ) { requested in
                    CloudPushSettings.setBinaryObjectsEnabled(requested)
                    snapshot = CloudPushSettings.snapshot()
                }

                pushToggle(
                    title: String(localized: "Enable automatic export"),
                    detail: String(localized: "After a full strap sync, export new and changed data automatically and catch up backlog on launch."),
                    isOn: snapshot.enabled
                ) { requested in
                    if !requested {
                        CloudPushSettings.setEnabled(false)
                        CloudPushScheduler.cancelScheduledWork()
                    } else {
                        CloudPushSettings.setEnabled(true)
                        Task {
                            guard let writer = await model.repo.registryWriterForPush() else { return }
                            CloudPushScheduler.enqueueLaunchCatchUp(db: writer)
                        }
                    }
                    snapshot = CloudPushSettings.snapshot()
                }

                NoopButton("Export now", kind: .secondary, fullWidth: true) {
                    exportNow()
                }
                .disabled(!snapshot.ready)

                Text("Start a catch-up immediately. Automatic export must be enabled first.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusCard: some View {
        pushSection(
            icon: "icloud.and.arrow.up.fill",
            title: "Status",
            blurb: "Credentials never appear in status or background task metadata."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2 + 2) {
                if isActive {
                    ProgressView()
                        .tint(StrandPalette.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Current state: \(runStateLabel(snapshot.runState))")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Current export: \(snapshot.acceptedBatches) batches · \(snapshot.acceptedRecords) records accepted")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("Last full catch-up: \(formattedDate(snapshot.lastSuccessAt) ?? String(localized: "Never"))")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let lastError = snapshot.lastError {
                    Text("Last error: \(lastError)")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Last verified cloud receipt: \(formattedDate(lastVerifiedReceipt) ?? String(localized: "Never"))")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                if cloudPaused {
                    NoopButton("Retry after resolution", kind: .secondary, fullWidth: true) {
                        resolvingPause = true
                        resolutionError = nil
                        Task {
                            defer { resolvingPause = false }
                            guard let context = CloudAuthClient.currentContext(),
                                  let runtime = try? CloudPushBackgroundRuntime.current(for: context) else { return }
                            do {
                                try await runtime.queue.resumePaused(captured: context)
                                guard CloudAuthClient.isCurrent(context),
                                      let writer = await model.repo.registryWriterForPush() else { return }
                                CloudPushScheduler.enqueueManualCatchUp(db: writer)
                            } catch {
                                if CloudAuthClient.isCurrent(context) {
                                    resolutionError = "Cloud sync could not resume. Saved data is retained."
                                }
                            }
                        }
                    }
                    .disabled(resolvingPause || !snapshot.ready)
                    if let resolutionError {
                        Text(resolutionError)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                    }
                    Text("Use after signing in again, updating the app, or resolving the reported server error. Saved data is retained.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var capabilitySummary: some View {
        if let shownStreams = snapshot.supportedStreams {
            let total = PushCapabilities.all.wireNames.count
            Text("Receiver supports \(shownStreams.count)/\(total) data types")
                .font(StrandFont.body)
                .foregroundStyle(shownStreams.isEmpty ? StrandPalette.statusWarning : StrandPalette.textPrimary)
            if let checkedAt = snapshot.capabilitiesCheckedAt {
                Text("Last checked: \(formattedDate(checkedAt) ?? "")")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Text(
                shownStreams.isEmpty
                    ? String(localized: "This receiver currently accepts no protocol 1.0 health data.")
                    : String(localized: "Accepted data: \(shownStreams.joined(separator: " · "))")
            )
            .font(StrandFont.footnote)
            .foregroundStyle(shownStreams.isEmpty ? StrandPalette.statusWarning : StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isActive: Bool {
        switch snapshot.runState {
        case .queued, .running, .continuing, .retrying: true
        case .idle, .complete, .failed: false
        }
    }

    private func exportNow() {
        Task {
            guard let writer = await model.repo.registryWriterForPush() else { return }
            CloudPushScheduler.enqueueManualCatchUp(db: writer)
            snapshot = CloudPushSettings.snapshot()
        }
    }

    private func runStateLabel(_ state: CloudPushSettings.RunState) -> String {
        switch state {
        case .idle: String(localized: "Idle")
        case .queued: String(localized: "Queued")
        case .running: String(localized: "Sending")
        case .continuing: String(localized: "More local data found; continuing")
        case .retrying: String(localized: "Retrying after error")
        case .complete: String(localized: "Up to date")
        case .failed: String(localized: "Paused after error")
        }
    }

    private func formattedDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    private func pushSection<Content: View>(
        icon: String,
        title: LocalizedStringKey,
        blurb: LocalizedStringKey,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        StrandCard(padding: NoopMetrics.space5) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: NoopMetrics.space2 + 2) {
                        Image(systemName: icon)
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                Text(blurb)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    private func pushToggle(
        title: String,
        detail: String,
        isOn: Bool,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: NoopMetrics.space4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: Binding(
                get: { isOn },
                set: { onChange($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(StrandPalette.accent)
        }
    }
}
#endif
