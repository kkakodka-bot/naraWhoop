import Foundation

/// A sleep correction is an input, never a locally restaged replacement for a server result.
struct ServerSleepInput: Equatable, Sendable {
    enum Failure: Error { case unavailableContract, ambiguousSession, invalidWindow }
    let device: String
    let day: String
    let entity: String
    let originalStart: Int
    let originalEnd: Int
    let start: Int
    let end: Int
    let isNap: Bool
    let timezone: String

    func change(start: Int? = nil, end: Int? = nil, dismissed: Bool = false) throws -> ScoringInputChange {
        let lo = start ?? self.start, hi = end ?? self.end
        guard let zone = TimeZone(identifier: timezone), UUID(uuidString: device) != nil, entity.hasPrefix("sleep:"),
              UUID(uuidString: String(entity.dropFirst(6))) != nil,
              originalStart > 0, originalEnd > originalStart, originalEnd <= 7_289_654_400,
              lo > 0, hi > lo, hi <= 7_289_654_400, hi - lo <= 172800 else { throw Failure.invalidWindow }
        let payload: [String: Any] = ["schemaVersion": 1, "originalStart": originalStart,
            "originalEnd": originalEnd, "start": lo, "end": hi, "isNap": isNap, "dismissed": dismissed]
        // Moving a wake time across midnight must invalidate both days. The snapshot's
        // timezone, not the phone's current timezone, defines the original result's day.
        let wakeDays = [originalEnd, self.end, hi].map {
            ServerScoreDate.day(Date(timeIntervalSince1970: Double($0)), timeZone: zone)
        }
        let affectedDay = ([day] + wakeDays).min() ?? day
        return try ScoringInputChange(device: device, kind: .sleepEdit, entity: entity,
            effectiveDay: affectedDay, payload: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
    }

    static func resolve(start: Int, end: Int, state: ServerScoreViewState) throws -> Self {
        var matches: [String: Self] = [:]
        for day in state.days.keys.sorted() {
            guard let snapshot = state.days[day]?.snapshot else { continue }
            for sleep in snapshot.sleep where (sleep.start == start || sleep.originalStart == start) && sleep.end == end {
                guard let originalStart = sleep.originalStart, let originalEnd = sleep.originalEnd,
                      let entity = sleep.editEntity else { throw Failure.unavailableContract }
                let candidate = Self(device: snapshot.sourceDeviceId, day: snapshot.day, entity: entity,
                    originalStart: originalStart, originalEnd: originalEnd,
                    start: sleep.start, end: sleep.end, isNap: sleep.isNap, timezone: snapshot.timezone)
                let key = snapshot.sourceDeviceId + ":" + entity
                if let previous = matches[key], previous != candidate {
                    // Conflicting cached snapshots are not authority to guess which edit target
                    // the user meant. Refresh first; never let dictionary order select a device.
                    throw Failure.ambiguousSession
                }
                matches[key] = candidate
            }
        }
        guard matches.count == 1, let match = matches.values.first else { throw Failure.ambiguousSession }
        return match
    }
}
