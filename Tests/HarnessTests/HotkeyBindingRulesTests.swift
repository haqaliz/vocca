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
import VoccaHotkey
import XCTest

/// **What makes a hotkey binding legal** (`binding-vocabulary/spec.md`, M6/M7).
///
/// Every other aspect of `hotkey-rebinding` asks this decision table; nothing else decides it.
/// The asymmetry that shapes these tests is in `plan_20260830.md` §6: a false `refused` is an
/// annoyance the user works around, while a false `accepted` on a text-entry key makes that key
/// untypeable **system-wide**, with the recovery path behind a Settings window that needs the
/// keyboard. So the refusal side is driven over whole tables and the acceptance side is
/// representative.
final class HotkeyBindingRulesTests: XCTestCase {

    // MARK: - The vocabulary

    /// The refusal set is closed at three reasons, and `CaseIterable` is the mechanism the
    /// exhaustiveness test below rides on rather than decoration: a fourth reason added without a
    /// candidate that produces it fails there, not in review.
    func testTheRefusalVocabularyIsClosed() {
        XCTAssertEqual(
            Set(HotkeyBindingRefusal.allCases),
            [.modifierOnly, .reservedByVocca, .unmodifiedTextEntryKey],
            """
            The refusal vocabulary changed. A new reason is a product decision — spec.md names \
            the closed set — and it needs a candidate that produces it before it exists.
            """)
    }
    /// The answer is three-way, and `warned` is not `accepted`. `shortcut-conflicts` needs
    /// somewhere to put "this is legal, and Spotlight already uses it" without inventing a second
    /// vocabulary — and a surface that renders a warning the same as an acceptance has silently
    /// dropped the only thing the warning was for. The conflicting shortcut's **name is part of
    /// the answer's identity**, because "used by another shortcut" and "used by Spotlight" are
    /// different sentences to show a user.
    func testTheValidityAnswerIsThreeWayAndAWarningCarriesItsName() {
        XCTAssertNotEqual(HotkeyBindingValidity.accepted, .warned(.usedBySystemShortcut(name: nil)))
        XCTAssertNotEqual(
            HotkeyBindingValidity.warned(.usedBySystemShortcut(name: "Spotlight")),
            .warned(.usedBySystemShortcut(name: nil)))
        XCTAssertNotEqual(
            HotkeyBindingValidity.refused(.modifierOnly), .refused(.reservedByVocca))
        XCTAssertEqual(HotkeyBindingValidity.refused(.modifierOnly), .refused(.modifierOnly))
    }
    // MARK: - The safe single-key table (M7)

    /// All twenty F-keys are bindable bare, at the codes Carbon actually gives them. This is the
    /// accessibility case `PRODUCT_SPEC.md:322` exists for — a user who cannot hold a chord binds
    /// one key — so a missing entry is not a rounding error, it is that user having no hotkey.
    ///
    /// The codes are asserted individually and **not** generated from a range, because they are
    /// neither contiguous nor in numeric order in `Carbon/HIToolbox/Events.h`: `kVK_F17` is `0x40`
    /// while `kVK_F16` is `0x6A`. A loop would pin a fiction.
    func testEveryFunctionKeyIsInTheSafeSet() {
        let fKeys: [(String, UInt16)] = [
            ("kVK_F1", 0x7A), ("kVK_F2", 0x78), ("kVK_F3", 0x63), ("kVK_F4", 0x76),
            ("kVK_F5", 0x60), ("kVK_F6", 0x61), ("kVK_F7", 0x62), ("kVK_F8", 0x64),
            ("kVK_F9", 0x65), ("kVK_F10", 0x6D), ("kVK_F11", 0x67), ("kVK_F12", 0x6F),
            ("kVK_F13", 0x69), ("kVK_F14", 0x6B), ("kVK_F15", 0x71), ("kVK_F16", 0x6A),
            ("kVK_F17", 0x40), ("kVK_F18", 0x4F), ("kVK_F19", 0x50), ("kVK_F20", 0x5A),
        ]
        for (name, code) in fKeys {
            XCTAssertTrue(
                HotkeyBindingTables.safeUnmodifiedKeyCodes.contains(code),
                "\(name) (0x\(String(code, radix: 16, uppercase: true))) is missing from the "
                    + "safe set, so a user who can only press one key cannot bind it.")
        }
    }
    /// **The difference pin** (`plan_20260830.md` §0.2). ``HotkeyBindingTables/safeUnmodifiedKeyCodes``
    /// and `HotkeyFlagTranslation.keyCodesCarryingFunctionImplicitly` overlap heavily and answer
    /// different questions, so the overlap is not evidence they are the same table. The five keys
    /// below are in the `fn` table and must never be in the safe set: Forward Delete is an editing
    /// key, and an arrow key is per-keystroke navigation — bind either and it is swallowed
    /// system-wide, in a tool whose whole job is putting text into fields.
    ///
    /// Without this test a later "these two lists are nearly identical, deduplicate them" change
    /// re-introduces exactly that bug with a green suite. Vacuity-guarded in both directions: the
    /// two tables must genuinely overlap, or the assertion below is comparing against nothing.
    func testTheSafeSetExcludesTheEditingAndNavigationKeysTheFnTableCarries() {
        let fnTable = HotkeyFlagTranslation.keyCodesCarryingFunctionImplicitly
        let safe = HotkeyBindingTables.safeUnmodifiedKeyCodes

        XCTAssertFalse(
            fnTable.intersection(safe).isEmpty,
            """
            The two tables no longer overlap at all, so this test is asserting a difference             between unrelated things and proves nothing. One of them has moved.
            """)

        let neverSafe: [(String, UInt16)] = [
            ("kVK_ForwardDelete", 0x75), ("kVK_LeftArrow", 0x7B), ("kVK_RightArrow", 0x7C),
            ("kVK_DownArrow", 0x7D), ("kVK_UpArrow", 0x7E),
        ]
        for (name, code) in neverSafe {
            XCTAssertTrue(
                fnTable.contains(code),
                "\(name) left the fn table; this pin no longer guards the deduplication it was "
                    + "written for.")
            XCTAssertFalse(
                safe.contains(code),
                """
                \(name) is bindable bare. Binding it swallows it system-wide, so the user loses                 deleting or navigating in every text field on the machine. It is in the fn table                 and must stay out of this one — the two answer different questions.
                """)
        }
    }
    /// The keypad is safe **because its codes are distinct from the main row's** — that is the
    /// whole argument for including it, so both halves are asserted. A keypad `5` (`0x57`) is
    /// bindable; the main-row `5` (`0x17`) is not, and assuming they share a code is the obvious
    /// mistake this guards (`spec.md`, open questions).
    func testTheKeypadIsSafeAndTheMainRowItDuplicatesIsNot() {
        let keypad: [(String, UInt16)] = [
            ("kVK_ANSI_Keypad0", 0x52), ("kVK_ANSI_Keypad1", 0x53), ("kVK_ANSI_Keypad2", 0x54),
            ("kVK_ANSI_Keypad3", 0x55), ("kVK_ANSI_Keypad4", 0x56), ("kVK_ANSI_Keypad5", 0x57),
            ("kVK_ANSI_Keypad6", 0x58), ("kVK_ANSI_Keypad7", 0x59), ("kVK_ANSI_Keypad8", 0x5B),
            ("kVK_ANSI_Keypad9", 0x5C), ("kVK_ANSI_KeypadDecimal", 0x41),
            ("kVK_ANSI_KeypadMultiply", 0x43), ("kVK_ANSI_KeypadPlus", 0x45),
            ("kVK_ANSI_KeypadClear", 0x47), ("kVK_ANSI_KeypadDivide", 0x4B),
            ("kVK_ANSI_KeypadEnter", 0x4C), ("kVK_ANSI_KeypadMinus", 0x4E),
            ("kVK_ANSI_KeypadEquals", 0x51),
        ]
        for (name, code) in keypad {
            XCTAssertTrue(
                HotkeyBindingTables.safeUnmodifiedKeyCodes.contains(code),
                "\(name) is missing from the safe set; the keypad is taken whole or not at all.")
        }

        let mainRow: [(String, UInt16)] = [
            ("kVK_ANSI_5", 0x17), ("kVK_ANSI_0", 0x1D), ("kVK_ANSI_Period", 0x2F),
            ("kVK_Return", 0x24), ("kVK_ANSI_Equal", 0x18), ("kVK_ANSI_Minus", 0x1B),
        ]
        for (name, code) in mainRow {
            XCTAssertFalse(
                HotkeyBindingTables.safeUnmodifiedKeyCodes.contains(code),
                """
                \(name) is bindable bare. The keypad is safe only because it duplicates the main                 row; the main row itself is what the user types with.
                """)
        }
    }
    // MARK: - The text-entry table

    /// **The bricking guard's ground truth.** Enumerated rather than sampled, because a gap here
    /// is not a missing test — it is one key on the user's keyboard that stops typing, everywhere,
    /// with the fix behind a Settings window they now need the keyboard to reach.
    ///
    /// Every code is named with its `kVK_*` spelling so a transcription error is visible to a
    /// reader rather than hiding in hex. The set is also asserted **disjoint** from the safe set:
    /// a key cannot be both the thing a person types with and the thing they may give up.
    func testTheTextEntryTableHoldsEverythingAPersonTypesWith() {
        let expected: [(String, UInt16)] = [
            ("kVK_ANSI_A", 0x00), ("kVK_ANSI_S", 0x01), ("kVK_ANSI_D", 0x02),
            ("kVK_ANSI_F", 0x03), ("kVK_ANSI_H", 0x04), ("kVK_ANSI_G", 0x05),
            ("kVK_ANSI_Z", 0x06), ("kVK_ANSI_X", 0x07), ("kVK_ANSI_C", 0x08),
            ("kVK_ANSI_V", 0x09), ("kVK_ANSI_B", 0x0B), ("kVK_ANSI_Q", 0x0C),
            ("kVK_ANSI_W", 0x0D), ("kVK_ANSI_E", 0x0E), ("kVK_ANSI_R", 0x0F),
            ("kVK_ANSI_Y", 0x10), ("kVK_ANSI_T", 0x11), ("kVK_ANSI_O", 0x1F),
            ("kVK_ANSI_U", 0x20), ("kVK_ANSI_I", 0x22), ("kVK_ANSI_P", 0x23),
            ("kVK_ANSI_L", 0x25), ("kVK_ANSI_J", 0x26), ("kVK_ANSI_K", 0x28),
            ("kVK_ANSI_N", 0x2D), ("kVK_ANSI_M", 0x2E),
            ("kVK_ANSI_1", 0x12), ("kVK_ANSI_2", 0x13), ("kVK_ANSI_3", 0x14),
            ("kVK_ANSI_4", 0x15), ("kVK_ANSI_6", 0x16), ("kVK_ANSI_5", 0x17),
            ("kVK_ANSI_9", 0x19), ("kVK_ANSI_7", 0x1A), ("kVK_ANSI_8", 0x1C),
            ("kVK_ANSI_0", 0x1D),
            ("kVK_ANSI_Equal", 0x18), ("kVK_ANSI_Minus", 0x1B),
            ("kVK_ANSI_RightBracket", 0x1E), ("kVK_ANSI_LeftBracket", 0x21),
            ("kVK_ANSI_Quote", 0x27), ("kVK_ANSI_Semicolon", 0x29),
            ("kVK_ANSI_Backslash", 0x2A), ("kVK_ANSI_Comma", 0x2B),
            ("kVK_ANSI_Slash", 0x2C), ("kVK_ANSI_Period", 0x2F), ("kVK_ANSI_Grave", 0x32),
            ("kVK_ISO_Section", 0x0A),
            ("kVK_Return", 0x24), ("kVK_Tab", 0x30), ("kVK_Space", 0x31),
            ("kVK_Delete", 0x33),
        ]
        for (name, code) in expected {
            XCTAssertTrue(
                HotkeyBindingTables.textEntryKeyCodes.contains(code),
                """
                \(name) (0x\(String(code, radix: 16, uppercase: true))) is missing from the                 text-entry table, so nothing enumerates it as a key that must never be bound bare.
                """)
        }
        XCTAssertEqual(
            HotkeyBindingTables.textEntryKeyCodes.count, expected.count,
            """
            The text-entry table holds a code this test does not name. Every entry needs its             kVK_* spelling here, or the table is a list of hex nobody can check.
            """)
        XCTAssertTrue(
            HotkeyBindingTables.textEntryKeyCodes
                .isDisjoint(with: HotkeyBindingTables.safeUnmodifiedKeyCodes),
            """
            A key is both typed with and giveable-up. One of the two tables is wrong, and if it             is the safe set the user loses that key system-wide.
            """)
    }
    // MARK: - Vocca's own keys

    /// Escape is reserved, and **Core's spelling of it must equal the tap policy's**. The two
    /// cannot share a constant — `VoccaCore` imports nothing, so it cannot read `VoccaHotkey`'s —
    /// so the duplication is deliberate and this is the pin that stops it drifting. Drift is not
    /// cosmetic: the two halves would disagree about which key cancels, and a binding refused as
    /// reserved in Settings would be a key that no longer cancels anything.
    ///
    /// Both are also checked against `kVK_Escape` (`0x35`, 53) rather than only against each
    /// other, so a matching pair of wrong numbers still fails.
    func testTheReservedKeyIsEscapeAndCoreAgreesWithTheTapPolicy() {
        XCTAssertEqual(HotkeyBindingTables.voccaReservedKeyCodes, [0x35])
        XCTAssertEqual(SessionKeyPolicy.escapeKeyCode, 0x35)
        XCTAssertEqual(
            HotkeyBindingTables.voccaReservedKeyCodes, [SessionKeyPolicy.escapeKeyCode],
            """
            Core and the tap policy disagree about Vocca's cancel key. VoccaCore cannot import             VoccaHotkey, so this pin is the only thing holding the two literals together.
            """)
    }
    /// A chord that is only modifiers has no key to store, and a recorder hands that over as the
    /// **key code of the modifier itself** — a lone ⌘ press arrives as `kVK_Command`, not as an
    /// absent key. So `modifierOnly` is decided from a table, and every modifier key code has to
    /// be in it: the right-hand variants are distinct codes from the left-hand ones, and `fn` and
    /// Caps Lock are modifier keys with codes of their own.
    ///
    /// A gap here is a user binding "⌘ alone" and getting a configuration whose key code is a
    /// modifier — a hotkey that can never match a key-down.
    func testEveryModifierKeyCodeIsNamed() {
        let modifiers: [(String, UInt16)] = [
            ("kVK_Command", 0x37), ("kVK_RightCommand", 0x36),
            ("kVK_Shift", 0x38), ("kVK_RightShift", 0x3C),
            ("kVK_Option", 0x3A), ("kVK_RightOption", 0x3D),
            ("kVK_Control", 0x3B), ("kVK_RightControl", 0x3E),
            ("kVK_CapsLock", 0x39), ("kVK_Function", 0x3F),
        ]
        for (name, code) in modifiers {
            XCTAssertTrue(
                HotkeyBindingTables.modifierKeyCodes.contains(code),
                """
                \(name) (0x\(String(code, radix: 16, uppercase: true))) is not known to be a                 modifier key, so binding it alone produces a hotkey no key-down can match.
                """)
        }
        XCTAssertEqual(HotkeyBindingTables.modifierKeyCodes.count, modifiers.count)
        XCTAssertTrue(
            HotkeyBindingTables.modifierKeyCodes
                .isDisjoint(with: HotkeyBindingTables.safeUnmodifiedKeyCodes),
            "A modifier key is also in the safe set, so it would be accepted rather than refused.")
    }
}
