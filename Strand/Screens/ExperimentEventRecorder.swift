import SwiftUI
import StrandDesign

/// Fast, removable research logger. It records annotations only; it never starts or stops sensors.
struct ExperimentEventRecorder: View {
    @EnvironmentObject private var ble: BLEManager
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var log = ExperimentEventLog.shared

    @State private var exportURL: URL?
    @State private var showingCustomEvent = false
    @State private var customName = ""
    @State private var customNote = ""
    @State private var rememberCustom = true
    @State private var activeNote = ""
    @State private var editingEvent: ExperimentEvent?
    @State private var editName = ""
    @State private var editNote = ""
    @State private var pendingDelete: ExperimentEvent?
    @State private var cloud = CloudPushSettings.snapshot()

    private var quickLabels: [String] { ExperimentEventLog.builtInLabels + log.customLabels }
    private var recentEvents: [ExperimentEvent] {
        Array(log.events.reversed().filter { $0.endUnixSeconds != nil }.prefix(3))
    }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                header
                if let active = log.active {
                    activeCard(active)
                } else {
                    quickEventGrid
                }
                recentSection
                footer
                if let error = log.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.statusCritical)
                }
            }
        }
        .sheet(isPresented: $showingCustomEvent) { customEventSheet }
        .sheet(item: $editingEvent) { event in editEventSheet(event) }
        .confirmationDialog(
            "Delete this event?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete event", role: .destructive) {
                if let pendingDelete { log.delete(id: pendingDelete.id) }
                pendingDelete = nil
                exportURL = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        .onChange(of: log.active?.id) { _ in
            activeNote = log.active?.note ?? ""
        }
        .onChange(of: activeNote) { note in
            guard log.active != nil, note != (log.active?.note ?? "") else { return }
            log.saveActiveNoteDraft(note)
            exportURL = nil
        }
        .onAppear {
            activeNote = log.active?.note ?? ""
        }
        .task {
            while !Task.isCancelled {
                cloud = CloudPushSettings.snapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        HStack(spacing: NoopMetrics.rowSpacing) {
            Image(systemName: "flag.checkered")
                .foregroundStyle(StrandPalette.accent)
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text("Event recorder")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Labels only · sensors keep running independently")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Menu {
                if let exportURL {
                    ShareLink("Share JSON", item: exportURL)
                } else {
                    Button("Prepare JSON export", systemImage: "square.and.arrow.up") {
                        exportURL = log.export()
                    }
                    .disabled(log.events.isEmpty)
                }
                Button("Upload now", systemImage: "icloud.and.arrow.up") { uploadNow() }
                    .disabled(!cloud.ready)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.accent)
            }
            .accessibilityLabel("Event recorder actions")
        }
    }

    private var quickEventGrid: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Tap to start").strandOverline()
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: NoopMetrics.space2),
                    GridItem(.flexible(), spacing: NoopMetrics.space2),
                ],
                spacing: NoopMetrics.space2
            ) {
                ForEach(quickLabels, id: \.self) { label in
                    Button {
                        start(label: label, note: nil)
                    } label: {
                        HStack(spacing: NoopMetrics.space2) {
                            Image(systemName: "play.fill").font(StrandFont.footnote)
                            Text(label)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                        }
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, NoopMetrics.space3)
                        .frame(minHeight: NoopMetrics.controlHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .contextMenu {
                        if log.customLabels.contains(label) {
                            Button("Remove quick event", role: .destructive) {
                                log.removeCustomLabel(label)
                                exportURL = nil
                            }
                        }
                    }
                }
            }
            Button {
                customName = ""
                customNote = ""
                rememberCustom = true
                showingCustomEvent = true
            } label: {
                Label("New event", systemImage: "plus")
                    .font(StrandFont.subhead)
                    .padding(.horizontal, NoopMetrics.space3)
                    .frame(minHeight: NoopMetrics.controlHeight)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func activeCard(_ active: ExperimentEvent) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text(active.label)
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Recording · \(duration(from: active.startUnixSeconds, to: context.date))")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Spacer()
                Circle()
                    .fill(StrandPalette.statusCritical)
                    .frame(width: NoopMetrics.space2, height: NoopMetrics.space2)
                    .accessibilityLabel("Recording")
            }

            HStack(spacing: NoopMetrics.space2) {
                TextField("Optional note", text: $activeNote)
                    .textFieldStyle(.roundedBorder)
                Button("Save note") {
                    log.saveActiveNoteDraft(activeNote)
                    exportURL = nil
                }
                .font(StrandFont.caption)
            }

            Button(role: .destructive) {
                log.stop(note: activeNote)
                exportURL = nil
            } label: {
                Label("Stop and save", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.statusCritical)

            Text("The active event survives backgrounding and app relaunch.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !recentEvents.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Recent").strandOverline()
                ForEach(recentEvents) { event in
                    HStack(spacing: NoopMetrics.rowSpacing) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(StrandPalette.statusPositive)
                        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                            Text(event.label)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(recentDetail(event))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer()
                        Menu {
                            Button("Edit", systemImage: "pencil") {
                                editName = event.label
                                editNote = event.note ?? ""
                                editingEvent = event
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDelete = event
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .padding(NoopMetrics.space2)
                        }
                        .accessibilityLabel("Actions for \(event.label)")
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: cloudIcon)
            Text(cloudStatus)
                .lineLimit(2)
            Spacer(minLength: NoopMetrics.space1)
            Text("\(log.events.count) events")
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textSecondary)
    }

    private var customEventSheet: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    TextField("Event name", text: $customName)
                    TextField("Optional note", text: $customNote, axis: .vertical)
                    Toggle("Keep as a quick event", isOn: $rememberCustom)
                }
                Section {
                    Button("Save preset") {
                        log.addCustomLabel(customName)
                        exportURL = nil
                        showingCustomEvent = false
                    }
                    .disabled(trimmed(customName).isEmpty)
                } footer: {
                    Text("Presets stay on this device and are included in JSON exports. Logged events join the normal cloud export when it is enabled.")
                }
            }
            .navigationTitle("New event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingCustomEvent = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let name = trimmed(customName)
                        if rememberCustom {
                            log.addCustomLabel(name)
                            exportURL = nil
                        }
                        start(label: name, note: customNote)
                        showingCustomEvent = false
                    }
                    .disabled(trimmed(customName).isEmpty)
                }
            }
        }
    }

    private func editEventSheet(_ event: ExperimentEvent) -> some View {
        NavigationStack {
            Form {
                TextField("Event name", text: $editName)
                TextField("Optional note", text: $editNote, axis: .vertical)
            }
            .navigationTitle("Edit event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editingEvent = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        log.update(id: event.id, label: editName, note: editNote)
                        exportURL = nil
                        editingEvent = nil
                    }
                    .disabled(trimmed(editName).isEmpty)
                }
            }
        }
    }

    private func start(label: String, note: String?) {
        let deviceId = ble.deviceId.isEmpty ? CloudPushSettings.sourceId() : ble.deviceId
        log.start(label: label, note: note, deviceId: deviceId)
        activeNote = log.active?.note ?? ""
        exportURL = nil
    }

    private func uploadNow() {
        Task {
            guard let writer = await app.repo.registryWriterForPush() else { return }
            CloudPushScheduler.enqueueManualCatchUp(db: writer)
            cloud = CloudPushSettings.snapshot()
        }
    }

    private var cloudIcon: String {
        switch cloud.runState {
        case .queued, .running, .continuing, .retrying: "icloud.and.arrow.up"
        case .complete: "icloud.fill"
        case .failed: "exclamationmark.icloud"
        case .idle: cloud.ready ? "icloud" : "iphone"
        }
    }

    private var cloudStatus: String {
        guard cloud.ready else { return "Saved locally · cloud export is off" }
        switch cloud.runState {
        case .queued: return "Saved locally · cloud export queued"
        case .running, .continuing: return "Uploading with health data…"
        case .retrying: return "Saved locally · cloud export will retry"
        case .failed: return "Saved locally · cloud export needs attention"
        case .complete:
            if let date = cloud.lastSuccessAt {
                return "Last cloud export completed · \(date.formatted(date: .omitted, time: .shortened))"
            }
            return "Saved locally · included in next cloud export"
        case .idle: return "Saved locally · included in next cloud export"
        }
    }

    private func recentDetail(_ event: ExperimentEvent) -> String {
        let start = Date(timeIntervalSince1970: event.startUnixSeconds)
        let duration = event.endUnixSeconds.map { max(0, $0 - event.startUnixSeconds) } ?? 0
        let note = event.note.map { " · \($0)" } ?? ""
        return "\(start.formatted(date: .omitted, time: .shortened)) · \(compactDuration(duration))\(note)"
    }

    private func duration(from start: Double, to end: Date) -> String {
        compactDuration(max(0, end.timeIntervalSince1970 - start))
    }

    private func compactDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.down))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
