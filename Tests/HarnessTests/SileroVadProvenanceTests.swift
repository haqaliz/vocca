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

/// Pins the `sdk-vetting` aspect's dependency decisions as manifest facts
/// (`docs/planning/turn-taking-barge-in/sdk-vetting/plan_20260915.md`): FluidAudio must stay the
/// pinned VAD/EOU provider — the same package that already carries Parakeet — and the shipped
/// Silero VAD artifact manifest must pin the exact model the resolved SDK names
/// (`ModelNames.VAD.sileroVadFile` = `silero-vad-unified-256ms-v6.2.1.mlmodelc`, a bare
/// `.mlmodelc` DIRECTORY of five files staged from `FluidInference/silero-vad-coreml`).
///
/// The package URL is asserted against the manifest's raw text (SwiftPM encodes package-level
/// dependencies nowhere the `PackageManifest` dump helper decodes — it parses targets and
/// products only), while the target edge is asserted against `swift package dump-package` output
/// so the reading cannot drift from what SwiftPM itself believes. The VAD manifest is parsed with
/// `JSONSerialization` directly from the repo file — the `ModelManifest` decoder is
/// EngineTier-keyed and deliberately out of scope here; the file's shape is asserted as raw JSON
/// so a future SDK rename of the `.mlmodelc` turns the pin RED (the mechanism working, not a
/// defect). Everything here is headless: no model, no network.
final class SileroVadProvenanceTests: XCTestCase {

    /// The package root, located the way every suite in `HarnessTests` locates it.
    private var packageRoot: URL {
        get throws {
            try PackageRootLocator.find(from: #filePath)
        }
    }

    /// `Package.swift` read as text — the only place SwiftPM records the package-level
    /// dependency URLs, which `PackageManifest` deliberately does not decode.
    private func manifestText() throws -> String {
        try String(
            contentsOf: try packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
    }

    /// The manifest the way SwiftPM itself sees it, for the target-dependency edges.
    private func manifest() throws -> PackageManifest {
        try PackageManifest.load(packageRoot: try packageRoot)
    }

    /// The shipped Silero VAD manifest, read from the repo (not the bundle) and decoded as raw
    /// JSON. `throws` when the file is absent — which is exactly the RED this suite's manifest
    /// pin exists to close.
    private func shippedSileroManifest() throws -> [String: Any] {
        let url = try packageRoot.appendingPathComponent(
            "Sources/VoccaASR/Models/Manifests/silero-vad.json")
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SileroManifestError.malformed
        }
        return object
    }

    /// The FluidAudio package URL must be declared in `Package.swift`: the VAD/EOU pick is the
    /// Parakeet precedent — the dependency is already pinned, no new package — so a rename or a
    /// repoint of the source is a reviewed edit, not a silent drift. The range is pinned as
    /// recorded (`from: "0.12.4"` carries VAD/EOU at the resolved 0.15.7 — the vetting record).
    func testPackageDeclaresTheFluidAudioPackageURL() throws {
        let text = try manifestText()
        XCTAssertTrue(
            text.contains("https://github.com/FluidInference/FluidAudio.git"),
            """
            Package.swift must declare the FluidAudio package URL \
            (https://github.com/FluidInference/FluidAudio.git). Without the package neither the \
            Parakeet engine nor the Silero VAD adapter has anything to build on.
            """)
        XCTAssertTrue(
            text.contains(#"from: "0.12.4""#),
            """
            Package.swift must keep the recorded FluidAudio range (from: "0.12.4"). The vetting \
            gate verified the resolved 0.15.7 carries the VAD/EOU surface — a range change is a \
            reviewed dependency decision, never a silent edit.
            """)
    }

    /// The `VoccaASR` target must depend on the `FluidAudio` product — the H8b confinement,
    /// pinned as a manifest fact: `VoccaASR` is the only module that may import the SDK, and the
    /// `SileroVAD`/`ParakeetEOU` adapters will live there.
    func testVoccaASRTargetDependsOnTheFluidAudioProduct() throws {
        let target = try XCTUnwrap(
            try manifest().targets["VoccaASR"],
            "Package.swift must declare a VoccaASR target")
        XCTAssertTrue(
            target.dependencies.contains("FluidAudio"),
            """
            The VoccaASR target's dependencies must include the FluidAudio product. Declared: \
            \(target.dependencies.sorted()). The SDK's VAD/EOU surface is reachable only through \
            this module (the H8b seam lint).
            """)
    }

    /// **The RED.** The shipped Silero VAD manifest must pin the artifact the resolved SDK names:
    /// `engineID "silero-vad"`, `version "1"`, `sdkDirectory "vad"`, and the `.mlmodelc`
    /// DIRECTORY's five files — each entry named under `silero-vad-unified-256ms-v6.2.1.mlmodelc/`
    /// (the SDK-shaped per-file layout the `parakeet-tdt-0.6b-v3.json` precedent uses — the
    /// artifact ships as a bare directory, not a tarball, so there is no single file to digest),
    /// each with a 64-hex SHA-256 and a positive byte count, because a manifest that ships a
    /// digest nobody measured is a manifest that cannot verify anything.
    func testShippedSileroManifestPinsTheVadModel() throws {
        let manifest = try shippedSileroManifest()

        XCTAssertEqual(
            manifest["engineID"] as? String, "silero-vad",
            "the VAD manifest must be keyed by its engineID")
        XCTAssertEqual(
            manifest["version"] as? String, "1",
            "the VAD manifest's version is immutable — a changed version is a new artifact")
        XCTAssertEqual(
            manifest["sdkDirectory"] as? String, "vad",
            "the VAD artifact stages under one named SDK directory, not the version root")

        let files = try XCTUnwrap(
            manifest["files"] as? [[String: Any]],
            "the manifest must carry a files array")
        let expected = [
            "silero-vad-unified-256ms-v6.2.1.mlmodelc/analytics/coremldata.bin",
            "silero-vad-unified-256ms-v6.2.1.mlmodelc/coremldata.bin",
            "silero-vad-unified-256ms-v6.2.1.mlmodelc/metadata.json",
            "silero-vad-unified-256ms-v6.2.1.mlmodelc/model.mil",
            "silero-vad-unified-256ms-v6.2.1.mlmodelc/weights/weight.bin",
        ]
        XCTAssertEqual(
            files.count, expected.count,
            "the SDK names exactly the v6.2.1 unified model (ModelNames.VAD.requiredModels) — a different file set is a different artifact")
        let names = files.compactMap { $0["name"] as? String }
        XCTAssertEqual(
            Set(names), Set(expected),
            "the manifest's file names must be the five files of the \(expected[0].split(separator: "/")[0]) directory as provisioned")

        for file in files {
            let name = try XCTUnwrap(file["name"] as? String)
            let digest = try XCTUnwrap(file["sha256"] as? String, "\(name): missing sha256")
            XCTAssertEqual(
                digest.count, 64,
                "\(name): a SHA-256 digest is exactly 64 hex characters")
            XCTAssertTrue(
                digest.allSatisfy(\.isHexDigit),
                "\(name): the digest must be hex — a non-hex digest would never match")
            let byteCount = try XCTUnwrap(file["byteCount"] as? Int, "\(name): missing byteCount")
            XCTAssertGreaterThan(
                byteCount, 0,
                "\(name): the manifest must carry the byte count measured from the real artifact, never zero")
        }
    }
}

enum SileroManifestError: Error {
    case malformed
}