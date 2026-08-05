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

/// Turns the modifier word macOS puts on a keyboard event into Vocca's own ``ModifierSet``.
///
/// This is the whole of the translation `ModifierSet.swift:23-26` reserves for `VoccaHotkey`, and
/// it is a pure function of two integers. That is deliberate: it is the one part of the event tap
/// that has a decision in it, and it therefore has to live where a machine with no Accessibility
/// grant, no keyboard and no window server can run it. The tap adapter reads the two integers off a
/// real event and calls this; it decides nothing itself.
///
/// ## Why the bits are written out rather than imported
///
/// The constants below are CoreGraphics' `CGEventFlags` values, transcribed. The framework is
/// deliberately **not** imported, for two reasons that point the same way:
///
/// - `ModifierSet`'s raw bit positions are this package's own, starting at bit 0, *specifically* so
///   that nobody can bridge the two worlds with a cast or a `rawValue` round-trip. Having the
///   source values in scope is the temptation that documentation asks to remove.
/// - This module is inside the zero-network coverage guard, and every framework linked into that
///   path is a framework whose start-up behaviour has to be argued about. A `UInt64` needs no
///   argument.
///
/// The cost of transcribing is that a wrong constant is not a compile error — it is a hotkey that
/// silently never fires. `HotkeyFlagTranslationTests` pays that cost off: it drives this function
/// with `CGEventFlags`' own values and `kVK_*`'s own values, so a transcription error here is a
/// test failure rather than a bug report. Do not change a number below without running it.
///
/// Values read from `CGEventTypes.h` (`kCGEventFlagMask*`) in the macOS SDK.
public enum HotkeyFlagTranslation {

    // MARK: - The macOS modifier bits

    /// `kCGEventFlagMaskControl`.
    static let controlBit: UInt64 = 0x0004_0000
    /// `kCGEventFlagMaskAlternate` — the Option key.
    static let alternateBit: UInt64 = 0x0008_0000
    /// `kCGEventFlagMaskShift`.
    static let shiftBit: UInt64 = 0x0002_0000
    /// `kCGEventFlagMaskCommand`.
    static let commandBit: UInt64 = 0x0010_0000
    /// `kCGEventFlagMaskSecondaryFn` — the `fn` key, and also whatever the hardware sets by itself.
    /// Which of those two it means is what ``keyCodesCarryingFunctionImplicitly`` exists to decide.
    static let secondaryFunctionBit: UInt64 = 0x0080_0000
    /// `kCGEventFlagMaskAlphaShift` — Caps Lock.
    static let alphaShiftBit: UInt64 = 0x0001_0000

    /// Read bit by bit rather than by masking the word, so that every bit macOS sets and Vocca has
    /// no member for — `kCGEventFlagMaskHelp`, `kCGEventFlagMaskNumericPad`,
    /// `kCGEventFlagMaskNonCoalesced`, and anything a future macOS adds — is dropped by
    /// construction rather than by an exclusion list that would need maintaining.
    ///
    /// `kCGEventFlagMaskNumericPad` is the one that makes this worth stating: macOS sets it on
    /// every arrow key, which are the same keys that carry `fn` implicitly. A translation that let
    /// an unrecognised bit land on some member would give every arrow-key binding a modifier the
    /// user never pressed — the `fn` bug again, by a second route.
    private static let bitsToModifiers: [(bit: UInt64, modifier: ModifierSet)] = [
        (controlBit, .control),
        (alternateBit, .option),
        (shiftBit, .shift),
        (commandBit, .command),
        (secondaryFunctionBit, .function),
        (alphaShiftBit, .capsLock),
    ]

    // MARK: - The `fn` rule

    /// The key codes macOS sets ``secondaryFunctionBit`` on with **no user involvement at all**.
    ///
    /// On these, the bit is a property of the key, not a report of what the user is holding, so it
    /// is removed before the session rules ever see it. On every other key code the bit means the
    /// user is holding `fn`, and it survives.
    ///
    /// This is the founder's decision recorded in `ModifierSet.swift:65-88`, and this is the only
    /// layer that can implement it: `ModifierSet` never sees a key code, so it cannot tell the two
    /// meanings apart, and adding `fn` to `ModifierSet.locking` instead would fix the accessibility
    /// case while silently breaking every genuine `fn`-held binding.
    ///
    /// Both directions of the list are load-bearing. A key code **missing** from it is a binding
    /// that never fires (configured `[]`, because the event's chord carries `.function` and the
    /// configured one does not) or one that ends on the user's first typed character (configured
    /// `[.function]`, because hold-to-talk stop rule (c) then sees `[] ⊉ [.function]`). A key code
    /// **wrongly present** can never be bound with a genuine `fn` at all, because the bit is gone
    /// before anything compares it.
    ///
    /// Values read individually from `Carbon/HIToolbox/Events.h` (`kVK_*`) in the macOS SDK, and
    /// pinned against it by `HotkeyFlagTranslationTests`. Note that the F-keys are **not
    /// contiguous** there and not in numeric order — `kVK_F17` is `0x40` while `kVK_F16` is `0x6A`
    /// — so no entry may be extrapolated from its neighbour.
    ///
    /// `kVK_Function` (`0x3F`) is deliberately *absent*: pressing `fn` by itself is the
    /// `flagsChanged` event that arms every genuine `fn` binding, and it arrives carrying that key
    /// code with the bit set. Strip it there and no `fn` binding could ever start.
    public static let keyCodesCarryingFunctionImplicitly: Set<UInt16> = [
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
        0x7B,  // kVK_LeftArrow
        0x7C,  // kVK_RightArrow
        0x7E,  // kVK_UpArrow
        0x7D,  // kVK_DownArrow
        0x73,  // kVK_Home
        0x77,  // kVK_End
        0x74,  // kVK_PageUp
        0x79,  // kVK_PageDown
        0x75,  // kVK_ForwardDelete — not kVK_Delete (0x33), which is backspace
        0x72,  // kVK_Help
    ]

    // MARK: - The translation

    /// The modifiers an event carries, as Vocca understands them.
    ///
    /// - Parameters:
    ///   - rawFlags: the event's modifier word — `CGEventFlags`' `rawValue`, taken as an integer so
    ///     that no CoreGraphics type reaches this file. Unrecognised bits are dropped.
    ///   - keyCode: the event's virtual key code. Needed *only* for the `fn` rule, and there is no
    ///     other reason this function is not a function of the flags alone.
    /// - Returns: the modifiers actually held, with an implicitly-set `fn` removed.
    public static func modifiers(rawFlags: UInt64, keyCode: UInt16) -> ModifierSet {
        var modifiers: ModifierSet = []
        for (bit, modifier) in bitsToModifiers where rawFlags & bit != 0 {
            modifiers.insert(modifier)
        }

        if keyCodesCarryingFunctionImplicitly.contains(keyCode) {
            modifiers.remove(.function)
        }

        return modifiers
    }
}
