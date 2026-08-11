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

/// The custody seam for undelivered transcripts — the `ModelDownloadSession` pattern: the core
/// owns the contract, and the adapters and the UI both implement it.
///
/// Two implementations speak this protocol at ship: the recovery journal (the failsafe rung's
/// implementation, which *holds* durably) and the FAILSAFE window (which *reads* to render and
/// *releases* on copy/retry/dismiss). `VoccaUI` can never see the journal, so everything the
/// window can observe about custody must fit this vocabulary — hold, current, release, and
/// nothing else. Retry re-runs the ladder against current focus; the held transcript stays put
/// until the retry succeeds or the user resolves it (`PRODUCT_SPEC.md:115-116`).
///
/// ## The load-bearing contract: `hold` is durable before it returns
///
/// PRD R6: the journal write is *committed as part of the failsafe hand-off, not after it*. A
/// crash between exhaustion and journal write is a lost transcript — the one window I1's floor
/// must close, and the only way to close it is to make the write part of the hand-off itself.
/// A conformer's `hold` must therefore not return until the transcript survives process death
/// (for the journal: written and the file's existence verified before `hold` answers). The
/// ladder hands off and moves on exactly once `hold` returns; it neither knows nor checks
/// whether the transcript is durable, so a conformer that returns before committing is a
/// silent I1 violation no caller can detect — the contract is the enforcement.
public protocol TranscriptHolder: Sendable {
    /// Durably stores `transcript`. Must not return before the transcript is safe against
    /// process death; throws when it cannot be made so.
    func hold(_ transcript: HeldTranscript) async throws

    /// The currently held transcript, or `nil` when nothing is held.
    func current() async -> HeldTranscript?

    /// Releases the held transcript — the user copied it or a retry delivered it. For the
    /// journal: purges the held entry (the journal is bounded, oldest dropped first).
    func release() async
}
