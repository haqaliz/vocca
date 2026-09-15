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

/// The turn-taking loop's state vocabulary (`prd.md:136-142`, R6).
///
/// The conversation's trajectory: **listening** (continuous capture + VAD) → **uttering**
/// (speech accumulating) → **committed** (the turn detector fires) → reply scheduled →
/// **playing** (ducked, cancellable) → barge-in (VAD speech during playback → the owner
/// cancels within the ≤50 ms contract → the reply is discarded → the interrupting words are
/// preserved; the machine's utterance state is `.uttering` while capture — which never
/// stopped — keeps the continuity fact the PRD's "→ listening" means). `.idle` is the
/// stopped machine.
///
/// Exactly five cases, by design — a caller's switch is exhaustive today and breaks at
/// compile time if the vocabulary ever grows (the `plan_20260915.md` compile pin). `Sendable +
/// Equatable`: the state crosses to the owner's surface (the N1 hook's payload).
public enum TurnState: Sendable, Equatable {
    /// The loop is stopped — capture is the owner's, closed by the `.stopped` effect.
    case idle

    /// Continuous capture + VAD, no turn in progress. Speech evidence flips to `.uttering`.
    case listening

    /// Speech is accumulating into the turn's utterance.
    case uttering

    /// The turn detector committed — the utterance was handed over, a reply is pending.
    case committed

    /// A reply is being rendered: the window is open, the echo gate is armed, and a speech
    /// frame barges in.
    case playing
}