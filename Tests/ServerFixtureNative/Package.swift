// swift-tools-version: 5.9
import Foundation
import PackageDescription

guard let sourceRoot = ProcessInfo.processInfo.environment["NARA_SERVER_FIXTURE_SOURCE_ROOT"],
      sourceRoot.hasPrefix("/") else { fatalError("Run Tests/ServerFixtureNative/run.sh") }

let package = Package(name: "ServerFixtureCurrentSource", platforms: [.macOS(.v14)], dependencies: [
    .package(path: sourceRoot + "/Packages/NoopPush"),
    .package(path: sourceRoot + "/Packages/WhoopStore"),
    .package(path: sourceRoot + "/Packages/WhoopProtocol"),
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
], targets: [
    .target(name: "CloudUploadHarness", dependencies: ["NoopPush", "WhoopStore", "WhoopProtocol",
        .product(name: "GRDB", package: "GRDB.swift")], linkerSettings: [.linkedLibrary("z")]),
    .testTarget(name: "CloudUploadHarnessTests", dependencies: ["CloudUploadHarness", "NoopPush", "WhoopStore",
        .product(name: "GRDB", package: "GRDB.swift")]),
])
