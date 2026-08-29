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
import VoccaCore
import XCTest

/// The shipped manifests' digests, checked against bytes rather than against reasoning
/// (`verification-smoke/spec.md` R1).
///
/// **What is open here is provenance, not a known defect.** The predicted placeholder — SHA-256 of
/// the literal `{}`, `44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a` — appears
/// in no shipped manifest, no entry declares a 0- or 2-byte size, and no digest repeats across
/// files. What has never happened is the comparison itself: `672367e` added both Whisper manifests
/// with no recorded provisioning run behind them, the same evidentiary shape as `ac381d0`, whose
/// Parakeet entry made the default engine unprovisionable for two weeks. *Not defective,
/// unverified* — and this suite is what turns that into something a machine can answer.
///
/// The suite is in two halves, because CI can reach one of them and never the other:
///
/// - **The mechanism**, which runs unconditionally: ``ManifestByteVerifier`` over synthesised
///   files in a temporary directory, including planted mismatches. A gate that cannot fail proves
///   nothing, so the planted rows are the load-bearing ones — they are the reason a green run of
///   the env-gated half below means anything at all.
/// - **The artifacts**, which run only with `VOCCA_MODEL_DIR` set and otherwise **skip visibly**
///   (the `ParakeetEngineWERTests` / `WhisperCppEngineWERTests` precedent). A silent pass is
///   precisely what let the Parakeet placeholder survive two weeks of green badges.
///
/// Nothing here downloads: the verifier reads local bytes the founder provisioned, and the
/// synthesised halves write only into a fresh temporary directory. The zero-network invariant is
/// absolute and this suite must never be the thing that weakens it.
final class ManifestDigestVerificationTests: XCTestCase {

    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots = []
        super.tearDown()
    }

    /// A fresh, empty temporary directory — never Application Support, never the repository.
    private func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-manifest-digest-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        tempRoots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes `contents` at `name` under `directory`, creating intermediate directories, and
    /// answers the manifest entry that describes it **truthfully** — so a test that wants a
    /// mismatch has to plant one deliberately, and a test that wants a match cannot get one by
    /// accident.
    @discardableResult
    private func writeFile(
        named name: String, contents: String, under directory: URL
    ) throws -> ManifestFile {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(contents.utf8)
        try data.write(to: url)
        return ManifestFile(
            name: name,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: data.count)
    }

    // MARK: - The mechanism, which CI can reach

    /// Bytes that match their manifest verify clean, in the flat layout every Whisper manifest
    /// uses.
    ///
    /// This is the row that would make every other row below meaningless if it failed for the
    /// wrong reason: a verifier that reported a mismatch for correct bytes would be discarded, and
    /// a verifier that could only ever say "matched" is the silent pass this aspect exists to
    /// prevent. Both directions are pinned — here, and in the planted rows that follow.
    func testBytesThatMatchTheirManifestVerifyClean() throws {
        let directory = try makeTempDirectory()
        let first = try writeFile(named: "ggml.bin", contents: "the first artifact", under: directory)
        let second = try writeFile(named: "vocab.json", contents: "the second", under: directory)
        let manifest = ModelManifest(
            engineID: "test-engine", version: "1", files: [first, second])

        let verdicts = ManifestByteVerifier.verify(manifest: manifest, versionDirectory: directory)

        XCTAssertEqual(verdicts.count, 2, "every declared file must be answered for")
        XCTAssertTrue(
            verdicts.allSatisfy { $0.isMatch },
            "bytes written from the manifest's own measurement must verify: \(verdicts)")
        XCTAssertTrue(ManifestByteVerifier.failures(in: verdicts).isEmpty)
    }

    /// An SDK-shaped manifest's files live one directory deeper, and the verifier must look where
    /// the store actually commits them.
    ///
    /// `ModelStore.performDownload` writes files under `<version>/<sdkDirectory>/` and the
    /// verified marker at the version root — the Parakeet layout the F1 spike measured. A verifier
    /// that looked at the version root instead would report thirteen missing files for a perfectly
    /// good Parakeet install, which is a gate that fails for the wrong reason and gets switched
    /// off.
    func testFilesAreSoughtUnderTheManifestsSDKDirectory() throws {
        let directory = try makeTempDirectory()
        let nested = directory.appendingPathComponent("sdk-repo", isDirectory: true)
        let file = try writeFile(named: "config.json", contents: "{\"real\": true}", under: nested)
        let manifest = ModelManifest(
            engineID: "test-engine", version: "1", sdkDirectory: "sdk-repo", files: [file])

        let verdicts = ManifestByteVerifier.verify(manifest: manifest, versionDirectory: directory)

        XCTAssertEqual(verdicts, [.matched(name: "config.json")])
    }

    /// **The gate can fail.** A planted digest mismatch is reported, naming the file, the declared
    /// digest and the digest the bytes actually have.
    ///
    /// This is the row the whole aspect rests on. The env-gated half below cannot run in CI, so
    /// the only evidence that a green CI run says anything about the verifier is that CI has
    /// watched it catch a lie it planted itself.
    func testAPlantedDigestMismatchIsReported() throws {
        let directory = try makeTempDirectory()
        let honest = try writeFile(named: "ggml.bin", contents: "the real bytes", under: directory)
        // The manifest claims a digest of the same length and shape that the bytes do not have —
        // the exact shape of a placeholder digest committed without a provisioning run behind it.
        let planted = ManifestFile(
            name: honest.name,
            sha256: String(repeating: "a", count: 64),
            byteCount: honest.byteCount)
        let manifest = ModelManifest(engineID: "test-engine", version: "1", files: [planted])

        let verdicts = ManifestByteVerifier.verify(manifest: manifest, versionDirectory: directory)

        XCTAssertEqual(
            verdicts,
            [
                .digestMismatch(
                    name: "ggml.bin",
                    declared: String(repeating: "a", count: 64),
                    actual: honest.sha256)
            ])
        XCTAssertEqual(ManifestByteVerifier.failures(in: verdicts).count, 1)
    }

    /// Every mismatching file is reported in one run, not just the first.
    ///
    /// A manifest generated by a partial run has more than one wrong entry, and a verifier that
    /// stopped at the first would make the founder re-download 1.6 GB once per bad line. The
    /// clean file between the two planted ones is deliberate: it pins that the run continues past
    /// a failure *and* past a success.
    func testEveryMismatchingFileIsReportedInOneRun() throws {
        let directory = try makeTempDirectory()
        let firstHonest = try writeFile(named: "a.bin", contents: "alpha", under: directory)
        let cleanFile = try writeFile(named: "b.bin", contents: "bravo", under: directory)
        let secondHonest = try writeFile(named: "c.bin", contents: "charlie", under: directory)
        let manifest = ModelManifest(
            engineID: "test-engine", version: "1",
            files: [
                ManifestFile(
                    name: firstHonest.name, sha256: String(repeating: "0", count: 64),
                    byteCount: firstHonest.byteCount),
                cleanFile,
                ManifestFile(
                    name: secondHonest.name, sha256: String(repeating: "f", count: 64),
                    byteCount: secondHonest.byteCount),
            ])

        let verdicts = ManifestByteVerifier.verify(manifest: manifest, versionDirectory: directory)
        let failures = ManifestByteVerifier.failures(in: verdicts)

        XCTAssertEqual(verdicts.count, 3, "every file is answered for, failing or not")
        XCTAssertEqual(
            failures.map(\.fileName), ["a.bin", "c.bin"],
            "both planted mismatches must appear, in manifest order")
        XCTAssertTrue(verdicts.contains(.matched(name: "b.bin")))
    }

    /// A declared byte count that disagrees with the bytes on disk is its own finding, reported
    /// before the digest.
    ///
    /// The 2-byte `config.json` that shipped in the Parakeet manifest was wrong in *both* fields,
    /// and the size is the cheaper and more legible signal: it says "this entry was written, not
    /// measured" without a 1.6 GB read. Reporting it separately is also what keeps the digest read
    /// off files whose length already proves them wrong.
    func testADeclaredByteCountThatDisagreesWithDiskIsReported() throws {
        let directory = try makeTempDirectory()
        let honest = try writeFile(named: "config.json", contents: "{\"real\": true}", under: directory)
        let planted = ManifestFile(name: honest.name, sha256: honest.sha256, byteCount: 2)
        let manifest = ModelManifest(engineID: "test-engine", version: "1", files: [planted])

        let verdicts = ManifestByteVerifier.verify(manifest: manifest, versionDirectory: directory)

        XCTAssertEqual(
            verdicts,
            [.byteCountMismatch(name: "config.json", declared: 2, actual: honest.byteCount)])
    }

    /// A declared file that is not on disk is reported as missing rather than as a digest
    /// mismatch.
    ///
    /// The two failures have different repairs — one is a broken provisioning run, the other a
    /// wrong manifest entry — and a verifier that folded them together would send the founder
    /// looking in the wrong place.
    func testADeclaredFileThatIsAbsentIsReportedMissing() throws {
        let directory = try makeTempDirectory()
        let manifest = ModelManifest(
            engineID: "test-engine", version: "1",
            files: [
                ManifestFile(
                    name: "never-written.bin", sha256: String(repeating: "b", count: 64),
                    byteCount: 12)
            ])

        let verdicts = ManifestByteVerifier.verify(manifest: manifest, versionDirectory: directory)

        XCTAssertEqual(verdicts, [.missing(name: "never-written.bin")])
        XCTAssertEqual(ManifestByteVerifier.failures(in: verdicts).count, 1)
    }

    /// A declared file that cannot be read is reported as unreadable, carrying the reason.
    ///
    /// The planted case is a *directory* where a file is declared — the shape a half-finished
    /// provisioning run leaves behind, and the one failure mode where the bytes exist in some
    /// sense and still cannot be hashed. It is kept distinct from ``missing`` and from a digest
    /// mismatch because its repair is different again, and because a verifier that swallowed the
    /// read error would report a clean sheet for a file it never opened.
    func testADeclaredFileThatCannotBeReadIsReportedWithItsReason() throws {
        let directory = try makeTempDirectory()
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("config.json", isDirectory: true),
            withIntermediateDirectories: true)
        let manifest = ModelManifest(
            engineID: "test-engine", version: "1",
            files: [
                ManifestFile(
                    name: "config.json", sha256: String(repeating: "c", count: 64), byteCount: 64)
            ])

        let verdicts = ManifestByteVerifier.verify(manifest: manifest, versionDirectory: directory)

        XCTAssertEqual(verdicts.count, 1)
        guard case .unreadable(let name, let reason) = verdicts.first else {
            return XCTFail("expected an unreadable verdict, got \(verdicts)")
        }
        XCTAssertEqual(name, "config.json")
        XCTAssertFalse(reason.isEmpty, "an unreadable file must say why it could not be read")
        XCTAssertEqual(ManifestByteVerifier.failures(in: verdicts).count, 1)
    }

    // MARK: - The artifacts, which CI cannot reach

    /// Every shipped manifest, checked against the bytes the founder provisioned — the comparison
    /// that has never been made for the two Whisper manifests.
    ///
    /// Env-gated on `VOCCA_MODEL_DIR`, which names a store-shaped **version** directory
    /// (`<root>/<storageID>/<version>`, the value `Scripts/provision-asr-fixtures.sh` prints), and
    /// **skips visibly** without it. From that value the model tree's root is the grandparent, and
    /// every tier whose version directory exists under that root is verified — so one run over a
    /// root holding all three artifacts checks all three, and a root holding one checks one and
    /// names the other two as unprovisioned rather than passing them.
    ///
    /// It downloads nothing. The store is not involved at all: this reads bytes that are already
    /// on the disk, which is the only way to answer a question about the bytes the manifests
    /// claim.
    func testEveryShippedManifestMatchesTheProvisionedBytes() throws {
        guard let modelDir = ProcessInfo.processInfo.environment["VOCCA_MODEL_DIR"] else {
            throw XCTSkip(
                "set VOCCA_MODEL_DIR to a store-shaped version directory to verify the shipped "
                    + "manifests against real bytes — see Scripts/provision-asr-fixtures.sh, and "
                    + "SMOKE_CHECKLIST.md step 102")
        }
        let modelRoot = URL(fileURLWithPath: modelDir)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        var verifiedTiers: [EngineTier] = []
        var unprovisionedTiers: [EngineTier] = []
        var report: [String] = []

        for tier in EngineTier.allCases {
            let manifest = try ShippedModelManifest.load(for: tier)
            let versionDirectory = modelRoot
                .appendingPathComponent(manifest.engineID, isDirectory: true)
                .appendingPathComponent(manifest.version, isDirectory: true)
            guard FileManager.default.fileExists(atPath: versionDirectory.path) else {
                unprovisionedTiers.append(tier)
                continue
            }
            verifiedTiers.append(tier)
            let failures = ManifestByteVerifier.failures(
                in: ManifestByteVerifier.verify(
                    manifest: manifest, versionDirectory: versionDirectory))
            report.append(
                contentsOf: failures.map { "\(manifest.engineID)/\(manifest.version): \($0)" })
        }

        // The env var was set, so something was meant to be checked. A run that verified no
        // manifest at all is the silent pass this suite exists to prevent, and it fails loudly
        // rather than reporting a clean sheet it never earned.
        XCTAssertFalse(
            verifiedTiers.isEmpty,
            "VOCCA_MODEL_DIR names \(modelRoot.path), under which no shipped manifest's version "
                + "directory exists — nothing was verified")

        XCTAssertTrue(
            report.isEmpty,
            "the shipped manifests disagree with the provisioned bytes:\n"
                + report.joined(separator: "\n"))

        // Not a failure — a fact the run must state, so a partial verification is never read as a
        // full one. Whichever tiers were absent are still unverified after this run.
        if !unprovisionedTiers.isEmpty {
            print(
                "MANIFEST-VERIFY: verified \(verifiedTiers); not provisioned under "
                    + "\(modelRoot.path), still unverified: \(unprovisionedTiers)")
        }
    }
}
