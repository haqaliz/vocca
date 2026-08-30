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

/// The keyboard facts the binding rules are decided against — one home each.
///
/// ## These are not `VoccaHotkey`'s `fn` table, and must never be derived from it
///
/// `HotkeyFlagTranslation.keyCodesCarryingFunctionImplicitly` answers *"which key codes does macOS
/// set the `fn` bit on by itself?"*. ``safeUnmodifiedKeyCodes`` answers *"which keys can a person
/// give up entirely?"*. The two overlap heavily and mean nothing alike, and the difference is
/// load-bearing: Forward Delete and the four arrow keys are in the `fn` table and are permanently
/// **out** of the safe set, because binding one swallows it system-wide and a tool whose job is
/// putting text into fields must not take away deleting and navigating in them.
///
/// They also live in different modules on purpose — `VoccaCore` decides, `VoccaHotkey` translates,
/// and `CoreBoundaryTests` forbids the import that would let one read the other. So the literals
/// are duplicated deliberately, and `HotkeyBindingRulesTests` pins the intended *difference*
/// explicitly, so a later "deduplicate these two tables" change fails rather than quietly widening
/// what a user can brick.
///
/// Every value below was read individually from `kVK_*` in `Carbon/HIToolbox/Events.h`. **No entry
/// may be extrapolated from its neighbour**: the F-keys there are neither contiguous nor in
/// numeric order (`kVK_F17` is `0x40` while `kVK_F16` is `0x6A`), and the keypad block has gaps.
public enum HotkeyBindingTables {

    /// The keys a person may bind with **no modifier at all** — `PRODUCT_SPEC.md:322`'s
    /// single-key binding, which `PRODUCT_SPEC.md:257` calls an accessibility requirement rather
    /// than a preference.
    ///
    /// Membership is a judgement, not a measurement (`prd.md` R3): a bound key is swallowed
    /// globally, so a safe key is one nobody needs *while typing*.
    ///
    /// - **F1–F20** — not text entry, not navigation. This is the case the set exists for.
    /// - **Home / End / Page Up / Page Down** — navigation, but not per-keystroke; a user who
    ///   binds one has chosen to lose it, and can still navigate with the arrows.
    /// - **Help** — vestigial on modern keyboards.
    /// - **The ANSI keypad block** — numeric duplicates. A keypad `5` is a distinct key code from
    ///   a main-row `5`, so giving it up costs a user nothing they cannot type on the main rows.
    ///   That reasoning covers Keypad Enter and Keypad Clear equally, so the block is taken whole
    ///   rather than second-guessed key by key.
    ///
    /// Deliberately absent, and to stay absent: **Forward Delete** (`0x75`) is an *editing* key,
    /// and the **arrow keys** (`0x7B`–`0x7E`) are per-keystroke navigation — swallowing an arrow
    /// makes every text field unusable. Both are in the `fn` table, which is exactly why they are
    /// named here: so nobody adds them by pattern-matching it.
    public static let safeUnmodifiedKeyCodes: Set<UInt16> = [
        // The function row. Values read individually; see the warning above.
        0x7A,  // kVK_F1
        0x78,  // kVK_F2
        0x63,  // kVK_F3
        0x76,  // kVK_F4
        0x60,  // kVK_F5
        0x61,  // kVK_F6
        0x62,  // kVK_F7
        0x64,  // kVK_F8
        0x65,  // kVK_F9
        0x6D,  // kVK_F10
        0x67,  // kVK_F11
        0x6F,  // kVK_F12
        0x69,  // kVK_F13
        0x6B,  // kVK_F14
        0x71,  // kVK_F15
        0x6A,  // kVK_F16
        0x40,  // kVK_F17
        0x4F,  // kVK_F18
        0x50,  // kVK_F19
        0x5A,  // kVK_F20

        // Coarse navigation — lost willingly, and the arrows still work.
        0x73,  // kVK_Home
        0x77,  // kVK_End
        0x74,  // kVK_PageUp
        0x79,  // kVK_PageDown

        0x72,  // kVK_Help

        // The ANSI keypad. Distinct codes from the main row, so nothing typable is given up.
        0x52,  // kVK_ANSI_Keypad0
        0x53,  // kVK_ANSI_Keypad1
        0x54,  // kVK_ANSI_Keypad2
        0x55,  // kVK_ANSI_Keypad3
        0x56,  // kVK_ANSI_Keypad4
        0x57,  // kVK_ANSI_Keypad5
        0x58,  // kVK_ANSI_Keypad6
        0x59,  // kVK_ANSI_Keypad7
        0x5B,  // kVK_ANSI_Keypad8
        0x5C,  // kVK_ANSI_Keypad9
        0x41,  // kVK_ANSI_KeypadDecimal
        0x43,  // kVK_ANSI_KeypadMultiply
        0x45,  // kVK_ANSI_KeypadPlus
        0x47,  // kVK_ANSI_KeypadClear
        0x4B,  // kVK_ANSI_KeypadDivide
        0x4C,  // kVK_ANSI_KeypadEnter
        0x4E,  // kVK_ANSI_KeypadMinus
        0x51,  // kVK_ANSI_KeypadEquals
    ]
    /// The keys a person types with — the set ``HotkeyBindingRefusal/unmodifiedTextEntryKey``
    /// is named after.
    ///
    /// **Enumerated, not sampled**, and that is the point: `spec.md`'s second acceptance criterion
    /// drives this whole table through the rules, because a sampled test would miss the one gap
    /// that costs a user a key.
    ///
    /// This table is *not* what the decision reads to refuse — the rule refuses **anything**
    /// unmodified that is not in ``safeUnmodifiedKeyCodes``, so an unlisted or unknown code is
    /// refused too. It exists so the guard has something exhaustive to drive and so the refusal
    /// reason names a set a reader can check, rather than being an assertion about hex.
    ///
    /// `kVK_ISO_Section` is here because it types a character on ISO layouts. The JIS-only codes
    /// (`kVK_JIS_Yen`, `kVK_JIS_Underscore`, `kVK_JIS_KeypadComma`) are deliberately absent: they
    /// are refused anyway by the rule's fallback, and claiming them here would be a judgement
    /// about a keyboard nobody on this project has to test against.
    public static let textEntryKeyCodes: Set<UInt16> = [
        // Letters, in Carbon's own order — which is the physical QWERTY order, not alphabetical.
        0x00,  // kVK_ANSI_A
        0x01,  // kVK_ANSI_S
        0x02,  // kVK_ANSI_D
        0x03,  // kVK_ANSI_F
        0x04,  // kVK_ANSI_H
        0x05,  // kVK_ANSI_G
        0x06,  // kVK_ANSI_Z
        0x07,  // kVK_ANSI_X
        0x08,  // kVK_ANSI_C
        0x09,  // kVK_ANSI_V
        0x0B,  // kVK_ANSI_B
        0x0C,  // kVK_ANSI_Q
        0x0D,  // kVK_ANSI_W
        0x0E,  // kVK_ANSI_E
        0x0F,  // kVK_ANSI_R
        0x10,  // kVK_ANSI_Y
        0x11,  // kVK_ANSI_T
        0x1F,  // kVK_ANSI_O
        0x20,  // kVK_ANSI_U
        0x22,  // kVK_ANSI_I
        0x23,  // kVK_ANSI_P
        0x25,  // kVK_ANSI_L
        0x26,  // kVK_ANSI_J
        0x28,  // kVK_ANSI_K
        0x2D,  // kVK_ANSI_N
        0x2E,  // kVK_ANSI_M

        // Digits. Note 0x16 is 6 and 0x17 is 5 — the header's order, not a transposition here.
        0x12,  // kVK_ANSI_1
        0x13,  // kVK_ANSI_2
        0x14,  // kVK_ANSI_3
        0x15,  // kVK_ANSI_4
        0x16,  // kVK_ANSI_6
        0x17,  // kVK_ANSI_5
        0x19,  // kVK_ANSI_9
        0x1A,  // kVK_ANSI_7
        0x1C,  // kVK_ANSI_8
        0x1D,  // kVK_ANSI_0

        // Punctuation.
        0x18,  // kVK_ANSI_Equal
        0x1B,  // kVK_ANSI_Minus
        0x1E,  // kVK_ANSI_RightBracket
        0x21,  // kVK_ANSI_LeftBracket
        0x27,  // kVK_ANSI_Quote
        0x29,  // kVK_ANSI_Semicolon
        0x2A,  // kVK_ANSI_Backslash
        0x2B,  // kVK_ANSI_Comma
        0x2C,  // kVK_ANSI_Slash
        0x2F,  // kVK_ANSI_Period
        0x32,  // kVK_ANSI_Grave
        0x0A,  // kVK_ISO_Section — types a character on ISO layouts

        // Whitespace and the two editing keys a text field cannot do without.
        0x24,  // kVK_Return
        0x30,  // kVK_Tab
        0x31,  // kVK_Space
        0x33,  // kVK_Delete — backspace, not kVK_ForwardDelete (0x75)
    ]
    /// The keys Vocca has already spent, and so cannot let a user bind.
    ///
    /// Escape alone: it is the session's cancel gesture (`PRODUCT_SPEC.md:129`, routed by
    /// `SessionKeyPolicy`) and the recorder's own abort. Binding it would leave a user mid-session
    /// with no way out, and mid-recording with no way to back out of the recording.
    ///
    /// **A second spelling of a number `VoccaHotkey` already holds**, and deliberately so:
    /// `SessionKeyPolicy.escapeKeyCode` lives in the adapter module and `VoccaCore` imports
    /// nothing (`CoreBoundaryTests`), so there is no constant for both to share. The two are held
    /// together by test instead — `HotkeyBindingRulesTests` asserts they agree, and that both
    /// equal Carbon's `kVK_Escape`, so a matching pair of wrong numbers still fails.
    public static let voccaReservedKeyCodes: Set<UInt16> = [
        0x35  // kVK_Escape — 53, the same number as SessionKeyPolicy.escapeKeyCode
    ]
    /// The modifier keys' own key codes — what ``HotkeyBindingRefusal/modifierOnly`` is decided
    /// from.
    ///
    /// A chord of modifiers and nothing else has no representation in ``HotkeyConfiguration``,
    /// which pairs a key code with a ``ModifierSet``. It reaches the rules as the modifier's *own*
    /// key code, because that is what a recorder observes: pressing ⌘ alone produces an event
    /// carrying `kVK_Command`, not an event with no key. Refusing on that code is what turns
    /// "the user pressed only modifiers" into an answer.
    ///
    /// The right-hand variants are separate codes from the left-hand ones and are all listed;
    /// so are `kVK_CapsLock` and `kVK_Function`, which are modifier keys with codes of their own
    /// even though ``ModifierSet/locking`` masks the first out of every comparison.
    public static let modifierKeyCodes: Set<UInt16> = [
        0x37,  // kVK_Command
        0x36,  // kVK_RightCommand
        0x38,  // kVK_Shift
        0x3C,  // kVK_RightShift
        0x3A,  // kVK_Option
        0x3D,  // kVK_RightOption
        0x3B,  // kVK_Control
        0x3E,  // kVK_RightControl
        0x39,  // kVK_CapsLock
        0x3F,  // kVK_Function
    ]
}
