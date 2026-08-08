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
import XCTest

/// The manifest format: the Codable shape `spec.md:52-53` names, with the near-miss validation
/// `spec.md:53-54` demands.
///
/// Like ``ASRVocabularyTests``, this suite pins *shape* — but shape that is load-bearing for a
/// different reason. The manifest is the trust anchor of the downloader: every byte that lands on
/// disk is verified against its digests, so a manifest that decoded a wrong value silently — a
/// non-hex digest, a truncated one, a duplicated file name, a field nobody in this repository ever
/// wrote — would be a checksum registry that does not check. The near-miss pattern
/// (``CapturedAudioFormat``'s style): every rejection is one field away from correct, and each is
/// the shape of a real regression somebody could ship.
final class ModelManifestTests: XCTestCase {

    /// A well-formed synthetic manifest: two files, a valid 64-hex-char digest for both, all three
    /// fields present on every entry.
    ///
    /// The digest is the same constant on both files: what is being pinned is the *shape* of the
    /// checksum registry, and the real digests land with the real manifest during the F1 spike
    /// (`plan_20260809.md:26-28`).
    private static let digest = String(repeating: "0123456789abcdef", count: 4)
    private static let validJSON = """
        {
          "engineID": "parakeet-tdt-0.6b-v3",
          "version": "1.0.0",
          "files": [
            {"name": "weights.bin", "sha256": "\(digest)", "byteCount": 12},
            {"name": "config.json", "sha256": "\(digest)", "byteCount": 4}
          ]
        }
        """

    /// The loader under test: the same one the real manifest JSON will be decoded with.
    private func load(_ json: String) throws -> ModelManifest {
        try ModelManifest.load(from: Data(json.utf8))
    }

    /// The good case, asserted field by field so a field that decodes to the wrong value — or to
    /// nothing — fails here rather than downstream at verification time.
    func testAValidSyntheticManifestDecodesWithAllFields() throws {
        let manifest = try load(Self.validJSON)

        XCTAssertEqual(manifest.engineID, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(manifest.version, "1.0.0")

        XCTAssertEqual(manifest.files.count, 2)
        XCTAssertEqual(manifest.files[0].name, "weights.bin")
        XCTAssertEqual(manifest.files[0].sha256, Self.digest)
        XCTAssertEqual(manifest.files[0].byteCount, 12)
        XCTAssertEqual(manifest.files[1].name, "config.json")
        XCTAssertEqual(manifest.files[1].sha256, Self.digest)
        XCTAssertEqual(manifest.files[1].byteCount, 4)
    }

    /// A digest that is not hex at all — a transcription slip that still looks like a string.
    func testANonHexDigestIsRejected() {
        let badDigest = String(repeating: "z", count: 64)
        XCTAssertThrowsError(try load(Self.validJSON.replacingOccurrences(of: Self.digest, with: badDigest))) { error in
            XCTAssertEqual(
                error as? ModelManifestError, .invalidDigest(file: "weights.bin"),
                "a non-hex digest must be rejected as an invalid digest for the file that carries it")
        }
    }

    /// A digest that is the right characters but the wrong length — 63 hex chars is one field away
    /// from correct, and it is the transcription of a digest that was truncated at the source.
    func testAWrongLengthDigestIsRejected() {
        let shortDigest = String(repeating: "a", count: 63)
        XCTAssertThrowsError(try load(Self.validJSON.replacingOccurrences(of: Self.digest, with: shortDigest))) { error in
            XCTAssertEqual(
                error as? ModelManifestError, .invalidDigest(file: "weights.bin"),
                "a digest that is not 64 hex chars must be rejected: verification would compare against a digest of the wrong shape")
        }
    }

    /// Two entries with the same name: the second would silently overwrite the first in the store,
    /// and a manifest that says two files are one file cannot be verified honestly.
    func testDuplicateFileNamesAreRejected() {
        let duplicated = Self.validJSON.replacingOccurrences(of: "config.json", with: "weights.bin")
        XCTAssertThrowsError(try load(duplicated)) { error in
            XCTAssertEqual(
                error as? ModelManifestError, .duplicateFileName("weights.bin"),
                "a duplicated file name must be rejected by name, so the manifest author sees which entry collided")
        }
    }

    /// A top-level field nobody in this repository wrote. Decoding must fail rather than silently
    /// drop it: a field that decodes to nothing today is a field that could hold something
    /// load-bearing tomorrow.
    func testUnknownTopLevelJSONFieldsAreRejected() {
        let withExtra = Self.validJSON.replacingOccurrences(
            of: "  \"engineID\": \"parakeet-tdt-0.6b-v3\",",
            with: "  \"engineID\": \"parakeet-tdt-0.6b-v3\",\n  \"unknownField\": 1,")
        XCTAssertThrowsError(try load(withExtra)) { error in
            XCTAssertEqual(
                error as? ModelManifestError, .unknownField("unknownField"),
                "an unknown top-level field must be rejected, not silently ignored")
        }
    }

    /// The same rule inside a file entry: a file is a trusted claim about bytes, so an entry with
    /// fields this repository does not define is an entry that cannot be verified.
    func testAnUnknownFieldInsideAFileEntryIsRejected() {
        let withExtra = Self.validJSON.replacingOccurrences(
            of: "\"byteCount\": 4",
            with: "\"byteCount\": 4, \"extra\": true")
        XCTAssertThrowsError(try load(withExtra)) { error in
            XCTAssertEqual(
                error as? ModelManifestError, .unknownField("extra"),
                "an unknown field inside a file entry must be rejected by its own name")
        }
    }

    /// Without an engine id the store cannot key the directory, so the manifest is not merely
    /// missing a convenience — it is missing the thing that routes its files to a location.
    func testMissingEngineIDIsRejected() {
        let withoutEngine = Self.validJSON.replacingOccurrences(
            of: "  \"engineID\": \"parakeet-tdt-0.6b-v3\",\n", with: "")
        XCTAssertThrowsError(try load(withoutEngine)) { error in
            XCTAssertEqual(error as? ModelManifestError, .missingField("engineID"))
        }
    }

    /// Without a version the store cannot distinguish two downloads of the same engine — the
    /// immutability claim (`PRODUCT_SPEC.md:273`) is about a *pinned* version.
    func testMissingVersionIsRejected() {
        let withoutVersion = Self.validJSON.replacingOccurrences(
            of: "  \"version\": \"1.0.0\",\n", with: "")
        XCTAssertThrowsError(try load(withoutVersion)) { error in
            XCTAssertEqual(error as? ModelManifestError, .missingField("version"))
        }
    }

    /// Compile-time, not runtime: `requireSendable` constrains its parameter to `Sendable`, so a
    /// type that loses the conformance fails to build this file rather than failing an assertion.
    ///
    /// The manifest crosses actor boundaries on every download path: `ModelStore` is an actor, and
    /// `downloadIfMissing` takes the manifest across it. The error vocabulary crosses back.
    func testTheManifestTypesAreSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }

        let file = ManifestFile(name: "weights.bin", sha256: Self.digest, byteCount: 12)
        let manifest = ModelManifest(
            engineID: "parakeet-tdt-0.6b-v3", version: "1.0.0", files: [file])
        _ = requireSendable(file)
        _ = requireSendable(manifest)
        _ = requireSendable(ModelManifestError.missingField("engineID"))
    }
}
