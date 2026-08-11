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

import VoccaCore
import VoccaUI
import XCTest

/// The FAILSAFE window's decision table (`failsafe-surface` Phase B, the `DownloadStateReducerTests`
/// pattern): every action × state transition, pinned headlessly. The window itself is thin glue
/// "executed by nothing in CI" (it needs a window server session), so this table is the decision.
///
/// The reducer is **pure** — no clock, no file, no pasteboard, no AppKit. It models custody, not
/// chrome: the state speaks ``HeldTranscript`` and ``FailsafeReason`` (the cause *and* the target
/// app name, the structured vocabulary the view renders), and the action set is **closed**, so the
/// structural pin on never-auto-dismiss is a test over that closed set, not a promise.
final class FailsafeStateReducerTests: XCTestCase {

    private func reduce(_ actions: [FailsafeAction]) -> FailsafeState {
        actions.reduce(FailsafeState.hidden) { FailsafeStateReducer.reduce($0, action: $1) }
    }

    private func heldTranscript(
        text: String = "The quick brown fox jumps over the lazy dog",
        reason: FailsafeReason = .exhausted,
        appName: String? = "Slack",
        capturedAt: Duration = .seconds(42)
    ) -> HeldTranscript {
        HeldTranscript(text: text, reason: reason, targetAppName: appName, capturedAt: capturedAt)
    }

    /// The held text a state carries, or `nil` when the state holds nothing — the "is the text
    /// still recoverable" probe for the any-order safety test.
    private func heldText(of state: FailsafeState) -> String? {
        switch state {
        case .hidden: return nil
        case .presenting(let transcript): return transcript.text
        case .retrying(let transcript): return transcript.text
        case .copied(let transcript): return transcript.text
        }
    }

    /// A failsafe fires: `hold` → the transcript presents with its reason and app name intact.
    func testTranscriptHeldPresentsWithTheTranscriptAndItsReason() {
        let transcript = heldTranscript(reason: .exhausted, appName: "Slack")
        let state = reduce([.transcriptHeld(transcript)])
        XCTAssertEqual(state, .presenting(transcript), "a fired failsafe must present the held transcript")
        guard case .presenting(let presented) = state else {
            return XCTFail("expected presenting, got \(state)")
        }
        XCTAssertEqual(presented.text, "The quick brown fox jumps over the lazy dog")
        XCTAssertEqual(presented.reason, .exhausted, "the cause must surface verbatim")
        XCTAssertEqual(presented.targetAppName, "Slack", "the {app} the view renders must surface")
    }

    /// Every cause-specific reason surfaces **verbatim** in the presented state — the enum case the
    /// ladder produced, never remapped. The rendered copy is the view's (`PRODUCT_SPEC.md:111-113`);
    /// the reducer's job is carrying the structured cause so the view can render it.
    func testEveryCauseSpecificReasonSurfacesVerbatimInThePresentedState() {
        let reasons: [FailsafeReason] = [.secureInput, .exhausted, .noFocusedField, .accessibilityRevoked]
        for reason in reasons {
            let transcript = heldTranscript(reason: reason, appName: "Mail")
            guard case .presenting(let presented) = reduce([.transcriptHeld(transcript)]) else {
                return XCTFail("expected presenting for \(reason), got a non-presenting state")
            }
            XCTAssertEqual(presented.reason, reason, "the \(reason) cause must surface unchanged")
            XCTAssertEqual(presented.targetAppName, "Mail", "the app name must surface for \(reason)")
        }
    }

    /// A second failsafe while one is showing replaces the presented transcript (the journal holds
    /// one entry): the newest custody wins the window.
    func testANewHoldReplacesThePresentedTranscript() {
        let first = heldTranscript(text: "First attempt")
        let second = heldTranscript(text: "Second attempt", reason: .noFocusedField)
        let state = reduce([.transcriptHeld(first), .transcriptHeld(second)])
        XCTAssertEqual(state, .presenting(second), "a new hold must replace the presented transcript")
    }

    /// ⌘C: the reducer decides *what* is copied — the full held text, never truncated.
    func testCopyCarriesTheFullHeldText() {
        let transcript = heldTranscript(text: "Copy every last word of this, verbatim.")
        guard case .copied(let copied) = reduce([.transcriptHeld(transcript), .copyRequested]) else {
            return XCTFail("expected copied, got a non-copied state")
        }
        XCTAssertEqual(copied.text, "Copy every last word of this, verbatim.")
    }

    /// Copy while a retry is in flight still works — the failsafe stays interactive throughout.
    func testCopyWorksWhileARetryIsInFlight() {
        let transcript = heldTranscript()
        let state = reduce([.transcriptHeld(transcript), .retryRequested, .copyRequested])
        XCTAssertEqual(state, .copied(transcript), "⌘C during a retry must copy the held text")
    }

    /// Repeated ⌘C is idempotent: each press carries the same full text.
    func testCopyIsIdempotent() {
        let transcript = heldTranscript()
        let state = reduce([.transcriptHeld(transcript), .copyRequested, .copyRequested])
        XCTAssertEqual(state, .copied(transcript), "every ⌘C must carry the same full text")
    }

    /// ⏎ starts a retry with the transcript retained — the text is held through the re-run, not
    /// released into it.
    func testRetryRetainsTheTranscript() {
        let transcript = heldTranscript(text: "Retry me, I am not lost.")
        guard case .retrying(let retrying) = reduce([.transcriptHeld(transcript), .retryRequested]) else {
            return XCTFail("expected retrying, got a non-retrying state")
        }
        XCTAssertEqual(retrying.text, "Retry me, I am not lost.", "the retry must retain the held text")
    }

    /// A second ⏎ while a re-run is in flight is a no-op — one retry in flight at a time.
    func testRetryWhileARetryIsInFlightIsANoOp() {
        let transcript = heldTranscript()
        let state = reduce([.transcriptHeld(transcript), .retryRequested, .retryRequested])
        XCTAssertEqual(state, .retrying(transcript), "a second retry press must not disturb the in-flight one")
    }

    /// A failed re-run re-fires the failsafe (the ladder re-holds the transcript): the state returns
    /// to `presenting` and the text is never dropped.
    func testAFailedReRunReturnsToPresentingWithoutDroppingTheText() {
        let original = heldTranscript(text: "Survive the re-run, verbatim.")
        let reRun = heldTranscript(text: "Survive the re-run, verbatim.", reason: .noFocusedField)
        let state = reduce([.transcriptHeld(original), .retryRequested, .transcriptHeld(reRun)])
        guard case .presenting(let presented) = state else {
            return XCTFail("a failed re-run must return to presenting, got \(state)")
        }
        XCTAssertEqual(presented.text, "Survive the re-run, verbatim.",
            "a failed re-run must never drop the text")
        XCTAssertEqual(presented.reason, .noFocusedField,
            "the re-run's updated cause must surface — the copy follows the fresh failure")
    }

    /// ✕ dismisses: the failsafe hides and the text is dropped — the *only* non-explicit path
    /// must never do this.
    func testDismissRequestedHidesFromEveryPresentedState() {
        let transcript = heldTranscript()
        let states: [(FailsafeState, String)] = [
            (.presenting(transcript), "presenting"),
            (.retrying(transcript), "retrying"),
            (.copied(transcript), "copied"),
        ]
        for (state, name) in states {
            XCTAssertEqual(
                FailsafeStateReducer.reduce(state, action: .dismissRequested),
                .hidden,
                "dismiss must hide from \(name)")
        }
    }

    /// The relaunch load presents the unresolved transcript with its captured-at note — the note's
    /// data flows through untouched; the reducer never rewrites the clock reading.
    func testRelaunchLoadedPresentsWithItsCapturedAtNote() {
        let transcript = heldTranscript(text: "Unresolved at the crash", capturedAt: .milliseconds(12_345))
        guard case .presenting(let presented) = reduce([.relaunchLoaded(transcript)]) else {
            return XCTFail("a relaunch load must present, got a non-presenting state")
        }
        XCTAssertEqual(presented.capturedAt, .milliseconds(12_345),
            "the captured-at note must flow through verbatim")
        XCTAssertEqual(presented.text, "Unresolved at the crash")
    }

    /// **Never-auto-dismiss, pinned structurally:** the action set is closed, and over that closed
    /// set the *only* transition from `presenting` into `hidden` is ``FailsafeAction/dismissRequested``.
    /// No time-based transition exists because no time-based action exists — the reducer's exhaustive
    /// switch cannot hide one, and this test names every case.
    func testOnlyExplicitDismissMovesAPresentedTranscriptToHidden() {
        let transcript = heldTranscript()
        let presented = FailsafeState.presenting(transcript)

        let nonDismissingActions: [(FailsafeAction, String)] = [
            (.transcriptHeld(heldTranscript(text: "A new hold")), "transcriptHeld"),
            (.copyRequested, "copyRequested"),
            (.retryRequested, "retryRequested"),
            (.relaunchLoaded(heldTranscript(text: "A relaunch load")), "relaunchLoaded"),
        ]
        for (action, name) in nonDismissingActions {
            let result = FailsafeStateReducer.reduce(presented, action: action)
            XCTAssertNotEqual(result, .hidden, "\(name) must never hide a presented transcript")
            XCTAssertNotNil(heldText(of: result), "\(name) must keep the text recoverable")
        }

        XCTAssertEqual(
            FailsafeStateReducer.reduce(presented, action: .dismissRequested),
            .hidden,
            "dismissRequested is the only path from presenting to hidden")
    }

    /// Any-order safety: copy, retry and dismiss in any sequence leave the text recoverable until
    /// the explicit dismiss — and the dismiss is the end of it.
    func testAnyOrderCopyRetryDismissKeepsTheTextRecoverableUntilDismiss() {
        let fullText = "Recoverable through every sequence, until ✕."
        let transcript = heldTranscript(text: fullText)

        let sequences: [[FailsafeAction]] = [
            [.transcriptHeld(transcript), .copyRequested, .dismissRequested],
            [.transcriptHeld(transcript), .retryRequested, .dismissRequested],
            [.transcriptHeld(transcript), .copyRequested, .retryRequested, .dismissRequested],
            [.transcriptHeld(transcript), .retryRequested, .copyRequested, .copyRequested, .dismissRequested],
            [.transcriptHeld(transcript), .copyRequested, .copyRequested, .retryRequested, .dismissRequested],
            [.transcriptHeld(transcript), .retryRequested, .transcriptHeld(transcript), .copyRequested, .dismissRequested],
        ]
        for sequence in sequences {
            var state = FailsafeState.hidden
            for action in sequence {
                state = FailsafeStateReducer.reduce(state, action: action)
                if state == .hidden {
                    XCTAssertEqual(action, .dismissRequested,
                        "only dismissRequested may hide the failsafe")
                } else {
                    XCTAssertEqual(heldText(of: state), fullText,
                        "the text must stay recoverable through \(sequence)")
                }
            }
            XCTAssertEqual(state, .hidden, "each sequence must end in explicit dismiss")
        }
    }

    /// Stray intents on a failsafe that never fired are no-ops — nothing held, nothing to copy,
    /// retry or dismiss; a stray event must not conjure a window.
    func testActionsOnHiddenAreNoOps() {
        XCTAssertEqual(reduce([.copyRequested]), .hidden)
        XCTAssertEqual(reduce([.retryRequested]), .hidden)
        XCTAssertEqual(reduce([.dismissRequested]), .hidden)
    }
}
