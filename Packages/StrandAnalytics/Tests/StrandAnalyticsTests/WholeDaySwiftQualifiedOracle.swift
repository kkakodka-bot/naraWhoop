import Foundation
import XCTest
@testable import StrandAnalytics

/// Historical artifacts stay immutable. Current kernels instead match a separately reviewed complete
/// DTO receipt from the reconciled sensor-pipeline base. Only documented qualification changes are
/// allowed relative to the historical DTO; identity, selection and other values remain exact.
enum WholeDaySwiftQualifiedOracle {
    typealias E = WholeDaySwiftParityExporter
    static func assertActual(_ actual: [String: Any], id: String, version: String, historical: Data,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let path = WholeDaySwiftV2Corpus.repository.appendingPathComponent("Tests/Fixtures/qualified-physiology-base-v1.json")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual(manifest["sourceRevision"] as? String, "cfb94434b1b4ed4dba587e5c4e7af405e782e560", file: file, line: line)
        XCTAssertEqual(manifest["contract"] as? String, "qualified-physiology-base-v1", file: file, line: line)
        let versions = try XCTUnwrap(manifest["versions"] as? [String: [[String: Any]]])
        let entries = try XCTUnwrap(versions[version]); XCTAssertEqual(entries.count, 13)
        let entry = try XCTUnwrap(entries.first { $0["id"] as? String == id })
        XCTAssertEqual(E.digest(historical), entry["historicalSHA256"] as? String, id, file: file, line: line)
        XCTAssertEqual(E.digest(try E.bytes(actual)), entry["fullSHA256"] as? String, id, file: file, line: line)
        let old = try XCTUnwrap(JSONSerialization.jsonObject(with: historical) as? [String: Any])
        let expected = try XCTUnwrap(actual["expected"] as? [String: Any])
        let oldExpected = try XCTUnwrap(old["expected"] as? [String: Any])
        XCTAssertEqual(E.digest(try E.bytes(expected)), entry["expectedSHA256"] as? String, id, file: file, line: line)
        XCTAssertEqual(try E.bytes(actual["input"]!), try E.bytes(old["input"]!), "input identity \(id)", file: file, line: line)

        func equalExcept(_ current: [String: Any], _ previous: [String: Any], _ keys: Set<String>, _ label: String) throws {
            XCTAssertEqual(try E.bytes(current.filter { !keys.contains($0.key) }),
                           try E.bytes(previous.filter { !keys.contains($0.key) }), label + " " + id, file: file, line: line)
        }
        let selection = try XCTUnwrap(expected["selection"] as? [String: Any])
        let oldSelection = try XCTUnwrap(oldExpected["selection"] as? [String: Any])
        try equalExcept(selection, oldSelection, ["hrvWindows"], "selected raw identities")
        let result = try XCTUnwrap(expected["result"] as? [String: Any])
        let oldResult = try XCTUnwrap(oldExpected["result"] as? [String: Any])
        try equalExcept(result, oldResult, ["daily", "sleep", "scores"], "unaffected result fields")
        let daily = try XCTUnwrap(result["daily"] as? [String: Any])
        let oldDaily = try XCTUnwrap(oldResult["daily"] as? [String: Any])
        // Qualification removes untimed RR measurements; sleep aggregates change only with qualified
        // staging and explicit unknown intervals. No calories/strain/RHR/device/clock fields may drift.
        try equalExcept(daily, oldDaily, ["avgHrv", "avgSdnn", "deepMin", "disturbances", "efficiency",
            "lightMin", "remMin", "totalSleepMin"], "unaffected daily fields")
        XCTAssertTrue(daily["avgHrv"] is NSNull, id, file: file, line: line)
        XCTAssertTrue(daily["avgSdnn"] is NSNull, id, file: file, line: line)
        XCTAssertTrue(daily["spo2Pct"] is NSNull, id, file: file, line: line)
        try equalExcept(try XCTUnwrap(result["scores"] as? [String: Any]),
                        try XCTUnwrap(oldResult["scores"] as? [String: Any]), ["rest", "restConfidence"], "unaffected scores")
        let sleeps = try XCTUnwrap(result["sleep"] as? [[String: Any]])
        let oldSleeps = try XCTUnwrap(oldResult["sleep"] as? [[String: Any]])
        XCTAssertEqual(sleeps.count, oldSleeps.count, id, file: file, line: line)
        for (sleep, oldSleep) in zip(sleeps, oldSleeps) {
            try equalExcept(sleep, oldSleep, ["avgHRV", "efficiency", "stages"], "sleep identity and direct RHR")
            XCTAssertTrue(sleep["avgHRV"] is NSNull, id, file: file, line: line)
            if sleep["hrOnly"] as? Bool == true {
                let stages = try XCTUnwrap(sleep["stages"] as? [[String: Any]])
                XCTAssertTrue(stages.allSatisfy { $0["stage"] as? String == "unknown" }, id, file: file, line: line)
            }
        }
        for window in try XCTUnwrap(selection["hrvWindows"] as? [[String: Any]]) {
            XCTAssertTrue(window["rmssd"] is NSNull, id, file: file, line: line)
            XCTAssertEqual(window["cleanBeats"] as? Int, 0, id, file: file, line: line)
        }
    }
}
