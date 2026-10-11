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

/// The seam completed CONVERSING turns are recorded through — the bounded, purged recent-turn
/// history, separated from the driver that decides when a turn is owed so recording is testable
/// without a file system (`history-store/spec.md` H2). The protocol is the only Core surface of
/// the store; the decisions — the caps, the oldest-first eviction, the atomic commit — stay in
/// the adapter module, never below this seam: the store moves turns, it never decides about one.
///
/// ## When a turn is recorded
///
/// A turn is recorded when its reply is committed to speak (the driver's `.speakReply` effect);
/// a subsequent barge-in marks **that** turn interrupted — never a neighbor's. Turns whose ASR
/// or reply failed are not recorded at all: the turn was never owed (`prd.md` Goals). The driver
/// hook is additive and defaulted to a no-op, so probes and existing tests are byte-identical
/// when it is unwired.
///
/// ## Concurrency contract
///
/// Single process, one writer; implementations are actors. A record is append-only from the
/// caller's point of view — order is the only metadata, and the store's own caps decide what
/// survives.
///
/// ## Failure contract
///
/// **`async`, never `async throws`** — the `local-data-provider` lesson: a failed record must
/// not interrupt the conversation. A store failure is a value the implementation logs; the
/// caller never sees a thrown error from a speak path. The same holds for the barge-in mark.
///
/// Stdlib-only by design: this file is the seam's home in `VoccaCore`, whose import allow-list
/// is empty (`CoreBoundaryTests`).
public protocol ConversationRecording: Sendable {
    /// Append one completed turn: the cleaned utterance and the reply that was committed to
    /// speak, in that order. The turn is new, so it is not interrupted yet. Never throws —
    /// whatever the backing does (bounding, evicting, failing to persist) is the
    /// implementation's to log, not the conversation's to survive.
    func recordTurn(utterance: String, reply: String) async

    /// Mark the most recent recorded turn **interrupted** — the barge-in mark, addressed to the
    /// turn whose reply was playing by the only thing that knows the order (the driver's effect
    /// sequence). With no turns, this is a no-op. Never throws.
    func markLastTurnInterrupted() async
}