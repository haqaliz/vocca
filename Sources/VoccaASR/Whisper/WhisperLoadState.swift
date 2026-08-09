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

/// The load-once bookkeeping for the engine's `prepare()` — a pure value, so the "second
/// `prepare` does not reload" rule is testable without a model on disk.
///
/// Warm load-once is the C2 promise (`CAPABILITY_ROADMAP.md:58`, amended): the model loads at
/// first use and stays resident; launch preload is C7's. This type records the three states the
/// engine's `prepare` runs on — nothing loaded yet, loaded and resident, or a failed load — with
/// the same transition shape as `ParakeetLoadState`: the engine calls ``beginAttempt()`` before
/// the (injected) load and ``complete()`` or ``fail()`` after it; a failed load lands on
/// ``failed`` (never read as ready), and the next `prepare` retries — a missing model is an
/// honest `modelUnavailable`, not a permanent dead end.
public enum WhisperLoadState: Sendable, Equatable {
    /// Nothing has loaded yet — the state before the first `prepare`, and the in-flight state of
    /// an attempt (an attempt that has neither completed nor failed is not yet any other state).
    case unloaded

    /// A load completed successfully; the model is resident. The only state `prepare` skips.
    case prepared

    /// The last load attempt failed; the next `prepare` retries from here.
    case failed

    /// Whether a load has completed successfully — the gate the second `prepare` skips.
    public var hasLoaded: Bool {
        self == .prepared
    }

    public init() {
        self = .unloaded
    }

    /// Records the start of a load attempt. Called exactly once per attempt, before it — and a
    /// no-op on a loaded engine: a re-`prepare` must never unload a resident model, even by
    /// passing through the in-flight state.
    public mutating func beginAttempt() {
        switch self {
        case .unloaded, .failed:
            self = .unloaded
        case .prepared:
            break
        }
    }

    /// Marks the attempt's load as completed successfully. Only this lands on ``prepared``.
    public mutating func complete() {
        self = .prepared
    }

    /// Marks the attempt's load as failed. ``hasLoaded`` stays false — the next `prepare` must be
    /// allowed to retry, and a completed load is never regressed to failed by a stray call.
    public mutating func fail() {
        switch self {
        case .unloaded:
            self = .failed
        case .prepared, .failed:
            break
        }
    }
}
