// swift-tools-version: 5.9
import PackageDescription

// Clean-room Oura Ring BLE protocol package. Mirrors the layout of Packages/WhoopProtocol:
// a pure value-type library target (zero CoreBluetooth, headless/JVM-testable), a test target,
// and an optional oura-decode executable that replays captured raw records into decoded events.
let package = Package(
    name: "OuraProtocol",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "OuraProtocol", targets: ["OuraProtocol"]),
        .executable(name: "oura-decode", targets: ["oura-decode"]),
    ],
    dependencies: [.package(path: "../WhoopProtocol")],
    targets: [
        .target(
            name: "OuraProtocol",
            dependencies: [.product(name: "WhoopProtocol", package: "WhoopProtocol")]
        ),
        .executableTarget(
            name: "oura-decode",
            dependencies: ["OuraProtocol"]
        ),
        .testTarget(
            name: "OuraProtocolTests",
            dependencies: ["OuraProtocol"]
        ),
    ]
)
