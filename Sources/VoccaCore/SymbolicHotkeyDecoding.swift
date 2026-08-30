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

/// The decode of Apple's own shortcut table, **as a function of integers**.
///
/// ## The format, and why every field is treated as hostile
///
/// `com.apple.symbolichotkeys` holds `AppleSymbolicHotKeys`: a dictionary keyed by an opaque
/// integer identifier, each value carrying an `enabled` flag and a `value.parameters` triple
/// `[characterCode, keyCode, modifierMask]`. None of that is documented by Apple. It is read here
/// from two primary sources on a real machine (2026-08-30): the live plist, and
/// `KeyboardSettings.appex/Contents/Resources/DefaultSpacesShortcuts.xml`, which Apple ships and
/// which declares identifier 118 as key 18, modifier 262144 — matching the live entry byte for
/// byte. That agreement is the whole of the evidence for the layout, and it may stop being true
/// in any macOS release.
///
/// So **every failure is silence**: absent, truncated, wrongly typed, out of range, disabled — all
/// yield nothing. Nothing here throws and nothing here refuses. The worst outcome of a wrong
/// decode is that Vocca fails to mention a collision the user notices within seconds anyway.
///
/// ## Why `parameters[0]` is never read
///
/// It is the **character code** — what the key produces on the current layout. Identifier 118's is
/// 49, the character `1`, which is 49 only on layouts where that key types a `1`; the key code
/// beside it, 18, is the same on every layout. A decode built on the character code would drift
/// with the user's keyboard layout, which is exactly the bug the key code exists to avoid.
///
/// ## Why this takes `Int?`s rather than plist objects
///
/// `VoccaCore` imports nothing, and that is not a formality here — it is what puts every decision
/// about a malformed entry on the side of the seam a headless CI run can reach. The adapter casts
/// each element and hands over what it found, **preserving position and arity**, so a
/// non-integer at any one position arrives as a `nil` in place rather than collapsing the whole
/// array. Every judgement about what that means is made below.
public enum SymbolicHotkeyDecoding {

    /// One entry, already lifted out of the plist by the adapter and reduced to integers.
    public struct RawEntry: Sendable, Equatable {

        /// The dictionary key — an opaque identifier. Carried through so
        /// ``SystemShortcutNames`` can name the few that are nameable.
        public let identifier: Int

        /// The entry's `enabled` flag: `nil` when absent or not a boolean.
        public let isEnabled: Bool?

        /// `value.parameters`, element by element: `nil` for the whole array when it is absent or
        /// not an array, and `nil` **in place** for an element that is not an integer.
        public let parameters: [Int?]?

        public init(identifier: Int, isEnabled: Bool?, parameters: [Int?]?) {
            self.identifier = identifier
            self.isEnabled = isEnabled
            self.parameters = parameters
        }
    }

    /// A usable entry: an identifier, a key code and the modifier word as macOS wrote it.
    ///
    /// The modifier word is left **untranslated** on purpose. Translating it needs the same rules
    /// the event tap already applies to a live key press — including the `fn` rule, which needs
    /// the key code — and those live in `VoccaHotkey`, in a function that is already pinned
    /// against the SDK's own constants. Transcribing them a second time here would be a duplicate
    /// that can drift silently, and a drifted copy shows up as a hotkey warning that never
    /// appears, which nobody reports.
    public struct DecodedEntry: Sendable, Equatable {
        public let identifier: Int
        public let keyCode: UInt16
        public let rawModifierFlags: UInt64

        public init(identifier: Int, keyCode: UInt16, rawModifierFlags: UInt64) {
            self.identifier = identifier
            self.keyCode = keyCode
            self.rawModifierFlags = rawModifierFlags
        }
    }

    /// The value macOS writes where a shortcut has **no key**: `0xFFFF`.
    ///
    /// Read off the live plist rather than reasoned about — on the authoring machine identifiers
    /// 163, 164, 175 and 222 all read `[65535, 65535, 0]`, and every unbound row carries it in
    /// position 0. An entry with no key occupies no chord, so it is dropped rather than admitted
    /// as a shortcut bound to key 65535.
    public static let noKeySentinel = 65535

    /// Decode one entry, or answer nothing.
    public static func decode(_ entry: RawEntry) -> DecodedEntry? {
        // An entry the user has switched off does not occupy its chord, and an entry whose flag
        // is absent or not a boolean is a shape this decode does not understand. Both are silence:
        // the second could be read as "enabled by default", but that is a guess about an
        // undocumented format, and guessing here spends the user's trust on a warning about a
        // shortcut that may not exist.
        guard entry.isEnabled == true else { return nil }

        guard let parameters = entry.parameters, parameters.count >= 3 else { return nil }
        guard let rawKeyCode = parameters[1], let rawModifiers = parameters[2] else { return nil }
        guard rawKeyCode != noKeySentinel else { return nil }
        guard let keyCode = UInt16(exactly: rawKeyCode) else { return nil }
        guard let modifiers = UInt64(exactly: rawModifiers) else { return nil }
        return DecodedEntry(
            identifier: entry.identifier, keyCode: keyCode, rawModifierFlags: modifiers)
    }

    /// Decode a whole table, dropping what it cannot read.
    ///
    /// One entry macOS changed the shape of must cost that entry and nothing else. A decode that
    /// gave up on the array would silence the entire check over a single row, and silence is
    /// already this aspect's answer to enough things.
    public static func decode(_ entries: [RawEntry]) -> [DecodedEntry] {
        entries.compactMap(decode)
    }
}
