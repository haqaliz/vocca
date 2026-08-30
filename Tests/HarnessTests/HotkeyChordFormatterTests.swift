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
import VoccaBootstrap
import VoccaCore
import XCTest

/// **The one renderer** (`binding-vocabulary/spec.md` M11): how a chord is written for a person to
/// read. Every surface uses it, so no second dialect exists — a user who reads `⌥Space` in the
/// menu bar and `Option+Space` in Settings has been handed two names for one key.
final class HotkeyChordFormatterTests: XCTestCase {

    /// **Criterion 7's load-bearing row.** The shipped binding must render byte-for-byte as the
    /// string the menu bar already shows, so that the day `AppBootstrap.shippedHotkeyDisplayName`
    /// starts coming from here, nothing a user sees changes.
    ///
    /// Asserted against the shipped constant, not against a copy of it: a literal here would
    /// agree with itself while disagreeing with the product.
    func testTheShippedChordRendersAsTheMenuBarAlreadyShowsIt() {
        XCTAssertEqual(
            HotkeyChordFormatter.describe(keyCode: 0x31, modifiers: [.option]),
            AppBootstrap.shippedHotkeyDisplayName)
        XCTAssertEqual(AppBootstrap.shippedHotkeyDisplayName, "⌥Space")
    }
    /// The modifiers render in the platform's canonical order — `fn` first, then `⌃⌥⇧⌘` — whatever
    /// order they were inserted in. macOS writes chords this way everywhere (menus, the Keyboard
    /// pane), so a Vocca that wrote `⌘⌃` would look like a different platform's app for no gain.
    ///
    /// The set is unordered, so "whatever order they were inserted in" is the real hazard: an
    /// implementation that walked the set would render the same chord differently on different
    /// runs.
    func testModifiersRenderInThePlatformsCanonicalOrder() {
        XCTAssertEqual(
            HotkeyChordFormatter.describe(
                keyCode: 0x02, modifiers: [.command, .shift, .option, .control]),
            "⌃⌥⇧⌘D")
        XCTAssertEqual(
            HotkeyChordFormatter.describe(
                keyCode: 0x02, modifiers: [.control, .option, .shift, .command]),
            "⌃⌥⇧⌘D",
            "The same chord rendered differently because it was built in a different order.")
        XCTAssertEqual(
            HotkeyChordFormatter.describe(
                keyCode: 0x69, modifiers: [.command, .function]),
            "fn⌘F13",
            "fn precedes the symbol modifiers, as macOS renders it.")
    }

    /// Caps Lock is never rendered. ``ModifierSet/locking`` masks it out of every comparison, so
    /// showing it would name a modifier that is not part of the binding — and a user would try to
    /// reproduce it.
    func testCapsLockIsNeverRendered() {
        XCTAssertEqual(
            HotkeyChordFormatter.describe(keyCode: 0x31, modifiers: [.option, .capsLock]),
            "⌥Space")
    }
    /// The key-name table, driven as a table. Two rules shape it:
    ///
    /// - a key whose glyph *is* its name renders that glyph (`D`, `7`, `,`) — writing "Comma"
    ///   beside a key printed `,` is a translation the user has to do;
    /// - a key with no glyph renders its printed name (`Space`, `Return`, `F13`, `Home`).
    ///
    /// Keypad keys are named as keypad keys, because that is the entire reason they are bindable:
    /// a "5" that meant either the main-row or the keypad key would be a chord the user cannot
    /// reproduce.
    func testKeysRenderTheNameThatIsPrintedOnThem() {
        let table: [(UInt16, String)] = [
            (0x02, "D"), (0x00, "A"), (0x2E, "M"),
            (0x1D, "0"), (0x1A, "7"),
            (0x2B, ","), (0x2F, "."), (0x2C, "/"), (0x27, "'"), (0x32, "`"),
            (0x18, "="), (0x1B, "-"), (0x21, "["), (0x1E, "]"), (0x2A, "\\"),
            (0x29, ";"), (0x0A, "§"),
            (0x31, "Space"), (0x24, "Return"), (0x30, "Tab"), (0x33, "Delete"),
            (0x35, "Escape"), (0x75, "Forward Delete"),
            (0x7A, "F1"), (0x69, "F13"), (0x40, "F17"), (0x5A, "F20"),
            (0x73, "Home"), (0x77, "End"), (0x74, "Page Up"), (0x79, "Page Down"),
            (0x72, "Help"),
            (0x7B, "←"), (0x7C, "→"), (0x7E, "↑"), (0x7D, "↓"),
            (0x52, "Keypad 0"), (0x57, "Keypad 5"), (0x5C, "Keypad 9"),
            (0x41, "Keypad ."), (0x43, "Keypad *"), (0x45, "Keypad +"),
            (0x4E, "Keypad -"), (0x4B, "Keypad /"), (0x51, "Keypad ="),
            (0x4C, "Keypad Enter"), (0x47, "Keypad Clear"),
        ]
        for (code, name) in table {
            XCTAssertEqual(
                HotkeyChordFormatter.describe(keyCode: code, modifiers: []), name,
                "Key code 0x\(String(code, radix: 16, uppercase: true)) renders wrongly.")
        }
    }

    /// **Every key a binding can legally name has a name here.** Driven over the safe set — the
    /// keys a user may bind bare — so a key that is bindable but renders as `Key 106` cannot ship.
    /// That combination is the worst of both: the recorder accepts the key and then cannot say
    /// what the user just bound.
    func testEverySafeKeyHasARealName() {
        for code in HotkeyBindingTables.safeUnmodifiedKeyCodes.sorted() {
            let rendered = HotkeyChordFormatter.describe(keyCode: code, modifiers: [])
            XCTAssertFalse(
                rendered.hasPrefix("Key "),
                """
                Key code 0x\(String(code, radix: 16, uppercase: true)) is bindable bare but has                 no name, so the recorder would accept it and then show the user a number.
                """)
            XCTAssertFalse(rendered.isEmpty)
        }
    }

    /// An unnamed key code renders as `Key <n>`, never as nothing. A nameless chord is still
    /// better than a blank control: a user shown an empty box cannot tell a binding from a bug,
    /// and the number is at least reproducible in a report.
    func testAnUnknownKeyCodeRendersItsNumber() {
        XCTAssertEqual(HotkeyChordFormatter.describe(keyCode: 0xFF, modifiers: []), "Key 255")
        XCTAssertEqual(
            HotkeyChordFormatter.describe(keyCode: 0xFF, modifiers: [.control]), "⌃Key 255")
    }
    /// A modifier key code contributes **no name of its own**: its glyph is already in the prefix,
    /// so a lone ⌘ renders `⌘` and not `⌘Key 55`.
    ///
    /// Such a chord is refused by ``HotkeyBindingRules`` and can never be a stored binding, so
    /// this only shows while a recorder watches a chord being pressed — which is exactly when a
    /// user is watching the field. The alternative, falling through to the number, would put
    /// visible nonsense on screen for the whole time a user holds a modifier before pressing the
    /// key they mean.
    func testAModifierKeyCodeAddsNoNameOfItsOwn() {
        XCTAssertEqual(HotkeyChordFormatter.describe(keyCode: 0x37, modifiers: [.command]), "⌘")
        XCTAssertEqual(
            HotkeyChordFormatter.describe(keyCode: 0x3B, modifiers: [.control, .shift]), "⌃⇧")
        XCTAssertEqual(
            HotkeyChordFormatter.describe(keyCode: 0x39, modifiers: [.capsLock]), "",
            "Caps Lock is masked from the prefix and named by nothing, so it renders as nothing.")
    }
}
