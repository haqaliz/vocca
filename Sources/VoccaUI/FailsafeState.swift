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
import VoccaCore

/// The FAILSAFE window's state, driven by the user's intents — a pure reducer, so the whole UI
/// decision table runs headlessly (`FailsafeStateReducerTests`); the window itself is thin glue
/// over this type (`DownloadState`'s shape exactly).
///
/// The state speaks custody, not chrome: every shown transcript state carries the
/// ``HeldTranscript`` itself, so the text is recoverable from `presenting`, `retrying` or
/// `copied` — and ``FailsafeState/hidden`` and the reason-only notice (PRD R5) hold nothing
/// between them: `hidden` because nothing fired, ``FailsafeState/reasonOnly(_:)`` because no
/// text ever existed (the voice-processing loop failed before a transcript did). `hidden` is
/// both the initial state and the dismissed one: there is no separate `dismissed` case, because
/// the reducer's contract is that *nothing but an explicit dismiss moves a presented transcript
/// to `hidden`* (`PRODUCT_SPEC.md:104`), and one resting state makes that the only transition
/// into `hidden` at all.
public enum FailsafeState: Equatable, Sendable {
    /// Nothing to show: the failsafe never fired, or the user dismissed it.
    case hidden
    /// The failsafe is showing `transcript`, persistent until the user acts (`PRODUCT_SPEC.md:48`).
    case presenting(HeldTranscript)
    /// A retry is in flight — the transcript is retained through the re-run, not released into it.
    case retrying(HeldTranscript)
    /// The user pressed ⌘C; `transcript.text` is exactly what went to the pasteboard.
    case copied(HeldTranscript)
    /// A reason-only notice (PRD R5): the voice-processing loop failed with `reason` and no text
    /// was ever held — nothing to copy, nothing to retry, dismiss only. Never auto-dismissed,
    /// like every state here.
    case reasonOnly(FailsafeReason)
}

/// The intents the window can offer the reducer. **The set is closed and time-free**: there is no
/// clock, no timer and no time-based action in it — so the never-auto-dismiss invariant
/// (`PRODUCT_SPEC.md:104`) is structural, not policed. The exhaustive switch in
/// ``FailsafeStateReducer`` cannot hide a transition no action can carry.
public enum FailsafeAction: Equatable, Sendable {
    /// A failsafe fired (the ladder handed the transcript off): show it. Also the re-run's
    /// completion — a failed retry re-fires the failsafe with the fresh cause, and the held text
    /// arrives again, never dropped (`PRODUCT_SPEC.md:116`).
    case transcriptHeld(HeldTranscript)
    /// The user pressed ⌘C — the reducer decides *what* is copied: the full held text.
    case copyRequested
    /// The user pressed ⏎ — re-run the ladder against current focus; the transcript stays held.
    case retryRequested
    /// The user pressed ✕ — the *only* transition into ``FailsafeState/hidden``. The text is
    /// released: the user resolved it (`PRODUCT_SPEC.md:104`).
    case dismissRequested
    /// The journal reloaded an unresolved transcript at launch: present it with its captured-at
    /// note (`PRODUCT_SPEC.md:117`). The note is carried by the transcript and flows untouched.
    case relaunchLoaded(HeldTranscript)
    /// The voice-processing loop failed with `reason` and held nothing: show the cause as a
    /// reason-only notice (PRD R5) — the newest reason replaces any shown transcript or an older
    /// reason-only notice, exactly as a new hold replaces the shown transcript.
    case reasonShown(FailsafeReason)
}

/// The transition table: every action × state rule the FAILSAFE window obeys.
///
/// - ``FailsafeAction/transcriptHeld(_:)`` and ``FailsafeAction/relaunchLoaded(_:)`` present from
///   any state: a new hold replaces the shown transcript (the journal holds one entry) and the
///   relaunch load is authoritative at startup. A reason-only notice yields to neither — it
///   holds nothing and nothing was held; the journal entry waits, and dismiss ends the notice.
/// - ``FailsafeAction/reasonShown(_:)`` presents the reason-only notice from any state: the
///   newest reason replaces a shown transcript or an older reason-only notice.
/// - Copy works from `presenting`, `retrying` and `copied` (idempotent — each ⌘C carries the same
///   full text); retry starts from `presenting` and `copied` and is a no-op while in flight.
///   Both are no-ops in ``FailsafeState/reasonOnly(_:)``: no text is held, so nothing exists to
///   copy or re-run (PRD R5).
/// - ``FailsafeAction/dismissRequested`` is the only action that yields ``FailsafeState/hidden`` —
///   for the reason-only notice it is the *only* exit at all — and stray intents on a failsafe
///   that never fired are no-ops.
public enum FailsafeStateReducer {

    public static func reduce(_ state: FailsafeState, action: FailsafeAction) -> FailsafeState {
        switch action {
        case .transcriptHeld(let transcript), .relaunchLoaded(let transcript):
            switch state {
            case .reasonOnly:
                return state
            case .hidden, .presenting, .retrying, .copied:
                return .presenting(transcript)
            }
        case .copyRequested:
            switch state {
            case .presenting(let transcript), .retrying(let transcript), .copied(let transcript):
                return .copied(transcript)
            case .hidden, .reasonOnly:
                return state
            }
        case .retryRequested:
            switch state {
            case .presenting(let transcript), .retrying(let transcript), .copied(let transcript):
                return .retrying(transcript)
            case .hidden, .reasonOnly:
                return state
            }
        case .dismissRequested:
            switch state {
            case .hidden:
                return .hidden
            case .presenting, .retrying, .copied, .reasonOnly:
                return .hidden
            }
        case .reasonShown(let reason):
            return .reasonOnly(reason)
        }
    }
}
