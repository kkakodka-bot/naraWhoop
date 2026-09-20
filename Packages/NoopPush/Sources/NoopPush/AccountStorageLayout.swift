import Foundation

/// An immutable location captured before asynchronous work starts. Legacy unowned files are separate.
public struct AccountStorageLayout: Equatable, Sendable {
    public let scope: AccountScope?
    public let directory: URL

    public init(baseDirectory: URL, scope: AccountScope?) {
        self.scope = scope
        self.directory = baseDirectory
            .appendingPathComponent("accounts-v1", isDirectory: true)
            .appendingPathComponent(scope?.namespace ?? "unassigned", isDirectory: true)
    }

    public var databaseURL: URL { directory.appendingPathComponent("whoop.sqlite") }
    public var uploadDirectory: URL { directory.appendingPathComponent("uploads", isDirectory: true) }
    public var imuDirectory: URL { directory.appendingPathComponent("imu", isDirectory: true) }
    public var quarantineDirectory: URL { directory.appendingPathComponent("quarantine", isDirectory: true) }
    public var preferencesSuite: String { "com.frwhoop.account." + (scope?.namespace ?? "signed-out") }

    /// Must run on the storage worker, before SQLite or any payload file is opened.
    public func prepare(fileManager: FileManager = .default) throws {
        for path in [directory, uploadDirectory, imuDirectory, quarantineDirectory] {
            try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
            #if os(iOS)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: path.path
            )
            #endif
        }
        #if os(iOS)
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            if fileManager.fileExists(atPath: path) {
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: path
                )
            }
        }
        #endif
    }
}
