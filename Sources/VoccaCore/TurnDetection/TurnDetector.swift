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

/// The pluggable turn-detection boundary (`ARCHITECTURE.md:262-263`): a scored
/// commit/keep-listening decision on a candidate pause, over the capture's own buffer type.
///
/// Every turn-detection adapter is this protocol and nothing else:
/// ``SilenceThresholdDetector`` (the pure fallback in `VoccaCore`, deterministic and headless
/// — CI's implementation) and the real EOU adapter (the `sdk-adapters` aspect, env-gated —
/// FluidAudio's `StreamingEouAsrManager`, whose EOU is a decoding byproduct the adapter
/// observes). The seam answers **one question per candidate pause** — did the speaker finish
/// their turn? — and the two buffers are the seam's only inputs.
///
/// ## The seam's contract
///
/// - **Synchronous, no actor hop.** `TurnDetector` runs once per candidate pause, at a
///   decision point, not over a stream — the barge-in loop is synchronous and owner-isolated
///   (the `SessionMachine` precedent). If the SDK forces an async adapter surface, that is the
///   `sdk-adapters` aspect's problem at its seam, not this one's.
/// - **Below the threshold keep listening, above it commit** (`CAPABILITY_ROADMAP.md:275`) —
///   a **scored** decision with a threshold, not a bare boolean. The 5×-weighted commitment
///   harness (`ARCHITECTURE.md:575`) consumes ``TurnScore/commitment``; the score is the
///   implementation's P(user-finished) proxy.
/// - **Stateless by signature.** The decision is over the two buffers passed in; the real EOU
///   adapter's internal history is its own business. `Sendable` end to end.
/// - **The seam never names an engine** — a caller drives the existential and cannot tell the
///   fallback from the EOU; the family lint (``VoiceDetectionSeamBoundaryTests``) confines
///   both implementations to their own files.
/// - **No identity.** The seam answers a yes/no question; attribution lives on the ASR/TTS
///   seams. If the loop needs attribution it can add it in `barge-in-loop` — recorded, not
///   added here.
///
/// The two seams (this one and ``VoiceActivityDetector``) are deliberately separate: the EOU
/// model replaces on a faster cycle than the VAD (`CAPABILITY_ROADMAP.md:282`).
public protocol TurnDetector: Sendable {
    /// Decides on a candidate pause: is the pause long enough, and the utterance it follows
    /// long enough, to commit the turn?
    ///
    /// - Parameter pause: the silence being scored. Its duration is the evidence.
    /// - Parameter utterance: the speech the pause follows. Its duration feeds the
    ///   not-a-bare-silence-timer guard in the fallback; the real EOU adapter reads its own
    ///   history instead.
    /// - Returns: the scored decision — `commitment` is the verdict the loop acts on.
    func decide(_ pause: AudioBuffer, utterance: AudioBuffer) -> TurnScore
}