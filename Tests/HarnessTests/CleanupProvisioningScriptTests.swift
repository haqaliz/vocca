// Copyright 2026 The Vocca Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import XCTest

/// The provisioning script's contract (`plan_20260815.md` §2.2, Phase 5): 
/// `Scripts/provision-cleanup-fixtures.sh` turns checked-in goldens (one golden per pair — the
/// golden IS the clean text) into the corpus's `.raw.txt` / `.clean.txt` / `.class.txt` triples
/// with deterministic ASR-ish error injection — and the planted raw-preferred pair with no
/// injection at all (`raw == clean`), the can-lose proof.
///
/// The script is driven the way `ProvisioningScriptTests` drives `provision-asr-fixtures.sh`: a
/// `Process` spawning `/bin/bash` with the script's own path over scratch directories — never a
/// copy of the script's logic. Two runs over identical goldens must produce byte-identical
/// output, and a goldens tree the script cannot classify must fail loudly rather than emit a
/// half-understood corpus.
///
/// Nothing here touches the repo's own corpus: every run is rooted in a fresh temporary
/// directory, and a test that wrote into `Tests/CleanupPairs/` would be a test that destroys
/// checked-in data.
final class CleanupProvisioningScriptTests: XCTestCase {

    private var scratchRoots: [URL] = []

    override func tearDown() {
        for root in scratchRoots {
            try? FileManager.default.removeItem(at: root)
        }
        scratchRoots = []
        super.tearDown()
    }

    private struct ScriptResult {
        let status: Int32
        let output: String
    }

    /// The script under test, located the way every suite in `HarnessTests` locates the package:
    /// walking up from this file to `Package.swift`, never a hardcoded path.
    private var scriptURL: URL {
        get throws {
            try PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Scripts/provision-cleanup-fixtures.sh")
        }
    }

    /// A fresh temporary directory for this test's goldens and output; torn down with the rest
    /// of the scratch roots.
    private func makeScratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-cleanup-provision-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scratchRoots.append(root)
        return root
    }

    /// Runs the script with `/bin/bash` and returns its exit status and combined output.
    private func runScript(arguments: [String]) throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [try scriptURL.path] + arguments
        process.currentDirectoryURL = try PackageRootLocator.find(from: #filePath)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ScriptResult(
            status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// One golden file for class `className`, written as `<goldens>/<className>/<name>.txt`.
    private func writeGolden(
        _ name: String, _ text: String, className: CleanupPairClass, in goldens: URL
    ) throws {
        let classDir = goldens.appendingPathComponent(className.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: classDir, withIntermediateDirectories: true)
        try Data(text.utf8).write(
            to: classDir.appendingPathComponent("\(name).txt"))
    }

    /// A full scratch goldens tree: four goldens per class (24 total, the shipped corpus's
    /// shape) — three plain numbers-units goldens plus the planted pair, which the script must
    /// emit with no injection at all.
    private func writeGoldensTree(in goldens: URL) throws {
        let classTexts: [CleanupPairClass: [String]] = [
            .fillers: [
                "I think we should meet tomorrow morning.",
                "The report is ready for your review now.",
                "We need to discuss the new feature today.",
                "She said the meeting was moved to noon.",
            ],
            .punctuation: [
                "Please send the invoice today",
                "The deadline is Friday",
                "Call me when you arrive",
                "The file has been uploaded",
            ],
            .capitalization: [
                "the quarterly review is on tuesday",
                "my new macbook arrived yesterday",
                "we use the google calendar at work",
                "the ceo will speak at the summit",
            ],
            .numbersUnits: [
                "Twelve people came to the meeting.",
                "The package weighs 3 kg and costs 15 dollars.",
                "We raised 2 million dollars for the fund.",
                "The building is 42 meters tall.",
            ],
            .dictionary: [
                "I use kawa for voice dictation daily.",
                "The mcp server handles the tools.",
                "Kawa is my favourite application.",
                "Set up the mcp server before noon.",
            ],
            .tokenProtection: [
                "Update the app to version 2.4.1 today.",
                "Email the build to aliz@vocca.dev.",
                "The API path is /api/v1/users/list.",
                "The branch name is feature-cleanup-rules.",
            ],
        ]
        for (className, texts) in classTexts {
            for (index, text) in texts.enumerated() {
                try writeGolden(
                    "\(className.rawValue)-\(String(format: "%02d", index + 1))",
                    text, className: className, in: goldens)
            }
        }
        try writeGolden(
            "numbers-units-planted-raw-preferred",
            "Twelve people came to the meeting.", className: .numbersUnits, in: goldens)
    }

    /// Reads a generated triple's side out of the output directory.
    private func readSide(
        _ name: String, suffix: String, in output: URL
    ) throws -> String {
        try String(
            contentsOf: output.appendingPathComponent("\(name).\(suffix)"), encoding: .utf8)
    }

    // MARK: - The generation contract

    /// The acceptance shape of `plan_20260815.md` §2.2-2.3: four goldens per class become
    /// exactly 24 triples (the planted pair included), each with its class tag, the clean side
    /// byte-equal to its golden, and a non-planted raw side that differs from the clean side
    /// (the injection actually happened). Two runs over the same goldens into two output
    /// directories must be byte-identical — the corpus is deterministic by construction.
    func testTheScriptGeneratesPairsDeterministicallyOverScratchGoldens() throws {
        let scratch = try makeScratchRoot()
        let goldens = scratch.appendingPathComponent("goldens", isDirectory: true)
        try writeGoldensTree(in: goldens)

        let outputA = scratch.appendingPathComponent("output-a", isDirectory: true)
        let outputB = scratch.appendingPathComponent("output-b", isDirectory: true)
        let arguments = [
            "--goldens", goldens.path,
            "--seed", "0x5EED_C0DE",
        ]
        let firstRun = try runScript(arguments: arguments + ["--output", outputA.path])
        XCTAssertEqual(firstRun.status, 0, "the script must succeed: \(firstRun.output)")
        let secondRun = try runScript(arguments: arguments + ["--output", outputB.path])
        XCTAssertEqual(secondRun.status, 0, "the script must succeed: \(secondRun.output)")

        let rawFilesA = try FileManager.default.contentsOfDirectory(
            at: outputA, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix(".raw.txt") }
            .sorted()
        XCTAssertEqual(
            rawFilesA.count, 24,
            "four goldens per class × six classes must produce 24 pairs, got: \(rawFilesA)")

        for name in rawFilesA.map({ String($0.dropLast(".raw.txt".count)) }) {
            XCTAssertEqual(
                try readSide(name, suffix: "clean.txt", in: outputA),
                try readSide(name, suffix: "clean.txt", in: outputB),
                "\(name): clean side must be byte-identical across runs")
            XCTAssertEqual(
                try readSide(name, suffix: "raw.txt", in: outputA),
                try readSide(name, suffix: "raw.txt", in: outputB),
                "\(name): raw side must be byte-identical across runs")
            XCTAssertEqual(
                try readSide(name, suffix: "class.txt", in: outputA),
                try readSide(name, suffix: "class.txt", in: outputB),
                "\(name): class tag must be byte-identical across runs")
        }

        let classTags = Set(rawFilesA.map {
            (try? readSide(
                String($0.dropLast(".raw.txt".count)), suffix: "class.txt", in: outputA)) ?? ""
        })
        XCTAssertEqual(
            classTags, Set(CleanupPairClass.allCases.map(\.rawValue)),
            "every class tag must be present in the generated corpus")

        let goldenClean = try readSide(
            "fillers-01", suffix: "clean.txt", in: outputA)
        XCTAssertEqual(
            goldenClean, "I think we should meet tomorrow morning.",
            "the clean side must be the golden, byte for byte")
        XCTAssertNotEqual(
            try readSide("fillers-01", suffix: "raw.txt", in: outputA),
            goldenClean,
            "a non-planted pair's raw side must differ from its clean side — the injection "
                + "actually happened")
    }

    /// The planted raw-preferred pair is the can-lose proof: its golden is a number-word
    /// sentence the shipped rules rewrite, and its raw side is emitted with **no injection** —
    /// `raw == clean` — so the oracle's verdict through the real engine is `rawPreferred`.
    func testThePlantedPairIsEmittedWithRawEqualToClean() throws {
        let scratch = try makeScratchRoot()
        let goldens = scratch.appendingPathComponent("goldens", isDirectory: true)
        try writeGoldensTree(in: goldens)
        let output = scratch.appendingPathComponent("output", isDirectory: true)

        let result = try runScript(arguments: [
            "--goldens", goldens.path,
            "--output", output.path,
            "--seed", "0x5EED_C0DE",
        ])
        XCTAssertEqual(result.status, 0, "the script must succeed: \(result.output)")

        let plantedName = "numbers-units-planted-raw-preferred"
        XCTAssertEqual(
            try readSide(plantedName, suffix: "raw.txt", in: output),
            "Twelve people came to the meeting.",
            "the planted pair's raw side is the golden verbatim — no injection")
        XCTAssertEqual(
            try readSide(plantedName, suffix: "raw.txt", in: output),
            try readSide(plantedName, suffix: "clean.txt", in: output),
            "the planted pair's raw must equal its clean — the scorer can lose, or it "
                + "measures nothing")
        XCTAssertEqual(
            try readSide(plantedName, suffix: "class.txt", in: output),
            "numbers-units",
            "the planted pair must carry its class tag")
    }

    // MARK: - Loud rejections

    /// A goldens tree the script cannot classify must fail loudly: an unknown class directory
    /// exits 2 naming the rejected value (a typo must not silently vanish into no class), and a
    /// goldens directory with nothing to generate exits 1 — a provisioning run that cannot
    /// produce the corpus must never read green.
    func testTheScriptRejectsAnUnknownClassDirectoryAndAnEmptyGoldensDirectory() throws {
        let scratch = try makeScratchRoot()

        let unknownGoldens = scratch.appendingPathComponent("unknown", isDirectory: true)
        let bogusDir = unknownGoldens.appendingPathComponent("bogus-class", isDirectory: true)
        try FileManager.default.createDirectory(at: bogusDir, withIntermediateDirectories: true)
        try Data("some text".utf8).write(to: bogusDir.appendingPathComponent("pair-01.txt"))
        let unknownOutput = scratch.appendingPathComponent("unknown-output", isDirectory: true)
        let unknownResult = try runScript(arguments: [
            "--goldens", unknownGoldens.path,
            "--output", unknownOutput.path,
        ])
        XCTAssertEqual(unknownResult.status, 2, "an unknown class must exit 2")
        XCTAssertTrue(
            unknownResult.output.contains("bogus-class"),
            "the rejection must name the rejected class directory, got: \(unknownResult.output)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: unknownOutput.path),
            "a rejected run must not create any output directory")

        let emptyGoldens = scratch.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyGoldens, withIntermediateDirectories: true)
        let emptyOutput = scratch.appendingPathComponent("empty-output", isDirectory: true)
        let emptyResult = try runScript(arguments: [
            "--goldens", emptyGoldens.path,
            "--output", emptyOutput.path,
        ])
        XCTAssertEqual(emptyResult.status, 1, "nothing to generate must exit 1")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: emptyOutput.path),
            "a run with nothing to generate must not create any output directory")
    }
}
