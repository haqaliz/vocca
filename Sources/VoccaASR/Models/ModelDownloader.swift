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

/// The per-file download engine: resume, verify, retry — every *decision* about a download,
/// standing on the ``ModelTransport`` seam.
///
/// ``ModelStore`` owns the manifest loop, the single-flight guard, and the atomic commit (rename
/// all, write the marker last); this type owns what happens to one file on its way there:
///
/// - **Resume.** If a `.part` file already exists, the transfer begins at its size — the bytes
///   already on disk are kept and only the remainder is fetched. A model is never re-downloaded
///   from zero because a previous attempt died.
/// - **Refusal detection.** A transport that ignores `Range` serves the full body, which a
///   resumed transfer would *append* to the partial file. The result cannot have the manifest's
///   `byteCount`, so the size check detects the refusal, discards the misaligned file, and
///   restarts from zero once. A misaligned append must never be assembled into a committed file.
/// - **Verification.** Every completed transfer is hashed against the manifest digest. A mismatch
///   discards the file and restarts from zero — bounded by ``restartLimit`` — because a file
///   whose bytes are wrong is not partial data that resume can repair.
/// - **Cancellation.** A cancelled transfer surfaces as ``ModelDownloadError/interrupted`` with
///   the `.part` file preserved — the next run resumes from it.
///
/// Transport errors are surfaced, not retried: a dead transfer ends the run (retrying a dead
/// transport with backoff is the PRD's S3, not this aspect's), and the `.part` it left is exactly
/// the resume material the next run needs.
public struct ModelDownloader: Sendable {

    /// How many times a file may be restarted from zero after verification (or refusal) failures,
    /// before the downloader gives up. The default, 2, means up to three attempts per file.
    public let restartLimit: Int

    public init(restartLimit: Int = 2) {
        precondition(restartLimit >= 0, "a negative restart limit is a caller bug")
        self.restartLimit = restartLimit
    }

    /// Downloads one manifest file into a version directory, verifying it before returning.
    ///
    /// - Parameters:
    ///   - file: The manifest entry — the digest and size the download is verified against.
    ///   - directory: The version directory (`<root>/<engineID>/<version>/`); the file is written
    ///     as `<name>.part` there.
    ///   - transport: The seam the bytes come through.
    ///   - onBytesWritten: The cumulative number of bytes written by the *current* transfer call,
    ///     monotonic within it. `nil` when progress is not needed.
    ///
    /// - Throws: ``ModelDownloadError``. On any throw, the `.part` file on disk is either the
    ///   resume material for the next run (interrupted or dead transfer) or a corrupt file the
    ///   next run will restart (mismatch paths). It never resembles a committed file.
    public func downloadFile(
        _ file: ManifestFile,
        into directory: URL,
        using transport: any ModelTransport,
        onBytesWritten: (@Sendable (Int) -> Void)? = nil
    ) async throws {
        let partURL = directory.appendingPathComponent(file.name + ".part")
        // Names may be nested (`"Encoder.mlmodelc/model.mil"` — the SDK repo tree's shape), so
        // the intermediate directories must exist before the transport opens the file. The
        // version root already exists (the store creates it); only the nested levels are new.
        do {
            try FileManager.default.createDirectory(
                at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw ModelDownloadError.diskWriteFailed(file: file.name)
        }
        let expectedDigest = file.sha256.lowercased()
        var rangeStart = Self.existingSize(of: partURL)
        var restarts = 0

        while true {
            do {
                try await transport.download(
                    file: file.name,
                    fromRangeStart: rangeStart,
                    to: partURL,
                    onBytesWritten: onBytesWritten)
            } catch let error as CancellationError {
                throw ModelDownloadError.interrupted
            } catch {
                throw ModelDownloadError.transportFailed(underlying: error)
            }

            let size = Self.existingSize(of: partURL)
            if rangeStart > 0 && size != file.byteCount {
                // The transfer that was asked to resume produced a file that is not the model.
                // Either the transport ignored the range (and appended the full body) or the
                // source changed; in both cases the file is misaligned and cannot be repaired by
                // appending to it. Discard and restart from zero — once.
                try? FileManager.default.removeItem(at: partURL)
                guard restarts < restartLimit else {
                    throw ModelDownloadError.resumeRefused(file: file.name)
                }
                restarts += 1
                rangeStart = 0
                continue
            }

            let digest: String
            do {
                digest = try Self.sha256Hex(ofFileAt: partURL)
            } catch {
                throw ModelDownloadError.diskWriteFailed(file: file.name)
            }
            if digest == expectedDigest {
                return
            }

            // Wrong bytes. This is not partial data resume can repair — the file is corrupt, not
            // short — so it is discarded and fetched from zero, at most restartLimit times. With
            // no restarts configured, the first mismatch is reported directly; otherwise the
            // exhausted state names the failure as retries run out.
            try? FileManager.default.removeItem(at: partURL)
            guard restarts < restartLimit else {
                throw restarts == 0
                    ? ModelDownloadError.checksumMismatch(file: file.name)
                    : ModelDownloadError.retryLimitExceeded(file: file.name)
            }
            restarts += 1
            rangeStart = 0
        }
    }

    /// The size of an existing `.part` file — the resume anchor — or 0 when it does not exist.
    private static func existingSize(of url: URL) -> Int {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.intValue
    }

    /// The SHA-256 of a file as 64 lowercase hex characters, read in chunks.
    ///
    /// The artifact is ~2 GB (`ROADMAP.md:14`), so the file is never buffered whole; the hasher is
    /// fed 1 MiB at a time through CryptoKit's `HashFunction` incremental API.
    private static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
