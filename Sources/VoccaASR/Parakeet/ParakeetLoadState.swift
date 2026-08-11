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

/// The load-once bookkeeping for the engine's `prepare()` — a pure struct, so the "second
/// `prepare` does not reload" rule is testable without a model on disk.
///
/// Warm load-once is the C2 promise (`CAPABILITY_ROADMAP.md:58`, amended): the model loads at
/// first use and stays resident; launch preload is C7's. This type records the two facts the
/// engine's `prepare` runs on — has the model loaded, and how many attempts the ledger shows —
/// and nothing else. The engine calls ``beginAttempt()`` before the (injected) load and
/// ``complete()`` or ``fail()`` after it; a failed attempt leaves ``hasLoaded`` false so the
/// next `prepare` retries (a missing model is an honest `modelUnavailable`, not a permanent
/// dead end).
public struct ParakeetLoadState: Sendable {
    /// Whether a load has completed successfully — the gate the second `prepare` skips.
    public private(set) var hasLoaded = false

    /// How many load attempts the ledger records, successful or not.
    public private(set) var loadAttempts = 0

    public init() {}

    /// Records the start of a load attempt. Called exactly once per attempt, before it.
    public mutating func beginAttempt() {
        loadAttempts += 1
    }

    /// Marks the attempt's load as completed successfully. Only this sets ``hasLoaded``.
    public mutating func complete() {
        hasLoaded = true
    }

    /// Marks the attempt's load as failed. ``hasLoaded`` stays false — the next `prepare`
    /// must be allowed to retry.
    public mutating func fail() {
        // hasLoaded is untouched by design: a failed load must never read as a ready engine.
    }
}
