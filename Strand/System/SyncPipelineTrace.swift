import Foundation
import os

/// Instruments intervals contain only stage names and generated signpost IDs.
enum SyncPipelineTrace {
    enum Stage: String {
        case discovery, connection, bleDecode, chunkPersistence, ackWait
        case uploadPreparation, uploadScheduling, uploadReceipt
        case cacheLoad, scoreRefresh, snapshotPublication, cachedContentReady, firstUsableFrame, interaction

        fileprivate var name: StaticString {
            switch self {
            case .discovery: return "Discovery"
            case .connection: return "Connection"
            case .bleDecode: return "BLEDecode"
            case .chunkPersistence: return "ChunkPersistence"
            case .ackWait: return "ACKWait"
            case .uploadPreparation: return "UploadPreparation"
            case .uploadScheduling: return "UploadScheduling"
            case .uploadReceipt: return "UploadReceipt"
            case .cacheLoad: return "CacheLoad"
            case .scoreRefresh: return "ScoreRefresh"
            case .snapshotPublication: return "SnapshotPublication"
            case .cachedContentReady: return "CachedContentReady"
            case .firstUsableFrame: return "FirstUsableFrame"
            case .interaction: return "Interaction"
            }
        }
    }

    enum Outcome: String {
        case succeeded, failed, cancelled, pending, offline, authenticationRequired
        case waitingForWiFi, waitingForOS, waitingForServer, storageFull, stale
    }

    struct Interval {
        fileprivate let stage: Stage
        fileprivate let id: OSSignpostID
        let correlation: UUID
    }

    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.frwhoop.sync",
        category: "ProductionSync"
    )

    static func begin(_ stage: Stage, correlation: UUID = UUID()) -> Interval {
        let interval = Interval(stage: stage, id: OSSignpostID(log: log), correlation: correlation)
        os_signpost(.begin, log: log, name: stage.name, signpostID: interval.id,
                    "correlation=%{public}@", correlation.uuidString)
        return interval
    }

    static func end(_ interval: Interval, outcome: Outcome = .succeeded) {
        os_signpost(.end, log: log, name: interval.stage.name, signpostID: interval.id,
                    "correlation=%{public}@ outcome=%{public}@", interval.correlation.uuidString, outcome.rawValue)
    }

    static func event(_ stage: Stage, outcome: Outcome = .succeeded, correlation: UUID = UUID()) {
        os_signpost(.event, log: log, name: stage.name,
                    "correlation=%{public}@ outcome=%{public}@", correlation.uuidString, outcome.rawValue)
    }
}
