import SwiftUI

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

    private let builtInLabels = [
        "Rest", "Walking", "Wrist movement", "Sleeve warming",
        "Off wrist", "Posture change", "Mental arithmetic",
    ]

    private var quickLabels: [String] { builtInLabels + log.customLabels }
    private var recentEvents: [ExperimentEvent] {
        Array(log.events.reversed().filter { $0.endUnixSeconds != nil }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
        .task {
            while !Task.isCancelled {
                cloud = CloudPushSettings.snapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "flag.checkered")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Event recorder").font(.headline)
                Text("Labels only · sensors keep running independently")
                    .font(.caption2).foregroundStyle(.secondary)
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
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .accessibilityLabel("Event recorder actions")
        }
    }

    private var quickEventGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tap to start").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 8)], spacing: 8) {
                ForEach(quickLabels, id: \.self) { label in
                    Button {
                        start(label: label, note: nil)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "play.fill").font(.caption2)
                            Text(label).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 11)
                        .frame(minHeight: 42)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if log.customLabels.contains(label) {
                            Button("Remove quick event", role: .destructive) {
                                log.removeCustomLabel(label)
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
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 11)
                        .frame(minHeight: 42)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func activeCard(_ active: ExperimentEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(active.label).font(.title3.weight(.semibold))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Recording · \(duration(from: active.startUnixSeconds, to: context.date))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Circle().fill(.red).frame(width: 9, height: 9)
                    .accessibilityLabel("Recording")
            }

            HStack(spacing: 8) {
                TextField("Optional note", text: $activeNote)
                    .textFieldStyle(.roundedBorder)
                Button("Save note") {
                    log.update(id: active.id, label: active.label, note: activeNote)
                    exportURL = nil
                }
                .font(.caption)
            }

            Button(role: .destructive) {
                if activeNote != (active.note ?? "") {
                    log.update(id: active.id, label: active.label, note: activeNote)
                }
                log.stop()
                exportURL = nil
            } label: {
                Label("Stop and save", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Text("The active event survives backgrounding and app relaunch.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
    }

    @ViewBuilder
    private var recentSection: some View {
        if !recentEvents.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(recentEvents) { event in
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.label).font(.subheadline.weight(.medium))
                            Text(recentDetail(event)).font(.caption2).foregroundStyle(.secondary)
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
                            Image(systemName: "ellipsis").padding(6)
                        }
                        .accessibilityLabel("Actions for \(event.label)")
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: cloudIcon)
            Text(cloudStatus)
                .lineLimit(2)
            Spacer(minLength: 4)
            Text("\(log.events.count) events")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
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
                        if rememberCustom { log.addCustomLabel(name) }
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
                return "Included in cloud export · \(date.formatted(date: .omitted, time: .shortened))"
            }
            return "Cloud export up to date"
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
