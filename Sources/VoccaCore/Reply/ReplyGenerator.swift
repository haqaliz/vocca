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

/// The pluggable reply boundary (`dual-mode` PRD R7, `CAPABILITY_ROADMAP.md:414` — the seam
/// doctrine's two-implementations guardrail): the text a committed `.conversing` turn is
/// answered with.
///
/// The seam is the plainest possible boundary: **input is the cleaned transcript text** — the
/// wiring runs ASR and per-mode cleanup before the generator, so this seam's input arrives
/// already cleaned, never the utterance frames (`[AudioBuffer]`) and never a `Transcript`
/// (attribution and completeness the reply has no use for) — and **output is the text handed
/// to the loop's `scheduleReply`**, which is `String`-typed by the loop's own vocabulary
/// (`TurnTakingLoop.scheduleReply(_ text: String)`, `TurnEffect.speakReply(text:)`), so no
/// wrapper type is needed.
///
/// The call is **synchronous and deterministic**: reply generation runs once per committed
/// turn, at a decision point, off the per-frame path — an actor hop at a decision point buys
/// nothing for the deterministic stand-ins, and if C13's real agent forces an async leg that
/// is a C13 signature reconsideration, recorded here rather than added now (the
/// frozen-signature doctrine). No identity either: a reply text is consumed immediately by
/// `scheduleReply` and rendered — nothing downstream attributes it.
///
/// Two deterministic, local, zero-network implementations ship behind this seam
/// (`CAPABILITY_ROADMAP.md:414`):
///
/// - ``EchoReplyGenerator`` — the wired default: the user's own words back, byte-for-byte;
/// - ``AcknowledgmentReplyGenerator`` — the fixed copy `"Vocca is listening."`.
///
/// Neither claims to be an agent: the default plays your words back (the strongest "the loop
/// heard you" signal), and the acknowledgment states the mode's own honest state. **C13's real
/// agent replaces the deterministic stand-in behind the same seam** (`prd.md:106-109`) — this
/// protocol is that slot.
public protocol ReplyGenerator: Sendable {

    /// The reply to the cleaned transcript text of a committed `.conversing` turn.
    ///
    /// - Parameter text: the cleaned transcript text, exactly as cleanup produced it for
    ///   `.conversing`.
    /// - Returns: the text to hand to the loop's `scheduleReply`. An empty reply is silence,
    ///   never an error — nothing to say is an answer.
    func reply(to text: String) -> String
}