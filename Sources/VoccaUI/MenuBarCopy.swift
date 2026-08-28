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

/// The menu bar's symbols and words — one file, so the icon, the status line and the VoiceOver
/// label for a state can never drift out of agreement with each other.
public enum MenuBarCopy {

    /// The SF Symbol the status item draws, rendered as a **template image**: monochrome, tinted
    /// by the system to match a light or dark menu bar automatically.
    ///
    /// ## Shape carries the state. Colour carries nothing.
    ///
    /// A template image is drawn in one colour by definition, so there is no colour available to
    /// encode with even if it were wanted — which makes the design's "state differentiated by
    /// shape only" rule the platform's rule too, not a preference. It is also the accessibility
    /// requirement (`PRODUCT_SPEC.md:288` — every distinction carries shape and text, never colour
    /// alone) satisfied by construction rather than by discipline.
    ///
    /// The grammar, so a later state has an obvious place to sit:
    ///
    /// - **Outline mic** — idle and able (``MenuBarState/ready``).
    /// - **Filled mic** — capturing. Fill means live audio, and only that.
    /// - **Waveform** — working on audio already captured.
    /// - **Slashed mic** — the microphone itself is unavailable.
    /// - **Lock** — something outside Vocca is holding the keyboard.
    /// - **Downward arrow** — bytes are arriving.
    /// - **Triangle** — the user must go and grant something; the only state they cannot resolve
    ///   from inside the app, and the only one that earns an alarm shape.
    public static func symbolName(for state: MenuBarState) -> String {
        switch state {
        case .ready: return "mic"
        case .listening: return "mic.fill"
        case .transcribing: return "waveform"
        case .noAccessibility: return "exclamationmark.triangle"
        case .noMicrophone: return "mic.slash"
        case .downloadingModel: return "arrow.down.circle"
        case .preparingEngine: return "hourglass"
        case .secureInput: return "lock"
        }
    }

    /// The menu's first line: what Vocca is doing, in words, without the user having to read an
    /// icon they have never seen before.
    public static func statusTitle(for state: MenuBarState) -> String {
        switch state {
        case .ready: return "Vocca is ready"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .noAccessibility: return "Vocca can't hear the hotkey"
        case .noMicrophone: return "No microphone"
        case .downloadingModel: return "Getting ready"
        case .preparingEngine: return "Warming up"
        case .secureInput: return "Hotkey paused by another app"
        }
    }

    /// The line under the title: what that means, and what to do about it.
    ///
    /// Written as consequence-then-remedy rather than as a diagnosis. "Accessibility permission
    /// missing" tells a user what a developer already knew; "Vocca can't hear the hotkey" tells
    /// them why nothing happened when they pressed it, which is the question they actually have.
    public static func statusDetail(for state: MenuBarState, hotkey: String) -> String {
        switch state {
        case .ready:
            return "Press \(hotkey) to start dictating."
        case .listening:
            return "Press \(hotkey) again to stop, or Esc to discard."
        case .transcribing:
            return "Turning what you said into text."
        case .noAccessibility:
            return "macOS needs your permission before Vocca can see \(hotkey). "
                + "Nothing else works until it does."
        case .noMicrophone:
            return "Vocca can't reach a microphone. Check that one is connected and that "
                + "Vocca is allowed to use it."
        case .downloadingModel:
            return "Downloading the speech model. Dictation works as soon as it finishes."
        case .preparingEngine:
            return "Loading the speech model. Dictation works as soon as it's ready."
        case .secureInput:
            return "Another app is in a password field, so macOS is hiding the keyboard from "
                + "everything — including Vocca. This clears up on its own."
        }
    }

    /// The button a blocked state offers, when there is somewhere useful to send the user.
    ///
    /// `nil` for the states with nothing to press. ``MenuBarState/secureInput`` is the case worth
    /// stating outright: it resolves by leaving the password field, so a button would be an action
    /// that does nothing, offered to someone who has done nothing wrong. Saying so and offering
    /// nothing is the honest surface.
    public static func actionTitle(for state: MenuBarState) -> String? {
        switch state {
        case .noAccessibility: return "Open System Settings…"
        case .noMicrophone: return "Open Privacy Settings…"
        case .downloadingModel: return "Show progress…"
        // `preparingEngine` offers nothing on purpose: a warm-up has no progress window to open
        // and no setting to change. It ends on its own, exactly as Secure Input does, and a button
        // would be an action that does nothing.
        case .ready, .listening, .transcribing, .preparingEngine, .secureInput: return nil
        }
    }

    /// The status item's VoiceOver label — the title and its detail as one sentence, because the
    /// button is a single element and its icon is meaningless to a screen reader.
    public static func accessibilityLabel(for state: MenuBarState, hotkey: String) -> String {
        "Vocca. \(statusTitle(for: state)). \(statusDetail(for: state, hotkey: hotkey))"
    }
}
