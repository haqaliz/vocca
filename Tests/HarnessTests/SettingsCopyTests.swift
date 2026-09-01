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
import VoccaUI
import XCTest

/// **The settings window's words** — the first byte-for-byte pin ``SettingsCopy`` has ever had.
///
/// It shipped with none (PRD R5), which is why deleting ``SettingsCopy/hotkeyNotRebindable`` —
/// *"Rebinding isn't available yet. ⌥Space is the only shortcut for now."* — was a change no test
/// in the suite would have noticed. That string became **false** the moment this aspect shipped,
/// and a settings window that tells a user a working control does not exist is worse than one that
/// never mentioned it: they will believe it and stop looking.
///
/// So the string is gone, not softened, and this file is the guard that the next one cannot drift
/// unremarked. The last assertion is the load-bearing one: it reads the enum's own source and
/// demands that every member below is pinned here, so a string added without a pin fails rather
/// than joining the four that had none.
final class SettingsCopyTests: XCTestCase {

    // MARK: - Activation

    /// The two activation modes, written as benefit rather than mechanism: "Hands-free" tells
    /// someone which radio button they want, which is the only question they are asking.
    func testTheActivationModesReadAsBenefitsRatherThanMechanisms() {
        XCTAssertEqual(SettingsCopy.toggleTitle, "Press once to start, press again to stop")
        XCTAssertEqual(SettingsCopy.toggleDetail, "Hands-free. Best for longer passages.")
        XCTAssertEqual(SettingsCopy.holdTitle, "Hold the key while speaking")
        XCTAssertEqual(
            SettingsCopy.holdDetail, "Release to type. Best for quick, precise bursts.")
    }

    /// The dictionary tab's empty state.
    func testTheDictionaryEmptyStateIsPinned() {
        XCTAssertEqual(
            SettingsCopy.dictionaryEmpty,
            "No replacements yet. Add one for a name or a piece of jargon Vocca keeps mishearing.")
    }

    // MARK: - Keep in tray

    /// The toggle's label says the menu bar, not "tray" — the product's own vocabulary
    /// (`OnboardingCopy.doneCopy`: "Vocca lives in your menu bar").
    func testTheKeepInTrayToggleIsPinned() {
        XCTAssertEqual(SettingsCopy.keepInTrayTitle, "Keep in menu bar")
    }

    /// The detail names both the path the option intercepts (⌘Q, U+2318 — the glyph asserted
    /// as-is) and the path it never touches: the tray menu's own Quit always quits, so the option
    /// can never hold the app hostage.
    func testTheKeepInTrayDetailIsPinned() {
        XCTAssertEqual(
            SettingsCopy.keepInTrayDetail,
            "Quitting from the Dock (⌘Q) leaves Vocca running in the menu bar. Use Quit Vocca to quit.")
        XCTAssertTrue(
            SettingsCopy.keepInTrayDetail.contains("⌘"),
            "the glyph must be the real ⌘ (U+2318), not a lookalike")
    }

    // MARK: - The recorder

    /// The control and the prompt it becomes. The prompt names the way out, because a control that
    /// has taken the keyboard and does not say how to give it back is a trap.
    func testTheRecorderControlNamesItselfAndTheWayOut() {
        XCTAssertEqual(SettingsCopy.hotkeyLabel, "Dictation shortcut")
        XCTAssertEqual(SettingsCopy.hotkeyRecordButton, "Change…")
        XCTAssertEqual(
            SettingsCopy.hotkeyRecordingPrompt, "Press the new shortcut. Esc to cancel.")
        XCTAssertEqual(SettingsCopy.hotkeyUseAnyway, "Use it anyway")
        XCTAssertEqual(SettingsCopy.hotkeyCancel, "Cancel")
    }

    /// Every refusal says **what to do next**, not what went wrong. A user refused a chord is
    /// holding a keyboard and looking for a different one; "invalid shortcut" sends them back to
    /// guessing.
    func testEveryChordRefusalTellsTheUserWhatToPressInstead() {
        XCTAssertEqual(
            SettingsCopy.hotkeyRefusal(.modifierOnly),
            "That's a modifier on its own. Hold it together with another key.")
        XCTAssertEqual(
            SettingsCopy.hotkeyRefusal(.reservedByVocca),
            "Esc is how you stop a dictation, so Vocca keeps that one for itself.")
        XCTAssertEqual(
            SettingsCopy.hotkeyRefusal(.unmodifiedTextEntryKey),
            "That key types on its own. Add ⌘, ⌥, ⌃ or ⇧ so you can still use it.")
    }

    /// The closed set is covered: a fourth refusal must be given words here rather than reaching a
    /// user as a blank line under a control that just refused them.
    func testEveryChordRefusalHasDistinctNonEmptyCopy() {
        let lines = HotkeyBindingRefusal.allCases.map(SettingsCopy.hotkeyRefusal)
        XCTAssertFalse(lines.contains(where: \.isEmpty), "a refusal with no words is a blank page")
        XCTAssertEqual(
            Set(lines).count, lines.count,
            "two refusals read identically — the reason is the half the user needs")
    }

    /// The system-shortcut warning **warns and does not refuse**, and says who wins is not
    /// guaranteed. The user's machine is the authority on their own shortcuts.
    func testTheSystemShortcutWarningNamesTheOwnerWhenItCan() {
        XCTAssertEqual(
            SettingsCopy.hotkeySystemShortcutWarning(name: "Switch to Desktop 1"),
            "macOS already uses this shortcut for Switch to Desktop 1. You can take it anyway, "
                + "but one of the two will win — and it may not be Vocca.")
        XCTAssertEqual(
            SettingsCopy.hotkeySystemShortcutWarning(name: nil),
            "macOS already uses this shortcut. You can take it anyway, but one of the two will "
                + "win — and it may not be Vocca.")
    }

    /// The mid-dictation refusal, which is the one a user will actually meet: it says the change
    /// did not happen and what to do, rather than leaving a rebind that appears not to have
    /// registered — the second attempt is made on a keyboard whose binding they are no longer
    /// sure of.
    func testTheRebindRefusalsAreCoveredAndActionable() {
        XCTAssertEqual(
            SettingsCopy.hotkeyRebindRefusal(.sessionInFlight),
            "Vocca is listening right now. Stop the dictation, then set the shortcut.")
        XCTAssertEqual(
            SettingsCopy.hotkeyRebindRefusal(.notBindable),
            "That shortcut can't be used.")

        let lines = RebindRefusal.allCases.map(SettingsCopy.hotkeyRebindRefusal)
        XCTAssertFalse(lines.contains(where: \.isEmpty))
        XCTAssertEqual(Set(lines).count, lines.count)
    }

    // MARK: - The two limits, which are the point of the page

    /// **Two sentences, not one.** The tab is where a user finds out what the check is worth, and
    /// the check has two separate holes:
    ///
    /// 1. There is no API to enumerate a hotkey another process registered, so Raycast, Alfred and
    ///    every other launcher are structurally invisible — including when they hold the very
    ///    chord being bound. Structural, and certain.
    /// 2. Vocca's view of macOS's *own* shortcuts is incomplete as well: Spotlight's identifiers
    ///    are absent from the table on the authoring machine, and why is **not understood**.
    ///
    /// The second sentence therefore asserts **no mechanism**, and this row is where that stays
    /// true. An earlier revision said Vocca sees only the shortcuts a user has changed themselves,
    /// explaining the gap by a rule about when macOS writes an entry. That rule is false — other
    /// identifiers are present holding their stock defaults — and it came within one commit of
    /// being read by users as a fact about their machine. A sentence that reports an observation
    /// survives being wrong about the cause; one that explains a mechanism does not.
    func testBothLimitsAreStatedAndNeitherAssertsAMechanism() {
        XCTAssertEqual(
            SettingsCopy.hotkeyOtherAppsUnknown,
            "Vocca can't see shortcuts other apps have taken, so it can't warn you about those.")
        XCTAssertEqual(
            SettingsCopy.hotkeySystemShortcutsIncomplete,
            "It can't promise to catch every one of macOS's own shortcuts either — some don't "
                + "appear in the list Vocca can read.")
        XCTAssertNotEqual(
            SettingsCopy.hotkeyOtherAppsUnknown, SettingsCopy.hotkeySystemShortcutsIncomplete,
            """
            The two limit sentences collapsed into one. They are different holes: other \
            applications cannot be enumerated at all, and macOS's own table is missing entries \
            for reasons nobody here understands. One sentence covering both would leave a reader \
            believing one of the two halves is checked.
            """)

        for line in [
            SettingsCopy.hotkeyOtherAppsUnknown, SettingsCopy.hotkeySystemShortcutsIncomplete,
        ] {
            XCTAssertFalse(
                line.contains("changed yourself") || line.contains("Apple shipped"),
                """
                A limit sentence is explaining *why* macOS's shortcut table is incomplete. Nobody \
                knows why. The retracted explanation — that macOS records only the shortcuts a \
                user has customised — is refuted by identifiers present holding stock defaults, \
                and it was one commit away from being shown to users as a fact about their Mac.
                """)
        }
    }

    // MARK: - The string that became false

    /// **`hotkeyNotRebindable` survives nowhere in `Sources/`** — deleted, not softened.
    ///
    /// A scan rather than a compile check, because dead code compiles: the constant could sit
    /// unreferenced in the enum for a year and nothing but this would notice. It says a control
    /// that now exists does not, which is the one error a settings page cannot afford.
    func testTheNotRebindableStringExistsNowhereInSources() throws {
        let sources = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources")
        let files = SwiftSourceScanner.swiftFiles(under: sources)
        XCTAssertFalse(files.isEmpty, "this scan ran against nothing")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                text.contains("hotkeyNotRebindable"),
                """
                \(file.lastPathComponent) still names hotkeyNotRebindable. The hotkey is \
                rebindable now, so the string is false — and it must be deleted rather than \
                reworded into "rebinding is limited", which would be a second false claim.
                """)
        }
    }

    // MARK: - The pin that keeps the pins honest

    /// **Every member of `SettingsCopy` is pinned above.** Read off the enum's own source, because
    /// the failure this aspect exists to end is a string nobody tested: four of them shipped that
    /// way, and one of the four went on to be wrong for two days.
    func testEverySettingsCopyMemberIsPinnedByThisFile() throws {
        let source = try String(
            contentsOf: PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Sources/VoccaUI/SettingsTab.swift"),
            encoding: .utf8)
        let stripped = SwiftSourceScanner.stripComments(from: source)
        let characters = Array(stripped)

        guard let declaration = stripped.range(of: "enum SettingsCopy"),
            let brace = characters[
                stripped.distance(from: stripped.startIndex, to: declaration.upperBound)...
            ].firstIndex(of: "{"),
            let body = SwiftSourceScanner.bracedBody(in: characters, openingBraceIndex: brace)
        else {
            return XCTFail("SettingsCopy's declaration could not be found to scan")
        }

        var members: Set<String> = []
        for line in body.body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for keyword in ["public static let ", "public static func "] {
                guard trimmed.hasPrefix(keyword) else { continue }
                members.insert(
                    String(trimmed.dropFirst(keyword.count).prefix {
                        $0.isLetter || $0.isNumber || $0 == "_"
                    }))
            }
        }

        XCTAssertEqual(
            members, Self.pinnedMembers,
            """
            SettingsCopy's members changed. Every string on this window is a product decision, and \
            until this aspect not one of them was pinned — which is exactly how \
            hotkeyNotRebindable went on telling users the hotkey was fixed. Add the new member to \
            this file with its own byte-for-byte assertion, then list it here.
            """)
    }

    /// Every member this file asserts. The list is the checklist the scan above enforces.
    private static let pinnedMembers: Set<String> = [
        "toggleTitle", "toggleDetail", "holdTitle", "holdDetail", "dictionaryEmpty",
        "hotkeyLabel", "hotkeyRecordButton", "hotkeyRecordingPrompt", "hotkeyUseAnyway",
        "hotkeyCancel", "hotkeyRefusal", "hotkeySystemShortcutWarning", "hotkeyRebindRefusal",
        "hotkeyOtherAppsUnknown", "hotkeySystemShortcutsIncomplete",
        "keepInTrayTitle", "keepInTrayDetail",
    ]
}
