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

/// The settings window's tabs, and the words on them.
///
/// Four tabs because there are four things a user can decide: how they start a dictation, which
/// engine hears them, what happens to the text afterwards, and which words Vocca gets wrong. Every
/// one of these has been editable since the day it shipped — by hand, in JSON, in Application
/// Support. This window is the same settings with a surface on them.
public enum SettingsTab: String, Sendable, CaseIterable, Identifiable {

    /// The hotkey and how it activates.
    case general
    /// Which speech engine transcribes.
    case speech
    /// What turns raw speech into polished text, and whether that leaves the machine.
    case cleanup
    /// The user's own replacements, for names and jargon the model mishears.
    case dictionary

    public var id: String { rawValue }

    /// The tab's label.
    public var title: String {
        switch self {
        case .general: return "General"
        case .speech: return "Speech"
        case .cleanup: return "Cleanup"
        case .dictionary: return "Dictionary"
        }
    }

    /// The SF Symbol above the label, in the macOS preferences idiom.
    public var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .speech: return "waveform"
        case .cleanup: return "wand.and.stars"
        case .dictionary: return "character.book.closed"
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

    /// The note under the hotkey, which is not rebindable yet.
    ///
    /// Says so plainly rather than showing a recorder that refuses input. A control that looks
    /// editable and is not teaches a user that the app is broken; a sentence teaches them it is
    /// unfinished, which is true and much cheaper to forgive.
    public static let hotkeyNotRebindable =
        "Rebinding isn't available yet. ⌥Space is the only shortcut for now."

    /// The dictionary tab's empty state.
    public static let dictionaryEmpty =
        "No replacements yet. Add one for a name or a piece of jargon Vocca keeps mishearing."

    /// The cleanup tab's note, while the choice is still made in a file rather than here.
    public static let cleanupNotEditable =
        "Choosing a different cleanup provider still means editing cleanup-config.json in "
        + "Application Support. This tab shows what Vocca is actually using."
}
