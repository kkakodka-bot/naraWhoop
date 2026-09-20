import Foundation
import WhoopProtocol

/// Latest completed UTC five-minute measurement. Legacy coarse rows cannot prove continuity.
///
/// Swift parity twin of `android/.../analytics/CurrentHrv.kt`. Reuses `HRVAnalyzer` primitives only.
public enum CurrentHRV {

    public struct Snapshot: Equatable, Sendable {
        public let rmssdMs: Double
        public let cleanBeats: Int
        public let coverage: Double
        public let computedAtUnix: Int

        public init(rmssdMs: Double, cleanBeats: Int, coverage: Double, computedAtUnix: Int) {
            self.rmssdMs = rmssdMs
            self.cleanBeats = cleanBeats
            self.coverage = coverage
            self.computedAtUnix = computedAtUnix
        }
    }

    /// Trailing window length (seconds) for the current HRV readout.
    public static let windowSeconds = HrvWindow.seconds

    /// Rows newer than this many seconds before `nowUnix` are treated as stale by the app-layer caller.
    public static let staleThresholdSeconds = 900

    /// Exact half-open query bounds used by both the collector read and the measurement.
    public static func completedWindow(nowUnix: Int) -> Range<Int> {
        let end = HrvWindow.alignedStart(nowUnix)
        return (end - HrvWindow.seconds)..<end
    }

    /// Compatibility entry point: no beat identities or acquisition spans can be recovered from
    /// this row shape. Retains null until ingestion supplies proven observations.
    public static func derive(rows: [RRInterval], nowUnix: Int,
                              windowSeconds: Int = CurrentHRV.windowSeconds) -> Snapshot? {
        guard windowSeconds == HrvWindow.seconds else { return nil }
        return derive(observations: PhysiologyQuality.legacy(rows, deviceId: "legacy-unscoped"), nowUnix: nowUnix)
    }

    public static func derive(observations: [PhysiologyQuality.IntervalObservation], nowUnix: Int,
                              policy: HrvWindow.Policy = .init(), inputRevision: String = "unversioned") -> Snapshot? {
        let result = HrvWindow.measure(start: completedWindow(nowUnix: nowUnix).lowerBound,
            observations: observations, policy: policy, inputRevision: inputRevision, computationMode: "causal")
        guard result.measurementValid, let rmssd = result.observedRMSSD else { return nil }
        return Snapshot(rmssdMs: rmssd, cleanBeats: Int((result.validIntervalFraction * Double(result.originalIds.count)).rounded()),
            coverage: result.observedTimeFraction, computedAtUnix: nowUnix)
    }
}
