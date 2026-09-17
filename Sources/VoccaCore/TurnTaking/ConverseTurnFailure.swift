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

/// The honest-drop vocabulary for the converse loop (`dual-mode` PRD O10, `prd.md:248`).
///
/// ## The contract (the honest-drop rule)
///
/// A `.conversing` turn whose ASR, reply rendering or capture fails is **not owed**: nothing is
/// injected (the driver names no injector — this vocabulary's cases are the whole surface), no
/// hang, and the loop keeps listening. The notice fires **exactly once** per failed turn — the
/// driver's delivery sites are the one-shot discipline, asserted by the contract tests — and it
/// never implies a transcript was lost: the loop's capture-failure rationale
/// (`TurnTakingLoop.reportCaptureFailed()`, "the voice loop owes no transcript hand-over") is
/// the same rationale this vocabulary's cases share. A user stop mid-turn is *not* a failure —
/// no case names it.
public enum ConverseTurnFailure: Sendable, Equatable {
    /// The committed utterance could not be transcribed (the engine resolved to nil — the
    /// readiness gate — or transcription threw). The turn is dropped: no reply, no injection.
    case asrFailed

    /// The reply's render leg failed (the synthesizer recipe threw or the render/play threw)
    /// after the reply was scheduled. The playback window closes honestly and the loop returns
    /// to listening.
    case replyFailed

    /// The capture stream ended while the session was still running — the honest stop: the
    /// loop entered `.idle` via `reportCaptureFailed()`, nothing is owed.
    case captureFailed
}