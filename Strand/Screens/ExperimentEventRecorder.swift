import SwiftUI
import StrandDesign

/// Fast, removable research logger. It records annotations only; it never starts or stops sensors.
struct ExperimentEventRecorder: View {
    @EnvironmentObject private var ble: BLEManager
    @EnvironmentObject private var app: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var log = ExperimentEventLog.shared

    @State private var exportURL: URL?
    @State private var showingCustomEvent = false
    @State private var showingEventPicker = false
    @State private var showingPastEvent = false
    @State private var showingEventTypeManager = false
    @State private var customName = ""
    @State private var customNote = ""
    @State private var rememberCustom = true
    @State private var pastName = ""
    @State private var pastNote = ""
    @State private var pastStart = Date().addingTimeInterval(-15 * 60)
    @State private var pastEnd = Date()
    @State private var rememberPastLabel = true
    @State private var activeNote = ""
    @State private var editingEvent: ExperimentEvent?
    @State private var editName = ""
    @State private var editNote = ""
    @State private var editStart = Date()
    @State private var editEnd = Date()
    @State private var newEventType = ""
    @State private var eventTypeBeingRenamed: String?
    @State private var renamedEventType = ""
    @State private var showingRenameEventType = false
    @State private var pendingDelete: ExperimentEvent?
    @State private var cloud = CloudPushSettings.snapshot()

    private var quickLabels: [String] { log.eventLabels }
    private var featuredLabels: [String] {
        Array(log.eventLabels.prefix(3))
    }
    private var recentEvents: [ExperimentEvent] {
        Array(log.events.reversed().filter { $0.endUnixSeconds != nil }.prefix(2))
    }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                header
                if let active = log.active {
                    activeCard(active)
                } else {
                    quickStartSection
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
        .sheet(isPresented: $showingEventPicker) { eventPickerSheet }
        .sheet(isPresented: $showingPastEvent) { pastEventSheet }
        .sheet(isPresented: $showingEventTypeManager) { eventTypeManagerSheet }
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
            openRequestedDemoSheet()
        }
        .task {
            while !Task.isCancelled {
                cloud = CloudPushSettings.snapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: NoopMetrics.rowSpacing) {
            if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: "flag.checkered")
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "flag.checkered")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                }
                Text("Event recorder")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Labels only · sensors keep running independently")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actionsMenu
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button("Log past event", systemImage: "clock.arrow.circlepath") {
                preparePastEvent()
            }
            Button("Manage event types", systemImage: "slider.horizontal.3") {
                showingEventTypeManager = true
            }
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
                .frame(minWidth: NoopMetrics.controlHeight, minHeight: NoopMetrics.controlHeight)
        }
        .accessibilityLabel("Event recorder actions")
    }

    private var quickStartSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Quick start").strandOverline()
            ForEach(featuredLabels, id: \.self) { label in
                quickStartButton(label)
            }

            Button {
                showingEventPicker = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Image(systemName: "list.bullet")
                        .accessibilityHidden(true)
                    Text("All event types")
                    Spacer(minLength: NoopMetrics.space2)
                    Text("\(quickLabels.count)")
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .font(StrandFont.body)
                .multilineTextAlignment(.leading)
                .padding(.vertical, NoopMetrics.space1)
                .frame(minHeight: NoopMetrics.controlHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Shows built-in and saved custom event types")

            Button {
                preparePastEvent()
            } label: {
                Label("Log past event", systemImage: "clock.arrow.circlepath")
                    .font(StrandFont.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, NoopMetrics.space1)
                    .frame(minHeight: NoopMetrics.controlHeight)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Enter a label, start time, and end time for an event that already happened")

            Button {
                customName = ""
                customNote = ""
                rememberCustom = true
                showingCustomEvent = true
            } label: {
                Label("Create custom event", systemImage: "plus")
                    .font(StrandFont.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, NoopMetrics.space1)
                    .frame(minHeight: NoopMetrics.controlHeight)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func quickStartButton(_ label: String) -> some View {
        Button {
            start(label: label, note: nil)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                Image(systemName: "play.fill")
                    .font(StrandFont.subhead)
                    .accessibilityHidden(true)
                Text(label)
                    .font(StrandFont.body)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: NoopMetrics.space2)
            }
            .foregroundStyle(StrandPalette.textPrimary)
            .multilineTextAlignment(.leading)
            .padding(.vertical, NoopMetrics.space1)
            .frame(minHeight: NoopMetrics.controlHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Start \(label) event")
    }

    private func activeCard(_ active: ExperimentEvent) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
            Label("Recording", systemImage: "record.circle.fill")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.statusCritical)

            Text(active.label)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(duration(from: active.startUnixSeconds, to: context.date))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityLabel("Elapsed time")
            }

            TextField("Optional note", text: $activeNote, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
            Text("Saved automatically")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)

            Button(role: .destructive) {
                log.stop(note: activeNote)
                exportURL = nil
            } label: {
                Label("Stop and save", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.statusCritical)
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !recentEvents.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Recent").strandOverline()
                ForEach(recentEvents) { event in
                    Button {
                        beginEditing(event)
                    } label: {
                        HStack(alignment: .top, spacing: NoopMetrics.rowSpacing) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(StrandPalette.statusPositive)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                                Text(event.label)
                                    .font(StrandFont.body)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(recentTiming(event))
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                if let note = event.note {
                                    Text(note)
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: NoopMetrics.space2)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(StrandPalette.textSecondary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens this event for editing")
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Label(cloudStatus, systemImage: cloudIcon)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(log.events.count) events")
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
        } else {
            HStack(alignment: .top, spacing: NoopMetrics.space2) {
                Image(systemName: cloudIcon)
                    .accessibilityHidden(true)
                Text(cloudStatus)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: NoopMetrics.space1)
                Text("\(log.events.count) events")
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var customEventSheet: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    TextField("Event name", text: $customName, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("Optional note", text: $customNote, axis: .vertical)
                        .lineLimit(2...6)
                    Toggle("Keep as a quick event", isOn: $rememberCustom)
                }
                Section {
                    Button {
                        let name = trimmed(customName)
                        if rememberCustom {
                            log.addEventLabel(name)
                            exportURL = nil
                        }
                        start(label: name, note: customNote)
                        showingCustomEvent = false
                    } label: {
                        Label("Start event", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed(customName).isEmpty)

                    Button("Save preset without starting") {
                        log.addEventLabel(customName)
                        exportURL = nil
                        showingCustomEvent = false
                    }
                    .disabled(trimmed(customName).isEmpty)
                } footer: {
                    Text("Presets stay on this device and are included in JSON exports. Logged events join the normal cloud export when it is enabled.")
                }
            }
            .navigationTitle("New event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingCustomEvent = false }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: dynamicTypeSize.isAccessibilitySize)
        #endif
    }

    private var eventPickerSheet: some View {
        NavigationStack {
            List {
                if log.eventLabels.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No event types",
                            systemImage: "tag.slash",
                            description: Text("Add an event type to create a reusable start button.")
                        )
                    }
                } else {
                    Section("Event types") {
                        ForEach(log.eventLabels, id: \.self) { label in
                            eventPickerRow(label)
                                .swipeActions {
                                    Button("Delete", role: .destructive) {
                                        log.removeEventLabel(label)
                                        exportURL = nil
                                    }
                                }
                        }
                    }
                }
                Section {
                    NavigationLink {
                        eventTypeManagerPage
                    } label: {
                        Label("Manage event types", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        showingEventPicker = false
                        Task { @MainActor in
                            await Task.yield()
                            preparePastEvent()
                        }
                    } label: {
                        Label("Log past event", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            .navigationTitle("Start event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingEventPicker = false }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    private func eventPickerRow(_ label: String) -> some View {
        Button {
            start(label: label, note: nil)
            showingEventPicker = false
        } label: {
            Label(label, systemImage: "play.fill")
                .font(StrandFont.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, NoopMetrics.space1)
                .frame(minHeight: NoopMetrics.controlHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("Start \(label) event")
    }

    private var pastEventSheet: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    if !log.eventLabels.isEmpty {
                        Picker("Use saved event type", selection: $pastName) {
                            Text("Choose or type below").tag("")
                            ForEach(log.eventLabels, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    TextField("Event label", text: $pastName, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("Optional note", text: $pastNote, axis: .vertical)
                        .lineLimit(2...6)
                    Toggle("Save label as an event type", isOn: $rememberPastLabel)
                }

                Section("Time range") {
                    DatePicker("Start", selection: $pastStart,
                               in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End", selection: $pastEnd,
                               in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                }

                if let validation = intervalValidation(start: pastStart, end: pastEnd) {
                    Section {
                        Label(validation, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(StrandPalette.statusCritical)
                    }
                }

                Section {
                    Button {
                        let name = trimmed(pastName)
                        let deviceId = currentDeviceId
                        guard log.addCompleted(label: name, note: pastNote, deviceId: deviceId,
                                               start: pastStart, end: pastEnd) else { return }
                        if rememberPastLabel { log.addEventLabel(name) }
                        exportURL = nil
                        showingPastEvent = false
                    } label: {
                        Label("Save past event", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed(pastName).isEmpty || intervalValidation(start: pastStart, end: pastEnd) != nil)
                } footer: {
                    Text("This interval is saved locally immediately and joins the same JSON and cloud exports as live-recorded events.")
                }
            }
            .navigationTitle("Past event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingPastEvent = false }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    private var eventTypeManagerSheet: some View {
        NavigationStack {
            eventTypeManagerPage
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingEventTypeManager = false }
                    }
                }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    private var eventTypeManagerPage: some View {
        List {
            Section {
                TextField("Name", text: $newEventType, axis: .vertical)
                    .lineLimit(1...3)
                Button {
                    guard log.addEventLabel(newEventType) else { return }
                    newEventType = ""
                    exportURL = nil
                } label: {
                    Label("Add event type", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(trimmed(newEventType).isEmpty)
            } header: {
                Text("Add")
            }

            if let error = log.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(StrandPalette.statusCritical)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                if log.eventLabels.isEmpty {
                    Text("No event types yet")
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    ForEach(log.eventLabels, id: \.self) { label in
                        Button {
                            eventTypeBeingRenamed = label
                            renamedEventType = label
                            showingRenameEventType = true
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                                Text(label)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: NoopMetrics.space2)
                                Image(systemName: "pencil")
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: NoopMetrics.controlHeight)
                        }
                        .accessibilityLabel("Edit \(label) event type")
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                log.removeEventLabel(label)
                                exportURL = nil
                            }
                        }
                    }
                    .onMove { offsets, destination in
                        log.moveEventLabels(fromOffsets: offsets, toOffset: destination)
                        exportURL = nil
                    }
                    .onDelete { offsets in
                        let labels = offsets.compactMap { index in
                            log.eventLabels.indices.contains(index) ? log.eventLabels[index] : nil
                        }
                        labels.forEach(log.removeEventLabel)
                        exportURL = nil
                    }
                }
            } header: {
                Text("Event types")
            } footer: {
                Text("Tap to rename, swipe to delete, or use Edit to reorder. Changes affect future choices; recorded events keep their original labels.")
            }
        }
        .navigationTitle("Event types")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .alert("Rename event type", isPresented: $showingRenameEventType) {
            TextField("Event name", text: $renamedEventType)
            Button("Cancel", role: .cancel) {
                eventTypeBeingRenamed = nil
            }
            Button("Save") {
                guard let old = eventTypeBeingRenamed else { return }
                if log.renameEventLabel(old, to: renamedEventType) {
                    exportURL = nil
                    eventTypeBeingRenamed = nil
                }
            }
            .disabled(trimmed(renamedEventType).isEmpty)
        } message: {
            Text("Recorded events keep their existing label.")
        }
    }

    private func editEventSheet(_ event: ExperimentEvent) -> some View {
        NavigationStack {
            Form {
                Section("Event") {
                    TextField("Event name", text: $editName, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("Optional note", text: $editNote, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section("Time range") {
                    DatePicker("Start", selection: $editStart,
                               in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End", selection: $editEnd,
                               in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                }
                if let validation = intervalValidation(start: editStart, end: editEnd) {
                    Section {
                        Label(validation, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(StrandPalette.statusCritical)
                    }
                }
                Section {
                    Button {
                        guard log.update(id: event.id, label: editName, note: editNote,
                                         start: editStart, end: editEnd) else { return }
                        exportURL = nil
                        editingEvent = nil
                    } label: {
                        Text("Save changes")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed(editName).isEmpty || intervalValidation(start: editStart, end: editEnd) != nil)

                    Button("Delete event", role: .destructive) {
                        editingEvent = nil
                        pendingDelete = event
                    }
                }
            }
            .navigationTitle("Edit event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editingEvent = nil }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: dynamicTypeSize.isAccessibilitySize)
        #endif
    }

    private func start(label: String, note: String?) {
        log.start(label: label, note: note, deviceId: currentDeviceId)
        activeNote = log.active?.note ?? ""
        exportURL = nil
    }

    private var currentDeviceId: String {
        ble.deviceId.isEmpty ? CloudPushSettings.sourceId() : ble.deviceId
    }

    private func preparePastEvent() {
        let now = Date()
        pastName = log.eventLabels.first ?? ""
        pastNote = ""
        pastStart = now.addingTimeInterval(-15 * 60)
        pastEnd = now
        rememberPastLabel = true
        showingPastEvent = true
    }

    private func beginEditing(_ event: ExperimentEvent) {
        editName = event.label
        editNote = event.note ?? ""
        editStart = Date(timeIntervalSince1970: event.startUnixSeconds)
        editEnd = Date(timeIntervalSince1970: event.endUnixSeconds ?? event.startUnixSeconds)
        editingEvent = event
    }

    private func intervalValidation(start: Date, end: Date) -> String? {
        if end < start { return "End time must be after the start time." }
        if end > Date().addingTimeInterval(60) { return "Past events cannot end in the future." }
        return nil
    }

    private func openRequestedDemoSheet() {
        #if DEBUG
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--demo-event-recorder-sheet"),
              index + 1 < args.count else { return }
        switch args[index + 1].lowercased() {
        case "past": preparePastEvent()
        case "manage": showingEventTypeManager = true
        default: break
        }
        #endif
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

    private func recentTiming(_ event: ExperimentEvent) -> String {
        let start = Date(timeIntervalSince1970: event.startUnixSeconds)
        let duration = event.endUnixSeconds.map { max(0, $0 - event.startUnixSeconds) } ?? 0
        return "\(start.formatted(date: .omitted, time: .shortened)) · \(compactDuration(duration))"
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
