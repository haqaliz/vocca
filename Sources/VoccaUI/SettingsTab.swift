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

/// The settings window's tabs, and the words on them.
///
/// Five tabs because there are five things a user can decide: how they start a dictation, which
/// engine hears them, what happens to the text afterwards, which words Vocca gets wrong, and how
/// it types into a given application. Every one of these has been editable since the day it
/// shipped — by hand, in JSON, in Application Support. This window is the same settings with a
/// surface on them.
public enum SettingsTab: String, Sendable, CaseIterable, Identifiable {

    /// The hotkey and how it activates.
    case general
    /// Which speech engine transcribes.
    case speech
    /// What turns raw speech into polished text, and whether that leaves the machine.
    case cleanup
    /// The user's own replacements, for names and jargon the model mishears.
    case dictionary
    /// What Vocca learned about typing into each application, and the user's own pins over it.
    case apps

    public var id: String { rawValue }

    /// The tab's label.
    public var title: String {
        switch self {
        case .general: return "General"
        case .speech: return "Speech"
        case .cleanup: return "Cleanup"
        case .dictionary: return "Dictionary"
        case .apps: return "Apps"
        }
    }

    /// The SF Symbol above the label, in the macOS preferences idiom.
    public var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .speech: return "waveform"
        case .cleanup: return "wand.and.stars"
        case .dictionary: return "character.book.closed"
        case .apps: return "square.grid.2x2"
        }
    }
}

/// The settings window's strings, kept out of the views so they can be read without a window
/// server — the `WidgetCopy` shape.
public enum SettingsCopy {

    /// The two activation modes, and why a person would pick each.
    ///
    /// Written as benefit rather than mechanism. "The panel stays open and keeps listening until
    /// you press again" describes what the software does; "Hands-free — best for longer passages"
    /// tells someone which one they want, which is the only question they are asking while looking
    /// at a pair of radio buttons.
    public static let toggleTitle = "Press once to start, press again to stop"
    /// The toggle mode's rationale.
    public static let toggleDetail = "Hands-free. Best for longer passages."
    /// The hold mode's label.
    public static let holdTitle = "Hold the key while speaking"
    /// The hold mode's rationale.
    public static let holdDetail = "Release to type. Best for quick, precise bursts."

    // MARK: - The hotkey recorder

    /// What the control is. The label is here rather than in the view because every other string
    /// on this page is, and a literal in a view is a string with no pin
    /// (``SettingsCopyTests``).
    public static let hotkeyLabel = "Dictation shortcut"

    /// The button that starts a recording.
    public static let hotkeyRecordButton = "Change…"

    /// What the control says while it is listening.
    ///
    /// **It names the way out.** The recorder takes the keyboard for as long as it is the window's
    /// first responder, and a control that has taken the keyboard without saying how to give it
    /// back is a trap — the more so here, where the key the user is about to press is one they are
    /// not sure of.
    public static let hotkeyRecordingPrompt = "Press the new shortcut. Esc to cancel."

    /// The confirm affordance for a chord macOS already claims.
    public static let hotkeyUseAnyway = "Use it anyway"

    /// The way out of that confirmation, which leaves the binding exactly as it was.
    public static let hotkeyCancel = "Cancel"

    /// Why a chord cannot be bound, in words that say **what to press instead**.
    ///
    /// A user who has just been refused is holding a keyboard and looking for a different chord;
    /// "invalid shortcut" sends them back to guessing. Exhaustive over the closed set
    /// (``HotkeyBindingRefusal``), so a fourth reason must be given words here rather than reaching
    /// a user as a blank line under the control that just refused them.
    public static func hotkeyRefusal(_ refusal: HotkeyBindingRefusal) -> String {
        switch refusal {
        case .modifierOnly:
            return "That's a modifier on its own. Hold it together with another key."
        case .reservedByVocca:
            return "Esc is how you stop a dictation, so Vocca keeps that one for itself."
        case .unmodifiedTextEntryKey:
            // The mechanism is deliberately not explained. What matters to the person in front of
            // it is that the bare key would stop typing everywhere, and that a modifier fixes it.
            return "That key types on its own. Add ⌘, ⌥, ⌃ or ⇧ so you can still use it."
        }
    }

    /// The system-shortcut collision, which **warns and never refuses**.
    ///
    /// The user's machine is the authority on their own shortcuts — theirs may be remapped or
    /// switched off — so a collision is something to say, not something to enforce. What the line
    /// must not do is promise an outcome: which of the two receives the key is not something Vocca
    /// can determine, so it says so.
    ///
    /// - Parameter name: what macOS calls the shortcut, or `nil` when the collision is known and
    ///   its owner is not — the common case, since the system's table carries no labels.
    public static func hotkeySystemShortcutWarning(name: String?) -> String {
        let owner = name.map { " for \($0)" } ?? ""
        return "macOS already uses this shortcut\(owner). You can take it anyway, but one of the "
            + "two will win — and it may not be Vocca."
    }

    /// Why a rebind did not take, in the binding's own vocabulary (``RebindRefusal``).
    ///
    /// Distinct from ``hotkeyRefusal(_:)`` because the two lead somewhere different: a refused
    /// chord means *pick another one*, and a refused rebind means *the chord was fine, the moment
    /// was not*.
    public static func hotkeyRebindRefusal(_ refusal: RebindRefusal) -> String {
        switch refusal {
        case .sessionInFlight:
            return "Vocca is listening right now. Stop the dictation, then set the shortcut."
        case .notBindable:
            // Defensive. The recorder refuses an unbindable chord before it ever reaches the
            // binding, so a user should never read this — but a refusal with no words is worse
            // than one that is terse.
            return "That shortcut can't be used."
        }
    }

    /// **The first of two limit sentences**, and the wider one: there is no API to enumerate a
    /// hotkey another process registered, whether through Carbon or through its own event tap. So
    /// Raycast, Alfred and every other launcher are structurally invisible to Vocca's check —
    /// including when they are holding the very chord being bound.
    public static let hotkeyOtherAppsUnknown =
        "Vocca can't see shortcuts other apps have taken, so it can't warn you about those."

    /// **The second limit sentence**, and the one a reader would not guess: macOS records a
    /// shortcut in its own table only when the user has **changed** it. On the authoring machine
    /// that table held 37 entries and Spotlight's untouched ⌘Space was not among them — so an
    /// untouched system shortcut is not merely unnamed, it is absent, and the check cannot see it
    /// either.
    ///
    /// Without this sentence the page implies a complete check of macOS's own shortcuts, which is
    /// the kind of half-truth this tab exists to not tell.
    public static let hotkeyChangedSystemShortcutsOnly =
        "It only knows about macOS shortcuts you've changed yourself — the ones still set the "
        + "way Apple shipped them are invisible to it."

    /// The dictionary tab's empty state.
    public static let dictionaryEmpty =
        "No replacements yet. Add one for a name or a piece of jargon Vocca keeps mishearing."
}
