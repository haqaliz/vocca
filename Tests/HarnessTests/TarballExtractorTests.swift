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

/// The tarball extractor: idempotent, self-healing extraction of the Kokoro model tarball
/// (`kokoro-binding`/`provisioning` spec acceptance 3).
///
/// The marker of a completed extraction is the **trio** the port itself requires before it will
/// load — `kokoro_frontend.mlmodelc` + `kokoro_backend.mlmodelc` + `voices/` (the port's own
/// `ModelManager.modelsAvailable` check, `KokoroEngine.swift:190-191` in the port) — so "extracted"
/// here means "extracted far enough to run", and an interrupted extraction (the trio incomplete)
/// is re-extracted on the next run rather than trusted.
///
/// The fixture is a committed 675-byte tarball (`Tests/HarnessTests/Fixtures/fixture.tar.gz`)
/// whose entries mirror the real artifact's shape: the three trio members — the two `.mlmodelc`
/// marker directories and `voices/` — plus the two tiny files the extraction assertions read
/// (`marker.bin` and `voices/af_heart.bin`). The tests never shell out: the fixture is read from
/// disk and extraction happens through the production code.
final class TarballExtractorTests: XCTestCase {

    /// Every temporary path a test created, removed after each test.
    private var tempPaths: [URL] = []

    override func tearDown() {
        for path in tempPaths {
            try? FileManager.default.removeItem(at: path)
        }
        tempPaths = []
        super.tearDown()
    }

    /// The committed fixture, located from this source file — never a hardcoded absolute path.
    private func fixtureTarball() throws -> URL {
        try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Tests/HarnessTests/Fixtures/fixture.tar.gz")
    }

    /// A fresh temporary directory to extract into (need not exist — the extractor creates it).
    private func makeTarget() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-tarball-extractor-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        tempPaths.append(url)
        return url
    }

    /// A copy of the fixture at a fresh temporary path, so a test can poison or mutate its copy
    /// without touching the committed bytes.
    private func makeFixtureCopy() throws -> URL {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-tarball-extractor-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString + ".tar.gz")
        tempPaths.append(copy)
        try FileManager.default.copyItem(at: fixtureTarball(), to: copy)
        return copy
    }

    /// Whether the extraction marker trio is present in `directory` — the same check the extractor
    /// itself makes, spelled out with the literal names so a rename fails here too.
    private func trioIsPresent(in directory: URL) -> Bool {
        let fileManager = FileManager.default
        return [
            "kokoro_frontend.mlmodelc",
            "kokoro_backend.mlmodelc",
            "voices",
        ].allSatisfy { component in
            fileManager.fileExists(
                atPath: directory.appendingPathComponent(component).path)
        }
    }

    /// **AC3a.** Extraction writes the tarball's files into the target directory and creates the
    /// directory itself — the caller may name a directory that does not exist yet.
    func testExtractionWritesBothFilesIntoTheTargetDirectoryAndCreatesIt() throws {
        let target = makeTarget()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.path),
            "the fixture is wrong if the target already exists")

        try TarballExtractor.extractIfNeeded(tarball: try fixtureTarball(), into: target)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: target.path),
            "the extractor must create the target directory, not require it")
        XCTAssertTrue(
            trioIsPresent(in: target),
            "the marker trio must be present after extraction")

        let marker = try Data(
            contentsOf: target.appendingPathComponent("marker.bin"))
        XCTAssertEqual(marker, Data("marker-bytes".utf8))
        let voice = try Data(
            contentsOf: target.appendingPathComponent("voices/af_heart.bin"))
        XCTAssertEqual(voice, Data("af-heart-embedding-bytes".utf8))
    }

    /// **AC3b.** A second run is a safe no-op: with the trio already present the extractor skips —
    /// proven by poisoning the tarball between the runs. A re-extract would read the poisoned
    /// bytes and must fail; a run that never touches the tarball succeeds and leaves the files
    /// intact.
    func testDoubleRunIsIdempotentAndSkipsWhenTheMarkerTrioIsPresent() throws {
        let target = makeTarget()
        let tarball = try makeFixtureCopy()

        try TarballExtractor.extractIfNeeded(tarball: tarball, into: target)
        let before = try Data(
            contentsOf: target.appendingPathComponent("voices/af_heart.bin"))

        // The poisoned copy: if the second run re-extracts, tar reads zero bytes and the post-
        // check throws — the skip is the only way this run can succeed.
        try Data().write(to: tarball)
        try TarballExtractor.extractIfNeeded(tarball: tarball, into: target)

        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("voices/af_heart.bin")),
            before,
            "a skipped run must leave the extracted files byte-for-byte intact")
        XCTAssertTrue(
            trioIsPresent(in: target),
            "the marker trio must survive a double run")
    }

    /// **AC3c.** A partial/interrupted state — one trio member present, the trio incomplete —
    /// re-extracts on the next run: the self-healing that makes an interrupted extraction
    /// recoverable without a manual wipe.
    func testAPartialInterruptedStateReExtracts() throws {
        let target = makeTarget()
        try TarballExtractor.extractIfNeeded(tarball: try fixtureTarball(), into: target)

        // Interrupted state: one member present, the rest gone — as if the process died mid-write.
        let backend = target.appendingPathComponent("kokoro_backend.mlmodelc")
        let voices = target.appendingPathComponent("voices")
        try FileManager.default.removeItem(at: backend)
        try FileManager.default.removeItem(at: voices)
        XCTAssertFalse(trioIsPresent(in: target), "the planted interruption must break the trio")

        try TarballExtractor.extractIfNeeded(tarball: try fixtureTarball(), into: target)

        XCTAssertTrue(
            trioIsPresent(in: target),
            "a partial extraction must self-heal on the next run")
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("voices/af_heart.bin")),
            Data("af-heart-embedding-bytes".utf8),
            "the re-extracted file must be byte-for-byte the fixture's")
    }

    /// **AC3d, missing.** A tarball that is not there is a recorded failure — never a silent
    /// partial. The missing case is caught before any extraction work.
    func testAMissingTarballIsARecordedFailure() throws {
        let target = makeTarget()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-tarball-extractor-tests")
            .appendingPathComponent(UUID().uuidString + "-missing.tar.gz")

        XCTAssertThrowsError(
            try TarballExtractor.extractIfNeeded(tarball: missing, into: target)
        ) { error in
            XCTAssertEqual(
                error as? TarballExtractorError, .tarballMissing(tarball: missing),
                "a missing tarball must be reported as exactly that, naming the path")
        }
        XCTAssertFalse(
            trioIsPresent(in: target),
            "a failed extraction must never leave a partial trio that reads as extracted")
    }

    /// **AC3d, empty.** An empty tarball is a recorded failure, never a silent partial.
    ///
    /// Measured on macOS: `/usr/bin/tar -xzf` on a zero-byte archive exits **0** silently,
    /// extracting nothing — so the post-extraction trio check is load-bearing: without it an
    /// empty or truncated archive would be a silent partial that the next launch trusts.
    func testAnEmptyTarballIsARecordedFailureNotASilentPartial() throws {
        let target = makeTarget()
        let empty = try makeFixtureCopy()
        try Data().write(to: empty)

        XCTAssertThrowsError(
            try TarballExtractor.extractIfNeeded(tarball: empty, into: target)
        ) { error in
            XCTAssertEqual(
                error as? TarballExtractorError, .markerComponentsMissing(tarball: empty),
                "tar exiting 0 on an empty archive must still be a recorded failure — the trio check is the guard")
        }
        XCTAssertFalse(
            trioIsPresent(in: target),
            "an empty archive must never leave a partial trio that reads as extracted")
    }

    /// **AC3d, corrupt.** A tarball that is not a valid archive is a recorded failure — tar's own
    /// non-zero exit, surfaced as the extractor's error rather than swallowed.
    func testACorruptTarballIsARecordedFailure() throws {
        let target = makeTarget()
        let corrupt = try makeFixtureCopy()
        try Data("not a gzip archive, just junk bytes".utf8).write(to: corrupt)

        XCTAssertThrowsError(
            try TarballExtractor.extractIfNeeded(tarball: corrupt, into: target)
        ) { error in
            guard case .tarFailed(let exitCode, let reported) = error as? TarballExtractorError else {
                XCTFail("a corrupt archive must be reported as a tar failure, got: \(error)")
                return
            }
            XCTAssertNotEqual(exitCode, 0, "tar must have failed with a non-zero exit")
            XCTAssertEqual(reported, corrupt, "the failure must name the archive that failed")
        }
        XCTAssertFalse(
            trioIsPresent(in: target),
            "a corrupt archive must never leave a partial trio that reads as extracted")
    }
}