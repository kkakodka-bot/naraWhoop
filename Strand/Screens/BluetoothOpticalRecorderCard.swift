import SwiftUI
import StrandDesign

struct BluetoothOpticalRecorderCard: View {
    @ObservedObject var recorder: BluetoothOpticalRecorder

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Toggle("Collect raw optical over Bluetooth", isOn: Binding(
                    get: { recorder.status.enabled }, set: { recorder.setEnabled($0) }))
                    .disabled(recorder.deviceId.isEmpty)
                Text("Target: 100 Hz · actual rate unverified")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.statusWarning)
                Text(recorder.status.requestSent ? "Optical enable requested on this connection" : "Waiting for the selected WHOOP")
                    .font(StrandFont.caption)
                if let code = recorder.status.responseCode, code != 1 {
                    Text("Strap did not confirm optical enable (response \(code))")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                }
                Text("Saved this connection: \(recorder.status.historyFrames) optical history packets · \(recorder.status.liveCandidateFrames) undecoded live raw packets")
                    .font(StrandFont.caption)
                if !recorder.status.lastSampleCounts.isEmpty {
                    Text("Native samples per slot: \(recorder.status.lastSampleCounts.map(String.init).joined(separator: ", "))")
                        .font(StrandFont.caption)
                }
                if let error = recorder.status.error {
                    Text(error).font(StrandFont.caption).foregroundStyle(StrandPalette.statusCritical)
                }
                Text("Optical packets and normal chunk history are saved on this phone. Channel counts are kept separate; no samples are invented. IMU records only live packets. Optical files remain local and are not automatically deleted or uploaded.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}
