import Foundation

/// Transport libraries also run in server/reference tools. Only the shipped application declares
/// final hosted mode; preferences, consent and network availability cannot change that declaration.
public enum PhoneComputeRuntime {
    public enum Mode: Sendable { case finalHosted, reference }
    @TaskLocal public static var testMode: Mode?
    private static let lock = NSLock()
    private static var executions: [String: Int] = [:]
    private static var denied: [String: Int] = [:]

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
        lock.lock(); denied[producer, default: 0] += 1; lock.unlock()
        return false
    }

    /// Place at the first line of numerical producers, beneath caller admission. An overlooked
    /// lifecycle, diagnostic or screen path is a test failure before numerical work can execute.
    public static func entered(_ producer: String, file: StaticString = #fileID, line: UInt = #line) {
        precondition(!isFinalHosted, "Local physiology forbidden in final hosted mode: \(producer)", file: file, line: line)
        lock.lock(); executions[producer, default: 0] += 1; lock.unlock()
    }

    public static func counters() -> (executions: [String: Int], denied: [String: Int]) {
        lock.lock(); defer { lock.unlock() }
        return (executions, denied)
    }

    public static func resetTestCounters() {
        precondition(isTestProcess)
        lock.lock(); executions.removeAll(); denied.removeAll(); lock.unlock()
    }
}
