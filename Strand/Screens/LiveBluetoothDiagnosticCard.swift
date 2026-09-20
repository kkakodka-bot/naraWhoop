import SwiftUI
import StrandDesign

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
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                HStack {
                    Label("Live Bluetooth", systemImage: "waveform.path")
                        .font(StrandFont.headline)
                    Spacer()
                    Text(live.connected ? "\(active) active" : "Disconnected")
                        .font(StrandFont.caption)
                        .foregroundStyle(active > 0 ? StrandPalette.statusPositive : StrandPalette.textSecondary)
                }
                Text("Live sensor streams · backfill shown separately below")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                if rows.isEmpty {
                    Text(live.connected ? "Waiting for live sensor data…" : "Connect your WHOOP to see incoming data.")
                        .font(StrandFont.subhead)
                }
                ForEach(rows) { row in
                    let receiving = live.connected && row.isActive(at: context.date)
                    HStack(alignment: .top, spacing: NoopMetrics.space2) {
                        Circle().fill(receiving ? StrandPalette.statusPositive : StrandPalette.textTertiary)
                            .frame(width: NoopMetrics.space2, height: NoopMetrics.space2)
                            .padding(.top, NoopMetrics.space1)
                        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                            HStack(spacing: NoopMetrics.space2) {
                                Text(row.title).font(StrandFont.captionNumber)
                                if row.id == "imu" {
                                    Button { showIMU3D = true } label: {
                                        Label("3D view", systemImage: "cube.transparent")
                                    }
                                    .font(StrandFont.caption).buttonStyle(.bordered)
                                    .accessibilityLabel("Open live IMU 3D visualization")
                                }
                            }
                            Text(row.detail).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            Text("\(row.packetsPerSecond(at: context.date), specifier: "%.1f") packets/s · \(row.packets) this connection")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary).monospacedDigit()
                        }
                        Spacer(minLength: NoopMetrics.space1)
                        Text(receiving ? "Live" : "\(max(0, Int(context.date.timeIntervalSince(row.lastReceived))))s ago")
                            .font(StrandFont.footnote)
                            .foregroundStyle(receiving ? StrandPalette.statusPositive : StrandPalette.textSecondary)
                            .monospacedDigit()
                    }
                }
                Text("Optical: no verified live stream. Historical optical is excluded from these sensor rows.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Text("Live = received within 5s. Sensor rows exclude history and command replies.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                Divider()
                trafficSummary(at: context.date)
                }
            }
            .accessibilityIdentifier("liveBluetoothDiagnostic")
        }
    }

    private func trafficSummary(at now: Date) -> some View {
        let diagnostics = ble.liveBluetoothDiagnostics
        let rates = diagnostics.trafficRates(at: now)
        return VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack {
                Text("Backfill").font(StrandFont.captionNumber)
                Spacer()
                Text(!live.connected ? "Disconnected" : (live.backfilling ? "Syncing history" : "Idle"))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            Text("\(rates.chunksPerSecond, specifier: "%.2f") chunks/s · \(diagnostics.savedChunks) completed this connection")
                .font(StrandFont.captionNumber)
            if let last = diagnostics.lastSavedChunk {
                Text("Last chunk saved \(max(0, Int(now.timeIntervalSince(last))))s ago")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
            Text("Incoming Bluetooth · live + backfill")
                .font(StrandFont.captionNumber)
            Text("\(rates.bytesPerSecond / 1000, specifier: "%.2f") kB/s · \(rates.bitsPerSecond / 1000, specifier: "%.2f") kbps")
                .font(StrandFont.bodyNumber)
            Text("10s averages. Chunks count after saving. Throughput includes all received Bluetooth payloads, including control replies; radio overhead is excluded.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }
    }
}
