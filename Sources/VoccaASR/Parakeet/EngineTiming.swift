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

/// The local-only latency ledger (PRD S1): where the engine's timings live, never transmitted.
///
/// The engine measures cold-load, warm-transcribe and first-after-launch durations against the
/// injected ``MonotonicClock`` and records them here; C7's latency work reads the ledger instead
/// of re-measuring blind. There is no network name anywhere near this type by construction — and
/// the H8b lint makes that a build failure rather than an intention.
public actor EngineTiming {

    /// The three spans the ledger tracks (PRD S1).
    public enum Kind: Sendable, Hashable {
        /// The first model load (CoreML compile included) — the one-time cost the spike
        /// measured at ~281 s cold, 0.111 s warm.
        case coldLoad
        /// A transcription on a warm engine — the number C7's p50/p95 budget is built from.
        case warmTranscribe
        /// The first transcription after launch, measured separately so the warm-start claim
        /// (C7's "within 20% of steady-state") has its own column.
        case firstAfterLaunch
    }

    private var ledger: [Kind: [Duration]] = [:]

    public init() {}

    /// Appends one measurement. Durations are process-local differences (``MonotonicClock``'s
    /// contract), so only their magnitudes are meaningful — exactly what the ledger needs.
    public func record(_ kind: Kind, elapsed: Duration) {
        ledger[kind, default: []].append(elapsed)
    }

    /// The readings for one kind, in the order they were recorded.
    public func samples(for kind: Kind) -> [Duration] {
        ledger[kind] ?? []
    }
}
