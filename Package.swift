// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vocca",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VoccaCore", targets: ["VoccaCore"]),
        .library(name: "VoccaAudio", targets: ["VoccaAudio"]),
        .library(name: "VoccaHotkey", targets: ["VoccaHotkey"]),
        .library(name: "VoccaASR", targets: ["VoccaASR"]),
        .library(name: "VoccaText", targets: ["VoccaText"]),
        .library(name: "VoccaInject", targets: ["VoccaInject"]),
        .library(name: "VoccaSpeech", targets: ["VoccaSpeech"]),
        .library(name: "VoccaUI", targets: ["VoccaUI"]),
        // Not part of Vocca's API. Declared only because a `dyld` interposition shim must be a
        // dynamic library, and SwiftPM builds a C target as one only when a product says so.
        .library(
            name: "VoccaNetworkInterposer", type: .dynamic, targets: ["CVoccaNetworkInterposer"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "VoccaCore",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "VoccaAudio",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "VoccaHotkey",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "VoccaASR",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "VoccaText",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "VoccaInject",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "VoccaSpeech",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "VoccaUI",
            dependencies: ["VoccaCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Test-only fixtures for the zero-network invariant. Neither is a package product:
        // they ship nothing, and are built only because HarnessTests depends on the probe and
        // the shim is a dynamic library product SwiftPM builds alongside the tests.
        //
        // The shim is loaded into the probe with DYLD_INSERT_LIBRARIES rather than linked, so
        // nothing declares a dependency on it. See Tests/HarnessTests/NetworkInterposer.swift.
        .target(
            name: "CVoccaNetworkInterposer"
        ),
        .executableTarget(
            name: "VoccaNetworkProbe",
            dependencies: [
                "VoccaCore", "VoccaAudio", "VoccaHotkey", "VoccaASR",
                "VoccaText", "VoccaInject", "VoccaSpeech", "VoccaUI",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HarnessTests",
            // Depending on the probe is what makes `swift test` build it. Without this the
            // binary only appears after a separate `swift build`, and the zero-network tests
            // would fail on a clean checkout.
            dependencies: ["VoccaNetworkProbe"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
