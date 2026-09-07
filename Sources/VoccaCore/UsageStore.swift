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

/// The seam the daily-use ledger is written through and read back from — the store of the
/// recent ``UsageWindow``, separated from everything that folds sessions into it so the ledger
/// is testable without a file system (`usage-store/spec.md`). The protocol is the only Core
/// surface of the store; the decisions stay out of it — the store moves a window, it never
/// decides about one. Retention is ``UsageWindow``'s own rule and is applied on the way in, not
/// by the file.
///
/// ## Concurrency contract
///
/// Single process, one writer: ``load()`` once at launch, then the caller holds the window and
/// ``save(_:)`` persists the **whole window** atomically — a racing pair of saves ends with one
/// complete file, never a partial one, and the in-memory window is what carries the merged state
/// forward. Implementations are actors; the atomic rename means a concurrent read sees the old
/// or the new complete file.
///
/// ## Persistence contract
///
/// Mirrors ``InjectionStrategyStore``'s exactly, because the failure modes are the same ones:
/// ``load()`` never throws — a missing file is the empty window **silently** (a first run is not
/// an error), a corrupt day row is skipped with one loud log while the readable remainder loads,
/// and **a load never rewrites the file**. A whole file that cannot be read as this format at
/// all — not an object, an unknown version, or bucket bounds that are not the running build's —
/// loads as the empty window with one loud log, and is likewise left on disk untouched: a file
/// this build cannot interpret is not a file this build may overwrite. ``save(_:)`` throws when
/// the persist fails, so the caller can see and log that the window it holds is not the window
/// on disk.
///
/// ## Privacy constraint
///
/// A window carries counts, latency buckets and calendar days — no transcript text, no
/// wall-clock time, no audio, nothing content-shaped (`prd.md` M6). The vocabulary's own shape
/// is what keeps that promise, and the store must not widen it: anything this seam could carry
/// that ``UsageWindow`` cannot hold would be a privacy decision made below the seam.
public protocol UsageStore: Sendable {
    /// The window held, loaded from the store's backing (the empty window on first run).
    /// Never throws. For the persistent store: missing → empty silently; unreadable → empty with
    /// one loud log; a corrupt day row → the readable remainder with one loud log per skipped
    /// row; the file is never rewritten.
    func load() async -> UsageWindow

    /// Replace the persisted window with `window`, atomically. Throws when the persist fails —
    /// the file was *not* updated while the caller's window says it was, and the caller must be
    /// able to see and log that.
    func save(_ window: UsageWindow) async throws

    /// Forget everything: **delete the backing**, so that a later ``load()`` answers the empty
    /// window.
    ///
    /// Deletion rather than a save of the empty window, because the user was told deletion —
    /// `PRODUCT_SPEC.md:306` ("empties the window and deletes the file behind it") and the Usage
    /// tab's own Clear copy. On a page whose whole purpose is that the claim can be checked, a
    /// file left on disk that the copy says is gone is the one failure worth more than the bytes
    /// it saves.
    ///
    /// A backing that is not there is not a failure: nothing to delete is the outcome the caller
    /// asked for, and a first run has no file. Throws only when a file that *is* there could not
    /// be removed — the ``save(_:)`` contract, for the same reason: the caller's window says the
    /// history is gone and the disk disagrees, and only the caller can say so out loud.
    func clear() async throws
}
