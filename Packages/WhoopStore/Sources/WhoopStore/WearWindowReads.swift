import Foundation
import GRDB
import WhoopProtocol

extension WhoopStore {
    /// A narrow wear-event read, including the last state preceding the window. Dense unrelated
    /// contact/diagnostic events cannot exhaust a generic event limit and hide a later wrist-off.
    public func wearEventsForWindow(deviceId: String, from: Int, to: Int) async throws -> [WhoopEvent] {
        try syncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT ts, kind FROM event
                WHERE deviceId = ? AND (kind LIKE 'WRIST_OFF%' OR kind LIKE 'WRIST_ON%')
                  AND ts <= ? AND (ts >= ? OR ts = (
                    SELECT MAX(ts) FROM event WHERE deviceId = ? AND ts < ?
                    AND (kind LIKE 'WRIST_OFF%' OR kind LIKE 'WRIST_ON%')))
                ORDER BY ts, kind
                """, arguments: [deviceId, to, from, deviceId, from])
            return rows.map { WhoopEvent(ts: $0["ts"], kind: $0["kind"], payload: [:]) }
        }
    }
}
