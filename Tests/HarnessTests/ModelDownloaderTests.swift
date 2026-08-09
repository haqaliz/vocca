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
import Synchronization
import VoccaASR
import XCTest

/// The downloader contract, `spec.md:60-68`: every download decision — resume, verify, retry,
/// cancel, progress — sits above the transport seam, and every failure leaves the store not
/// present.
///
/// Everything here drives the **real** ``ModelStore`` and ``ModelDownloader`` through the
/// ``StubTransport`` in temporary directories. The two places that bypass the store — the
/// restart-limit tests — are deliberate: the store maps the downloader's exhausted-retry error
/// onto its own ``ModelStoreError/checksumMismatch(file:)`` (that is the Phase 1 contract,
/// `ModelStoreTests`), so the downloader's own vocabulary can only be pinned by calling the
/// downloader directly.
final class ModelDownloaderTests: XCTestCase {

    private let engineID = "parakeet-tdt-0.6b-v3"
    private let version = "1.0.0"

    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots = []
        super.tearDown()
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-model-downloader-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        tempRoots.append(root)
        return root
    }

    private func makeStore(root: URL) -> ModelStore {
        ModelStore(rootURL: root)
    }

    private func makeManifest(files: [ManifestFile]) -> ModelManifest {
        ModelManifest(engineID: engineID, version: version, files: files)
    }

    private func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    private func versionDirectory(under root: URL) -> URL {
        root
            .appendingPathComponent(engineID, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    private func partSize(_ partURL: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: partURL.path) else {
            return nil
        }
        return (attributes[.size] as? Int) ?? (attributes[.size] as? NSNumber)?.intValue
    }

    // MARK: - Happy path and progress

    /// The happy path through the real store: two files download, verify, and commit; progress is
    /// monotonic, reaches exactly 1.0 only at the end, and the aggregate is byte-weighted.
    func testHappyPathCommitsWithMonotonicByteWeightedProgress() async throws {
        let root = makeRoot()
        let store = makeStore(root: root)
        let weights = bytes("0123456789")
        let config = bytes("abcdefghij")
        let manifest = makeManifest(files: [
            ManifestFile(name: "weights.bin", sha256: sha256Hex(weights), byteCount: weights.count),
            ManifestFile(name: "config.json", sha256: sha256Hex(config), byteCount: config.count),
        ])
        let stub = StubTransport(files: ["weights.bin": weights, "config.json": config])
        let progress = Mutex<[Double]>([])

        try await store.downloadIfMissing(manifest: manifest, transport: stub) { value in
            progress.withLock { $0.append(value) }
        }

        let values = progress.withLock { $0 }
        XCTAssertFalse(values.isEmpty, "progress must be reported")
        XCTAssertTrue(
            values.enumerated().allSatisfy { index, value in
                index == 0 || value >= values[index - 1]
            },
            "progress must be monotonic, got \(values)")
        XCTAssertEqual(
            values.last, 1.0,
            "progress must end at exactly 1.0, got \(values.last ?? -1)")
        XCTAssertEqual(
            values.filter { $0 == 1.0 }.count, 1,
            "progress must reach 1.0 exactly once — only after every byte is written")
        XCTAssertTrue(
            values.contains(0.5),
            "two equal-sized files must report the halfway mark: byte-weighted aggregation")

        let directory = versionDirectory(under: root)
        let present = await store.isPresent(engineID: engineID, version: version)
        XCTAssertTrue(present)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("weights.bin")),
            Data(weights))
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("config.json")),
            Data(config))
    }

    // MARK: - Resume

    /// A transfer that dies mid-file leaves a `.part` of exactly N bytes; the *next* run resumes
    /// from N — Range from N, remainder only — verifies once, and commits. The model is never
    /// re-downloaded from zero.
    func testAFailedTransferResumesFromThePartialFileOnTheNextRun() async throws {
        let root = makeRoot()
        let store = makeStore(root: root)
        let weights = bytes("0123456789")  // 10 bytes
        let manifest = makeManifest(files: [
            ManifestFile(name: "weights.bin", sha256: sha256Hex(weights), byteCount: weights.count),
        ])
        let failing = StubTransport(
            files: ["weights.bin": weights], mode: .failsFirstAttempt(afterBytes: 7))

        do {
            try await store.downloadIfMissing(manifest: manifest, transport: failing)
            XCTFail("a transfer that dies after 7 bytes must fail the run")
        } catch {
            guard case ModelDownloadError.transportFailed = error else {
                XCTFail("a dead transfer must surface as .transportFailed, got \(error)")
                return
            }
        }

        let directory = versionDirectory(under: root)
        let partURL = directory.appendingPathComponent("weights.bin.part")
        XCTAssertEqual(partSize(partURL), 7, "the partial file must hold exactly the 7 bytes served")
        let presentAfterFailure = await store.isPresent(engineID: engineID, version: version)
        XCTAssertFalse(presentAfterFailure, "a failed run must not be present")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(ModelStore.markerFileName).path),
            "a failed run must never commit")

        // The next run, with a healthy transport: it must resume from 7, not restart from zero.
        let healthy = StubTransport(files: ["weights.bin": weights])
        try await store.downloadIfMissing(manifest: manifest, transport: healthy)

        let ranges = await healthy.recordedRangeStarts
        XCTAssertEqual(
            ranges, [7],
            "the resuming run must ask for a Range starting at the partial file's size, got \(ranges)")
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("weights.bin")),
            Data(weights),
            "resume must assemble the file exactly: 7 bytes kept plus the 3-byte remainder")
        let present = await store.isPresent(engineID: engineID, version: version)
        XCTAssertTrue(present)
    }

    /// Cancelling mid-transfer surfaces `.interrupted`, preserves the partial file, and the next
    /// run resumes from it.
    func testCancellationPreservesThePartialFileAndTheNextRunResumes() async throws {
        let root = makeRoot()
        let store = makeStore(root: root)
        let weights = bytes(String(repeating: "x", count: 2_000))
        let manifest = makeManifest(files: [
            ManifestFile(name: "weights.bin", sha256: sha256Hex(weights), byteCount: weights.count),
        ])
        let stub = StubTransport(files: ["weights.bin": weights])
        let directory = versionDirectory(under: root)
        let partURL = directory.appendingPathComponent("weights.bin.part")

        let task = Task { try await store.downloadIfMissing(manifest: manifest, transport: stub) }

        // Wait until bytes are actually on disk, then cancel while the transfer is in flight.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if partSize(partURL) ?? 0 > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("a cancelled download must throw")
        } catch {
            guard case ModelDownloadError.interrupted = error else {
                XCTFail("a cancelled download must surface as .interrupted, got \(error)")
                return
            }
        }

        let preserved = partSize(partURL)
        XCTAssertNotNil(preserved, "the partial file must survive cancellation")
        XCTAssertGreaterThan(
            preserved ?? 0, 0,
            "cancellation must happen mid-transfer, not before it started")
        XCTAssertLessThan(
            preserved ?? .max, weights.count,
            "cancellation must happen mid-transfer, not after it finished")
        let presentAfterCancel = await store.isPresent(engineID: engineID, version: version)
        XCTAssertFalse(presentAfterCancel)

        // The next run resumes from the preserved size.
        let resuming = StubTransport(files: ["weights.bin": weights])
        try await store.downloadIfMissing(manifest: manifest, transport: resuming)

        let ranges = await resuming.recordedRangeStarts
        XCTAssertEqual(
            ranges, [preserved],
            "the resuming run must ask for a Range starting at the preserved partial size, got \(ranges)")
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("weights.bin")),
            Data(weights))
        let present = await store.isPresent(engineID: engineID, version: version)
        XCTAssertTrue(present)
    }

    // MARK: - Verification and retry

    /// A transport whose bytes can never match the manifest digest is restarted from zero on every
    /// attempt — never resumed — and after the restart limit the downloader gives up, loudly, with
    /// the file named.
    ///
    /// This test calls the downloader directly because the store maps the exhausted-retry error
    /// onto its own vocabulary (`ModelStoreTests` pins that mapping).
    func testCorruptBytesRestartFromZeroAndExhaustTheRetryLimit() async throws {
        let root = makeRoot()
        let directory = root.appendingPathComponent("v", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let weights = bytes("0123456789")
        let file = ManifestFile(name: "weights.bin", sha256: sha256Hex(weights), byteCount: weights.count)
        let stub = StubTransport(files: ["weights.bin": weights], mode: .corruptBytes)
        let downloader = ModelDownloader(restartLimit: 2)

        do {
            try await downloader.downloadFile(file, into: directory, using: stub)
            XCTFail("corrupt bytes must never pass verification")
        } catch {
            guard case ModelDownloadError.retryLimitExceeded(let failed) = error else {
                XCTFail("exhausted retries must surface as .retryLimitExceeded, got \(error)")
                return
            }
            XCTAssertEqual(failed, "weights.bin")
        }

        let ranges = await stub.recordedRangeStarts
        XCTAssertEqual(
            ranges, [0, 0, 0],
            "a corrupt file must restart from zero on every attempt — resume is for partial data, not wrong data — got \(ranges)")
    }

    /// A downloader configured with no restarts reports the first checksum mismatch directly —
    /// the `.checksumMismatch` case is reachable, not decorative.
    func testChecksumMismatchSurfacesDirectlyWithoutRestarts() async throws {
        let root = makeRoot()
        let directory = root.appendingPathComponent("v", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let weights = bytes("0123456789")
        let file = ManifestFile(name: "weights.bin", sha256: sha256Hex(weights), byteCount: weights.count)
        let stub = StubTransport(files: ["weights.bin": weights], mode: .corruptBytes)
        let downloader = ModelDownloader(restartLimit: 0)

        do {
            try await downloader.downloadFile(file, into: directory, using: stub)
            XCTFail("corrupt bytes must never pass verification")
        } catch {
            guard case ModelDownloadError.checksumMismatch(let failed) = error else {
                XCTFail("with no restarts the first mismatch must surface as .checksumMismatch, got \(error)")
                return
            }
            XCTAssertEqual(failed, "weights.bin")
        }
    }

    /// A corrupt download through the real store maps onto the store's own error contract and
    /// leaves no marker. The corrupt `.part` is *discarded*, not preserved: wrong bytes are not
    /// resume material — the spec's rule is "corrupt bytes → the .part is deleted, the file
    /// restarts from zero" — so the next run fetches the file from scratch.
    func testACorruptDownloadThroughTheStoreLeavesNoMarkerAndDiscardsTheCorruptPartial() async throws {
        let root = makeRoot()
        let store = makeStore(root: root)
        let weights = bytes("0123456789")
        let manifest = makeManifest(files: [
            ManifestFile(name: "weights.bin", sha256: sha256Hex(weights), byteCount: weights.count),
        ])
        let stub = StubTransport(files: ["weights.bin": weights], mode: .corruptBytes)

        do {
            try await store.downloadIfMissing(manifest: manifest, transport: stub)
            XCTFail("corrupt bytes must never pass verification")
        } catch {
            XCTAssertEqual(
                error as? ModelStoreError, .checksumMismatch(file: "weights.bin"),
                "the store must surface the exhausted-retry failure as its own checksum error")
        }

        let directory = versionDirectory(under: root)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(ModelStore.markerFileName).path),
            "a failed download must never commit")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("weights.bin.part").path),
            "a corrupt partial must be discarded, never kept as resume material")
        let present = await store.isPresent(engineID: engineID, version: version)
        XCTAssertFalse(present)
    }

    // MARK: - A transport that refuses resume

    /// A transport that ignores Range (serves the full body, appended to whatever is already
    /// there) cannot be resumed into: the misaligned file's size cannot equal `byteCount`, so the
    /// downloader detects the refusal, restarts the file from zero once, and commits the correct
    /// bytes — a misaligned append must be impossible, and the refusal is visible in the range
    /// ledger: [partial size, 0].
    func testAResumeRefusingTransportRestartsOnceAndCommits() async throws {
        let root = makeRoot()
        let store = makeStore(root: root)
        let weights = bytes("0123456789")
        let manifest = makeManifest(files: [
            ManifestFile(name: "weights.bin", sha256: sha256Hex(weights), byteCount: weights.count),
        ])
        // Seed a partial file as a previous run left it.
        let directory = versionDirectory(under: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(weights.prefix(3)).write(to: directory.appendingPathComponent("weights.bin.part"))

        let stub = StubTransport(files: ["weights.bin": weights], mode: .ignoresRange)
        try await store.downloadIfMissing(manifest: manifest, transport: stub)

        let ranges = await stub.recordedRangeStarts
        XCTAssertEqual(
            ranges, [3, 0],
            "a refused resume must restart from zero exactly once, got \(ranges)")
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("weights.bin")),
            Data(weights),
            "the committed file must be the source bytes exactly — never a misaligned append")
        let present = await store.isPresent(engineID: engineID, version: version)
        XCTAssertTrue(present)
    }

    // MARK: - Nested paths (the SDK repo tree's shape)

    /// Nested manifest names land in the intermediate directories they name, and a transfer that
    /// dies mid-file resumes across them: the `.part` sits two levels deep, and the next run asks
    /// for a Range starting at its size.
    func testNestedNamesCreateIntermediateDirectoriesAndResumeAcrossThem() async throws {
        let root = makeRoot()
        let store = makeStore(root: root)
        let mil = bytes("0123456789")
        let manifest = makeManifest(files: [
            ManifestFile(
                name: "Encoder.mlmodelc/Deep/model.mil",
                sha256: sha256Hex(mil), byteCount: mil.count),
        ])
        let failing = StubTransport(
            files: ["Encoder.mlmodelc/Deep/model.mil": mil],
            mode: .failsFirstAttempt(afterBytes: 7))

        do {
            try await store.downloadIfMissing(manifest: manifest, transport: failing)
            XCTFail("a transfer that dies after 7 bytes must fail the run")
        } catch {
            guard case ModelDownloadError.transportFailed = error else {
                XCTFail("a dead transfer must surface as .transportFailed, got \(error)")
                return
            }
        }

        let partURL = versionDirectory(under: root)
            .appendingPathComponent("Encoder.mlmodelc/Deep/model.mil.part")
        XCTAssertEqual(
            partSize(partURL), 7,
            "the nested partial must hold exactly the 7 bytes served, in its named directory")

        let healthy = StubTransport(files: ["Encoder.mlmodelc/Deep/model.mil": mil])
        try await store.downloadIfMissing(manifest: manifest, transport: healthy)

        let ranges = await healthy.recordedRangeStarts
        XCTAssertEqual(
            ranges, [7],
            "the resuming run must resume the nested file from the partial size, got \(ranges)")
        let finalURL = versionDirectory(under: root)
            .appendingPathComponent("Encoder.mlmodelc/Deep/model.mil")
        XCTAssertEqual(try Data(contentsOf: finalURL), Data(mil))
        let present = await store.isPresent(engineID: engineID, version: version)
        XCTAssertTrue(present)
    }
}
