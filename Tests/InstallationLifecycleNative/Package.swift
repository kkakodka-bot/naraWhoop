// swift-tools-version: 5.9
import PackageDescription
import Foundation
let root = ProcessInfo.processInfo.environment["NARA_LIFECYCLE_SOURCE_ROOT"]!
let package = Package(name: "InstallationLifecycleNative", platforms: [.macOS(.v14)],
    dependencies: [.package(path: root + "/Packages/NoopPush")], targets: [
        .target(name: "InstallationLifecycleHarness", dependencies: ["NoopPush"]),
        .testTarget(name: "InstallationLifecycleTests", dependencies: ["InstallationLifecycleHarness", "NoopPush"])
    ])
