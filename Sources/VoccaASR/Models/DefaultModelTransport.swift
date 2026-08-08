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

/// The one file in `Sources/` permitted to name `URLSession` — the network half of the
/// zero-network claim (`ARCHITECTURE.md:16`, amended by this capability).
///
/// Everything *decided* about a download — resume, verify, retry, refusal detection,
/// cancellation, progress — lives above the ``ModelTransport`` seam, in ``ModelDownloader``.
/// This type is the adapter: it resolves a manifest file name against a base URL, speaks
/// HTTP, and writes bytes to disk. It contains no decisions, which is why CI never executes
/// a line of it (the seam's stub drives every test) and why that is acceptable — the H7
/// lesson applied to the network (`HotkeySeamBoundaryTests`).
///
/// Contract, mirroring the seam's:
/// - **Ranged.** A transfer from `rangeStart > 0` sends `Range: bytes=<rangeStart>-` and
///   *appends* to the destination; a transfer from zero truncates and writes the body. A
///   server that ignores the range serves the full body, which the caller's size check
///   detects (`ModelDownloader`'s refusal path) — never assembled into a committed file.
/// - **Streaming.** The async-bytes API is consumed chunk by chunk and written to disk as it
///   arrives. The Parakeet artifact is ~2 GB (`ROADMAP.md:14`); the body is never buffered.
/// - **Cancellation.** A cancelled transfer surfaces as `CancellationError` (translated from
///   `URLError.cancelled`), which the downloader maps onto ``ModelDownloadError/interrupted``.
public struct DefaultModelTransport: ModelTransport {

    /// Where manifest file names resolve to — the base URL of the model repository's file
    /// tree (e.g. the Hugging Face `resolve/main` URL of the model repo). The engine binding
    /// (`parakeet-engine`) configures this; the type itself stays engine-agnostic.
    public let baseURL: URL

    /// The session used for transfers. Injected so a caller can supply an ephemeral or
    /// custom-configured session; defaults to the shared one.
    public let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func download(
        file name: String,
        fromRangeStart rangeStart: Int,
        to destination: URL,
        onBytesWritten: (@Sendable (Int) -> Void)?
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(name))
        if rangeStart > 0 {
            request.setValue("bytes=\(rangeStart)-", forHTTPHeaderField: "Range")
        }

        do {
            let (bytes, _) = try await session.bytes(for: request)

            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: destination.path) {
                fileManager.createFile(atPath: destination.path, contents: nil)
            }
            let handle = try FileHandle(forUpdating: destination)
            defer { try? handle.close() }
            if rangeStart == 0 {
                try handle.truncate(atOffset: 0)
            }
            try handle.seekToEnd()

            // The async-bytes stream yields individual bytes (`AsyncBytes.Iterator.Element` is
            // `UInt8` on this SDK), so they are batched into 1 MiB flushes: one write per flush
            // instead of one per byte, with the body never buffered whole.
            var written = 0
            var buffer = Data()
            buffer.reserveCapacity(1_048_576)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == 1_048_576 {
                    try handle.write(contentsOf: buffer)
                    written += buffer.count
                    onBytesWritten?(written)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                onBytesWritten?(written)
            }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }
}
