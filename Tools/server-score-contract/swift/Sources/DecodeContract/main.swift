import Foundation
import WhoopStore

struct Expectation: Decodable {
    let file: String, ownerId: String, day: String
    let availableFeatures: [String], unavailableFeatures: [String]
    let nestedHrvAvailable: Bool, nestedRespirationAvailable: Bool
    let expectedDeviceId: String?
    let expectedValues: [String: Double]?
}

struct ContractFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ContractFailure(description: message) }
}

guard CommandLine.arguments.count == 2 else { fatalError("usage: DecodeContract FIXTURE_DIRECTORY") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let expectations = try JSONDecoder().decode([Expectation].self,
    from: Data(contentsOf: directory.appendingPathComponent("expectations.json")))
try require(!expectations.isEmpty, "No real Edge envelopes were supplied")
for expectation in expectations {
    let bytes = try Data(contentsOf: directory.appendingPathComponent(expectation.file))
    let cache = try ServerScoreCacheCodec.parseSnapshot(bytes, day: expectation.day, ownerId: expectation.ownerId)
    for key in expectation.availableFeatures {
        try require(cache.features[key]?.isCanonicalAvailable == true, "\(expectation.file): \(key) did not activate")
        if let device = expectation.expectedDeviceId {
            try require(cache.features[key]?.deviceId == device, "\(expectation.file): selected device differs")
        }
    }
    let metrics: [String: ServerVitalSelection.Metric] = ["sleep": .sleep, "hrv": .hrv, "respiration": .respiratory]
    for (key, expected) in expectation.expectedValues ?? [:] {
        guard let metric = metrics[key] else { throw ContractFailure(description: "unsupported expected metric") }
        let selection = ServerVitalSelection.resolve(metric, serverEnabled: true, selectedDay: expectation.day, overlay: cache, localValue: nil)
        try require(selection.value == expected && selection.fromServer && selection.displayDiagnostic.status == "available",
                    "\(expectation.file): selected \(key) value differs")
    }
    for key in expectation.unavailableFeatures {
        try require(cache.features[key]?.isCanonicalAvailable != true, "\(expectation.file): \(key) unexpectedly activated")
        if let metric = metrics[key] {
            let selection = ServerVitalSelection.resolve(metric, serverEnabled: true, selectedDay: expectation.day, overlay: cache, localValue: nil)
            try require(selection.value == nil && selection.displayDiagnostic.status == "unavailable", "\(expectation.file): unavailable value reached display selection")
        }
    }
    try require(cache.nights.contains { $0.hrvRmssdMs != nil } == expectation.nestedHrvAvailable,
                "\(expectation.file): embedded HRV availability differs")
    try require(cache.nights.contains { $0.respRateBpm != nil } == expectation.nestedRespirationAvailable,
                "\(expectation.file): embedded respiration availability differs")
    let root = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    let raw = root["server_scoring"] as! [String: Any]
    let nights = raw["nights"] as? [[String: Any]] ?? []
    for night in nights {
        let fields = (expectation.nestedHrvAvailable ? [] : ["hrv_rmssd_ms", "hrv_sdnn_ms", "resting_hr_bpm", "overnight_hr_bpm", "hrv_summary", "heart_rate_windows",
            "recovery", "strain", "spo2_pct", "skin_temp_c", "skin_temp_dev_c"]) +
            (expectation.nestedRespirationAvailable ? [] : ["resp_rate_bpm", "respiration_summary"])
        for field in fields {
            try require(night[field] == nil || night[field] is NSNull, "\(expectation.file): real Edge envelope leaked \(field)")
        }
    }
    print("swift \(expectation.file): decoded and display selection verified")
}
print("swift: \(expectations.count) real Edge envelopes passed")
