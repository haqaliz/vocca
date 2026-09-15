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

/// The turn-taking loop's effect vocabulary — what the machine hands back to its owner.
///
/// The loop is synchronous and owner-isolated (the `SessionMachine` precedent): it never
/// touches a microphone, a synthesizer or a playback engine. Every one of those touches is
/// this vocabulary, applied by the owner. The effect ledger is the loop's only observable
/// output besides ``TurnState`` and the counters.
///
/// - ``started``/``stopped``: the owner opens/closes the continuous capture.
/// - ``speechBegan``: the VAD flipped — an utterance is accumulating.
/// - ``turnCommitted(utterance:)``: the turn detector fired — exactly the speech frames,
///   never the pause frames, are handed over for the reply generator.
/// - ``speakReply(text:)``: the owner should render the reply (the loop names no engine —
///   the synthesizer is the owner's).
/// - ``bargeIn``: defined by the **≤50 ms cancel contract** — the owner must call
///   `synthesizer.cancel()` within the budget, duck via `playback.cancelToSilence()`, and
///   discard the reply: "a barge-in that leaks the tail of the utterance is a barge-in that
///   does not work".
/// - ``captureFailed``: the capture stream died — the loop entered `.idle` and owes no
///   transcript hand-over (the voice loop's stop-path rationale).
///
/// Exactly seven cases, by design — a caller's switch is exhaustive today and breaks at
/// compile time if the vocabulary ever grows. `Sendable + Equatable`: effects cross to the
/// owner (who may be an actor).
public enum TurnEffect: Sendable, Equatable {
    /// The loop started — the owner should open the continuous capture.
    case started

    /// The loop stopped — the owner should close the continuous capture.
    case stopped

    /// The VAD flipped — a new utterance is accumulating.
    case speechBegan

    /// The turn detector fired: the utterance (exactly the speech frames) is committed.
    case turnCommitted(utterance: [AudioBuffer])

    /// The owner should render this reply text (the loop never names an engine).
    case speakReply(text: String)

    /// VAD speech during playback: cancel within ≤50 ms, duck, discard the reply.
    case bargeIn

    /// The capture stream failed — the loop is `.idle`, nothing is owed.
    case captureFailed
}