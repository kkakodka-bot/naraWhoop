import SwiftUI
import StrandAnalytics
import StrandDesign

/// A device-scoped view of sampled HR. It does not replace the nightly resting baseline.
struct FiveMinuteHeartRateView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.scenePhase) private var scenePhase
    @State private var measurements: [HeartRateWindows.Measurement] = []
    @State private var loadedDevice: String?
    @State private var error: String?
    @State private var expanded = false
    @State private var refresh = 0

    private var requestKey: String { "\(repo.deviceId)|\(repo.refreshSeq)|\(refresh)" }
    var body: some View {
        let rows = loadedDevice == repo.deviceId ? measurements : []
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Five-minute heart rate").font(StrandFont.subhead)
                    Spacer()
                    Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh heart rate windows")
                }
                Text("Past 24 hours · this strap’s stored data")
                Text("Low-motion averages are estimates, separate from your overnight resting-heart-rate baseline.")
                if let error { Text(error) }
                Text("\(rows.filter { $0.meanBpm != nil }.count) measured windows · \(rows.filter { $0.lowMotionBpm != nil }.count) low-motion windows")
                if rows.isEmpty { Text("No completed five-minute windows available.") }
                ForEach(Array((expanded ? rows : Array(rows.suffix(12))).reversed()), id: \.start) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(time(row.start))–\(time(row.end))").monospacedDigit()
                        Text("Average: \(bpm(row.meanBpm)) · Low motion: \(bpm(row.lowMotionBpm))")
                        Text("HR samples: \(Int((row.sampleFraction * 100).rounded()))% · low-motion qualified: \(Int((row.lowMotionSampleFraction * 100).rounded()))%")
                        if let reason = row.reason ?? row.lowMotionReason { Text(reasonText(reason)) }
                    }.padding(.vertical, 3)
                }
                if rows.count > 12 { Button(expanded ? "Show latest hour" : "Show all windows") { expanded.toggle() } }
            }.font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }.task(id: "\(requestKey)|\(scenePhase)") {
            guard scenePhase == .active else { return }
            await load()
            // This task is cancelled when the card leaves the foreground view hierarchy.
            while !Task.isCancelled {
                let now = Date().timeIntervalSince1970
                let delay = 300 - now.truncatingRemainder(dividingBy: 300) + 1
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
                await load()
            }
        }
    }

    @MainActor private func load() async {
        let device = repo.deviceId
        guard let store = await repo.storeHandle() else { return }
        let end = Int(Date().timeIntervalSince1970) / 300 * 300, start = end - 86400
        do {
            async let hr = store.hrSamples(deviceId: device, from: start, to: end-1, limit: 100_000)
            async let gravity = store.gravitySamples(deviceId: device, from: start, to: end-1, limit: 100_000)
            async let events = store.wearEventsForWindow(deviceId: device, from: start, to: end-1)
            let (h, g, e) = try await (hr, gravity, events)
            let result = await Task.detached(priority: .utility) {
                HeartRateWindows.windows(start: start, end: end, hr: h, gravity: g,
                    excluded: AnalyticsEngine.offWristIntervals(events: e, windowEnd: end).map {
                        PhysiologyQuality.Span(Double($0.start), Double($0.end))
                    })
            }.value
            guard !Task.isCancelled, repo.deviceId == device else { return }
            measurements = result; loadedDevice = device; error = nil
        } catch {
            guard !Task.isCancelled, repo.deviceId == device else { return }
            measurements = []; loadedDevice = device
            self.error = "Could not read this strap’s stored heart-rate samples."
        }
    }

    private func bpm(_ value: Double?) -> String {
        value.map { String(format: "%.1f bpm", locale: .current, $0) } ?? "Unavailable"
    }
    private func time(_ timestamp: Int) -> String {
        Date(timeIntervalSince1970: Double(timestamp)).formatted(date: .abbreviated, time: .shortened)
    }
    private func reasonText(_ reason: String) -> String {
        switch reason {
        case "insufficient_hr_samples", "hr_sample_gap": return "Not enough heart-rate samples in this window."
        case "movement_detected": return "Movement detected; low-motion estimate unavailable."
        case "off_body_evidence": return "Strap-off evidence; low-motion estimate unavailable."
        default: return "Not enough matching motion samples for a low-motion estimate."
        }
    }
}
