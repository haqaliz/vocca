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

/// Where a hotkey recording has got to.
///
/// Four phases rather than a `Bool`, because the two that are neither idle nor recording are the
/// ones that carry the product's decisions: a warned chord is waiting on a person, and an armed
/// chord is waiting on the caller that owns the binding. Collapsing either into "recording" would
/// leave the surface unable to tell a question from an answer.
public enum HotkeyRecorderPhase: Sendable, Equatable {

    /// Not recording. The last attempt's outcome, if it had one, is in
    /// ``HotkeyRecorderState/notice``.
    case idle

    /// Watching for a chord. The window's own first responder is consuming keys — never the event
    /// tap, which would swallow them for the whole machine.
    case recording

    /// The chord is legal and something should be said about it first — a system shortcut already
    /// claims it. Nothing is armed until the user says so.
    case confirming(chord: HotkeyChord, warning: HotkeyBindingWarning)

    /// **The chord the caller must now bind.** The reducer is pure and cannot rebind anything, so
    /// this phase is how it asks: the surface reads it, calls the rebind seam, and folds the
    /// answer back as ``HotkeyRecorderAction/rebindAnswered(_:)``.
    case applying(HotkeyChord)
}

/// What the recorder has to say about the last attempt.
///
/// Two sources, kept apart because they are refused by different things and read differently: a
/// ``HotkeyBindingRefusal`` is about the chord itself and is known before anything is attempted; a
/// ``RebindRefusal`` is about the moment — overwhelmingly a dictation in flight — and means *try
/// that again shortly*, not *pick something else*.
public enum HotkeyRecorderNotice: Sendable, Equatable {

    /// The rules would not bind this chord.
    case chordRefused(HotkeyBindingRefusal)

    /// The binding itself refused the change.
    case rebindRefused(RebindRefusal)
}

/// What the hotkey recorder is showing.
public struct HotkeyRecorderState: Sendable, Equatable {

    /// Where the recording has got to.
    public var phase: HotkeyRecorderPhase

    /// What to tell the user about the last attempt, or `nil` when there is nothing to say. An
    /// abandoned recording is `nil`: abandoning is not a failure and must not read as one.
    public var notice: HotkeyRecorderNotice?

    /// The state the tab opens in.
    public static let idle = HotkeyRecorderState(phase: .idle, notice: nil)

    public init(phase: HotkeyRecorderPhase, notice: HotkeyRecorderNotice?) {
        self.phase = phase
        self.notice = notice
    }

    /// The chord the caller must bind now, or `nil`.
    ///
    /// The one output of this whole reducer that changes anything outside the window, which is why
    /// every test asserts on it: a chord reaching here that the user did not ask for is a key made
    /// untypeable on the whole machine, with the way back behind a window that needs it.
    public var chordToApply: HotkeyChord? {
        if case .applying(let chord) = phase { return chord }
        return nil
    }

    /// Whether the control is listening for a chord.
    public var isRecording: Bool { phase == .recording }
}

/// Everything that can happen to a hotkey recorder.
///
/// A closed set with **no time-based case in it** — the ``HotkeyRecorderPhase`` fold takes no
/// clock reading and there is nothing here for one to arrive through. That is the house rule
/// (`FailsafeStateReducer`'s never-auto-dismiss, `AppsTabAction`'s clock-free set) and it applies
/// here for the sharpest version of the reason: a recorder that timed out mid-chord would return
/// to idle under a user who is still choosing, and the next key they press would land in whatever
/// they were typing into before.
public enum HotkeyRecorderAction: Sendable, Equatable {

    /// The user clicked the control. Starts a recording and clears the last attempt's notice.
    case began

    /// A chord arrived, with the answer ``HotkeyBindingRules`` and ``SystemShortcutRules`` gave
    /// for it. **The validity is handed in, never re-derived here** — the recorder, the launch
    /// read and the binding's own gate give one answer or they give three.
    case chordCaptured(HotkeyChord, HotkeyBindingValidity)

    /// The user accepted a warning and wants the chord anyway.
    case confirmed

    /// Escape, a click away, or declining a warning. Aborts without arming anything.
    case cancelled

    /// What the binding said about the chord this recorder handed it.
    case rebindAnswered(RebindOutcome)
}

/// The hotkey recorder's decisions — pure, clock-free, and holding no validation of its own.
public enum HotkeyRecorderReducer {

    public static func reduce(
        _ state: HotkeyRecorderState, _ action: HotkeyRecorderAction
    ) -> HotkeyRecorderState {
        switch action {
        case .began:
            // The notice goes with it. A stale refusal sitting under a live recorder reads as a
            // refusal of the chord being pressed now.
            return HotkeyRecorderState(phase: .recording, notice: nil)

        case .chordCaptured(let chord, let validity):
            // Only during a recording. The recorder is a first-responder override in Vocca's own
            // window, so keys can reach it while nothing is being recorded — and folding one would
            // rebind the hotkey to whatever the user last typed.
            guard case .recording = state.phase else { return state }
            switch validity {
            case .accepted:
                return HotkeyRecorderState(phase: .applying(chord), notice: nil)
            case .warned(let warning):
                return HotkeyRecorderState(
                    phase: .confirming(chord: chord, warning: warning), notice: nil)
            case .refused(let refusal):
                return HotkeyRecorderState(phase: .idle, notice: .chordRefused(refusal))
            }

        case .confirmed:
            guard case .confirming(let chord, _) = state.phase else { return state }
            return HotkeyRecorderState(phase: .applying(chord), notice: nil)

        case .cancelled:
            switch state.phase {
            case .recording, .confirming:
                return HotkeyRecorderState(phase: .idle, notice: nil)
            case .idle, .applying:
                // Nothing to abandon. An armed chord is already with the caller, and pretending
                // otherwise would leave the page and the binding disagreeing about what happened.
                return state
            }

        case .rebindAnswered(let outcome):
            guard case .applying = state.phase else { return state }
            switch outcome {
            case .rebound, .unchanged:
                // Nothing to say: the control now shows the chord the user asked for, which is the
                // whole of the feedback.
                return .idle
            case .refused(let refusal):
                return HotkeyRecorderState(phase: .idle, notice: .rebindRefused(refusal))
            }
        }
    }
}
