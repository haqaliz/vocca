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

/// How a chord is written for a person to read — the one renderer, used by every surface
/// (`binding-vocabulary/spec.md` M11).
public enum HotkeyChordFormatter {

    /// The chord as a user reads it, e.g. `⌥Space`.
    public static func describe(keyCode: UInt16, modifiers: ModifierSet) -> String {
        let bindable = modifiers.subtracting(.locking)

        var rendered = ""
        if bindable.contains(.function) { rendered += "fn" }
        if bindable.contains(.control) { rendered += "⌃" }
        if bindable.contains(.option) { rendered += "⌥" }
        if bindable.contains(.shift) { rendered += "⇧" }
        if bindable.contains(.command) { rendered += "⌘" }

        return rendered + keyName(for: keyCode)
    }

    /// What is printed on the key, or the closest thing to it.
    ///
    /// A key whose glyph *is* its name renders that glyph — `D`, `7`, `,` — because writing
    /// "Comma" beside a key printed `,` asks the user to translate. A key with no glyph renders
    /// its printed name: `Space`, `Return`, `F13`, `Home`.
    ///
    /// A modifier key renders **nothing**: its glyph is already in the prefix, and `⌘Key 55` is
    /// not a thing to show anyone. Such a chord is refused by ``HotkeyBindingRules`` and cannot be
    /// a stored binding, so this only ever shows while a recorder watches a chord being pressed.
    ///
    /// Anything else — an unusual keyboard, a layout nobody here has — renders `Key <n>` rather
    /// than the empty string. A user shown a blank control cannot tell a binding from a bug, and
    /// the number is at least something they can put in a report.
    private static func keyName(for keyCode: UInt16) -> String {
        if let named = names[keyCode] { return named }
        if HotkeyBindingTables.modifierKeyCodes.contains(keyCode) { return "" }
        return "Key \(keyCode)"
    }

    /// Every key code Vocca can name, `kVK_*` values read individually from
    /// `Carbon/HIToolbox/Events.h`. Covers the whole of ``HotkeyBindingTables/safeUnmodifiedKeyCodes``
    /// — a key that is bindable but nameless would be accepted by the recorder and then shown to
    /// the user as a number — plus everything a modified chord can legally name.
    private static let names: [UInt16: String] = [
        // Letters, in Carbon's physical order.
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x1F: "O",
        0x20: "U", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x28: "K",
        0x2D: "N", 0x2E: "M",

        // Digits — 0x16 is 6 and 0x17 is 5 in the header, not a transposition here.
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
        0x19: "9", 0x1A: "7", 0x1C: "8", 0x1D: "0",

        // Punctuation renders as the glyph on the key.
        0x18: "=", 0x1B: "-", 0x1E: "]", 0x21: "[", 0x27: "'", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2F: ".", 0x32: "`",
        0x0A: "§",  // kVK_ISO_Section

        // Keys with no glyph render their printed name.
        0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "Delete",
        0x35: "Escape", 0x75: "Forward Delete",

        // The function row.
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
        0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
        0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
        0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",

        // Navigation.
        0x73: "Home", 0x77: "End", 0x74: "Page Up", 0x79: "Page Down", 0x72: "Help",
        0x7B: "←", 0x7C: "→", 0x7E: "↑", 0x7D: "↓",

        // The keypad, named as the keypad: a bare "5" would not say which key was bound.
        0x52: "Keypad 0", 0x53: "Keypad 1", 0x54: "Keypad 2", 0x55: "Keypad 3",
        0x56: "Keypad 4", 0x57: "Keypad 5", 0x58: "Keypad 6", 0x59: "Keypad 7",
        0x5B: "Keypad 8", 0x5C: "Keypad 9",
        0x41: "Keypad .", 0x43: "Keypad *", 0x45: "Keypad +", 0x47: "Keypad Clear",
        0x4B: "Keypad /", 0x4C: "Keypad Enter", 0x4E: "Keypad -", 0x51: "Keypad =",
    ]
}
