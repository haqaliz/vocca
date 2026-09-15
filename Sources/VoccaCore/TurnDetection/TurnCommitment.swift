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

/// The turn-detection seam's verdict: has the speaker finished their turn, or is the loop
/// still listening?
///
/// Exactly two cases, by design — a caller's `switch` is exhaustive today and breaks at
/// compile time if the vocabulary ever grows (the `plan_20260915.md` compile pin). The
/// **scored** decision lives in ``TurnScore`` alongside this verdict: the 5×-weighted
/// commitment harness (`ARCHITECTURE.md:575`) consumes ``TurnScore/commitment`` — below the
/// threshold keep listening, above it commit (`CAPABILITY_ROADMAP.md:275`) — and both the
/// ``SilenceThresholdDetector`` fallback (pure, in `VoccaCore`) and the real EOU adapter
/// (`sdk-adapters`) answer through this vocabulary. Callers never branch on which one they
/// hold.
public enum TurnCommitment: Sendable, Hashable {
    /// The candidate pause was not enough — keep listening, no turn boundary yet.
    case keepListening

    /// The speaker's turn is over — commit the utterance and hand it to the loop.
    case commit
}