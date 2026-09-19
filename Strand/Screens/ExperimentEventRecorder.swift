import SwiftUI

/// Small removable home-screen leaf; no timer, background task, or sensor commands.
struct ExperimentEventRecorder: View {
    @EnvironmentObject private var ble: BLEManager
    @ObservedObject private var log = ExperimentEventLog.shared
    @State private var selected = "Rest"
    @State private var customLabel = ""
    @State private var exportURL: URL?
    private let labels = ["Rest", "Walking", "Wrist movement", "Sleeve warming",
                          "Off wrist", "Posture change", "Mental arithmetic", "Other"]
    private var label: String { selected == "Other" ? customLabel : selected }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Event recorder", systemImage: "flag")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("TEMPORARY").font(.caption2).foregroundStyle(.secondary)
            }
            if let active = log.active {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(active.label).font(.headline)
                        Text("Started \(Date(timeIntervalSince1970: active.startUnixSeconds).formatted(date: .abbreviated, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Stop", role: .destructive) {
                        log.stop()
                        exportURL = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Stop and save event")
                }
                Text("Recording label · continues until you tap Stop, even after reopening the app.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker("Event", selection: $selected) {
                        ForEach(labels, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                    Button("Start") {
                        log.start(label: label, deviceId: ble.deviceId)
                        exportURL = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if selected == "Other" {
                    TextField("Event name", text: $customLabel).textFieldStyle(.roundedBorder)
                }
                if let last = log.events.last {
                    Text("Saved: \(last.label)").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("\(log.events.count) labels · saved on this device")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let exportURL {
                    ShareLink("Share JSON", item: exportURL).font(.caption)
                } else {
                    Button("Export") { exportURL = log.export() }
                        .font(.caption).disabled(log.events.isEmpty)
                }
            }
            if let error = log.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
