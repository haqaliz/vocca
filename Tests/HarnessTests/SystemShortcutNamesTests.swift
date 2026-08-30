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

/// `shortcut-conflicts` criterion 3's other half: the identifiers Vocca can name, and the very
/// much larger set it cannot.
///
/// ## Every name here came from a table Apple ships, and nothing else did
///
/// `com.apple.symbolichotkeys` carries no labels — only opaque integer keys — so a name has to
/// come from somewhere else, and the only acceptable somewhere is a primary source. Two exist on
/// a real machine, and both were read on 2026-08-30:
///
/// - `KeyboardSettings.appex/Contents/Resources/DefaultSpacesShortcuts.xml`, which maps identifier
///   to shortcut: 118 is `Switch to Space 1`, and its declared key and modifier (18, 262144) match
///   this machine's live entry exactly.
/// - `.../DefaultShortcutsTable.loctable`, which maps that to the English label macOS shows:
///   `Switch to Space 1` → **"Switch to Desktop 1"**.
///
/// All sixteen rows below were checked through both. **Nothing else was named**, and the reason is
/// in the next paragraph rather than in a shortage of effort.
///
/// ## Why Spotlight — the one that matters — is not named
///
/// `spec.md` says *"Spotlight (32/33) is the one that matters"* and `plan_20260830.md` says 64/65,
/// warning that both are unverified. Neither could be verified, and 32/33 are demonstrably
/// **not** Spotlight: on this machine identifier 32 reads `[65535, 126, 8650752]`, which is the Up
/// arrow with `fn | control` — ⌃↑, Mission Control. No Apple-shipped table on the machine maps any
/// identifier outside the Spaces range to a name, and the appex binary embeds no such table.
///
/// Worse for the feature and better to know: **identifiers 64 and 65 are not in the live file at
/// all.** macOS writes an entry only for a shortcut whose setting differs from the shipped
/// default, and Spotlight's ⌘Space is untouched here. So Spotlight is not merely unnamed, it is
/// absent — and naming an identifier we cannot see would be a guess dressed as a finding.
///
/// Criterion 3 is what makes that acceptable rather than fatal: an unnamed collision still warns.
final class SystemShortcutNamesTests: XCTestCase {

    /// The sixteen Spaces identifiers, each named exactly as macOS names it.
    ///
    /// The full range rather than a sample, because the two ends of it come from different rows of
    /// Apple's table — 118–127 are ⌃1…⌃0 and 128–133 are ⌃⌥1…⌃⌥6 — and an off-by-one in the
    /// middle would name a user's shortcut as the wrong desktop.
    func testEverySpacesIdentifierIsNamedAsMacOSNamesIt() {
        let expected = (1...16).map { ($0 + 117, "Switch to Desktop \($0)") }

        for (identifier, name) in expected {
            XCTAssertEqual(
                SystemShortcutNames.name(forIdentifier: identifier), name,
                """
                Identifier \(identifier) is "\(name)": Apple's DefaultSpacesShortcuts.xml maps it \
                to "Switch to Space \(identifier - 117)" and DefaultShortcutsTable.loctable maps \
                that to the English label. Both were read from the installed system.
                """)
        }
    }

    /// **Everything else is unnamed**, including the identifiers the spec and the plan each
    /// guessed at, and including the ones this machine holds live entries for.
    ///
    /// Driven as a table so the guesses are recorded as refused rather than merely absent: a later
    /// reader who wonders why Spotlight is missing finds the answer here instead of adding it.
    func testIdentifiersThatCouldNotBeVerifiedAreNotNamed() {
        let unverifiable: [(Int, String)] = [
            (32, "spec.md's Spotlight guess — live entry is [65535, 126, 8650752], ⌃↑"),
            (33, "spec.md's second Spotlight guess — live entry is ⌃↓"),
            (64, "plan_20260830.md's Spotlight guess — absent from the live file entirely"),
            (65, "plan_20260830.md's second guess — also absent"),
            (60, "⌃Space on this machine, but no shipped table names it"),
            (36, "F11 on this machine, but no shipped table names it"),
            (117, "one below the verified range"),
            (134, "one above it"),
            (0, "no identifier at all"),
            (-1, "a negative key, which the adapter can produce from a malformed dictionary key"),
        ]

        for (identifier, why) in unverifiable {
            XCTAssertNil(
                SystemShortcutNames.name(forIdentifier: identifier),
                """
                Identifier \(identifier) must be unnamed: \(why). A guessed name is worse than no \
                name — the user cannot tell one from a verified one, and criterion 3 already \
                covers the unnamed case by warning anyway.
                """)
        }
    }
}
