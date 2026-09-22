import XCTest
import NoopPush

final class PushDaySelectorCalendarTests: XCTestCase {
    private let sourceID = "3a3486dd-5030-4e17-a00d-a781399890f9"

    func testDaySelectorsIncrementCivilLabelsIndependentlyOfProcessTimeZone() throws {
        // CI can launch this suite separately with TZ and NARA_CODEC_TEST_ZONE; no global TZ mutation.
        if let expectedZone = ProcessInfo.processInfo.environment["NARA_CODEC_TEST_ZONE"] {
            XCTAssertEqual(TimeZone.current.identifier, expectedZone)
        }
        let days = [
            ("2026-03-07", "2026-03-08"), ("2026-03-08", "2026-03-09"), ("2026-03-09", "2026-03-10"),
            ("2026-10-31", "2026-11-01"), ("2026-11-01", "2026-11-02"), ("2026-11-02", "2026-11-03"),
            ("2026-04-04", "2026-04-05"), ("2026-04-05", "2026-04-06"), ("2026-04-06", "2026-04-07"),
            ("2026-10-03", "2026-10-04"), ("2026-10-04", "2026-10-05"), ("2026-10-05", "2026-10-06"),
            ("2026-09-18", "2026-09-19"), ("2024-02-29", "2024-03-01"), ("2026-12-31", "2027-01-01")
        ]
        for (day, nextDay) in days {
            let window = try capturedWindow(day: day, zone: TimeZone.current)
            for table in [PushMutableTable.dailyMetric, .journal] {
                let batch = try XCTUnwrap(PushProtocol.mutableBatches(table: table, sourceId: sourceID,
                    deviceId: "synthetic-calendar", window: window, records: []).first)
                let selector = try selector(batch)
                XCTAssertEqual(selector["selector"] as? String, "day")
                XCTAssertEqual(selector["startInclusive"] as? String, day)
                XCTAssertEqual(selector["endExclusive"] as? String, nextDay, "\(TimeZone.current.identifier) \(day) \(table)")
                XCTAssertEqual(batch.window?.startTsInclusive, window.startTsInclusive)
                XCTAssertEqual(batch.window?.endTsExclusive, window.endTsExclusive)
                XCTAssertEqual(batch.part, 1)
                XCTAssertEqual(batch.parts, 1)
            }
        }
    }

    func testTimestampSelectorsKeepCapturedZoneSpansInsteadOfUsingUTCDays() throws {
        for (zoneName, day, duration) in [
            ("Etc/UTC", "2026-03-08", 86_400),
            ("America/Los_Angeles", "2026-03-08", 82_800),
            ("America/Los_Angeles", "2026-11-01", 90_000),
            ("Australia/Lord_Howe", "2026-04-05", 88_200),
            ("Australia/Lord_Howe", "2026-10-04", 84_600),
            ("Asia/Kathmandu", "2026-09-18", 86_400)
        ] {
            let window = try capturedWindow(day: day, zone: XCTUnwrap(TimeZone(identifier: zoneName)))
            XCTAssertEqual(window.fromDay, day)
            XCTAssertEqual(window.toDay, day)
            XCTAssertEqual(window.endTsExclusive - window.startTsInclusive, Int64(duration), zoneName)
            for table in [PushMutableTable.sleepSession, .workout] {
                let batch = try XCTUnwrap(PushProtocol.mutableBatches(table: table, sourceId: sourceID,
                    deviceId: "synthetic-calendar", window: window, records: []).first)
                let selector = try selector(batch)
                XCTAssertEqual(selector["selector"] as? String, "startTs")
                XCTAssertEqual((selector["startInclusive"] as? NSNumber)?.int64Value, window.startTsInclusive)
                XCTAssertEqual((selector["endExclusive"] as? NSNumber)?.int64Value, window.endTsExclusive)
            }
        }
    }

    private func capturedWindow(day: String, zone: TimeZone) throws -> PushWindow {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let noon = try XCTUnwrap(formatter.date(from: day + " 12:00"))
        return PushWindow.days(from: noon, to: noon, calendar: calendar)
    }

    private func selector(_ batch: PushBatch) throws -> [String: Any] {
        let newline = try XCTUnwrap(batch.body.firstIndex(of: 10))
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: batch.body[..<newline]) as? [String: Any])
        return try XCTUnwrap(header["window"] as? [String: Any])
    }
}
