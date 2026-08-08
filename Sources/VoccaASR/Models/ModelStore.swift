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
import Synchronization

/// Why a model download did not complete.
///
/// Phase 1's vocabulary is one case: the store verifies and a mismatch is the store's own finding.
/// Phase 2 adds the transport's failures, resume refusals and retry exhaustion
/// (`spec.md:69`); every case must leave the store in a state where `isPresent` is false — no
/// failure state is silently "present".
public enum ModelStoreError: Error, Equatable, Sendable {
    /// A downloaded file's bytes did not match the manifest's digest for it.
    case checksumMismatch(file: String)
}

/// The presence truth for downloaded models: whether a version is on disk, and *verified*.
///
/// `isPresent` means "present and verified", never "a directory exists" (`spec.md:44-45`). The
/// commit is atomic: every file is downloaded to `<name>.part` (by the injected
/// ``ModelDownloader``, which owns resume, verification and retry), every checksum is checked
/// *there*, and only then are the `.part` files renamed to their final names and the verified
/// marker written — **last**, so presence (the marker) and completeness (the files) can never be
/// observed apart. A `.part` file anywhere in the version directory means a download is in flight
/// or incomplete, and in-flight is never present.
///
/// The store is an **actor**: concurrent `downloadIfMissing` calls for the same version are
/// single-flight — one download, and the second caller awaits the in-flight one rather than
/// starting a second. And a verified version is immutable (`PRODUCT_SPEC.md:273`): once the
/// marker exists, `downloadIfMissing` returns without touching the directory.
public actor ModelStore {

    /// The marker file whose existence is the commit record: it is written only after every file's
    /// checksum passed, and it is written last.
    public static let markerFileName = "verified"

    /// The root of the model tree: `<root>/<engineID>/<version>/` holds each version's files.
    ///
    /// Injected, never hardcoded — the no-argument initializer computes the default from
    /// `FileManager`.
    public let rootURL: URL

    /// The per-file download engine: resume, verify, retry. Injected so the downloader's own
    /// contract can be pinned independently of the store's.
    public let downloader: ModelDownloader

    /// The download currently in flight, if any — the one-flight guard. A second call that arrives
    /// while this is set awaits it and returns; it is cleared on success *and* on failure, so a
    /// failed download never poisons the next attempt.
    private var inFlightDownload: Task<Void, Error>?

    public init(rootURL: URL, downloader: ModelDownloader = ModelDownloader()) {
        self.rootURL = rootURL
        self.downloader = downloader
    }

    /// The default root: `Application Support/Vocca/models`, computed from `FileManager` — never a
    /// hardcoded path.
    ///
    /// The force unwrap is safe by contract: `urls(for:in:)` always returns at least the
    /// standard directory on macOS, and this initializer is a convenience — every test and every
    /// injection point passes an explicit root.
    public init() {
        let applicationSupport =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.init(
            rootURL: applicationSupport
                .appendingPathComponent("Vocca", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true))
    }

    /// The directory for a model version: `<root>/<engineID>/<version>/`.
    ///
    /// This is the load-from-URL hook `parakeet-engine` consumes (`spec.md:56-58`): the URL a
    /// verified model is loaded from. Both components are joined as directories, so appending a
    /// manifest file name never produces a doubled separator.
    public func baseURL(for engineID: String, version: String) -> URL {
        rootURL
            .appendingPathComponent(engineID, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    /// Whether a model version is present **and verified**.
    ///
    /// True only when the verified marker exists and no `.part` file exists anywhere in the
    /// version directory. A directory that holds every file but no marker reads as absent — the
    /// marker is the commit record, and files without it may be a half-verified download.
    public func isPresent(engineID: String, version: String) -> Bool {
        let directory = baseURL(for: engineID, version: version)
        let fileManager = FileManager.default
        guard
            fileManager.fileExists(atPath: directory.path),
            fileManager.fileExists(
                atPath: directory.appendingPathComponent(Self.markerFileName).path)
        else { return false }

        // `.part` files are the in-flight mark, and they win over a marker: an interrupted commit
        // must never read as a ready model.
        let entries =
            (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            ?? []
        return !entries.contains { $0.lastPathComponent.hasSuffix(".part") }
    }

    /// Downloads a model version if it is not already present and verified — and never otherwise.
    ///
    /// Single-flight: concurrent calls for the same version share one download. The actor
    /// serialises the calls, but the *guard* matters because the actor is reentrant: the second
    /// call runs while the first is suspended inside the transport, and without this guard it
    /// would start a second download of the same version. With the guard it awaits the in-flight
    /// download and returns — the second call never touches the directory.
    ///
    /// The per-file work (resume, verify, retry) is ``ModelDownloader``'s; this method owns the
    /// loop, the byte-weighted aggregate progress, and the commit.
    ///
    /// - Parameters:
    ///   - onProgress: Called with the aggregate fraction of all bytes written so far, monotonic
    ///     non-decreasing, exactly `1.0` once every byte of every file is on disk. The value is
    ///     byte-weighted across the manifest's files.
    ///
    /// - Throws: ``ModelStoreError`` when verification fails (the downloader's exhausted-retry and
    ///   mismatch errors map onto it — the store's contract, pinned in `ModelStoreTests`); the
    ///   downloader's own error otherwise. Either way the store is left not present, with `.part`
    ///   files for the next run's resume.
    public func downloadIfMissing(
        manifest: ModelManifest,
        transport: any ModelTransport,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        if isPresent(engineID: manifest.engineID, version: manifest.version) {
            return
        }
        if let inFlight = inFlightDownload {
            try await inFlight.value
            return
        }
        let task = Task {
            try await self.performDownload(
                manifest: manifest, transport: transport, onProgress: onProgress)
        }
        inFlightDownload = task
        defer { inFlightDownload = nil }
        // The internal task is unstructured, so the caller's cancellation does not reach it by
        // inheritance. This handler bridges that gap: cancelling the caller cancels the in-flight
        // download, which surfaces as ModelDownloadError.interrupted with the .part preserved.
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The download-verify-commit cycle, run once per `downloadIfMissing`.
    ///
    /// Commit ordering is the atomicity claim: every file is downloaded and verified first, then
    /// all `.part` files are renamed to their final names, then the marker is written — last.
    private func performDownload(
        manifest: ModelManifest,
        transport: any ModelTransport,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws {
        let directory = baseURL(for: manifest.engineID, version: manifest.version)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let totalBytes = manifest.files.reduce(0) { $0 + $1.byteCount }
        // The per-file cumulative byte ledger, aggregated by max: a restarted file briefly
        // reports a smaller cumulative, and the aggregate must stay monotonic. The lock exists
        // because the progress callback fires on the transport's executor, not the actor's.
        let ledger = Mutex<[String: Int]>([:])
        for file in manifest.files {
            do {
                try await downloader.downloadFile(
                    file,
                    into: directory,
                    using: transport
                ) { written in
                    guard let onProgress, totalBytes > 0 else { return }
                    ledger.withLock { current in
                        current[file.name] = max(current[file.name] ?? 0, written)
                        let sum = current.values.reduce(0, +)
                        onProgress(Double(sum) / Double(totalBytes))
                    }
                }
            } catch ModelDownloadError.retryLimitExceeded(let failedFile) {
                throw ModelStoreError.checksumMismatch(file: failedFile)
            } catch ModelDownloadError.checksumMismatch(let failedFile) {
                throw ModelStoreError.checksumMismatch(file: failedFile)
            }
        }

        for file in manifest.files {
            let partURL = directory.appendingPathComponent(file.name + ".part")
            let finalURL = directory.appendingPathComponent(file.name)
            try FileManager.default.moveItem(at: partURL, to: finalURL)
        }
        try Data().write(to: directory.appendingPathComponent(Self.markerFileName))
    }
}
