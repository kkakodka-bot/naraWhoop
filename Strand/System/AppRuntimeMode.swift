import Foundation

enum AppRuntimeMode {
    /// Unit-test host launches must not scan radios, open personal stores, migrate preferences,
    /// clean import files or use saved cloud credentials. Release builds cannot enable this mode.
    static var isUnitTesting: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["NOOP_HERMETIC_TESTING"] == "1"
        #else
        return false
        #endif
    }
}
