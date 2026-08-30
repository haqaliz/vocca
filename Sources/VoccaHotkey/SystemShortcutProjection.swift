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

/// Turns decoded shortcut-table entries into the ``SystemShortcut`` values the collision rule
/// compares against.
///
/// ## Why this is a file of its own, and not part of the adapter
///
/// The adapter beside it (`SystemShortcutReader.swift`) is the one file in `Sources/` permitted to
/// name `UserDefaults` for the `systemShortcuts` seam, and it is executed by nothing in CI — it
/// reads the runner's own preferences, and asserting anything about those is asserting a fact
/// about the machine. So everything with a decision in it lives here instead, where a headless
/// suite can drive it. That is the tap adapter's arrangement, applied again.
///
/// ## The modifier word is `CGEventFlags`', so the translation is the one Vocca already has
///
/// `plan_20260830.md` calls the mask *"Carbon's"* and asks for it to be checked against
/// `Carbon/HIToolbox/Events.h`. It was, and the plan is wrong about this: Carbon's `cmdKey` is
/// `1 << cmdKeyBit` with `cmdKeyBit = 8`, which is `0x100`. The plan's own numbers are
/// `1 << 17` … `1 << 20` — `kCGEventFlagMaskShift` through `kCGEventFlagMaskCommand` — and the
/// live plist agrees with them, so its **values** are right and its **attribution** is not.
///
/// That matters, because it means ``HotkeyFlagTranslation`` — already written, already pinned
/// against the SDK's own constants — is exactly the right translation, and transcribing the bits
/// a second time here would be a copy that drifts. It also brings the `fn` rule along, which is
/// load-bearing rather than incidental: macOS sets the `fn` bit on arrow keys and F-keys by
/// itself, so Mission Control's ⌃↑ is stored as `fn | control`, while a recorder produces plain
/// `[.control]` for the same press. Without the rule the two chords are never equal and every
/// arrow-key system shortcut is silently invisible to the collision check.
public enum SystemShortcutProjection {

    /// The shortcuts a decoded table describes, in the order given.
    public static func shortcuts(
        from entries: [SymbolicHotkeyDecoding.DecodedEntry]
    ) -> [SystemShortcut] {
        entries.map { entry in
            SystemShortcut(
                chord: HotkeyChord(
                    keyCode: entry.keyCode,
                    modifiers: HotkeyFlagTranslation.modifiers(
                        rawFlags: entry.rawModifierFlags, keyCode: entry.keyCode)),
                name: nil)
        }
    }
}
