import Foundation

/// Explicit observations only. There is deliberately no journal text/custom-question inference.
enum ScoringContextInput {
    struct Flags: Equatable, Sendable {
        var alcohol: Bool?
        var stress: Bool?
        var sauna: Bool?
        var hardOrLateWorkout: Bool?
        var travelPhaseJump: Bool?
        var alreadyUnwell: Bool?

        var payload: [String: Any] {
            ["alcohol": alcohol.map { $0 as Any } ?? NSNull(),
             "stress": stress.map { $0 as Any } ?? NSNull(),
             "sauna": sauna.map { $0 as Any } ?? NSNull(),
             "hardOrLateWorkout": hardOrLateWorkout.map { $0 as Any } ?? NSNull(),
             "travelPhaseJump": travelPhaseJump.map { $0 as Any } ?? NSNull(),
             "alreadyUnwell": alreadyUnwell.map { $0 as Any } ?? NSNull()]
        }
    }

    static func context(device: String, day: String, timezone: String, flags: Flags,
                        decision: ScoringContextDecision) throws -> ScoringInputChange {
        guard decision.enabled, decision.purpose == .journal, TimeZone(identifier: timezone) != nil else {
            throw ScoringInputJournal.Failure.invalidInput
        }
        let body: [String: Any] = ["schemaVersion": 1, "day": day, "timezone": timezone,
                                  "flags": flags.payload, "consent": decision.payload]
        return try ScoringInputChange(device: device, kind: .context, entity: "context:" + day,
            effectiveDay: day, payload: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
    }

    static func periodStart(device: String, day: String, timezone: String, eventID: UUID,
                            decision: ScoringContextDecision) throws -> ScoringInputChange {
        guard decision.enabled, decision.purpose == .cycle, TimeZone(identifier: timezone) != nil else {
            throw ScoringInputJournal.Failure.invalidInput
        }
        let body: [String: Any] = ["schemaVersion": 1, "day": day, "timezone": timezone,
                                  "event": "period_start", "consent": decision.payload]
        return try ScoringInputChange(device: device, kind: .period, entity: "period:" + eventID.uuidString.lowercased(),
            effectiveDay: day, payload: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
    }
}
