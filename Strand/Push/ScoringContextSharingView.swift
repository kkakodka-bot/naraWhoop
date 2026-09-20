import SwiftUI
import NoopPush
import StrandDesign

/// Captured presentation authority, never a lookup of whichever account happens to be current later.
@MainActor
struct ScoringSyncControlOwner {
    let context: AccountSessionContext
    let isCurrent: () -> Bool

    init(context: AccountSessionContext, isCurrent: @escaping () -> Bool) {
        self.context = context
        self.isCurrent = isCurrent
    }

    init?(model: AppModel) {
        guard let context = model.accountContext, model.isAccountRuntimeActive else { return nil }
        self.init(context: context, isCurrent: { [weak model] in
            model?.isAccountRuntimeActive == true && model?.accountContext == context
        })
    }
}

@MainActor
final class ScoringContextSharingActions: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, saving, failed, retired }
    static let unconfirmedMessage = String(localized: "A sharing choice could not be confirmed. New sends for affected context are paused on this device. Reload saved choices before making a new choice. Server acceptance is not confirmed here.")
    @Published private var storedPhase: Phase = .idle
    @Published private var note: String?
    private let owner: ScoringSyncControlOwner
    let consent: ScoringContextConsent
    private var revision: UInt64 = 0
    private var presented = true

    init(owner: ScoringSyncControlOwner, consent: ScoringContextConsent) {
        self.owner = owner; self.consent = consent
    }

    private var current: Bool { owner.isCurrent() && consent.gate.writeFence.isValid }
    var phase: Phase { current ? storedPhase : .retired }
    var message: String? { current ? note : String(localized: "This account is no longer active. Reopen settings for the current account.") }
    var disabled: Bool { !current || !presented || !consent.loaded || consent.saving || phase == .saving || phase == .loading }

    private func canPublish(_ request: UInt64) -> Bool {
        current && presented && revision == request && !Task.isCancelled
    }

    func load() async {
        guard current, !consent.saving, storedPhase != .saving, !Task.isCancelled else { return }
        presented = true; revision &+= 1
        let request = revision
        storedPhase = .loading; note = nil
        guard canPublish(request) else { return }
        await consent.load()
        guard canPublish(request) else { return }
        note = consent.error == nil ? nil : Self.unconfirmedMessage
        guard canPublish(request) else { return }
        storedPhase = consent.loaded && consent.error == nil ? .ready : .failed
    }

    /// Every invocation is a new explicit choice. Reopening/loading never repeats a failed choice.
    func save(_ enabled: Bool, purpose: ScoringContextPurpose, now: Date = Date()) async {
        guard !disabled, [.journal, .cycle].contains(purpose), !Task.isCancelled else { return }
        let previousID = consent.decisions[purpose]?.id
        revision &+= 1
        let request = revision
        storedPhase = .saving; note = nil
        guard canPublish(request) else { return }
        let interval = SyncPipelineTrace.begin(.interaction)
        var outcome = SyncPipelineTrace.Outcome.cancelled
        defer { SyncPipelineTrace.end(interval, outcome: outcome) }
        await consent.setEnabled(enabled, purpose: purpose, now: now)
        guard canPublish(request) else { return }
        if consent.error != nil {
            outcome = .failed; note = Self.unconfirmedMessage
            guard canPublish(request) else { return }
            storedPhase = .failed
        } else if let decision = consent.decisions[purpose], decision.id != previousID, decision.enabled == enabled {
            outcome = .succeeded
            note = String(localized: "Choice saved on this device. Server acceptance is not confirmed here.")
            guard canPublish(request) else { return }
            storedPhase = .ready
        } else {
            outcome = .failed
            note = String(localized: "The choice could not be confirmed. Reload the saved choices before making a new choice.")
            guard canPublish(request) else { return }
            storedPhase = .failed
        }
    }

    func suspend() {
        revision &+= 1; presented = false; note = nil; storedPhase = .idle
    }
}

@MainActor
struct ScoringContextSharingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        StrandCard(padding: NoopMetrics.space5) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Optional server context").font(StrandFont.title2)
                if !model.isAccountRuntimeActive {
                    Text("This account is no longer active. Reopen settings for the current account.")
                } else if model.accountContext == nil {
                    Text("Sign in to manage optional context for your account and server. Local tracking is separate.")
                } else if let owner = ScoringSyncControlOwner(model: model), let consent = model.scoringContextConsent {
                    ScoringContextSharingControls(owner: owner, consent: consent)
                        .id(owner.context)
                } else {
                    Text("Sharing controls are unavailable for this account. Reopen settings before making a choice.")
                }
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textPrimary)
        }
    }
}

@MainActor
private struct ScoringContextSharingControls: View {
    @ObservedObject var consent: ScoringContextConsent
    @StateObject private var actions: ScoringContextSharingActions

    init(owner: ScoringSyncControlOwner, consent: ScoringContextConsent) {
        self.consent = consent
        _actions = StateObject(wrappedValue: ScoringContextSharingActions(owner: owner, consent: consent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Separate from local tracking and general cloud sync. Choices apply only to this account and server. Turning on sharing does not upload earlier local-only entries.")
                .foregroundStyle(StrandPalette.textSecondary)
            if actions.phase == .loading || (!consent.loaded && actions.phase != .failed) {
                ProgressView("Loading saved sharing choices…")
            }
            if consent.saving || actions.phase == .saving {
                ProgressView("Saving choice on this device…")
            }
            toggle("Use explicitly shared daily journal context", purpose: .journal)
            Text("Shares only selected daily flags, not notes or custom question text.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            toggle("Use newly shared period starts", purpose: .cycle)
            Text("Period dates are sensitive health data. Turning off pauses new sends from this device. Offline, the server may continue processing previously shared data until it accepts and applies the change. Previously shared data is not deleted. Older queued entries stay retained and are not automatically released when sharing is turned on again.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            if let message = actions.message ?? (consent.error == nil ? nil : ScoringContextSharingActions.unconfirmedMessage) {
                Text(message).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(actions.phase == .failed ? StrandPalette.textPrimary : StrandPalette.textSecondary)
            }
            if actions.phase == .failed {
                Button("Reload saved choices") { Task { await actions.load() } }
                    .frame(minHeight: 44).disabled(consent.saving)
                Text("A new choice is not a retry of the original decision. Server acceptance is not confirmed here.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .task { await actions.load() }
        .onDisappear { actions.suspend() }
    }

    private func toggle(_ label: String, purpose: ScoringContextPurpose) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Toggle(label, isOn: Binding(get: { consent.enabled(purpose) }, set: { value in
                Task { await actions.save(value, purpose: purpose) }
            }))
            .tint(StrandPalette.accent).frame(minHeight: 44).disabled(actions.disabled)
            if consent.error != nil, !consent.enabled(purpose) {
                Button("Save Off as a new choice") { Task { await actions.save(false, purpose: purpose) } }
                    .frame(minHeight: 44).disabled(actions.disabled)
                    .accessibilityLabel("\(label): save Off as a new choice")
            }
        }
    }
}
