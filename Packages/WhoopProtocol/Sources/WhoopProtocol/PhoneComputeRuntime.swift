import Foundation

/// Transport libraries also run in server/reference tools. Only the shipped application declares
/// final hosted mode; preferences, consent and network availability cannot change that declaration.
public enum PhoneComputeRuntime {
    public enum Mode: Sendable { case finalHosted, reference }
    @TaskLocal public static var testMode: Mode?
    private static let lock = NSLock()
    private static var executions: [String: Int] = [:]
    private static var denied: [String: Int] = [:]
    private static var executionTotal = 0
    private static var deniedTotal = 0
    private static var forbiddenTotal = 0
    private static var resetCount = 0
    // Random diagnostic identity, never an owner, installation or hardware identifier. Underscores
    // keep the existing peripheral-UUID redactor from erasing this process correlation token.
    private static let processGeneration = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "_")
    private static var observationStart: (wall: Double, monotonic: TimeInterval)?

    private static func observeLocked() {
        if observationStart == nil {
            observationStart = (Date().timeIntervalSince1970, ProcessInfo.processInfo.systemUptime)
        }
    }

    private static func increment(_ value: Int) -> Int { value == Int.max ? value : value + 1 }

    public static var isFinalHosted: Bool {
        if let testMode, isTestProcess { return testMode == .finalHosted }
        if isTestProcess, ProcessInfo.processInfo.environment["NOOP_COMPUTE_REFERENCE_TESTS"] == "1" { return false }
        return Bundle.main.object(forInfoDictionaryKey: "NOOPFinalHostedCompute") as? Bool == true
    }

    private static var isTestProcess: Bool {
        NSClassFromString("XCTestCase") != nil ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            CommandLine.arguments.contains { $0.hasSuffix(".xctest") }
    }

    /// An admission is not an inference execution. Missing server results never open this gate.
    public static func permitsLocal(_ producer: String) -> Bool {
        guard isFinalHosted else { return true }
        lock.lock()
        observeLocked()
        denied[producer] = increment(denied[producer, default: 0])
        deniedTotal = increment(deniedTotal)
        lock.unlock()
        return false
    }

    /// Place at the first line of numerical producers, beneath caller admission. An overlooked
    /// lifecycle, diagnostic or screen path is a test failure before numerical work can execute.
    public static func entered(_ producer: String, file: StaticString = #fileID, line: UInt = #line) {
        let finalHosted = isFinalHosted
        lock.lock()
        observeLocked()
        if finalHosted {
            forbiddenTotal = increment(forbiddenTotal)
        } else {
            executions[producer] = increment(executions[producer, default: 0])
            executionTotal = increment(executionTotal)
        }
        lock.unlock()
        precondition(!finalHosted, "Local physiology forbidden in final hosted mode: \(producer)", file: file, line: line)
    }

    public static func counters() -> (executions: [String: Int], denied: [String: Int]) {
        lock.lock(); defer { lock.unlock() }
        return (executions, denied)
    }

    /// Fixed-size, value-free evidence for the existing reviewed Test Centre bundle. This snapshot
    /// covers this runtime generation only; it cannot recover a previous process's unexported tail.
    public static func diagnosticSnapshot() -> [String: Any] {
        let finalHosted = isFinalHosted
        lock.lock(); defer { lock.unlock() }
        observeLocked()
        let start = observationStart!
        return [
            "schema_version": 1,
            "process_generation": processGeneration,
            "coverage": "current_process_only",
            "previous_process_coverage": "NOT_MEASURED",
            "first_observed_at_unix_ms": Int64(start.wall * 1000),
            "captured_at_unix_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "observation_elapsed_ms": Int64(max(0, ProcessInfo.processInfo.systemUptime - start.monotonic) * 1000),
            "final_hosted": finalHosted,
            "execution_count": executionTotal,
            "denied_admission_count": deniedTotal,
            "forbidden_attempt_count": forbiddenTotal,
            "test_counter_reset_count": resetCount,
            "test_process": isTestProcess,
            "counter_saturated": [executionTotal, deniedTotal, forbiddenTotal].contains(Int.max),
        ]
    }

    public static func resetTestCounters() {
        precondition(isTestProcess)
        lock.lock()
        executions.removeAll(); denied.removeAll()
        executionTotal = 0; deniedTotal = 0; forbiddenTotal = 0
        resetCount = increment(resetCount)
        observationStart = nil
        lock.unlock()
    }
}
