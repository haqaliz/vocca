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

/// One step of a model download, as the UI sees it — the seam between `VoccaUI` (which may
/// import nothing but this module) and the store's machinery (which lives in `VoccaASR`).
///
/// `VoccaUI`'s module boundary rule is what makes this seam load-bearing: the download window
/// can never see a ``ModelStore``, so everything the user can observe about a download must
/// fit this vocabulary.
public enum ModelDownloadEvent: Sendable, Equatable {
    /// The aggregate fraction of all bytes written so far — monotonic, 0...1, reaching exactly
    /// 1.0 only when every file is on disk.
    case progress(Double)
    /// Every file downloaded, verified, and committed — the model is present.
    case committed
    /// The download failed. The payload is a human-readable cause (which file, what happened).
    case failed(String)
    /// The user cancelled (the Skip button). The partial file survives for the next attempt.
    case cancelled
}

/// The contract the download window consumes: an event stream and a cancel — nothing else.
///
/// ``ModelDownloadSession`` is owned here so the UI depends on the seam, not on the store.
/// ``VoccaASR/StoreModelDownloadSession`` is the first implementation; a hosted-tier download
/// manager would be a second, behind the same seam.
public protocol ModelDownloadSession: Sendable {
    /// The download's events, in order, terminating after `.committed`, `.failed` or
    /// `.cancelled`.
    var events: AsyncStream<ModelDownloadEvent> { get }

    /// Starts the download if it is not already in flight. Idempotent; safe to call before any
    /// consumer begins iterating ``events``.
    func start() async

    /// Cancels an in-flight download. The bytes already on disk (the `.part` files) are kept;
    /// the next attempt resumes from them. Safe to call at any time; a no-op after the stream
    /// has terminated.
    func cancel()
}
