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

import XCTest

@testable import VoccaCore

/// `shortcut-conflicts` M8: the pure decision above the ``SystemShortcutReader`` seam — does a
/// candidate chord collide with something the system has already claimed, and what is it called.
///
/// **The answer is a warning or nothing. There is no third branch, and there must never be one.**
/// The user's machine is the authority on their own Spotlight, not our table: a chord we believe
/// is taken may have been remapped or turned off, and refusing it would be Vocca overruling a
/// user about their own keyboard on the strength of a preferences file it does not own.
final class SystemShortcutRulesTests: XCTestCase {

    // MARK: - Criterion 1: a match warns, and names what it can

    /// A candidate matching an occupied chord warns, carrying the occupant's name.
    func testAMatchingChordWarnsAndNamesTheShortcut() {
        let chord = HotkeyChord(keyCode: 49, modifiers: [.command])
        let occupied = [SystemShortcut(chord: chord, name: "Switch to Desktop 1")]

        XCTAssertEqual(
            SystemShortcutRules.warning(for: chord, against: occupied),
            .usedBySystemShortcut(name: "Switch to Desktop 1"),
            """
            A candidate the system has already claimed must warn, and must carry the name so the \
            recorder can say whose shortcut it is rather than that "something" uses it.
            """)
    }

    /// A candidate nothing has claimed earns no warning — and neither does one checked against a
    /// reader that knows nothing at all, which is what every decode failure degrades to.
    func testAnUnclaimedChordAndAnEmptyTableBothWarnAboutNothing() {
        let occupied = [
            SystemShortcut(chord: HotkeyChord(keyCode: 49, modifiers: [.command]), name: "Taken")
        ]

        XCTAssertNil(
            SystemShortcutRules.warning(
                for: HotkeyChord(keyCode: 49, modifiers: [.option]), against: occupied),
            "⌥Space is not ⌘Space: the modifiers are part of the chord, not decoration on it.")
        XCTAssertNil(
            SystemShortcutRules.warning(
                for: HotkeyChord(keyCode: 48, modifiers: [.command]), against: occupied),
            "A different key with the same modifier is a different chord.")
        XCTAssertNil(
            SystemShortcutRules.warning(
                for: HotkeyChord(keyCode: 49, modifiers: [.command]), against: []),
            """
            An empty table is what an absent, unreadable or unparseable shortcut file degrades to, \
            and it must read as silence rather than as an error with nowhere to go.
            """)
    }

    // MARK: - Criterion 3: an unnamed collision is still a collision

    /// A match we cannot name still warns, with `name: nil`.
    ///
    /// This is the **common** path, not the exotic one: `com.apple.symbolichotkeys` is keyed by
    /// opaque integers, and Vocca can name only the identifiers it verified against a table Apple
    /// ships. Dropping the rest would hide real collisions behind the ones we happen to have
    /// labels for.
    func testAnUnnamedOccupantStillWarns() {
        let chord = HotkeyChord(keyCode: 126, modifiers: [.control])

        XCTAssertEqual(
            SystemShortcutRules.warning(
                for: chord, against: [SystemShortcut(chord: chord, name: nil)]),
            .usedBySystemShortcut(name: nil),
            "An unnamed collision is still a collision; silence here would hide a real one.")
    }

    /// When two entries hold the same chord, the named one is reported.
    ///
    /// Order-independent on purpose — the plist is a dictionary and its iteration order is not a
    /// promise, so a rule that reported "whichever came first" would name the shortcut on some
    /// runs and not on others.
    func testANamedOccupantIsPreferredOverAnUnnamedOneInEitherOrder() {
        let chord = HotkeyChord(keyCode: 49, modifiers: [.control])
        let unnamed = SystemShortcut(chord: chord, name: nil)
        let named = SystemShortcut(chord: chord, name: "Select the previous input source")

        for occupied in [[unnamed, named], [named, unnamed]] {
            XCTAssertEqual(
                SystemShortcutRules.warning(for: chord, against: occupied),
                .usedBySystemShortcut(name: "Select the previous input source"),
                """
                A named occupant must win over an unnamed one whichever order the table arrives \
                in: the plist is a dictionary, and its order is not a promise.
                """)
        }
    }

    /// Caps Lock is not part of a chord on either side of the comparison.
    ///
    /// ``HotkeyChord``'s initialiser masks ``ModifierSet/locking`` out, so this is a pin on that
    /// masking reaching the collision check too — a user who recorded their chord with Caps Lock
    /// on must get the same answer as one who did not.
    func testCapsLockIsNotPartOfTheComparison() {
        let occupied = [
            SystemShortcut(
                chord: HotkeyChord(keyCode: 49, modifiers: [.command, .capsLock]), name: "Taken")
        ]

        XCTAssertEqual(
            SystemShortcutRules.warning(
                for: HotkeyChord(keyCode: 49, modifiers: [.command]), against: occupied),
            .usedBySystemShortcut(name: "Taken"),
            "A chord recorded with Caps Lock on is the same chord as one recorded without.")
    }

    // MARK: - Criterion 5: a warning never blocks

    /// **Every answer this aspect can produce is adoptable.** Not "`.warned` is adoptable" in the
    /// abstract — that is pinned elsewhere — but the two shapes ``SystemShortcutRules`` actually
    /// returns, taken from the function rather than written out beside it.
    ///
    /// This is the pin the whole aspect rests on. `shortcut-conflicts` reads a preferences file
    /// Vocca does not own, in a format Apple does not document, about shortcuts the user may have
    /// remapped or switched off. If a detection change could ever become a refusal, a wrong guess
    /// in that file would stop a user binding a chord that is, on their machine, entirely free —
    /// and the recovery path is a Settings window they reach with the keyboard.
    func testEveryWarningThisAspectProducesIsAdoptable() {
        let chord = HotkeyChord(keyCode: 49, modifiers: [.command])
        let produced = [
            SystemShortcutRules.warning(
                for: chord, against: [SystemShortcut(chord: chord, name: "Named")]),
            SystemShortcutRules.warning(
                for: chord, against: [SystemShortcut(chord: chord, name: nil)]),
        ]

        for warning in produced {
            let warning = try? XCTUnwrap(warning)
            guard let warning else { return XCTFail("a colliding chord must produce a warning") }
            XCTAssertTrue(
                PersistedSettings.isAdoptable(.warned(warning)),
                """
                \(warning) must be adoptable. A conflict Vocca detected in a file it does not own \
                is something to say, never something to enforce: the user's machine is the \
                authority on their own shortcuts, and refusing here would overrule them on the \
                strength of a guess.
                """)
        }
    }
}
