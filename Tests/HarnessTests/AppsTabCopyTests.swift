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

/// **The Apps tab's words** (`PRODUCT_SPEC.md:275`), pinned before the tab exists.
///
/// The health column is the whole point of the tab: it is the one place a user is told *how*
/// Vocca types into a given application, in language that means something to them. The spec names
/// the three labels outright — `typing directly` / `pasting` / `manual only` — so they are pinned
/// byte-for-byte here, exactly as ``BadgeCopy`` pins the egress line. A label that drifts is a
/// product decision, and it fails here rather than being noticed in a screenshot.
///
/// The override picker uses the **same three words**, not a second dialect. A user who reads
/// "pasting" in one column and picks "Clipboard" in the next has been handed two vocabularies for
/// one idea, and has to work out that they are the same thing.
final class AppsTabCopyTests: XCTestCase {

    /// The three health labels, byte for byte.
    func testHealthLabelsMatchTheSpec() {
        XCTAssertEqual(AppsTabCopy.healthLabel(.typingDirectly), "typing directly")
        XCTAssertEqual(AppsTabCopy.healthLabel(.pasting), "pasting")
        XCTAssertEqual(AppsTabCopy.healthLabel(.manualOnly), "manual only")
    }

    /// The reset button. `PRODUCT_SPEC.md:275` writes the phrase in running prose, lower case;
    /// a button label carries a leading capital and nothing else changes. That single deviation
    /// is spelled out here so it stays the only one.
    func testResetButtonCopyMatchesTheSpec() {
        let specPhrase = "reset what Vocca learned"
        XCTAssertEqual(AppsTabCopy.resetButton, "Reset what Vocca learned")
        XCTAssertEqual(
            AppsTabCopy.resetButton,
            specPhrase.prefix(1).uppercased() + specPhrase.dropFirst(),
            """
            The reset button no longer says what PRODUCT_SPEC.md:275 promises. Sentence case for \
            a button label is the one permitted difference; any other change is a product \
            decision and belongs in the spec first.
            """)
    }

    /// The override picker speaks the health vocabulary — the same three words, so the column a
    /// user reads and the control they use to change it name the same thing.
    func testOverrideMethodLabelsMapToTheHealthVocabulary() {
        XCTAssertEqual(AppsTabCopy.methodLabel(.typeDirectly), "typing directly")
        XCTAssertEqual(AppsTabCopy.methodLabel(.paste), "pasting")
        XCTAssertEqual(AppsTabCopy.methodLabel(.manual), "manual only")
        for method in AppsTabMethod.allCases {
            XCTAssertEqual(
                AppsTabCopy.methodLabel(method), AppsTabCopy.healthLabel(method.health),
                "The picker and the health column disagree about what \(method) is called.")
        }
    }

    /// An overridden row says so in words, not only by a shade of grey. The row's *state* — Vocca
    /// worked this out, or you told it — is the difference the tab exists to make visible, and a
    /// colour cannot be read by VoiceOver or by anyone who does not already know the convention.
    ///
    /// NEW COPY: `PRODUCT_SPEC.md:275` promises overrides but names no indicator.
    func testOverriddenRowIsDistinguishedInWords() {
        XCTAssertEqual(AppsTabCopy.overriddenBadge, "Pinned by you")
        XCTAssertEqual(AppsTabCopy.learnedBadge, "Learned")
        XCTAssertNotEqual(
            AppsTabCopy.overriddenBadge, AppsTabCopy.learnedBadge,
            "The two row states read identically — the distinction the tab promises is invisible.")
    }

    /// The empty state is honest about *why* it is empty. "No apps" reads like a fault; Vocca
    /// genuinely knows nothing until it has typed into something.
    func testEmptyStateCopyIsHonest() {
        XCTAssertEqual(
            AppsTabCopy.empty,
            "Vocca hasn't learned anything about your apps yet. It learns the first time it "
            + "types into one.")
    }

    /// A failed write is a sentence on screen, never a swallow — the `DictionarySettingsPage`
    /// rule. A pin that silently fails to save is one the user sets again next launch, and again
    /// after that.
    func testSaveErrorCopyIsASurface() {
        XCTAssertEqual(AppsTabCopy.saveError("disk full"), "Couldn't save: disk full")
        XCTAssertFalse(AppsTabCopy.saveError("disk full").isEmpty)
    }

    /// The three column headings. They are the table's own words and are pinned for the same
    /// reason the labels are.
    func testColumnHeadingsArePinned() {
        XCTAssertEqual(AppsTabCopy.appColumn, "App")
        XCTAssertEqual(AppsTabCopy.healthColumn, "How Vocca types")
        XCTAssertEqual(AppsTabCopy.stateColumn, "Where that came from")
    }
}
