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

/// The onboarding flow's decision table (`first-run-permissions` A1) — the closed
/// `OnboardingAction` set folded from every step, headless: the window (A5) is thin glue over
/// this table, so the table is the decision (`DownloadStateReducerTests`' shape).
///
/// The invariants this suite pins structurally, asserted after every fold of the closed set:
///
/// - **`restartOffered` is only reachable from `grantedNotArmed`** (M5c): a ✓ that hides a dead
///   tap is the silent gate this capability exists to kill, so the restart offer must never
///   ride over any other Accessibility state — and the flow must never *pretend* the tap is
///   armed, which is exactly what a status input cannot be forced into.
/// - **`completed` ⟺ `step == .done` ⟺ `deliveredTranscript != nil`** (M4/R4): the completion
///   flag is set by exactly one transition (`tryItSucceeded`), and nothing in the closed set
///   clears it — closing the window mid-flow never un-completes a done flow, and a transcript
///   cannot exist without the flag that means the dictation landed.
/// - **`tryItUnavailableReason` implies a model that cannot serve a dictation** (M7): the
///   refusal is only ever derived from `absent`/`failed`/`skipped` at a press, and a fresh
///   model status clears a stale refusal — the surface can never say "unavailable" over a
///   model that exists.
///
/// **No time-based transition exists anywhere in this table**: `reduce` takes no clock, and the
/// closed set contains no timer — the never-auto-dismiss rule (`FailsafeAction`'s shape), so a
/// window left alone stays exactly where it is, whatever real time passes.
final class OnboardingReducerTests: XCTestCase {

    // MARK: - Helpers

    private func makeState(
        step: OnboardingStep,
        accessibility: OnboardingAccessibility = .armed,
        microphone: OnboardingMicrophone = .granted,
        model: OnboardingModel,
        tryItUnavailableReason: TryItUnavailable? = nil,
        restartOffered: Bool = false,
        deliveredTranscript: String? = nil,
        completed: Bool = false
    ) -> OnboardingState {
        OnboardingState(
            step: step,
            accessibility: accessibility,
            microphone: microphone,
            model: model,
            tryItUnavailableReason: tryItUnavailableReason,
            restartOffered: restartOffered,
            deliveredTranscript: deliveredTranscript,
            completed: completed)
    }

    private func fold(_ actions: [OnboardingAction], from state: OnboardingState) -> OnboardingState {
        actions.reduce(state) { OnboardingReducer.reduce($0, action: $1) }
    }

    // MARK: - The resume matrix (begin / windowClosed)

    /// The resume target, **hard-coded here as a second copy of the decision** — the matrix is
    /// pinned in both directions (`WidgetProjectionTests`' shape): the test's switch must agree
    /// with `OnboardingReducer.initialState(accessibility:microphone:model:)` row for row.
    ///
    /// The step is derived from the *statuses alone*, never from extra persisted step state
    /// (PRD S3): the first step whose precondition is unmet. Permissions is unmet until the
    /// Accessibility grant is **armed** (a `grantedNotArmed` grant is not armed — the tap is
    /// still dead until restart) and the microphone is granted; the MODEL step is unmet while
    /// no usable model decision exists (`absent` — nothing decided, `failed` — the decision
    /// failed and the step shows retry, `downloading` — the decision is in flight and the step
    /// shows its progress); a `skipped` model *is* a decision (M7's "try again" surface lives
    /// at the TRY IT step, so the flow must be able to land there after a skip); `committed`
    /// is a decision; and the flow itself is complete only when `completed` — which
    /// `initialState` cannot fabricate, so it is carried by the reducer's fold (a completed
    /// flow stays at `.done`, tested below).
    private func expectedStep(
        accessibility: OnboardingAccessibility,
        microphone: OnboardingMicrophone,
        model: OnboardingModel
    ) -> OnboardingStep {
        switch (accessibility, microphone, model) {
        case (.notGranted, _, _), (.grantedNotArmed, _, _):
            return .permissions
        case (.armed, .notDetermined, _), (.armed, .denied, _):
            return .permissions
        case (.armed, .granted, .absent),
             (.armed, .granted, .failed),
             (.armed, .granted, .downloading):
            return .model
        case (.armed, .granted, .committed), (.armed, .granted, .skipped):
            return .tryIt
        }
    }

    /// `begin` and `windowClosed` re-derive the step from the statuses — the S3 resume, driven
    /// across every step × every status combination: whatever step the window was on, a fold of
    /// either action lands on the first incomplete step, and the fresh state carries no stale
    /// refusal, no transcript, no completion.
    func testBeginAndWindowClosedResumeAtTheFirstIncompleteStep() {
        let accessibilities: [OnboardingAccessibility] = [.notGranted, .grantedNotArmed, .armed]
        let microphones: [OnboardingMicrophone] = [.notDetermined, .denied, .granted]
        let models: [OnboardingModel] = [.absent, .downloading(0.5), .committed, .failed, .skipped]
        let steps: [OnboardingStep] = [.welcome, .permissions, .model, .tryIt]
        let actions: [(OnboardingAction, String)] = [(.begin, "begin"), (.windowClosed, "windowClosed")]

        for accessibility in accessibilities {
            for microphone in microphones {
                for model in models {
                    let expected = expectedStep(
                        accessibility: accessibility, microphone: microphone, model: model)
                    for step in steps {
                        let start = makeState(step: step, accessibility: accessibility,
                                              microphone: microphone, model: model)
                        for (action, actionName) in actions {
                            let next = OnboardingReducer.reduce(start, action: action)
                            XCTAssertEqual(
                                next.step, expected,
                                "\(actionName) from \(step) with (\(accessibility), \(microphone), \(model)) must resume at \(expected)")
                            XCTAssertEqual(next.accessibility, accessibility)
                            XCTAssertEqual(next.microphone, microphone)
                            XCTAssertEqual(next.model, model)
                            XCTAssertNil(next.tryItUnavailableReason,
                                "a resume fold must never carry a stale refusal")
                            XCTAssertEqual(next.restartOffered, accessibility == .grantedNotArmed,
                                "the restart offer is derived from the status on resume")
                            XCTAssertNil(next.deliveredTranscript)
                            XCTAssertFalse(next.completed)
                        }
                    }
                }
            }
        }
    }

    /// A **completed** flow is terminal for the resume actions too: `begin`/`windowClosed` on a
    /// done state keep it done — closing the window must never un-complete the user (M4/R4:
    /// nothing in the closed set clears the completion flag).
    func testBeginAndWindowClosedOnACompletedStateKeepItCompleted() {
        let done = makeState(
            step: .done, model: .committed,
            deliveredTranscript: "Hello world", completed: true)
        XCTAssertEqual(
            OnboardingReducer.reduce(done, action: .begin), done,
            "begin on a completed flow must be a no-op")
        XCTAssertEqual(
            OnboardingReducer.reduce(done, action: .windowClosed), done,
            "windowClosed on a completed flow must be a no-op")
    }

    // MARK: - The restart offer (M3, M5c)

    /// `restartOffered` flips on exactly the `grantedNotArmed` status: a grant present with the
    /// tap dead (mask cleared at launch cannot be re-enabled, `ARCHITECTURE.md:604`). `.armed`
    /// and `.notGranted` both clear it — the offer can never ride over a state that doesn't
    /// need the restart.
    func testRestartIsOfferedExactlyWhenAccessibilityIsGrantedNotArmed() {
        let start = makeState(step: .permissions, accessibility: .armed, model: .absent)

        let granted = OnboardingReducer.reduce(
            start, action: .accessibilityStatusChanged(.grantedNotArmed))
        XCTAssertTrue(granted.restartOffered)
        XCTAssertEqual(granted.accessibility, .grantedNotArmed)

        let armed = OnboardingReducer.reduce(
            granted, action: .accessibilityStatusChanged(.armed))
        XCTAssertFalse(armed.restartOffered, ".armed must clear the offer — the tap is live")

        let revoked = OnboardingReducer.reduce(
            granted, action: .accessibilityStatusChanged(.notGranted))
        XCTAssertFalse(revoked.restartOffered, ".notGranted must clear the offer — there is nothing granted to arm")
    }

    /// The M5c edge case pinned: a `grantedNotArmed` status arriving **while on a later step**
    /// (revoked-and-regranted mid-flow, M8's "revoked mid-flow") updates the status and offers
    /// the restart at the current step's surface — the flow does **not** yank the user
    /// backwards. Only `begin`/`windowClosed` re-derive the step.
    func testGrantedNotArmedOnALaterStepDoesNotYankTheFlowBack() {
        for step in [OnboardingStep.model, .tryIt] {
            let start = makeState(step: step, model: .committed)
            let next = OnboardingReducer.reduce(
                start, action: .accessibilityStatusChanged(.grantedNotArmed))
            XCTAssertEqual(next.step, step,
                "a status change must never move the step — the flow is not yanked back from \(step)")
            XCTAssertEqual(next.accessibility, .grantedNotArmed)
            XCTAssertTrue(next.restartOffered)
        }
    }

    /// `restartDismissed` clears the offer — the user chose not to restart right now; the offer
    /// returns only on a fresh `grantedNotArmed` status input.
    func testRestartDismissedClearsTheOffer() {
        let offering = makeState(
            step: .permissions, accessibility: .grantedNotArmed, model: .absent,
            restartOffered: true)
        let next = OnboardingReducer.reduce(offering, action: .restartDismissed)
        XCTAssertFalse(next.restartOffered)
        XCTAssertEqual(next.accessibility, .grantedNotArmed,
            "dismissing the offer must not touch the status it described")
        XCTAssertEqual(next.step, .permissions)
    }

    /// `restartRequested` is a wiring signal, not a state transition: the relaunch itself
    /// (A2's one-file adapter) is the change, and the offer stays until the process dies — so a
    /// *failed* relaunch (the invisible-failure class, R2) leaves the button exactly where the
    /// user left it, retryable, rather than consumed by a relaunch that never happened.
    func testRestartRequestedLeavesTheOfferForARetryableRelaunch() {
        let offering = makeState(
            step: .permissions, accessibility: .grantedNotArmed, model: .absent,
            restartOffered: true)
        XCTAssertEqual(
            OnboardingReducer.reduce(offering, action: .restartRequested), offering,
            "the offer must survive the request — a relaunch that fails must remain retryable")
    }

    // MARK: - Microphone status (M5, M5b)

    /// `microphoneRequestResulted` maps the system callback's Bool to the two concrete states:
    /// the TCC prompt's answer is a fact, not a guess.
    func testMicrophoneRequestResultsMapToGrantedAndDenied() {
        let start = makeState(step: .permissions, model: .absent)
        XCTAssertEqual(
            OnboardingReducer.reduce(start, action: .microphoneRequestResulted(true)).microphone,
            .granted)
        XCTAssertEqual(
            OnboardingReducer.reduce(start, action: .microphoneRequestResulted(false)).microphone,
            .denied)
    }

    /// `microphoneStatusChanged` carries the read's answer verbatim — including back to
    /// `.notDetermined` (a revoked-then-cleared TCC record). Status changes never move the step.
    func testMicrophoneStatusChangesUpdateTheFieldAndNeverMoveTheStep() {
        let start = makeState(step: .permissions, model: .absent)
        for status in [OnboardingMicrophone.notDetermined, .denied, .granted] {
            let next = OnboardingReducer.reduce(start, action: .microphoneStatusChanged(status))
            XCTAssertEqual(next.microphone, status)
            XCTAssertEqual(next.step, .permissions,
                "a microphone status change must never move the step")
        }
    }

    // MARK: - The model state (MODEL step; DownloadState's terminal shapes)

    /// `modelDownloadCancelled` (Skip for now) moves to `.skipped` from the two live download
    /// shapes — a skip with no download in flight is as much a skip as one that cancels
    /// mid-flight.
    func testModelDownloadCancelledMovesToSkippedFromAbsentAndDownloading() {
        XCTAssertEqual(
            fold([.modelDownloadCancelled],
                 from: makeState(step: .model, model: .absent)).model,
            .skipped)
        XCTAssertEqual(
            fold([.modelDownloadCancelled],
                 from: makeState(step: .model, model: .downloading(0.4))).model,
            .skipped)
    }

    /// `.skipped`, `.committed` and `.failed` are terminal shapes (`DownloadState`'s rule): the
    /// ended session's own events must not move them — a cancelled session cannot commit later,
    /// a committed one cannot regress into a download, a failed one cannot resolve itself.
    func testModelDownloadCancelledIsRejectedByTerminalModelStates() {
        for model in [OnboardingModel.committed, .failed, .skipped] {
            let start = makeState(step: .model, model: model)
            XCTAssertEqual(
                OnboardingReducer.reduce(start, action: .modelDownloadCancelled), start,
                "a cancel on a terminal \(model) model state must be rejected")
        }
    }

    /// The DownloadStateReducer straggler rule, in the plan's own vocabulary: after a skip, the
    /// cancelled session's stragglers (a late commit, a second cancel) are rejected — the skip
    /// is the session's last word. A late *progress* report is deliberately **not** in the
    /// rejected set: it is indistinguishable from M7's new "[ Download now ]" download, which
    /// must be accepted (pinned by ``testDownloadNowAfterSkipStartsAFreshDownload``) — the
    /// plan's "terminal" amendment, documented on ``OnboardingModel``.
    func testASkippedDownloadRejectsTheCancelledSessionsStragglers() {
        let skipped = makeState(step: .model, model: .skipped)
        XCTAssertEqual(
            fold([.modelStatusChanged(.committed)], from: skipped).model, .skipped,
            "a late commit from the cancelled session must be rejected")
        XCTAssertEqual(
            fold([.modelDownloadCancelled], from: skipped).model, .skipped,
            "a second cancel must be rejected")
    }

    /// A `.committed` model is terminal: the model exists, and nothing may regress it into a
    /// download or a failure.
    func testACommittedModelIsTerminal() {
        let committed = makeState(step: .model, model: .committed)
        XCTAssertEqual(
            fold([.modelStatusChanged(.downloading(0.1))], from: committed).model, .committed)
        XCTAssertEqual(
            fold([.modelStatusChanged(.failed)], from: committed).model, .committed)
        XCTAssertEqual(
            fold([.modelStatusChanged(.absent)], from: committed).model, .committed)
    }

    /// A `.failed` model rejects its own session's stragglers but accepts a **retry**: a fresh
    /// download is a new decision, not the failed session's late word — the MODEL step must be
    /// able to offer retry (`PRODUCT_SPEC.md:233-235`: a stalled download never blocks the
    /// product).
    func testAFailedModelRejectsStragglersButAcceptsARetry() {
        let failed = makeState(step: .model, model: .failed)
        XCTAssertEqual(
            fold([.modelStatusChanged(.committed)], from: failed).model, .failed,
            "a late commit from the failed session must be rejected")
        XCTAssertEqual(
            fold([.modelDownloadCancelled], from: failed).model, .failed,
            "a late cancel from the failed session must be rejected")
        XCTAssertEqual(
            fold([.modelStatusChanged(.downloading(0.3))], from: failed).model,
            .downloading(0.3),
            "a retry starts a fresh download")
    }

    /// M7's way forward: a **new** download after a skip (the "Download now" affordance at the
    /// TRY IT step's model-unavailable surface) must start — the skip was the *cancelled
    /// session's* last word, not the flow's.
    func testDownloadNowAfterSkipStartsAFreshDownload() {
        let skipped = makeState(step: .tryIt, model: .skipped,
                                tryItUnavailableReason: .modelUnavailable)
        let next = OnboardingReducer.reduce(
            skipped, action: .modelStatusChanged(.downloading(0.1)))
        XCTAssertEqual(next.model, .downloading(0.1))
        XCTAssertEqual(next.step, .tryIt,
            "the download-now must not yank the user off the TRY IT step")
    }

    /// The happy path: progress to a full download, then the commit.
    func testTheModelHappyPathEndsCommitted() {
        let start = makeState(step: .model, model: .absent)
        let next = fold(
            [.modelStatusChanged(.downloading(0.25)),
             .modelStatusChanged(.downloading(0.75)),
             .modelStatusChanged(.downloading(1)),
             .modelStatusChanged(.committed)],
            from: start)
        XCTAssertEqual(next.model, .committed)
    }

    // MARK: - TRY IT (M6, M7)

    /// `tryItPressed` with a model that cannot serve a dictation refuses honestly (M7): the
    /// pipeline's `.modelUnavailable` — never a dead end, never an auto-download; the surface
    /// offers Download now instead (`PRODUCT_SPEC.md:233-235`).
    func testTryItPressedWithAnUnavailableModelSetsTheReason() {
        for model in [OnboardingModel.absent, .failed, .skipped] {
            let start = makeState(step: .tryIt, model: model)
            let next = OnboardingReducer.reduce(start, action: .tryItPressed)
            XCTAssertEqual(next.tryItUnavailableReason, .modelUnavailable,
                "a press with a \(model) model must refuse with .modelUnavailable")
            XCTAssertEqual(next.step, .tryIt, "the refusal must not move the step")
            XCTAssertFalse(next.completed)
        }
    }

    /// The other rows: a committed model is ready, and an in-flight download is *not*
    /// "unavailable" — the refusal is reserved for models that will not serve a dictation.
    func testTryItPressedWithAPresentOrInFlightModelIsReady() {
        for model in [OnboardingModel.committed, .downloading(1), .downloading(0.5)] {
            let start = makeState(step: .tryIt, model: model)
            let next = OnboardingReducer.reduce(start, action: .tryItPressed)
            XCTAssertNil(next.tryItUnavailableReason,
                "a press with a \(model) model must not be refused")
        }
    }

    /// `tryItSucceeded` is the **only** transition that completes (M4/R4): the real transcript
    /// arrives with the flag, the step moves to DONE, and any refusal is cleared — a success
    /// overrides a stale unavailable.
    func testTryItSucceededCompletesAndMovesToDone() {
        let ready = makeState(step: .tryIt, model: .committed)
        let next = OnboardingReducer.reduce(ready, action: .tryItSucceeded("Hello world"))
        XCTAssertEqual(next.step, .done)
        XCTAssertTrue(next.completed)
        XCTAssertEqual(next.deliveredTranscript, "Hello world")
        XCTAssertNil(next.tryItUnavailableReason)

        let unavailable = makeState(
            step: .tryIt, model: .skipped, tryItUnavailableReason: .modelUnavailable)
        let afterDownload = OnboardingReducer.reduce(
            unavailable, action: .modelStatusChanged(.committed))
        let completed = OnboardingReducer.reduce(
            afterDownload, action: .tryItSucceeded("Now it works"))
        XCTAssertTrue(completed.completed)
        XCTAssertEqual(completed.deliveredTranscript, "Now it works")
    }

    /// The R4 sweep: every action in the closed set folded from an uncompleted state — none may
    /// set `completed` or deliver a transcript but the one transition.
    func testTryItSucceededIsTheOnlyTransitionThatCompletes() {
        let start = makeState(step: .tryIt, model: .committed)
        let actions: [OnboardingAction] = [
            .begin, .windowClosed,
            .accessibilityStatusChanged(.armed),
            .accessibilityStatusChanged(.grantedNotArmed),
            .accessibilityGrantSignal,
            .microphoneStatusChanged(.granted),
            .microphoneRequestResulted(true),
            .microphoneRequestResulted(false),
            .modelStatusChanged(.committed),
            .modelDownloadCancelled,
            .tryItPressed,
            .tryItFailed,
            .restartRequested,
            .restartDismissed,
        ]
        for action in actions {
            let next = OnboardingReducer.reduce(start, action: action)
            XCTAssertFalse(next.completed,
                "\(action) must not set completed — only tryItSucceeded may")
            XCTAssertNil(next.deliveredTranscript,
                "\(action) must not deliver a transcript")
        }
    }

    /// The plan's edge case: a second `tryItSucceeded` is a no-op — the state is already
    /// `.done`/completed, and the first transcript is the one that landed.
    func testADoubleTryItSucceededIsANoOp() {
        let done = fold(
            [.tryItSucceeded("First words")],
            from: makeState(step: .tryIt, model: .committed))
        XCTAssertEqual(
            OnboardingReducer.reduce(done, action: .tryItSucceeded("Second words")), done,
            "the second success must not overwrite the first — the state is already done")
    }

    /// `tryItFailed` keeps the step (the failure surface is the window's, A5) and clears any
    /// refusal — a real attempt happened, so an unavailable state cannot linger over it — but
    /// it never completes, and it cannot un-complete a done flow.
    func testTryItFailedKeepsTheStepAndNeverCompletes() {
        let ready = makeState(step: .tryIt, model: .committed)
        let failed = OnboardingReducer.reduce(ready, action: .tryItFailed)
        XCTAssertEqual(failed.step, .tryIt, "a failed try must keep the step")
        XCTAssertFalse(failed.completed)
        XCTAssertNil(failed.tryItUnavailableReason)

        let unavailable = makeState(
            step: .tryIt, model: .skipped, tryItUnavailableReason: .modelUnavailable)
        let afterFailed = OnboardingReducer.reduce(unavailable, action: .tryItFailed)
        XCTAssertEqual(afterFailed.step, .tryIt)
        XCTAssertNil(afterFailed.tryItUnavailableReason,
            "a failed attempt must clear the refusal — the attempt was real")

        let done = makeState(
            step: .done, model: .committed,
            deliveredTranscript: "Words", completed: true)
        XCTAssertEqual(
            OnboardingReducer.reduce(done, action: .tryItFailed), done,
            "a straggler failure after completion must not un-complete the flow")
    }

    // MARK: - The grant signal (M5)

    /// `accessibilityGrantSignal` is the wiring's *hint* that the status may have changed
    /// (`TapHealthTimer.accessibilityGrantChanged()`); the reducer cannot read, so the signal
    /// alone must be a no-op — it never fabricates `.armed` from nothing. The wiring answers
    /// the hint with a fresh status read, which arrives as `accessibilityStatusChanged`.
    func testAccessibilityGrantSignalIsANoOpWithoutAFreshStatusInput() {
        let states: [(OnboardingState, String)] = [
            (makeState(step: .permissions, accessibility: .notGranted, model: .absent), "notGranted"),
            (makeState(step: .permissions, accessibility: .grantedNotArmed, model: .absent,
                       restartOffered: true), "grantedNotArmed"),
            (makeState(step: .model, accessibility: .armed, model: .committed), "later step"),
            (makeState(step: .done, model: .committed,
                       deliveredTranscript: "Words", completed: true), "done"),
        ]
        for (state, name) in states {
            XCTAssertEqual(
                OnboardingReducer.reduce(state, action: .accessibilityGrantSignal), state,
                "the grant signal alone must not move the \(name) state")
        }
    }

    // MARK: - The stale-refusal guard

    /// A fresh model status invalidates a stale refusal: the surface can never keep saying
    /// "unavailable" after the model arrived (the Download now flow: refusal → download →
    /// commit must render ready, not stuck on the unavailable surface).
    func testAModelStatusChangeClearsAStaleReason() {
        let unavailable = makeState(
            step: .tryIt, model: .absent, tryItUnavailableReason: .modelUnavailable)
        let downloading = OnboardingReducer.reduce(
            unavailable, action: .modelStatusChanged(.downloading(0.5)))
        XCTAssertNil(downloading.tryItUnavailableReason,
            "a new download must clear the refusal")
        let committed = OnboardingReducer.reduce(
            unavailable, action: .modelStatusChanged(.committed))
        XCTAssertNil(committed.tryItUnavailableReason,
            "a commit must clear the refusal")
    }

    /// ...and the refusal survives a **rejected** straggler: a late commit that the terminal
    /// `.skipped` state refuses must not clear the reason either — the model is still absent,
    /// so the surface still says so.
    func testAStaleReasonSurvivesAStragglerCommitAfterSkip() {
        let unavailable = makeState(
            step: .tryIt, model: .skipped, tryItUnavailableReason: .modelUnavailable)
        let next = OnboardingReducer.reduce(
            unavailable, action: .modelStatusChanged(.committed))
        XCTAssertEqual(next.model, .skipped, "the straggler commit must be rejected")
        XCTAssertEqual(next.tryItUnavailableReason, .modelUnavailable,
            "the refusal must survive — nothing about the model changed")
    }

    // MARK: - The closed set

    /// The closed set, enumerated exactly: 13 actions, no clock and no timer anywhere in it —
    /// the never-auto-dismiss rule is structural (`FailsafeAction`'s shape). Removing a case
    /// stops this file compiling; adding one stops the reducer's exhaustive switch compiling.
    func testTheClosedSetIsExactlyTheseThirteenActions() {
        let actions: [OnboardingAction] = [
            .begin,
            .accessibilityStatusChanged(.armed),
            .accessibilityGrantSignal,
            .microphoneStatusChanged(.granted),
            .microphoneRequestResulted(true),
            .modelStatusChanged(.committed),
            .modelDownloadCancelled,
            .tryItPressed,
            .tryItSucceeded("text"),
            .tryItFailed,
            .restartRequested,
            .restartDismissed,
            .windowClosed,
        ]
        XCTAssertEqual(actions.count, 13)
    }

    /// The closed set folds from every representative state: totality (every action × state
    /// answers), and the four invariants the table must hold at every step — the restart offer
    /// only over `grantedNotArmed`, completion exactly at `.done`, a transcript exactly with
    /// completion, and a refusal only over a model that cannot serve.
    func testTheClosedSetFoldsFromEveryRepresentativeState() {
        let states: [(OnboardingState, String)] = [
            (OnboardingState(), "welcome fresh"),
            (makeState(step: .permissions, accessibility: .notGranted, model: .absent),
             "permissions notGranted"),
            (makeState(step: .permissions, accessibility: .grantedNotArmed, model: .absent,
                       restartOffered: true), "permissions grantedNotArmed"),
            (makeState(step: .permissions, accessibility: .armed,
                       microphone: .denied, model: .absent), "permissions micDenied"),
            (makeState(step: .permissions, accessibility: .armed,
                       microphone: .granted, model: .absent), "permissions complete"),
            (makeState(step: .model, model: .downloading(0.4)), "model downloading"),
            (makeState(step: .model, model: .failed), "model failed"),
            (makeState(step: .model, model: .skipped), "model skipped"),
            (makeState(step: .tryIt, model: .committed), "tryIt ready"),
            (makeState(step: .tryIt, model: .skipped,
                       tryItUnavailableReason: .modelUnavailable), "tryIt unavailable"),
            (makeState(step: .done, model: .committed,
                       deliveredTranscript: "Words", completed: true), "done"),
        ]
        let actions: [(OnboardingAction, String)] = [
            (.begin, "begin"),
            (.accessibilityStatusChanged(.notGranted), "acc notGranted"),
            (.accessibilityStatusChanged(.grantedNotArmed), "acc grantedNotArmed"),
            (.accessibilityStatusChanged(.armed), "acc armed"),
            (.accessibilityGrantSignal, "grant signal"),
            (.microphoneStatusChanged(.notDetermined), "mic notDetermined"),
            (.microphoneStatusChanged(.denied), "mic denied"),
            (.microphoneStatusChanged(.granted), "mic granted"),
            (.microphoneRequestResulted(true), "mic request true"),
            (.microphoneRequestResulted(false), "mic request false"),
            (.modelStatusChanged(.absent), "model absent"),
            (.modelStatusChanged(.downloading(0.5)), "model downloading"),
            (.modelStatusChanged(.committed), "model committed"),
            (.modelStatusChanged(.failed), "model failed"),
            (.modelStatusChanged(.skipped), "model skipped"),
            (.modelDownloadCancelled, "model cancel"),
            (.tryItPressed, "tryIt pressed"),
            (.tryItSucceeded("Hello"), "tryIt succeeded"),
            (.tryItFailed, "tryIt failed"),
            (.restartRequested, "restart requested"),
            (.restartDismissed, "restart dismissed"),
            (.windowClosed, "windowClosed"),
        ]

        for (state, stateName) in states {
            for (action, actionName) in actions {
                let next = OnboardingReducer.reduce(state, action: action)
                if let violation = invariantViolation(in: next) {
                    XCTFail("\(actionName) on \(stateName) violates the invariants: \(violation)")
                }
            }
        }
    }

    /// The four invariants every fold must hold. Returns the first violation as a message, or
    /// `nil`.
    private func invariantViolation(in state: OnboardingState) -> String? {
        if state.restartOffered && state.accessibility != .grantedNotArmed {
            return "restartOffered over \(state.accessibility)"
        }
        if state.completed != (state.step == .done) {
            return "completed \(state.completed) over step \(state.step)"
        }
        if (state.deliveredTranscript != nil) != state.completed {
            return "a transcript \(String(describing: state.deliveredTranscript)) over completed \(state.completed)"
        }
        if let reason = state.tryItUnavailableReason {
            switch state.model {
            case .absent, .failed, .skipped:
                break
            case .committed, .downloading:
                return "\(reason) over a \(state.model) model"
            }
        }
        return nil
    }
}