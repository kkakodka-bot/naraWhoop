import Foundation
import SwiftUI
import NoopPush
import StrandDesign
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class ScoringInputConflictActions: ObservableObject {
    enum LoadPhase: Equatable { case idle, loading, loaded, failed, retired }
    enum ReviewPhase: Equatable { case local, checking, ready, recording, recorded, failed, retired }
    typealias PayloadReader = @Sendable (Data) async throws -> String
    typealias Resolution = @MainActor (ScoringInputCoordinator.ConflictReview, ScoringInputChange) async throws -> Void
    static let listLimit = 32
    static let unknownServerValues = String(localized: "Server values are unavailable in this review. The revision is not a copy of the server's values.")

    @Published private var rows: [ScoringInputJournal.Conflict] = []
    @Published private var storedLoadPhase: LoadPhase = .idle
    @Published private var storedReviewPhase: ReviewPhase = .local
    @Published private var selected: ScoringInputJournal.Conflict?
    @Published private var reviewed: ScoringInputCoordinator.ConflictReview?
    @Published private var replacementID: String?
    @Published private var acknowledged = false
    @Published private var listNote: String?
    @Published private var reviewNote: String?
    @Published private var inspectionID: String?
    @Published private var inspectionText: String?
    @Published private var inspectionError: String?
    @Published private var inspecting = false
    private let owner: ScoringSyncControlOwner
    private let coordinator: ScoringInputCoordinator
    private let readPayload: PayloadReader
    private let resolve: Resolution
    private var listRevision: UInt64 = 0
    private var reviewRevision: UInt64 = 0
    private var payloadRevision: UInt64 = 0
    private var presented = true
    private var resolutionInFlight = false

    init(owner: ScoringSyncControlOwner, coordinator: ScoringInputCoordinator,
         readPayload: @escaping PayloadReader = { data in try await ScoringInputConflictActions.decodePayload(data) },
         resolve: Resolution? = nil) {
        self.owner = owner; self.coordinator = coordinator; self.readPayload = readPayload
        self.resolve = resolve ?? { try await coordinator.resolveConflict($0, replacement: $1) }
    }

    private var current: Bool { owner.isCurrent() && owner.context == coordinator.context }
    var loadPhase: LoadPhase { current ? storedLoadPhase : .retired }
    var reviewPhase: ReviewPhase { current ? storedReviewPhase : .retired }
    var conflicts: [ScoringInputJournal.Conflict] { current && presented ? rows : [] }
    var conflict: ScoringInputJournal.Conflict? { current && presented ? selected : nil }
    var review: ScoringInputCoordinator.ConflictReview? { current && presented ? reviewed : nil }
    var selectedMutationID: String? { current && presented ? replacementID : nil }
    var wholeQueueAcknowledged: Bool { current && presented && acknowledged }
    var listMessage: String? { current ? listNote : String(localized: "This account is no longer active. Reopen settings for the current account.") }
    var reviewMessage: String? { current ? reviewNote : String(localized: "Account changed. No result is confirmed in this view.") }
    var payloadID: String? { current && presented ? inspectionID : nil }
    var payloadText: String? { current && presented ? inspectionText : nil }
    var payloadError: String? { current && presented ? inspectionError : nil }
    var payloadLoading: Bool { current && presented && inspecting }
    var busy: Bool { resolutionInFlight || storedReviewPhase == .checking }
    var canConfirm: Bool {
        guard current, presented, !busy, storedReviewPhase == .ready, acknowledged,
              let review = reviewed, review.context == owner.context,
              review.conflict == selected, let id = replacementID else { return false }
        return review.conflict.queuedMutationIDs.contains(id)
    }

    private func canPublish(_ revision: UInt64) -> Bool {
        current && presented && reviewRevision == revision && !Task.isCancelled
    }

    func load() async {
        guard current, !Task.isCancelled else { return }
        presented = true; listRevision &+= 1
        let request = listRevision
        storedLoadPhase = .loading; listNote = nil
        do {
            let result = try await coordinator.conflicts(limit: Self.listLimit)
            guard current, presented, listRevision == request, !Task.isCancelled else { return }
            rows = result
            guard current, presented, listRevision == request else { return }
            storedLoadPhase = .loaded
        } catch {
            guard current, presented, listRevision == request, !Task.isCancelled else { return }
            listNote = Self.failureMessage(error)
            storedLoadPhase = .failed
        }
    }

    func open(_ id: String) {
        guard current, presented, !resolutionInFlight, let value = rows.first(where: { $0.pending.id == id }) else { return }
        dismissReview()
        selected = value
        storedReviewPhase = .local
    }

    func checkHead() async {
        guard current, presented, !resolutionInFlight, let conflict = selected, !Task.isCancelled else { return }
        reviewRevision &+= 1
        let request = reviewRevision
        reviewed = nil; replacementID = nil; acknowledged = false; reviewNote = nil
        closePayload(); storedReviewPhase = .checking
        guard canPublish(request) else { return }
        do {
            let result = try await coordinator.reviewConflict(id: conflict.pending.id)
            guard canPublish(request) else { return }
            guard result.context == owner.context,
                  result.conflict.queuedMutationIDs.count == result.conflict.queuedChanges.count else {
                throw ScoringInputJournal.Failure.invalidReceipt
            }
            selected = result.conflict
            guard canPublish(request) else { return }
            reviewed = result
            storedReviewPhase = .ready
        } catch {
            guard canPublish(request) else { return }
            reviewNote = Self.failureMessage(error)
            storedReviewPhase = .failed
        }
    }

    func select(_ id: String) {
        guard current, presented, !busy, storedReviewPhase == .ready,
              reviewed?.conflict.queuedMutationIDs.contains(id) == true else { return }
        replacementID = id; acknowledged = false
    }

    func acknowledge(_ value: Bool) {
        guard current, presented, !busy, storedReviewPhase == .ready, replacementID != nil else { return }
        acknowledged = value
    }

    func confirm() async {
        guard canConfirm, let review = reviewed, let id = replacementID,
              let index = review.conflict.queuedMutationIDs.firstIndex(of: id),
              review.conflict.queuedChanges.indices.contains(index), !Task.isCancelled else { return }
        let replacement = review.conflict.queuedChanges[index]
        let request = reviewRevision
        resolutionInFlight = true
        defer { resolutionInFlight = false }
        storedReviewPhase = .recording; reviewNote = nil
        guard canPublish(request) else { return }
        let interval = SyncPipelineTrace.begin(.interaction)
        var outcome = SyncPipelineTrace.Outcome.cancelled
        defer { SyncPipelineTrace.end(interval, outcome: outcome) }
        do {
            try await resolve(review, replacement)
            guard canPublish(request) else { return }
            outcome = .succeeded
            reviewed = nil; replacementID = nil; acknowledged = false
            reviewNote = String(localized: "Replacement recorded locally. Server acceptance is not confirmed here. Refresh the list to check remaining work.")
            guard canPublish(request) else { return }
            storedReviewPhase = .recorded
        } catch {
            guard canPublish(request) else { return }
            outcome = .failed
            // A status read can fail after the replacement committed. Never retry blindly or
            // claim rollback; the next explicit review reads the journal again.
            reviewed = nil; replacementID = nil; acknowledged = false
            reviewNote = Self.failureMessage(error)
            storedReviewPhase = .failed
        }
    }

    func inspect(_ id: String) async {
        guard current, presented, let conflict = selected,
              let index = conflict.queuedMutationIDs.firstIndex(of: id),
              conflict.queuedChanges.indices.contains(index), !Task.isCancelled else { return }
        payloadRevision &+= 1
        let payloadRequest = payloadRevision, request = reviewRevision
        inspectionText = nil; inspectionError = nil; inspectionID = id; inspecting = true
        do {
            let text = try await readPayload(conflict.queuedChanges[index].payload)
            guard canPublish(request), payloadRevision == payloadRequest, inspectionID == id else { return }
            inspectionText = text; inspecting = false
        } catch {
            guard canPublish(request), payloadRevision == payloadRequest, inspectionID == id else { return }
            inspectionError = String(localized: "The complete payload could not be opened. Nothing was submitted.")
            inspecting = false
        }
    }

    nonisolated static func decodePayload(_ bytes: Data) async throws -> String {
        try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard bytes.count <= 65536, let text = String(data: bytes, encoding: .utf8) else {
                throw ScoringInputJournal.Failure.invalidInput
            }
            // Exact bounded UTF-8, not pretty printing whose indentation can amplify nested JSON.
            return text
        }.value
    }

    func closePayload() {
        payloadRevision &+= 1
        inspectionID = nil; inspectionText = nil; inspectionError = nil; inspecting = false
    }

    func dismissReview() {
        reviewRevision &+= 1
        selected = nil; reviewed = nil; replacementID = nil; acknowledged = false; reviewNote = nil
        closePayload(); storedReviewPhase = .local
    }

    func suspend() {
        presented = false; listRevision &+= 1
        dismissReview(); rows = []; listNote = nil; storedLoadPhase = .idle
    }

    private static func failureMessage(_ error: Error) -> String {
        switch error {
        case ScoringInputJournal.Failure.staleReview:
            return String(localized: "The queued changes changed. Review the complete queue again and make a new selection.")
        case ScoringInputRPC.Failure.held, ScoringInputJournal.Failure.held:
            return String(localized: "Sharing or admission is paused for this change. It remains retained. Review cannot obtain a new permission or release older sensitive entries.")
        case ScoringInputRPC.Failure.unavailable:
            return String(localized: "The server revision is unavailable. Check sign-in, connectivity and sync policy, then check the revision again. Saved changes remain retained.")
        case ScoringInputJournal.Failure.storageLimit, ScoringInputJournal.Failure.relayCapacity:
            return String(localized: "Storage could not confirm the operation. No automatic retry was made. Refresh the list before another review.")
        case ScoringInputJournal.Failure.retired, ScoringInputJournal.Failure.wrongOwner, ScoringInputRPC.Failure.staleOwner:
            return String(localized: "This review belongs to an inactive account session. Reopen settings for the current account.")
        case ScoringInputJournal.Failure.invalidReceipt, ScoringInputRPC.Failure.invalidResponse:
            return String(localized: "The server response could not be verified for this review. No server values are available. Check the revision again.")
        default:
            return String(localized: "The operation could not be confirmed. Refresh the list before reviewing again; do not assume a pending change was sent or discarded.")
        }
    }
}

@MainActor
struct ScoringInputConflictReviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        StrandCard(padding: NoopMetrics.space5) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Changes needing review").font(StrandFont.title2)
                if !model.isAccountRuntimeActive {
                    Text("This account is no longer active. Reopen settings for the current account.")
                } else if model.accountContext == nil {
                    Text("Sign in to review this account's queued changes.")
                } else if let owner = ScoringSyncControlOwner(model: model), let inputs = model.scoringInputs {
                    ScoringInputConflictControls(owner: owner, coordinator: inputs).id(owner.context)
                } else {
                    Text("The account's input journal is unavailable. No queued changes can be reviewed here yet.")
                }
            }
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
        }
    }
}

@MainActor
private struct ScoringInputConflictControls: View {
    @StateObject private var actions: ScoringInputConflictActions

    init(owner: ScoringSyncControlOwner, coordinator: ScoringInputCoordinator) {
        _actions = StateObject(wrappedValue: ScoringInputConflictActions(owner: owner, coordinator: coordinator))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            if actions.loadPhase == .loading { ProgressView("Loading retained changes…") }
            if actions.loadPhase == .loaded, actions.conflicts.isEmpty {
                Text("No changes currently need conflict review. This does not confirm that all pending uploads reached the server.")
            }
            if let message = actions.listMessage { Text(message).foregroundStyle(StrandPalette.textPrimary) }
            LazyVStack(alignment: .leading, spacing: NoopMetrics.space2) {
                ForEach(actions.conflicts, id: \.pending.id) { conflict in
                    Button {
                        actions.open(conflict.pending.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("Review \(conflict.pending.change.kind.rawValue): \(conflict.pending.change.entity)")
                            Text("\(conflict.queuedMutationIDs.count) queued changes · first effective day \(conflict.pending.change.effectiveDay)")
                                .font(StrandFont.caption)
                        }
                    }
                    .frame(minHeight: 44)
                }
            }
            if actions.conflicts.count == ScoringInputConflictActions.listLimit {
                Text("Showing the first 32 review groups. Resolve and refresh to see later groups. Every queued change within an opened group is listed.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            Button("Refresh review list") { Task { await actions.load() } }
                .frame(minHeight: 44).disabled(actions.loadPhase == .loading || actions.loadPhase == .retired)
        }
        .task { await actions.load() }
        .onDisappear { actions.suspend() }
        .sheet(isPresented: Binding(get: { actions.conflict != nil }, set: { if !$0 { actions.dismissReview() } })) {
            ScoringInputConflictSheet(actions: actions)
        }
    }
}

@MainActor
private struct ScoringInputConflictSheet: View {
    @ObservedObject var actions: ScoringInputConflictActions

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack {
                Text("Review queued changes").font(StrandFont.title2)
                Spacer()
                Button("Close") { actions.dismissReview() }
                    .keyboardShortcut(.cancelAction).frame(minHeight: 44)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    if let conflict = actions.conflict {
                        Text("Device: \(conflict.pending.change.device)")
                        Text("Account: \(conflict.pending.scope.userID)")
                        Text("Server: \(conflict.pending.scope.projectURL)")
                        Text("Kind: \(conflict.pending.change.kind.rawValue) · Entity: \(conflict.pending.change.entity)")
                        Text("Original expected revision: \(conflict.pending.expectedRevision)")
                        if let head = actions.review?.head {
                            Text("Reviewed server head revision: \(head.headRevision)")
                        } else { Text("Server head revision has not been verified for this review.") }
                        Text(ScoringInputConflictActions.unknownServerValues)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Button(actions.reviewPhase == .checking ? "Checking server revision…" : "Check server revision") {
                            Task { await actions.checkHead() }
                        }
                        .frame(minHeight: 44).disabled(actions.busy || actions.reviewPhase == .recorded)
                        ForEach(conflict.queuedMutationIDs.indices, id: \.self) { index in
                            if conflict.queuedChanges.indices.contains(index) {
                                intent(conflict.queuedChanges[index], id: conflict.queuedMutationIDs[index], ordinal: index + 1)
                            }
                        }
                        Toggle(isOn: Binding(get: { actions.wholeQueueAcknowledged }, set: { actions.acknowledge($0) })) {
                            Text("I reviewed all \(conflict.queuedMutationIDs.count) listed changes, including differing effective dates. Replace this entire entity queue with my selected version and archive all original intents.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .tint(StrandPalette.accent).frame(minHeight: 44)
                        .disabled(actions.selectedMutationID == nil || actions.busy || actions.reviewPhase != .ready)
                        Button(actions.reviewPhase == .recording ? "Recording replacement…" : "Record selected replacement") {
                            Task { await actions.confirm() }
                        }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(!actions.canConfirm)
                        Text("This replaces pending server-input work, not your currently accepted on-device preferences. Server acceptance and recomputation are separate.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    if let message = actions.reviewMessage {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .padding(NoopMetrics.space5)
        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 600, minHeight: 520)
        #endif
        .sheet(isPresented: Binding(get: { actions.payloadID != nil }, set: { if !$0 { actions.closePayload() } })) {
            if let id = actions.payloadID { payload(id: id).padding(NoopMetrics.space5) }
        }
    }

    private func intent(_ change: ScoringInputChange, id: String, ordinal: Int) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Divider()
            Text("Queued change \(ordinal)").font(StrandFont.subhead)
            Text("Mutation: \(id)")
            Text("Effective day: \(change.effectiveDay)")
            Text(change.deleted ? "Operation: deletion" : "Operation: value replacement")
            Text("Complete payload: \(change.payload.count) bytes")
            Button("Inspect full payload") { Task { await actions.inspect(id) } }.frame(minHeight: 44)
            Button(actions.selectedMutationID == id ? "Selected version" : "Select this version") { actions.select(id) }
                .frame(minHeight: 44).disabled(actions.busy || actions.reviewPhase != .ready)
                .accessibilityValue(actions.selectedMutationID == id ? "Selected" : "Not selected")
        }
    }

    private func payload(id: String) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Full payload for \(id)").font(StrandFont.subhead)
            if actions.payloadLoading { ProgressView("Opening complete payload…") }
            if let text = actions.payloadText {
                ScoringPayloadTextView(text: text).frame(height: 260)
                    .accessibilityLabel("Complete read-only queued JSON payload")
            }
            if let error = actions.payloadError { Text(error).foregroundStyle(StrandPalette.textPrimary) }
            Button("Close payload") { actions.closePayload() }
                .keyboardShortcut(.cancelAction).frame(minHeight: 44)
        }
    }
}

// A single <=64 KiB payload is decoded off-main. Native selectable text keeps raw-data inspection
// read-only and scrollable; monospace distinguishes exact JSON from explanatory presentation copy.
#if os(iOS)
private struct ScoringPayloadTextView: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true
        view.font = UIFontMetrics.default.scaledFont(for: .monospacedSystemFont(ofSize: 14, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label; view.backgroundColor = .secondarySystemBackground
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text; view.setContentOffset(.zero, animated: false) }
    }
}
#elseif os(macOS)
private struct ScoringPayloadTextView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false; view.isSelectable = true
            view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            view.textColor = .labelColor; view.backgroundColor = .textBackgroundColor
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let view = scroll.documentView as? NSTextView, view.string != text {
            view.string = text; view.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }
}
#endif
