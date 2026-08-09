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

/// The single-file manifest's round trip through the **shipped** ``ModelStore`` over a stub
/// transport (`plan_20260810.md:61-73`, `spec.md:45-47`): a whisper-shaped manifest — flat,
/// `sdkDirectory` absent, exactly one GGUF — downloads, verifies, commits its marker, and reads
/// as present; an in-flight `.part` remnant reads as absent; and a digest mismatch surfaces as
/// the store's own ``ModelStoreError/checksumMismatch(file:)`` and never commits.
///
/// The manifest is **test-authored** — a tiny fake file whose real SHA-256 is computed in the
/// test — not one of the checked-in manifests, which do not exist yet (they land with the
/// founder's provisioning run, `plan_20260810.md:41-59`). The store and downloader are reused
/// as-is; this suite is the proof that a manifest of the whisper shape works through them, so a
/// future store change that broke the flat layout fails here before any real GGUF is ever
/// downloaded.
final class WhisperStoreRoundTripTests: XCTestCase {

    private let engineID = "whisper-large-v3-turbo"
    private let version = "1"
    private let file = "ggml-large-v3-turbo.bin"

    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots = []
        super.tearDown()
    }

    private func makeStore() -> (store: ModelStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-whisper-store-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        tempRoots.append(root)
        return (ModelStore(rootURL: root), root)
    }

    private func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private func versionDirectory(under root: URL) -> URL {
        root
            .appendingPathComponent(engineID, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    /// The whisper-shaped manifest: one flat file, no `sdkDirectory` — the exact shape
    /// `whisper-large-v3-turbo.json` will have (`spec.md:14-19`).
    private func makeWhisperManifest(fakeGGUF: [UInt8]) -> ModelManifest {
        ModelManifest(engineID: engineID, version: version, files: [
            ManifestFile(name: file, sha256: sha256Hex(fakeGGUF), byteCount: fakeGGUF.count),
        ])
    }

    // MARK: - The happy path

    /// Download → verify → marker → present: a single-file flat manifest commits the GGUF
    /// directly under the version directory (no SDK subdirectory), writes the verified marker,
    /// and reads as present. This is the store-half of acceptance criterion 2
    /// (`spec.md:45-47`).
    func testSingleFileManifestRoundTripsTheStoreWithAVerifiedMarker() async throws {
        let (store, root) = makeStore()
        let fakeGGUF: [UInt8] = (0..<2_048).map { UInt8($0 % 251) }
        let stub = StubTransport(files: [file: fakeGGUF])

        try await store.downloadIfMissing(manifest: makeWhisperManifest(fakeGGUF: fakeGGUF), transport: stub)

        let directory = versionDirectory(under: root)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(ModelStore.markerFileName).path),
            "the verified marker must be written for a single-file manifest too")
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(file)),
            Data(fakeGGUF),
            "the GGUF must land flat, directly under the version directory")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(file + ".part").path),
            "no .part may survive the commit")
        let present = await store.isPresent(engineID: engineID, version: version)
        XCTAssertTrue(present, "a verified single-file install must read as present")
    }

    // MARK: - The in-flight rule

    /// A `.part` remnant beside a committed single file keeps presence false — the store's
    /// "in-flight is never present" rule (`ModelStore.swift`'s recursive scan), pinned in the
    /// single-file layout: a half-replaced GGUF must never read as ready.
    func testAPartRemnantBesideTheCommitKeepsPresenceFalse() async throws {
        let (store, root) = makeStore()
        let fakeGGUF: [UInt8] = (0..<2_048).map { UInt8($0 % 251) }
        let stub = StubTransport(files: [file: fakeGGUF])

        try await store.downloadIfMissing(manifest: makeWhisperManifest(fakeGGUF: fakeGGUF), transport: stub)
        let directory = versionDirectory(under: root)
        try Data("resume-material".utf8).write(to: directory.appendingPathComponent(file + ".part"))

        let present = await store.isPresent(engineID: engineID, version: version)
        XCTAssertFalse(
            present,
            "a .part file means a download is in flight or incomplete, and in-flight is never present")
    }

    // MARK: - The failure path

    /// A digest mismatch surfaces as the store's own checksum error, and the version never
    /// commits: no marker, not present. The corrupt `.part` is discarded, not kept — wrong
    /// bytes are not resume material.
    func testDigestMismatchSurfacesChecksumMismatchAndNeverCommits() async throws {
        let (store, root) = makeStore()
        let fakeGGUF: [UInt8] = (0..<2_048).map { UInt8($0 % 251) }
        // The manifest promises the real bytes' digest; the stub serves XOR-mangled bytes that
        // can never match it.
        let stub = StubTransport(files: [file: fakeGGUF], mode: .corruptBytes)

        do {
            try await store.downloadIfMissing(manifest: makeWhisperManifest(fakeGGUF: fakeGGUF), transport: stub)
            XCTFail("a download whose bytes cannot match the manifest digest must throw")
        } catch {
            XCTAssertEqual(
                error as? ModelStoreError, .checksumMismatch(file: file),
                "the store must surface the mismatch in its own vocabulary, naming the file")
        }

        let directory = versionDirectory(under: root)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(ModelStore.markerFileName).path),
            "a failed download must never commit: no marker may be written")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(file + ".part").path),
            "a corrupt partial must be discarded, never kept as resume material")
        let present = await store.isPresent(engineID: engineID, version: version)
        XCTAssertFalse(present)
    }
}
