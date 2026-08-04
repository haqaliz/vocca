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
        // The app's composition root. It is a package module rather than a file in the Xcode app
        // target so that VoccaNetworkProbe can drive it: sources under App/ are outside the
        // package and therefore outside the zero-network invariant.
        .library(name: "VoccaBootstrap", targets: ["VoccaBootstrap"]),
        // Test fixture, not API. The underscore is the Swift convention for "no source
        // stability, do not depend on this"; it is the strongest signal available, because
        // SwiftPM has no notion of an internal product and every product is visible to
        // consumers. It cannot simply be dropped: a `dyld` interposition shim must be a dynamic
        // library, SwiftPM builds a C target as one only when a product says so, and both
        // alternatives were measured and do not work — `dyld` ignores interpose tuples in a
        // `dlopen`ed test bundle and in the main executable alike.
        .library(
            name: "_VoccaNetworkInterposerTestFixture", type: .dynamic,
            targets: ["CVoccaNetworkInterposer"]),
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
        .target(
            name: "VoccaBootstrap",
            dependencies: [],
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
                "VoccaBootstrap",
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
