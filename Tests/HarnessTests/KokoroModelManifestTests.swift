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
import VoccaASR
import VoccaCore
import XCTest

/// The Kokoro TTS manifest: the parallel loader, its shipped JSON, and its storage key's
/// pairwise distinctness from every ASR tier (`kokoro-binding`/`provisioning` spec acceptance 1-2).
///
/// The ASR manifests are keyed through the EngineTier-closed ``ShippedModelManifest`` switch, and
/// that switch must **not** grow for the TTS artifact — Kokoro is not an ``EngineTier``, it is a
/// `SpeechSynthesizer` with its own model tree. So this suite pins the sibling loader
/// ``KokoroModelManifest`` and, because storage is keyed by directory name
/// (`ModelStoreTierKeyingTests`), pins that the TTS `engineID` collides with none of the three
/// ASR storage keys — the same pairwise-distinct claim that file makes, extended to the new
/// key without touching that file.
final class KokoroModelManifestTests: XCTestCase {

    /// The loader under test is ``KokoroModelManifest/load()`` — the real bundle-resource route
    /// the composition root's TTS preparation will call, not a synthetic JSON string.
    private func loadShipped() throws -> ModelManifest {
        try KokoroModelManifest.load()
    }

    /// **Acceptance 1a.** The shipped Kokoro manifest has the pinned shape: the TTS engine's
    /// `engineID`, the immutable version, a single-component `sdkDirectory` (the layout rule
    /// `ModelManifest.isSafeSingleComponent` enforces), and exactly the one tarball entry —
    /// with a 64-hex SHA-256 and a positive byte count, because a manifest that ships a digest
    /// nobody measured is a manifest that cannot verify anything.
    func testTheShippedKokoroManifestLoadsWithThePinnedShape() throws {
        let manifest = try loadShipped()

        XCTAssertEqual(manifest.engineID, "kokoro-82m")
        XCTAssertEqual(manifest.version, "1")
        XCTAssertEqual(
            manifest.sdkDirectory, "kokoro",
            "the TTS artifact extracts into one named SDK directory, not the version root")

        XCTAssertEqual(
            manifest.files.count, 1,
            "the Kokoro artifact is one tarball — a manifest with more entries describes a different artifact")
        let file = manifest.files[0]
        XCTAssertEqual(file.name, "kokoro-models.tar.gz")
        XCTAssertEqual(
            file.sha256.count, 64,
            "a SHA-256 digest is exactly 64 hex characters — anything else is not the shape verification can honour")
        XCTAssertTrue(
            file.sha256.allSatisfy(\.isHexDigit),
            "the digest must be hex — a non-hex digest would decode as a digest that never matches")
        XCTAssertGreaterThan(
            file.byteCount, 0,
            "the manifest must carry the byte count measured from the real artifact, never zero")
    }

    /// **Acceptance 1b.** The shipped manifest passes the repo's manifest-validation shape: hex
    /// digest, safe relative file name, no duplicates. Loading through `ModelManifest.load(from:)`
    /// *is* that validation — every near-miss `ModelManifestTests` pins (non-hex, truncated,
    /// duplicated, traversing) is a throw inside that loader — so this row asserts the shipped
    /// file's own values against the shape rules directly, in the `ModelStoreTierKeyingTests`
    /// style.
    func testTheShippedKokoroManifestPassesTheManifestValidationShape() throws {
        let manifest = try loadShipped()

        for file in manifest.files {
            XCTAssertTrue(
                ModelManifestTestShape.isHexDigest(file.sha256),
                "\(file.name): the shipped digest is not 64 hex characters")
            XCTAssertTrue(
                ModelManifestTestShape.isSafeRelativePath(file.name),
                "\(file.name): the shipped file name is not a safe relative path")
        }

        let names = manifest.files.map(\.name)
        XCTAssertEqual(
            Set(names).count, names.count,
            "two entries share a name — the second would overwrite the first in the store")
    }

    /// **Acceptance 2.** The TTS engineID is pairwise-distinct from every ASR tier's storageID —
    /// the `ModelStoreTierKeyingTests` claim extended to the new key.
    ///
    /// `ModelStore` keys directories as `<root>/<engineID>/<version>/`, and the whole
    /// tier-keying defect was two names for one directory. Kokoro is a different artifact with a
    /// different directory, so its engineID must collide with none of the three ASR storage keys
    /// — a collision would make one tier's verified marker answer for the TTS models, or the
    /// other way around. The check runs over ``EngineTier/allCases`` so a tier added later cannot
    /// quietly reuse the TTS key either.
    func testTheKokoroEngineIDIsPairwiseDistinctFromEveryASRTierStorageID() throws {
        let kokoro = try loadShipped()

        for tier in EngineTier.allCases {
            XCTAssertNotEqual(
                kokoro.engineID, tier.storageID,
                "\(tier)'s storage key collides with the Kokoro TTS key — two artifacts would share one directory and one verified marker")
        }
    }
}

/// The manifest shape rules spelled out for the shipped-file assertions, mirroring the validation
/// inside `ModelManifest` (`ModelManifest.swift:90-114`) without reaching into its privates.
enum ModelManifestTestShape {
    static func isHexDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    static func isSafeRelativePath(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/")
            && name.split(separator: "/").allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}