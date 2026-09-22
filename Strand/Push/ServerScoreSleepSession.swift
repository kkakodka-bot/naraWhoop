import Foundation
import WhoopStore

/// CachedSleepSession cannot represent UUIDs, nap classification or snapshot provenance.
/// Keep the original immutable DTO alongside the compatible legacy row for export consumers.
struct ServerScoreSleepProjection: Equatable {
    let session: CachedSleepSession
    let sleep: ServerScoreSleep
    let userID: String
    let sourceDeviceID: String
    let day: String
    let timeZoneID: String
    let schemaVersion: Int
    let algorithmVersion: String
    let inputRevision: Int64
    let resultRevision: Int64
}

enum ServerScoreSleepPresentation {
    static func session(_ value: ServerScoreSleep) -> CachedSleepSession { session(value, diagnostics: nil) }

    static func session(_ value: ServerScoreSleep, diagnostics: ServerScoreSleepDiagnostics?) -> CachedSleepSession {
        CachedSleepSession(startTs: value.start, endTs: value.end, efficiency: value.efficiency,
                           restingHr: value.restingHrBpm.map { Int($0.rounded()) }, avgHrv: value.hrvRmssdMs,
                           stagesJSON: value.stagesJSON, userEdited: false,
                           startTsAdjusted: nil, stagingSparse: diagnostics?.stagingSparse)
    }

    /// Presentation replacement only: an owned missing snapshot returns no rows, never local sessions.
    /// Export deletion still requires an actual completed snapshot, not merely an empty projection.
    /// The caller must retain AccountScope.projectURL separately; it is not part of the RPC payload.
    static func projections(day: String, state: ServerScoreViewState) -> [ServerScoreSleepProjection] {
        guard let snapshot = ServerScoreDisplay.detailSnapshot(.sleepSessions, day: day, state: state) else { return [] }
        let diagnostics = ServerScoreDisplay.sleepDiagnostics(day: day, state: state)
        return snapshot.sleep.map { value in
            ServerScoreSleepProjection(session: session(value, diagnostics: diagnostics.first { $0.id == value.id }), sleep: value, userID: snapshot.userId,
                sourceDeviceID: snapshot.sourceDeviceId, day: snapshot.day, timeZoneID: snapshot.timezone,
                schemaVersion: snapshot.schemaVersion, algorithmVersion: snapshot.algorithmVersion,
                inputRevision: snapshot.inputRevision, resultRevision: snapshot.resultRevision)
        }
    }
}
