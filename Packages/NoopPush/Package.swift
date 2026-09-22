// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoopPush",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "NoopPush", targets: ["NoopPush"])],
    targets: [
        .target(
            name: "CNoopZstd",
            exclude: ["vendor/zstd/LICENSE", "vendor/zstd/provenance.json"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("vendor/zstd/lib"),
                .define("ZSTD_DISABLE_ASM", to: "1"),
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
                .define("ZSTD_TRACE", to: "0"),
            ]
        ),
        .target(
            name: "NoopPush",
            dependencies: [
                .target(name: "CNoopZstd"),
            ],
            resources: [.copy("Resources/Zstandard-LICENSE.txt")]
        ),
        .testTarget(
            name: "NoopPushTests",
            dependencies: ["NoopPush"],
            resources: [.process("Resources")]
        ),
    ]
)
