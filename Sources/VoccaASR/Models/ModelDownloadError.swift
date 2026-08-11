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

/// Why a model file did not reach the store.
///
/// The vocabulary of the downloader — the layer between the transport seam and the store's
/// commit. Every case leaves the store in a state where ``ModelStore/isPresent(engineID:version:)``
/// is false: a failure may leave a `.part` file (the next run's resume material) but never a
/// marker, so no failure state is silently "present".
///
/// Not `Equatable`: ``ModelDownloadError/transportFailed(underlying:)`` carries an arbitrary
/// `Error`, which cannot participate in equality. Tests pattern-match the other cases, which
/// carry the failing file's name.
public enum ModelDownloadError: Error, Sendable {
    /// The transport failed. The underlying error is whatever the transport threw; the `.part`
    /// file — if any bytes were written before the failure — is preserved for the next run's
    /// resume.
    case transportFailed(underlying: any Error)
    /// The downloaded bytes did not match the manifest digest and the downloader was configured
    /// with no restarts (`restartLimit == 0`) — the first mismatch is reported directly.
    case checksumMismatch(file: String)
    /// A resumed transfer produced a file of the wrong size — the transport served the full body
    /// despite the requested range, and even the restart-from-zero recovery failed to produce a
    /// correctly sized file. A misaligned append must never be assembled into a "complete" model.
    case resumeRefused(file: String)
    /// A local file operation failed (creating, opening, or hashing the `.part` file).
    case diskWriteFailed(file: String)
    /// The transfer was cancelled. The `.part` file is preserved; the next run resumes from it.
    case interrupted
    /// The file's bytes never matched the manifest digest across the configured number of
    /// restarts. The file is named so the caller can say which file of the artifact failed.
    case retryLimitExceeded(file: String)
}
