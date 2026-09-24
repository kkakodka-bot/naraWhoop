import SwiftUI
import StrandDesign

/// Keep the per-second clock in this leaf, not in either Today dashboard.
struct LiveBluetoothDiagnosticCard: View {
    @EnvironmentObject private var ble: BLEManager
    @EnvironmentObject private var live: LiveState
    // Preserve visibility for the current installation; an explicit Off persists across launches.
    @AppStorage(LiveBluetoothDiagnostics.visibilityKey) private var isVisible = true
    @ObservedObject private var uploads = CloudUploadProgressCenter.shared
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
                Divider()
                cloudUploadSummary(at: context.date)
                }
            }
            .accessibilityIdentifier("liveBluetoothDiagnostic")
            .onAppear { uploads.refresh(minimumInterval: 30, now: context.date) }
            .onChangeCompat(of: Int(context.date.timeIntervalSince1970) / 5) { _ in
                // The card already ticks once a second; re-count the backlog every fifth tick while a
                // pass is active. Idle cards keep the last measurement instead of hammering SQLite.
                if uploads.current.isActive { uploads.refresh(minimumInterval: 4, now: context.date) }
            }
        }
    }

    private func cloudUploadSummary(at now: Date) -> some View {
        let progress = uploads.current
        return VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack {
                Text("Cloud upload").font(StrandFont.captionNumber)
                Spacer()
                if let at = progress.lastSuccessAt {
                    Text("Last pass completed \(relativeAgo(at.timeIntervalSince1970, now: now.timeIntervalSince1970))")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            CloudUploadStatusLine(progress: progress)
            if let backlog = progress.backlog {
                Text("\(backlog.uploadedRows) of \(backlog.totalRows) rows uploaded · counted \(relativeAgo(backlog.measuredAt.timeIntervalSince1970, now: now.timeIntervalSince1970))")
                    .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
            } else {
                Text("Backlog not counted yet. It is measured when the next upload pass starts.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            Text("\(progress.acceptedRecords) rows in \(progress.acceptedBatches) batches accepted this pass")
                .font(StrandFont.captionNumber)
            if let error = progress.lastError {
                Text(error).font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
            }
            Text("Rows still on this phone across the streams the receiver accepts, per paired strap. Re-counted every 5 s while a pass is active. Raw batches count until the server acknowledges them.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func trafficSummary(at now: Date) -> some View {
        let diagnostics = ble.liveBluetoothDiagnostics
        let rates = diagnostics.trafficRates(at: now)
        let mostRecentSync = [
            diagnostics.lastSavedChunk?.timeIntervalSince1970,
            live.lastSyncedAt,
        ].compactMap { $0 }.max()
        return VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack {
                Text("Backfill").font(StrandFont.captionNumber)
                Spacer()
                Text(!live.connected ? "Disconnected" : (live.backfilling ? "Syncing history" : "Idle"))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            if let mostRecentSync {
                Text("Last synced \(relativeAgo(mostRecentSync, now: now.timeIntervalSince1970))")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                Text("Last synced: never")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Text("\(diagnostics.savedChunks) chunks saved this connection · \(rates.chunksPerSecond, specifier: "%.2f") chunks/s")
                .font(StrandFont.captionNumber)
            Text("Incoming Bluetooth").font(StrandFont.captionNumber)
            throughputRow("Live", bytesPerSecond: rates.liveBytesPerSecond)
            throughputRow("Backfill", bytesPerSecond: rates.backfillBytesPerSecond)
            throughputRow("Total incoming", bytesPerSecond: rates.totalBytesPerSecond)
            Text("10s averages in kilobytes per second. Backfill is completed history frames; live is completed realtime/control traffic. Total incoming includes every raw payload, including a frame still being assembled. Radio overhead is excluded.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func throughputRow(_ title: String, bytesPerSecond: Double) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: NoopMetrics.space2)
                Text("\(bytesPerSecond / 1000, specifier: "%.2f") kB/s")
                    .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(title)
                Text("\(bytesPerSecond / 1000, specifier: "%.2f") kB/s")
                    .monospacedDigit()
            }
        }
        .font(StrandFont.bodyNumber)
    }
}
