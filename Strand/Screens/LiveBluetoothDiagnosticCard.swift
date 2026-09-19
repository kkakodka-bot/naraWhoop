import SwiftUI

/// Keep the per-second clock in this leaf, not in either Today dashboard.
struct LiveBluetoothDiagnosticCard: View {
    @EnvironmentObject private var ble: BLEManager
    @EnvironmentObject private var live: LiveState
    // Preserve visibility for the current installation; an explicit Off persists across launches.
    @AppStorage(LiveBluetoothDiagnostics.visibilityKey) private var isVisible = true
    @State private var showIMU3D = false

    var body: some View {
        if isVisible {
            panel.sheet(isPresented: $showIMU3D) {
                LiveIMU3DView(model: ble.liveBluetoothDiagnostics.imuVisualization)
                    .environmentObject(live)
            }
        }
    }

    private var panel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let rows = ble.liveBluetoothDiagnostics.streams.values.sorted { $0.id < $1.id }
            let active = live.connected ? rows.filter { $0.isActive(at: context.date) }.count : 0
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Live Bluetooth", systemImage: "waveform.path")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(live.connected ? "\(active) active" : "Disconnected")
                        .font(.caption).foregroundStyle(active > 0 ? .green : .secondary)
                }
                Text("Live sensor streams · backfill shown separately below")
                    .font(.caption).foregroundStyle(.secondary)
                if rows.isEmpty {
                    Text(live.connected ? "Waiting for live sensor data…" : "Connect your WHOOP to see incoming data.")
                        .font(.subheadline)
                }
                ForEach(rows) { row in
                    let receiving = live.connected && row.isActive(at: context.date)
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(receiving ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(row.title).font(.caption.weight(.semibold))
                                if row.id == "imu" {
                                    Button { showIMU3D = true } label: {
                                        Label("3D view", systemImage: "cube.transparent")
                                    }
                                    .font(.caption).buttonStyle(.bordered)
                                    .accessibilityLabel("Open live IMU 3D visualization")
                                }
                            }
                            Text(row.detail).font(.caption).foregroundStyle(.secondary)
                            Text("\(row.packetsPerSecond(at: context.date), specifier: "%.1f") packets/s · \(row.packets) this connection")
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer(minLength: 4)
                        Text(receiving ? "Live" : "\(max(0, Int(context.date.timeIntervalSince(row.lastReceived))))s ago")
                            .font(.caption2).foregroundStyle(receiving ? .green : .secondary)
                            .monospacedDigit()
                    }
                }
                Text("Optical: no verified live stream. Historical optical is excluded from these sensor rows.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Live = received within 5s. Sensor rows exclude history and command replies.")
                    .font(.caption2).foregroundStyle(.secondary)
                Divider()
                trafficSummary(at: context.date)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("liveBluetoothDiagnostic")
        }
    }

    private func trafficSummary(at now: Date) -> some View {
        let diagnostics = ble.liveBluetoothDiagnostics
        let rates = diagnostics.trafficRates(at: now)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Backfill").font(.caption.weight(.semibold))
                Spacer()
                Text(!live.connected ? "Disconnected" : (live.backfilling ? "Syncing history" : "Idle"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(rates.chunksPerSecond, specifier: "%.2f") chunks/s · \(diagnostics.savedChunks) completed this connection")
                .font(.caption).monospacedDigit()
            if let last = diagnostics.lastSavedChunk {
                Text("Last chunk saved \(max(0, Int(now.timeIntervalSince(last))))s ago")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("Incoming Bluetooth · live + backfill")
                .font(.caption.weight(.semibold))
            Text("\(rates.bytesPerSecond / 1000, specifier: "%.2f") kB/s · \(rates.bitsPerSecond / 1000, specifier: "%.2f") kbps")
                .font(.subheadline.monospacedDigit())
            Text("10s averages. Chunks count after saving. Throughput includes all received Bluetooth payloads, including control replies; radio overhead is excluded.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
