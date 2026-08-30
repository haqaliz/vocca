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
import XCTest

/// **The hotkey recorder's decision table** — `hotkey-rebinding/general-tab-recorder` S1.
///
/// The reducer is pure, and deliberately **does not validate**: it is handed a
/// ``HotkeyBindingValidity`` and shapes it. Validation lives in ``HotkeyBindingRules`` and the
/// warning in ``SystemShortcutRules``, and re-deriving either here would give the recorder, the
/// launch read and ``RebindOutcome``'s own gate three answers where the product needs one — the
/// `AppsTabReducer` precedent of deferring to Core's projections.
///
/// The recorder is also the surface where the two wrong answers are least symmetrical. Abandoning
/// a recording costs a user one click; arming a chord they did not confirm costs them a key they
/// then need in order to reach the window that would undo it. So every row below that leaves
/// ``HotkeyRecorderState/chordToApply`` non-`nil` is a row the user explicitly asked for.
final class HotkeyRecorderReducerTests: XCTestCase {

    /// ⌃⌥J — modified, so the rules accept it, and not the shipped chord.
    private static let candidate = HotkeyChord(keyCode: 38, modifiers: [.control, .option])
    /// A bare `J` — the rules refuse it.
    private static let bareKey = HotkeyChord(keyCode: 38, modifiers: [])

    private func fold(
        _ actions: [HotkeyRecorderAction], from state: HotkeyRecorderState = .idle
    ) -> HotkeyRecorderState {
        actions.reduce(state) { HotkeyRecorderReducer.reduce($0, $1) }
    }

    // MARK: - Criterion 1: the decision table, one row per transition

    /// The window opens closed: nothing recording, nothing to apply, nothing to explain.
    func testTheRecorderOpensIdleWithNothingToSay() {
        XCTAssertEqual(HotkeyRecorderState.idle.phase, .idle)
        XCTAssertNil(HotkeyRecorderState.idle.notice)
        XCTAssertNil(HotkeyRecorderState.idle.chordToApply)
        XCTAssertFalse(HotkeyRecorderState.idle.isRecording)
    }

    /// Clicking the control starts a recording and clears whatever the last attempt said. A stale
    /// refusal sitting under a live recorder reads as a refusal of the chord being pressed *now*.
    func testBeginningARecordingClearsTheLastNotice() {
        let stale = fold([
            .began, .chordCaptured(Self.bareKey, .refused(.unmodifiedTextEntryKey)),
        ])
        XCTAssertEqual(stale.notice, .chordRefused(.unmodifiedTextEntryKey))

        let recording = fold([.began], from: stale)
        XCTAssertEqual(recording.phase, .recording)
        XCTAssertNil(recording.notice, "a new recording must not inherit the last one's refusal")
        XCTAssertTrue(recording.isRecording)
    }

    /// **Escape aborts, and the binding is untouched.** Nothing is offered for applying and no
    /// notice is raised: an abandoned recording is not a failure and must not read as one.
    func testEscapeAbortsARecordingAndLeavesTheBindingUntouched() {
        let aborted = fold([.began, .cancelled])

        XCTAssertEqual(aborted.phase, .idle)
        XCTAssertNil(aborted.chordToApply, "an aborted recording must never arm a chord")
        XCTAssertNil(aborted.notice, "abandoning a recording is not a failure to report")
    }

    /// A refused chord returns to idle carrying **the reason**, and offers nothing to persist.
    func testARefusedChordReturnsToIdleWithItsReasonAndPersistsNothing() {
        for refusal in HotkeyBindingRefusal.allCases {
            let refused = fold([.began, .chordCaptured(Self.bareKey, .refused(refusal))])

            XCTAssertEqual(refused.phase, .idle, "\(refusal)")
            XCTAssertEqual(
                refused.notice, .chordRefused(refusal),
                "the user is told which refusal it was — the reason is the half they need")
            XCTAssertNil(
                refused.chordToApply,
                "a refused chord must never reach the binding: \(refusal)")
        }
    }

    /// An accepted chord arms **immediately** — one press, no second confirmation. The confirm
    /// step exists for the warned case and nowhere else; asking twice for an ordinary chord is
    /// the friction that makes people leave the shipped binding alone.
    func testAnAcceptedChordIsArmedWithoutASecondConfirmation() {
        let armed = fold([.began, .chordCaptured(Self.candidate, .accepted)])

        XCTAssertEqual(armed.chordToApply, Self.candidate)
        XCTAssertNil(armed.notice)
    }

    /// **A warned chord requires an explicit confirm.** Capture alone arms nothing — the whole
    /// point of ``HotkeyBindingValidity/warned`` is that it is neither a refusal nor silence, and
    /// a recorder that armed it on capture would have dropped the warning it exists to carry.
    func testAWarnedChordArmsNothingUntilItIsConfirmed() {
        let warning = HotkeyBindingWarning.usedBySystemShortcut(name: "Switch to Desktop 1")
        let pending = fold([.began, .chordCaptured(Self.candidate, .warned(warning))])

        XCTAssertEqual(pending.phase, .confirming(chord: Self.candidate, warning: warning))
        XCTAssertNil(
            pending.chordToApply,
            "a warned chord must not reach the binding before the user has read the warning")

        let confirmed = fold([.confirmed], from: pending)
        XCTAssertEqual(confirmed.chordToApply, Self.candidate)
        XCTAssertNil(confirmed.notice)
    }

    /// Declining the warning leaves the binding exactly as it was — the `cleanup-tab` rule, where
    /// declining a confirmation leaves the previous choice intact *by construction* rather than by
    /// a rollback that could get written wrong.
    func testDecliningAWarningLeavesTheBindingUntouched() {
        let warning = HotkeyBindingWarning.usedBySystemShortcut(name: nil)
        let declined = fold([
            .began, .chordCaptured(Self.candidate, .warned(warning)), .cancelled,
        ])

        XCTAssertEqual(declined.phase, .idle)
        XCTAssertNil(declined.chordToApply)
        XCTAssertNil(declined.notice)
    }

    /// A key press outside a recording arms nothing. The recorder is a first-responder override in
    /// Vocca's own window, so a keystroke can reach it while nothing is being recorded — and a
    /// reducer that folded one would rebind the hotkey to whatever the user last typed.
    func testAChordCapturedOutsideARecordingIsIgnored() {
        let idle = fold([.chordCaptured(Self.candidate, .accepted)])
        XCTAssertEqual(idle, .idle, "a stray key press must change nothing at all")

        let applying = fold([.began, .chordCaptured(Self.candidate, .accepted)])
        let second = fold([.chordCaptured(Self.bareKey, .accepted)], from: applying)
        XCTAssertEqual(
            second.chordToApply, Self.candidate,
            "a second capture must not overwrite a chord already handed to the caller")
    }

    /// Confirming when there is nothing to confirm arms nothing.
    func testConfirmingOutsideAWarningArmsNothing() {
        XCTAssertNil(fold([.confirmed]).chordToApply)
        XCTAssertNil(fold([.began, .confirmed]).chordToApply)
    }

    // MARK: - Criterion 6: the rebind's own answer reaches the page

    /// **A mid-dictation rebind surfaces the refusal** rather than silently doing nothing
    /// (`rebind-boundary` M5). A rebind that appears not to have registered invites a second
    /// attempt, and the second attempt is made on a keyboard whose binding the user is no longer
    /// sure of.
    func testAMidSessionRefusalIsShownRatherThanSwallowed() {
        let armed = fold([.began, .chordCaptured(Self.candidate, .accepted)])
        let answered = fold([.rebindAnswered(.refused(.sessionInFlight))], from: armed)

        XCTAssertEqual(answered.phase, .idle)
        XCTAssertEqual(answered.notice, .rebindRefused(.sessionInFlight))
        XCTAssertNil(answered.chordToApply, "the chord is not re-offered — the caller answered")
    }

    /// Every refusal a rebind can give has somewhere to land, over the closed set — so a third
    /// reason must state itself here rather than reaching a user as a rebind that did nothing.
    func testEveryRebindRefusalReachesTheNotice() {
        for refusal in RebindRefusal.allCases {
            let answered = fold([
                .began, .chordCaptured(Self.candidate, .accepted),
                .rebindAnswered(.refused(refusal)),
            ])
            XCTAssertEqual(answered.notice, .rebindRefused(refusal), "\(refusal)")
        }
    }

    /// A rebind that landed says nothing: the control now shows the new chord, which is the whole
    /// of the feedback. ``RebindOutcome/unchanged`` is the same — the user asked for the chord that
    /// is already bound, and got it.
    func testASuccessfulRebindRaisesNoNotice() {
        for outcome in [RebindOutcome.rebound, .unchanged] {
            let answered = fold([
                .began, .chordCaptured(Self.candidate, .accepted), .rebindAnswered(outcome),
            ])
            XCTAssertEqual(answered, .idle, "\(outcome)")
        }
    }

    /// An answer arriving with nothing armed changes nothing — the caller answers the chord it was
    /// handed, and a late answer must not close a recording the user has since restarted.
    func testARebindAnswerWithNothingArmedIsIgnored() {
        let recording = fold([.began, .rebindAnswered(.refused(.notBindable))])
        XCTAssertEqual(recording.phase, .recording, "a late answer must not close a live recording")
        XCTAssertNil(recording.notice)
    }

    // MARK: - Criterion 2: no time-based transition exists

    /// **The closed action set, named here in full.** No time-based action exists, so no
    /// time-based transition can: the reducer takes no clock reading, and the enum below is the
    /// whole of what can reach it (`FailsafeStateReducer`'s never-auto-dismiss rule, applied to a
    /// settings surface for the same reason — nothing should change while a user is reading it).
    ///
    /// The list is asserted against the **source** as well as folded, because a fold cannot fail
    /// on a case it does not know about: adding `.timedOut` would leave every row below passing.
    func testTheActionSetIsClosedAndCarriesNoTimeBasedCase() throws {
        let source = try String(
            contentsOf: PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Sources/VoccaCore/HotkeyRecorderState.swift"),
            encoding: .utf8)
        let stripped = SwiftSourceScanner.stripComments(from: source)
        let characters = Array(stripped)

        guard let declaration = stripped.range(of: "enum HotkeyRecorderAction"),
            let brace = characters[stripped.distance(from: stripped.startIndex, to: declaration.upperBound)...]
                .firstIndex(of: "{"),
            let body = SwiftSourceScanner.bracedBody(in: characters, openingBraceIndex: brace)
        else {
            return XCTFail("HotkeyRecorderAction's declaration could not be found to scan")
        }

        var declared: Set<String> = []
        for line in body.body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case ") else { continue }
            // Names only: an associated-value list carries commas of its own, so the parenthesised
            // groups are skipped rather than split on — `case chordCaptured(A, B)` is one case.
            var depth = 0
            var current = ""
            for character in trimmed.dropFirst(5) {
                switch character {
                case "(": depth += 1
                case ")": depth -= 1
                case "," where depth == 0:
                    declared.insert(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                default:
                    if depth == 0, character.isLetter || character.isNumber || character == "_" {
                        current.append(character)
                    }
                }
            }
            let last = current.trimmingCharacters(in: .whitespaces)
            if !last.isEmpty { declared.insert(last) }
        }

        XCTAssertEqual(
            declared, ["began", "chordCaptured", "confirmed", "cancelled", "rebindAnswered"],
            """
            HotkeyRecorderAction's cases changed. Five things can happen to a recorder, and none \
            of them is a clock: a settings surface that changed its answer because time passed is \
            reporting a scheduling detail as a decision the user made. A sixth case must be \
            argued here, and it must not be a timer.
            """)
    }

    /// Totality: every action folds from every phase, and the only two ways to arm a chord are an
    /// accepted capture and an explicit confirm. Asserted over the cross product rather than per
    /// row, because the failure this guards is a *combination* nobody wrote a row for.
    func testEveryActionFoldsFromEveryPhaseAndOnlyTwoRoutesArmAChord() {
        let warning = HotkeyBindingWarning.usedBySystemShortcut(name: nil)
        let phases: [(HotkeyRecorderState, String)] = [
            (.idle, "idle"),
            (fold([.began]), "recording"),
            (fold([.began, .chordCaptured(Self.candidate, .warned(warning))]), "confirming"),
            (fold([.began, .chordCaptured(Self.candidate, .accepted)]), "applying"),
            (fold([.began, .chordCaptured(Self.bareKey, .refused(.modifierOnly))]), "refused"),
        ]
        let actions: [(HotkeyRecorderAction, String)] = [
            (.began, "began"),
            (.chordCaptured(Self.candidate, .accepted), "captured accepted"),
            (.chordCaptured(Self.candidate, .warned(warning)), "captured warned"),
            (.chordCaptured(Self.bareKey, .refused(.unmodifiedTextEntryKey)), "captured refused"),
            (.confirmed, "confirmed"),
            (.cancelled, "cancelled"),
            (.rebindAnswered(.rebound), "answered rebound"),
            (.rebindAnswered(.refused(.sessionInFlight)), "answered refused"),
        ]

        for (state, phaseName) in phases {
            for (action, actionName) in actions {
                let next = HotkeyRecorderReducer.reduce(state, action)
                guard next.chordToApply != nil, state.chordToApply == nil else { continue }
                let armedByCapture =
                    phaseName == "recording" && actionName == "captured accepted"
                let armedByConfirm = phaseName == "confirming" && actionName == "confirmed"
                XCTAssertTrue(
                    armedByCapture || armedByConfirm,
                    """
                    \(actionName) on \(phaseName) armed a chord. Only an accepted capture during a \
                    recording, and an explicit confirm of a warning, may hand a chord to the \
                    binding — every other route arms a key the user did not ask for, on a machine \
                    where the way to undo it needs that key.
                    """)
            }
        }
    }
}
