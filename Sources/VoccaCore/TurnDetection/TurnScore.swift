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

/// The turn-detection seam's scored decision: the implementation's P(user-finished) proxy
/// plus the verdict the loop acts on.
///
/// The score is **the implementation's own proxy** — `SilenceThresholdDetector` scores
/// `pause ÷ commitAfterPause`, the real EOU adapter (the `sdk-adapters` aspect) scores its own
/// model's confidence — so the score is comparable within one implementation, never across
/// them. What the loop and the 5×-weighted commitment harness consume is
/// ``TurnCommitment``/``commitment``: false cutoffs weigh 5× worse than late commits
/// (`ARCHITECTURE.md:575`, `ROADMAP.md:211`), and the harness scores commitments, ordered by
/// the score where it needs one.
///
/// Plain data, `Sendable + Hashable` — a scored decision with a threshold, not a bare boolean
/// (`CAPABILITY_ROADMAP.md:275`).
public struct TurnScore: Sendable, Hashable {
    /// The implementation's P(user-finished) proxy. ≥ 0; 0 means "no evidence of a turn end".
    public let score: Double

    /// The verdict the loop acts on: below the threshold keep listening, at or above it commit.
    public let commitment: TurnCommitment

    public init(score: Double, commitment: TurnCommitment) {
        self.score = score
        self.commitment = commitment
    }
}