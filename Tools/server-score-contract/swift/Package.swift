// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ServerScoreContract",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../../Packages/WhoopStore")],
    targets: [.executableTarget(name: "DecodeContract", dependencies: ["WhoopStore"])]
)
