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
        .testTarget(
            name: "HarnessTests",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
