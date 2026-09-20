import Foundation
import WhoopStore

/// Maps server score cache onto Today/Sleep display fields when `serverScoring` is on.
enum ServerScoreDisplay {
    static func recovery(day: String, overlay: ServerScoreDayCache?) -> Double? {
        guard ServerScoringSettings.isEnabled, overlay?.day == day else { return nil }
        return overlay?.daily?.recovery
    }

    static func strain(day: String, overlay: ServerScoreDayCache?) -> Double? {
        guard ServerScoringSettings.isEnabled, overlay?.day == day else { return nil }
        return overlay?.daily?.strain
    }

    static func spo2(day: String, overlay: ServerScoreDayCache?) -> Double? {
        guard ServerScoringSettings.isEnabled, overlay?.day == day else { return nil }
        return overlay?.daily?.spo2Pct
    }

    static func hrvRmssd(day: String, overlay: ServerScoreDayCache?) -> Double? {
        guard ServerScoringSettings.isEnabled, overlay?.day == day, let daily = overlay?.daily else { return nil }
        return daily.hrvRmssdMs
    }

    static func restingHr(day: String, overlay: ServerScoreDayCache?) -> Int? {
        guard ServerScoringSettings.isEnabled, overlay?.day == day, let daily = overlay?.daily else { return nil }
        return daily.restingHrBpm
    }

    static func sleepTotalMin(day: String, overlay: ServerScoreDayCache?) -> Double? {
        guard ServerScoringSettings.isEnabled, overlay?.day == day, let daily = overlay?.daily else { return nil }
        return daily.sleepTotalMin
    }

    static func sleepStageMin(_ key: String, overlay: ServerScoreDayCache?) -> Double? {
        guard ServerScoringSettings.isEnabled, let daily = overlay?.daily else { return nil }
        switch key {
        case "light": return daily.sleepLightMin
        case "deep": return daily.sleepDeepMin
        case "rem": return daily.sleepRemMin
        case "awake": return daily.sleepAwakeMin
        case "sleep_unstaged": return daily.sleepUnstagedMin
        case "state_unknown": return daily.stateUnknownMin
        case "off_body": return daily.offBodyMin
        default: return nil
        }
    }

    static func staleNote(overlay: ServerScoreDayCache?) -> String? {
        guard ServerScoringSettings.isEnabled, let overlay else { return nil }
        guard overlay.stale || overlay.daily == nil else { return nil }
        if let computed = overlay.computedAt {
            return String(localized: "Server score from \(computed)")
        }
        return String(localized: "Waiting for server score")
    }
}
