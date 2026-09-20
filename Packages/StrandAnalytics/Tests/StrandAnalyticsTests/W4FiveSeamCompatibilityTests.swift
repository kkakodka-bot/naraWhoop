import Foundation
import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

enum W4FiveSeamFixtures {
    static func epoch(_ text: String) -> Int {
        Int(ISO8601DateFormatter().date(from: text)!.timeIntervalSince1970)
    }
    static func zone(_ name: String) -> TimeZone { TimeZone(identifier: name)! }
    static func day(_ index: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: Double(epoch("2026-01-01T00:00:00Z")))
        let d = cal.date(byAdding: .day, value: index, to: start)!
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func metric(_ index: Int, hrv: Double? = 60, rhr: Int? = 52,
                       strain: Double? = nil, resp: Double? = nil) -> DailyMetric {
        metric(day: day(index), hrv: hrv, rhr: rhr, strain: strain, resp: resp)
    }
    static func metric(day: String, hrv: Double? = 60, rhr: Int? = 52,
                       strain: Double? = nil, resp: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
            lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil,
            strain: strain, exerciseCount: nil, respRateBpm: resp)
    }
    static func hr(_ start: Int, bpm: Int = 65, count: Int = 300) -> [HRSample] {
        (0..<count).map { HRSample(ts: start + $0, bpm: bpm) }
    }
    static func rr(_ start: Int, count: Int = 120) -> [RRInterval] {
        (0..<count).map { RRInterval(ts: start + $0 / 2, rrMs: 800 + ($0 % 3) * 20, ord: $0 % 2) }
    }
}

final class W4FiveSeamCompatibilityTests: XCTestCase {
    func testThirteenLiveV2DTOsStillMatchImmutableFullCaseBytes() async throws {
        typealias C = WholeDaySwiftV2Corpus
        typealias E = WholeDaySwiftParityExporter
        let manifestBytes = try Data(contentsOf: C.directory.appendingPathComponent("manifest.json"))
        XCTAssertEqual(E.digest(manifestBytes), "a12ec687e5d075c52825c1fb45b8680d239059b403a756d81940d330b9ae5b86")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any])
        let entries = try XCTUnwrap(manifest["cases"] as? [[String: Any]])
        let recipes = try C.recipes()
        XCTAssertEqual(entries.count, 13)
        XCTAssertEqual(entries.compactMap { $0["id"] as? String }, recipes.map(\.id))
        for recipe in recipes {
            let entry = try XCTUnwrap(entries.first { $0["id"] as? String == recipe.id })
            let bytes = try Data(contentsOf: C.directory.appendingPathComponent("\(recipe.id).json"))
            XCTAssertEqual(E.digest(bytes), entry["sha256"] as? String)
            let current = try E.bytes(await E.export(recipe))
            XCTAssertEqual(E.digest(current), E.digest(bytes), "full default DTO drift: \(recipe.id)")
            print("FIVE_SEAM_DEFAULT_V2 \(recipe.id) sha256=\(E.digest(current))")
        }
        // This tests live behavior against historical bytes, not current-source provenance.
        XCTAssertEqual(try Data(contentsOf: C.directory.appendingPathComponent("manifest.json")), manifestBytes)
    }

    func testNilDefaultsAndConstantZoneRemainExact() {
        let start = W4FiveSeamFixtures.epoch("2026-06-15T08:00:00Z")
        let hr = W4FiveSeamFixtures.hr(start), rr = W4FiveSeamFixtures.rr(start)
        let old = DaytimeStress.analyze(hr: hr, rr: rr)
        XCTAssertEqual(old, DaytimeStress.analyze(hr: hr, rr: rr, timezone: nil))
        XCTAssertEqual(old, DaytimeStress.analyze(hr: hr, rr: rr, timezone: .init(secondsFromGMT: 0)!))
        let legacy = DaytimeStress.DaytimeDayStreams(hr: hr, rr: rr, tzOffsetSeconds: 0)
        XCTAssertEqual(legacy, .init(hr: hr, rr: rr, tzOffsetSeconds: 0, timezone: nil))
        let a = DaytimeStress.dayDaytimeAggregate(hr: hr, rr: rr, tzOffsetSeconds: 0)
        let b = DaytimeStress.dayDaytimeAggregate(hr: hr, rr: rr, tzOffsetSeconds: 0, timezone: nil)
        XCTAssertEqual(a.hr, b.hr); XCTAssertEqual(a.rmssd, b.rmssd)
    }
}
