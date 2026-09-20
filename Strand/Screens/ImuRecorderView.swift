import SwiftUI
import StrandDesign

/// Developer Options → "Record 100 Hz IMU locally" detail screen: live state, honest coverage,
/// storage/retention, export, and delete. The switch itself also sits inline on the Test Centre
/// Developer Options card (`ImuRecorderCard`); this screen is where the recording is inspected.
///
/// Everything shown here comes from `ImuContinuousRecorder`'s published status/coverage — a
/// command acknowledgment is never presented as recording, and uncovered seconds are shown as
/// gaps, never smoothed over.
struct ImuRecorderView: View {
    @ObservedObject var recorder: ImuContinuousRecorder

    @State private var exporting = false
    @State private var confirmDeleteAll = false

    var body: some View {
        ScreenScaffold(
            title: "IMU Recorder",
            subtitle: "Live-only 100 Hz motion recording on this device."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                switchCard
                coverageCard
                storageCard
                privacyCard
            }
        }
        .task {
            // Coverage walks the timestamp indexes, so it refreshes on this screen's own cadence
            // rather than the recorder's 2 s tick — and only while the screen is alive.
            while !Task.isCancelled {
                recorder.refreshCoverage()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .confirmationDialog("Delete all IMU data?", isPresented: $confirmDeleteAll,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { _ = recorder.deleteAll() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All continuously recorded 100 Hz data on this device will be deleted permanently.")
        }
    }

    // MARK: - Switch + state

    private var switchCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Toggle(isOn: Binding(
                    get: { recorder.status.enabled },
                    set: { recorder.setEnabled($0) }
                )) {
                    Text("Record 100 Hz IMU locally").font(StrandFont.body)
                }
                .toggleStyle(.switch).tint(StrandPalette.accent)
                Text("Record live 100 Hz six-axis motion until you turn this off. Disconnect gaps remain gaps: historical packets are excluded. Enabled by default for the enrolled research strap; your saved switch setting is preserved.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(StrandPalette.hairline)
                Text(Self.phaseText(recorder.status))
                    .font(StrandFont.subhead)
                    .foregroundStyle(Self.phaseTone(recorder.status))
                if let last = recorder.status.lastLivePacketAt {
                    Text("Last packet: \(last.formatted(date: .omitted, time: .standard))")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    Text("No packets observed yet")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                if let since = recorder.status.recordingSince, recorder.status.enabled {
                    Text("Recording since \(since.formatted(date: .abbreviated, time: .shortened))")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                if recorder.status.strayPacketsWhileOff, !recorder.status.enabled {
                    Text("100 Hz packets are arriving while off — another client may have armed the strap")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if recorder.status.lowDiskPaused {
                    Text("Writes paused — free disk space is low")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.statusCritical)
                }
            }
        }
    }

    // MARK: - Coverage

    private var coverageCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Coverage").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text("Covered \(recorder.coverage.coveredSeconds) of \(recorder.coverage.expectedSeconds) seconds")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text("Gaps: \(recorder.coverage.gapCount)")
                    .font(StrandFont.subhead)
                    .foregroundStyle(recorder.coverage.gapCount == 0
                                     ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                if let gap = recorder.coverage.firstGap {
                    Text("First gap: \(Self.timeRange(from: gap.start, to: gap.end))")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Text("Gaps are real: no samples are invented. Disconnects, background limits, and strap-side drops all show up here.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Storage

    private var storageCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Storage").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text("Disk use: \(ByteCountFormatter.string(fromByteCount: recorder.coverage.diskBytes, countStyle: .file))")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Picker("Retention limit", selection: Binding(
                    get: { recorder.status.retentionCapBytes },
                    set: { recorder.setRetentionCap($0) }
                )) {
                    ForEach(ImuContinuousRecorder.capOptionsBytes, id: \.self) { cap in
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: cap, countStyle: .memory))
                            .tag(cap)
                    }
                }
                Text("Oldest segments are evicted first when the limit is reached; the segment being written is never evicted. Evicted seconds stay evicted — late history cannot bring them back.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Evicted segments: \(recorder.status.evictedSegments) · Conflicts: \(recorder.status.conflicts) · Duplicates skipped: \(recorder.status.duplicatesSkipped)")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Text("100 Hz recording drains the strap battery roughly 1.5–2.3× faster than normal wear (measured on a WHOOP 5.0).")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                NoopButton(exporting ? "Building export…" : "Export recording",
                           systemImage: "square.and.arrow.up", kind: .secondary, fullWidth: true) {
                    Task { await export() }
                }
                .disabled(exporting)
                NoopButton("Delete all recorded data", systemImage: "trash", kind: .destructive,
                           fullWidth: true) { confirmDeleteAll = true }
                    .disabled(recorder.status.enabled)
                if recorder.status.enabled {
                    Text("Turn recording off before deleting.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    // MARK: - Privacy

    private var privacyCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Privacy").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text("This 100 Hz data stays on this device. It is never included in cloud push — exporting is the only way it leaves, and only when you choose it.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions + formatting

    private func export() async {
        exporting = true
        let entries = recorder.exportEntries()
        _ = await FileExport.exportBundle(
            entries: entries,
            suggestedName: FileExport.timestampedName("noop-imu-continuous", ext: "zip"))
        exporting = false
    }

    /// The three Off distinctions the switch contract calls for — "requested off", "stop command
    /// sent", and the owed-stop-pending state — plus the On states, where a command acknowledgment
    /// alone ("startSent") is never presented as recording.
    static func phaseText(_ status: ImuContinuousRecorder.Status) -> String {
        switch status.phase {
        case .off:
            return status.strayPacketsWhileOff
                ? String(localized: "Off — but 100 Hz packets are still arriving")
                : String(localized: "Off")
        case .offStopPending:
            return String(localized: "Off — hardware stop pending until reconnection")
        case .waitingForConnection:
            return String(localized: "On — waiting for a bonded WHOOP 5/MG")
        case .startSent:
            return status.noPacketsObserved
                ? String(localized: "No 100 Hz packets observed — the strap may not be honoring the mode")
                : String(localized: "Start sent — verifying 100 Hz packets…")
        case .recording:
            return String(localized: "Recording")
        case .stopSent:
            return String(localized: "Stop command sent — waiting for packets to cease")
        }
    }

    static func phaseTone(_ status: ImuContinuousRecorder.Status) -> Color {
        switch status.phase {
        case .off: return StrandPalette.textSecondary
        case .offStopPending, .stopSent: return StrandPalette.statusWarning
        case .waitingForConnection: return StrandPalette.textSecondary
        case .startSent: return status.noPacketsObserved ? StrandPalette.statusCritical : StrandPalette.statusWarning
        case .recording: return StrandPalette.statusPositive
        }
    }

    static func timeRange(from start: Int64, to end: Int64) -> String {
        let from = Date(timeIntervalSince1970: TimeInterval(start))
        let to = Date(timeIntervalSince1970: TimeInterval(end))
        return "\(from.formatted(date: .omitted, time: .standard)) – \(to.formatted(date: .omitted, time: .standard))"
    }
}

/// The Test Centre "Developer Options" card: the Record 100 Hz IMU locally switch inline, its
/// current state, and the link to the detail screen. 5/MG-gated by the caller, like the other
/// 5/MG cards.
struct ImuRecorderCard: View {
    @ObservedObject var recorder: ImuContinuousRecorder

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("DEVELOPER OPTIONS")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Toggle(isOn: Binding(
                    get: { recorder.status.enabled },
                    set: { recorder.setEnabled($0) }
                )) {
                    Text("Record 100 Hz IMU locally").font(StrandFont.body)
                }
                .toggleStyle(.switch).tint(StrandPalette.accent)
                Text(ImuRecorderView.phaseText(recorder.status))
                    .font(StrandFont.caption)
                    .foregroundStyle(ImuRecorderView.phaseTone(recorder.status))
                NavigationLink(destination: ImuRecorderView(recorder: recorder)) {
                    Text("Recording details, export & storage")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }
}
