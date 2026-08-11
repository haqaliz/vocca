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

import CryptoKit
import Foundation
import VoccaASR
import XCTest

/// The provisioning script's contract (`spec.md:48-49`): `Scripts/provision-asr-fixtures.sh`
/// produces a store-shaped install **and** a manifest whose digests match the bytes actually
/// installed — without any real model artifact entering the suite.
///
/// The script is the tool that generates the committed manifests' *content* (founder-executed,
/// real downloads), so its contract is tested by driving the real script over scratch
/// directories of tiny fake files, the way ``PackageSuiteBridge`` drives the real suite: a
/// `Process` spawning `/bin/bash` with the script's own path — never a copy of the script's
/// logic. The emitted manifest is decoded through the shipped ``ModelManifest.load``, so a
/// shape the store would refuse is a shape this test refuses.
///
/// Nothing here downloads anything, and every run is rooted in a fresh temporary directory:
/// a test that wrote into the repo tree (or into a real model store) would be a test that
/// destroys data.
final class ProvisioningScriptTests: XCTestCase {

    /// The two engines the script knows, and the tier-dependent single file each whisper tier
    /// requires (`plan_20260810.md:25-29`).
    private let parakeetEngineID = "parakeet-tdt-0.6b-v3"
    private let whisperEngineID = "whisper-large-v3-turbo"
    private let whisperVersion = "1"

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
                .appendingPathComponent("Scripts/provision-asr-fixtures.sh")
        }
    }

    /// A fresh temporary directory for this test's source model files and store root; torn down
    /// with the rest of the scratch roots.
    private func makeScratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-provision-script-tests", isDirectory: true)
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

    /// The SHA-256 of a file's bytes, exactly as `shasum -a 256` (and the script's
    /// `hashlib.sha256`) computes it — SHA-256 is one function, so the three implementations
    /// agree on identical bytes, and the script's digest is verified against the same function
    /// the suite has used since the store's first manifest tests.
    private func sha256Hex(of bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// Deterministic pseudo-random bytes — "small random bytes" that a rerun can reproduce, via
    /// the suite's shared seeded generator. `2_048` is a 2 KB fake GGUF.
    private func fakeArtifactBytes(count: Int = 2_048) -> [UInt8] {
        var generator = SeededGenerator(seed: 0x5A17_CAFE_6D2E_B0F0)
        return (0..<count).map { _ in UInt8(generator.next() & 0xFF) }
    }

    /// The manifest the script must have written beside the install, decoded through the shipped
    /// loader — so the shape assertions below are the store's own shape rules.
    private func readEmittedManifest(
        in scratch: URL, engineID: String, version: String
    ) throws -> ModelManifest {
        let manifestURL = scratch
            .appendingPathComponent("root", isDirectory: true)
            .appendingPathComponent(engineID, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("manifest.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: manifestURL.path),
            "the script must emit a manifest at \(manifestURL.path)")
        return try ModelManifest.load(from: Data(contentsOf: manifestURL))
    }

    // MARK: - The whisper path: flat, single-file, no sdkDirectory

    /// The acceptance shape of `spec.md:48-49`: `--engine whisper-large-v3-turbo --tier turbo`
    /// (the default tier) installs the single GGUF **flat** — directly under the version
    /// directory, with no `sdkDirectory` — and the manifest's digest and byteCount are the real
    /// ones of the installed bytes.
    func testWhisperTurboProvisioningInstallsFlatWithADigestedManifest() throws {
        let scratch = try makeScratchRoot()
        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let fakeGGUF = fakeArtifactBytes()
        try Data(fakeGGUF).write(
            to: source.appendingPathComponent("ggml-large-v3-turbo.bin"))

        let result = try runScript(arguments: [
            "--engine", whisperEngineID,
            "--source", source.path,
            "--root", scratch.appendingPathComponent("root", isDirectory: true).path,
        ])
        XCTAssertEqual(result.status, 0, "the script must succeed: \(result.output)")

        let versionDir = scratch
            .appendingPathComponent("root", isDirectory: true)
            .appendingPathComponent(whisperEngineID, isDirectory: true)
            .appendingPathComponent(whisperVersion, isDirectory: true)
        let installed = versionDir.appendingPathComponent("ggml-large-v3-turbo.bin")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: installed.path),
            "the whisper install must land flat at <version>/ggml-large-v3-turbo.bin")
        XCTAssertEqual(try Data(contentsOf: installed), Data(fakeGGUF))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: versionDir.appendingPathComponent(ModelStore.markerFileName).path),
            "the verified marker must be written, as with every engine")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: versionDir
                    .appendingPathComponent(whisperEngineID, isDirectory: true).path),
            "the whisper layout is flat: no sdkDirectory subdirectory may be created")

        let manifest = try readEmittedManifest(
            in: scratch, engineID: whisperEngineID, version: whisperVersion)
        XCTAssertEqual(manifest.engineID, whisperEngineID)
        XCTAssertEqual(manifest.version, whisperVersion)
        XCTAssertNil(
            manifest.sdkDirectory,
            "a whisper manifest must not declare an sdkDirectory: the layout is flat")
        XCTAssertEqual(
            manifest.files.map(\.name), ["ggml-large-v3-turbo.bin"],
            "the whisper manifest must name exactly the single GGUF file")
        XCTAssertEqual(manifest.files[0].sha256, sha256Hex(of: fakeGGUF))
        XCTAssertEqual(manifest.files[0].byteCount, fakeGGUF.count)

        XCTAssertTrue(
            result.output.contains("VOCCA_MODEL_DIR=\(versionDir.path)"),
            "the script must print the VOCCA_MODEL_DIR value: \(result.output)")
    }

    /// The `--tier q5_0` mapping: the constrained tier names a different required artifact
    /// (`ggml-large-v3-turbo-q5_0.bin`), installs it flat, and the manifest names it — a wrong
    /// tier→file mapping must fail here, not on a founder's machine with a 547 MiB download.
    func testWhisperQ5TierMapsToTheQ5ArtifactName() throws {
        let scratch = try makeScratchRoot()
        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let fakeQ5 = fakeArtifactBytes()
        try Data(fakeQ5).write(
            to: source.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin"))

        let result = try runScript(arguments: [
            "--engine", whisperEngineID,
            "--tier", "q5_0",
            "--source", source.path,
            "--root", scratch.appendingPathComponent("root", isDirectory: true).path,
        ])
        XCTAssertEqual(result.status, 0, "the script must succeed: \(result.output)")

        let manifest = try readEmittedManifest(
            in: scratch, engineID: whisperEngineID, version: whisperVersion)
        XCTAssertEqual(
            manifest.files.map(\.name), ["ggml-large-v3-turbo-q5_0.bin"],
            "the q5_0 tier must require and manifest the q5_0 artifact")
        XCTAssertEqual(manifest.files[0].sha256, sha256Hex(of: fakeQ5))
        XCTAssertEqual(manifest.files[0].byteCount, fakeQ5.count)
        XCTAssertNil(manifest.sdkDirectory)
    }

    // MARK: - The parakeet path: regression, byte-identical shape

    /// The parakeet path must keep today's shape (`plan_20260810.md:37-38`) — and it must keep
    /// today's **invocation**: no `--engine` argument at all, because that is how the script has
    /// always been called and how the C2 workflow calls it still. The install lands under
    /// `<version>/<sdkDirectory>/` with nested files walked, and the manifest declares the
    /// `sdkDirectory`.
    func testParakeetDefaultEngineKeepsTheSDKShapedLayout() throws {
        let scratch = try makeScratchRoot()
        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        // A minimal parakeet-shaped source: the four .mlmodelc bundles (each holding a nested
        // file, the shape the recursive walk exists for) plus the two JSON files.
        let bundleNames = [
            "Preprocessor.mlmodelc", "Encoder.mlmodelc",
            "Decoder.mlmodelc", "JointDecisionv3.mlmodelc",
        ]
        for bundle in bundleNames {
            try FileManager.default.createDirectory(
                at: source.appendingPathComponent(bundle, isDirectory: true),
                withIntermediateDirectories: true)
            try Data("fake-mil-\(bundle)".utf8).write(
                to: source.appendingPathComponent(bundle).appendingPathComponent("model.mil"))
        }
        let config = Array(#"{"dtype":"int8"}"#.utf8)
        let vocab = Array(#"{"vocab":"fake"}"#.utf8)
        try Data(config).write(to: source.appendingPathComponent("config.json"))
        try Data(vocab).write(to: source.appendingPathComponent("parakeet_vocab.json"))

        let result = try runScript(arguments: [
            "--source", source.path,
            "--root", scratch.appendingPathComponent("root", isDirectory: true).path,
        ])
        XCTAssertEqual(result.status, 0, "the default-engine path must still work: \(result.output)")

        let versionDir = scratch
            .appendingPathComponent("root", isDirectory: true)
            .appendingPathComponent(parakeetEngineID, isDirectory: true)
            .appendingPathComponent(whisperVersion, isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: versionDir
                    .appendingPathComponent(parakeetEngineID, isDirectory: true)
                    .appendingPathComponent("config.json").path),
            "the parakeet install must land under <version>/<sdkDirectory>/")

        let manifest = try readEmittedManifest(
            in: scratch, engineID: parakeetEngineID, version: whisperVersion)
        XCTAssertEqual(manifest.engineID, parakeetEngineID)
        XCTAssertEqual(
            manifest.sdkDirectory, parakeetEngineID,
            "the parakeet manifest must declare its sdkDirectory, as today")
        XCTAssertEqual(
            manifest.files.map(\.name),
            [
                "config.json",
                "parakeet_vocab.json",
                "Decoder.mlmodelc/model.mil",
                "Encoder.mlmodelc/model.mil",
                "JointDecisionv3.mlmodelc/model.mil",
                "Preprocessor.mlmodelc/model.mil",
            ],
            "the parakeet walk must cover both JSON files and the nested bundle files, "
                + "in the walk's deterministic order (top-level files first)")
        let configEntry = manifest.files.first { $0.name == "config.json" }
        XCTAssertEqual(configEntry?.sha256, sha256Hex(of: config))
        XCTAssertEqual(configEntry?.byteCount, config.count)
    }

    // MARK: - Rejections

    /// An engine the script does not know must fail the run loudly and name the rejected value —
    /// a typo that silently provisioned the wrong engine's directory would be an install no one
    /// asked for.
    func testAnUnknownEngineIsRejectedWithTheValueNamed() throws {
        let scratch = try makeScratchRoot()
        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let result = try runScript(arguments: [
            "--engine", "nope",
            "--source", source.path,
            "--root", scratch.appendingPathComponent("root", isDirectory: true).path,
        ])
        XCTAssertNotEqual(result.status, 0, "an unknown engine must fail the run")
        XCTAssertTrue(
            result.output.contains("nope"),
            "the rejection must name the rejected engine value, got: \(result.output)")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: scratch.appendingPathComponent("root", isDirectory: true).path),
            "an unknown engine must not create any install directory")
    }

    /// A tier the script does not know (and a tier on the parakeet engine, which has no tiers)
    /// must fail the run loudly and name the rejected value.
    func testAnUnknownTierIsRejectedWithTheValueNamed() throws {
        let scratch = try makeScratchRoot()
        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let result = try runScript(arguments: [
            "--engine", whisperEngineID,
            "--tier", "bogus",
            "--source", source.path,
            "--root", scratch.appendingPathComponent("root", isDirectory: true).path,
        ])
        XCTAssertNotEqual(result.status, 0, "an unknown tier must fail the run")
        XCTAssertTrue(
            result.output.contains("bogus"),
            "the rejection must name the rejected tier value, got: \(result.output)")
    }
}
