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

/// The one seam through which model bytes enter the machine — the downloader's side of the
/// zero-network claim.
///
/// This aspect builds the seam now, before any implementation, so the store's tests can drive a
/// stub through the real protocol; `DefaultModelTransport` (Phase 2) is the one file in
/// `Sources/` permitted to name `URLSession`, and the H7-shaped confinement lint (`spec.md:70-71`)
/// makes that a build failure elsewhere rather than an aspiration.
///
/// The contract is deliberately minimal — one method, ranged, streaming, byte-counted — because
/// every *decision* about a download (resume, verify, retry, cancel, progress) belongs above this
/// seam, where tests can drive it:
///
/// - **Ranged.** `rangeStart` is where the transfer begins, which is how a retry resumes a
///   half-downloaded file instead of restarting it. A conformer that ignores `rangeStart` is
///   honest about it only by serving the full body — Phase 2's downloader detects and records that
///   (`spec.md:67-68`), and the caller must never assemble a file from a misaligned append.
/// - **Streaming.** The bytes are written into `destination` as they arrive. The Parakeet artifact
///   is ~2 GB (`ROADMAP.md:14`), so a conformer must never buffer a whole file in memory.
/// - **Byte-counted.** `onBytesWritten` reports the cumulative number of bytes written so far —
///   monotonic, and exactly the total once the download completes. It is how the downloader builds
///   aggregate progress without the seam knowing what "progress" means.
///
/// The seam names a file, not a URL: resolving the name to a remote address is the conformer's
/// business, which keeps the store independent of where models are served from.
public protocol ModelTransport: Sendable {
    /// Streams one manifest file into a destination file.
    ///
    /// - Parameters:
    ///   - name: The manifest's `ManifestFile.name` — the file's identity within its version.
    ///   - rangeStart: The byte offset at which to begin the transfer, `0` meaning the whole file.
    ///     A conformer is expected to resume by appending from this offset; the caller (Phase 2's
    ///     downloader) is responsible for the destination already holding `rangeStart` bytes, and
    ///     for detecting a conformer that served the full body anyway.
    ///   - destination: The file the downloaded bytes are written into. The caller writes to a
    ///     `.part` file so that an incomplete download can never be mistaken for a committed file.
    ///   - onBytesWritten: Called with the cumulative number of bytes written so far; `nil` when
    ///     the caller does not need progress. Values are monotonic, and the final call reports the
    ///     total byte count for the transfer.
    ///
    /// - Throws: Whatever the transport failed with. The downloader maps failures onto its own
    ///   error vocabulary; the seam itself carries no Vocca types.
    func download(
        file name: String,
        fromRangeStart rangeStart: Int,
        to destination: URL,
        onBytesWritten: (@Sendable (Int) -> Void)?
    ) async throws
}
