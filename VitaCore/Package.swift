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
        // macOS 14 to match mlx-swift-lm, which the app target also links.
        // VitaCore itself needs nothing newer than 13; this only keeps the
        // package graph consistent. Tests run on the Mac, which is on 15.6.
        .macOS(.v14),
    ],
    products: [
        .library(name: "VitaCore", targets: ["VitaCore"]),
    ],
    targets: [
        .target(name: "VitaCore"),
        .testTarget(name: "VitaCoreTests", dependencies: ["VitaCore"]),
    ]
)
