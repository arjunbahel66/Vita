// swift-tools-version: 6.1
import PackageDescription

// VitaCore holds the logic that has no UI and no iOS-specific dependencies:
// ingestion, computation, and the safety boundary around the LLM.
// It builds for macOS so `swift test` runs without a simulator or a device.
// See CLAUDE.md section 3.
let package = Package(
    name: "VitaCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "VitaCore", targets: ["VitaCore"]),
    ],
    targets: [
        .target(name: "VitaCore"),
        .testTarget(name: "VitaCoreTests", dependencies: ["VitaCore"]),
    ]
)
