// swift-tools-version: 5.9
import Foundation
import PackageDescription

guard let sourceRoot = ProcessInfo.processInfo.environment["NARA_CLOUD_SOURCE_ROOT"],
      sourceRoot.hasPrefix("/") else {
    fatalError("Run this harness through Tests/CloudUploadNative/run.sh")
}

let package = Package(name: "CloudOutcomeCurrentSource", platforms: [.macOS(.v14)],
    dependencies: [.package(path: sourceRoot + "/Packages/NoopPush")],
    targets: [
        .target(name: "CloudUploadHarness", dependencies: ["NoopPush"],
            linkerSettings: [.linkedLibrary("z")]),
        .testTarget(name: "CloudUploadHarnessTests", dependencies: ["CloudUploadHarness", "NoopPush"])
    ])
