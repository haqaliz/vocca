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

/// The Cleanup tab's copy — pinned byte-for-byte to `PRODUCT_SPEC.md:263-274`, the
/// `BadgeCopyTests`/`EnginePickerCopyTests` rule. The spec's three rungs are the product's own
/// wording, not a paraphrase, and the ⚠️ line is the one a user reads before their text leaves the
/// machine: if the spec's wording changes, this test fails until the copy changes with it.
///
/// Character fidelity matters here more than anywhere else in the app. The warning glyph is
/// U+26A0 WARNING SIGN followed by U+FE0F VARIATION SELECTOR-16 — the emoji presentation, which is
/// what makes it read as a warning rather than as an outline triangle — and the ellipsis is
/// U+2026, not three periods. Both are pinned as scalars, because a lookalike substitution is
/// invisible in a diff.
final class CleanupTabCopyTests: XCTestCase {

    // MARK: - The three rungs (`PRODUCT_SPEC.md:266-268`)

    /// **The rung names match the spec's mock byte-for-byte.**
    func testTheRungNamesMatchTheSpec() {
        XCTAssertEqual(CleanupTabCopy.rungName(.rules), "Basic")
        XCTAssertEqual(CleanupTabCopy.rungName(.ollama), "Local AI")
        XCTAssertEqual(CleanupTabCopy.rungName(.byok), "Cloud (BYOK)")
    }

    /// **The rung descriptions match the spec's mock byte-for-byte.**
    func testTheRungDescriptionsMatchTheSpec() {
        XCTAssertEqual(CleanupTabCopy.rungDetail(.rules), "Removes fillers, adds punctuation.")
        XCTAssertEqual(CleanupTabCopy.rungDetail(.ollama), "Better rewriting. Needs Ollama.")
        XCTAssertEqual(CleanupTabCopy.rungDetail(.byok), "Your own API key.")
    }

    /// **Every rung states where the text goes**, in the spec's own words — and the cloud rung's
    /// is the ⚠️ line, which is the whole reason this column is separate from the description.
    func testEveryRungStatesWhereTheTextGoes() {
        XCTAssertEqual(CleanupTabCopy.rungEgressNote(.rules), "Instant, on-device.")
        XCTAssertEqual(CleanupTabCopy.rungEgressNote(.ollama), "On-device.")
        XCTAssertEqual(CleanupTabCopy.rungEgressNote(.byok), "⚠️ Text leaves your Mac.")
    }

    /// **The ⚠️ line is the emoji-presentation warning sign, not a lookalike.**
    ///
    /// U+26A0 WARNING SIGN + U+FE0F VARIATION SELECTOR-16, asserted as scalars. Without the
    /// selector macOS renders a thin monochrome outline that reads as decoration; with it the
    /// glyph reads as a warning, which is the difference between a line a user notices before
    /// their text leaves the machine and one they do not. The same pin `BadgeCopy` puts on the ☁︎.
    func testTheCloudWarningGlyphIsTheEmojiPresentationWarningSign() {
        XCTAssertEqual(
            Array(CleanupTabCopy.cloudWarningGlyph.unicodeScalars.map(\.value)),
            [0x26A0, 0xFE0F])
        XCTAssertTrue(
            CleanupTabCopy.rungEgressNote(.byok).hasPrefix(CleanupTabCopy.cloudWarningGlyph),
            "the cloud rung's note leads with the warning, as the spec's mock does")
    }

    /// **The dictionary affordance matches the spec's mock**, ellipsis included — U+2026, not
    /// three periods.
    func testTheCustomDictionaryAffordanceMatchesTheSpec() {
        XCTAssertEqual(CleanupTabCopy.customDictionaryButton, "Custom dictionary…")
        XCTAssertEqual(CleanupTabCopy.customDictionaryHint, "names, jargon, replacements")
        XCTAssertTrue(
            CleanupTabCopy.customDictionaryButton.unicodeScalars.contains { $0.value == 0x2026 },
            "the spec's ellipsis is one character, and three periods is a different string")
    }

    /// **The radio glyphs are not restated.** `EnginePickerCopy` already pins the spec's `◉` and
    /// `○` from the Speech mock, and the Cleanup mock uses the same two characters. A second pair
    /// of literals is how one of them drifts.
    func testTheRadioGlyphsAreTheOnesTheSpeechTabAlreadyPinned() {
        XCTAssertEqual(CleanupTabCopy.radioSelected, EnginePickerCopy.radioSelected)
        XCTAssertEqual(CleanupTabCopy.radioUnselected, EnginePickerCopy.radioUnselected)
    }

    /// **Every rung is described, with no `default:` hiding a missing one.** A rung added to
    /// `CleanupProviderKind` and not to the copy would render as an empty row, which is a rung a
    /// user can select and cannot read.
    func testEveryRungHasCopy() {
        for kind in CleanupProviderKind.allCases {
            XCTAssertFalse(CleanupTabCopy.rungName(kind).isEmpty, "\(kind) has no name")
            XCTAssertFalse(CleanupTabCopy.rungDetail(kind).isEmpty, "\(kind) has no description")
            XCTAssertFalse(
                CleanupTabCopy.rungEgressNote(kind).isEmpty, "\(kind) does not say where text goes")
        }
    }

    // MARK: - What the page has to say that a mock does not

    /// **The tab says a change applies at the next launch**, rather than implying immediacy.
    ///
    /// The resolver is resolve-once: the provider is built at launch and a mid-session swap is
    /// structurally impossible (`CleanupResolver`). So a choice made here is not the choice
    /// running now, and a page that let a user believe otherwise would have them dictate something
    /// sensitive through the provider they thought they had just left (`spec.md` Risks).
    func testTheTabSaysAChangeAppliesAtTheNextLaunch() {
        let note = CleanupTabCopy.appliesAtNextLaunch
        XCTAssertTrue(note.lowercased().contains("next"), "it must name when, not just that")
        XCTAssertTrue(
            note.lowercased().contains("restart") || note.lowercased().contains("launch"),
            "and the when is a restart, because the provider is resolved once at launch")
    }

    /// **The tab says where the BYOK key lives, and it is not this file** (R4).
    ///
    /// A user looking at a cloud rung with no key field needs to be told where the key goes, or
    /// the rung looks broken. Saying "Keychain" also says the thing that matters: the key is not
    /// in the plain-text config file beside it.
    func testTheTabSaysTheKeyLivesInTheKeychain() {
        XCTAssertTrue(CleanupTabCopy.keychainNote.contains("Keychain"))
        XCTAssertFalse(
            CleanupTabCopy.keychainNote.contains("cleanup-config.json"),
            "the key is never in the config file, so the note must not send a user there for it")
    }

    /// **The summary lines say what is happening in plain words**, and the local one is
    /// unambiguous — "nothing is sent anywhere" is the sentence the whole tab exists to be able
    /// to say truthfully.
    func testTheSummaryLinesSayWhatIsHappening() {
        XCTAssertEqual(
            CleanupTabCopy.textIsSentTo("api.example.com"),
            "Text is sent to api.example.com.")
        XCTAssertEqual(
            CleanupTabCopy.runsOnThisMac, "Runs on this Mac. Nothing is sent anywhere.")
        XCTAssertFalse(
            CleanupTabCopy.textLeavesThisMac.isEmpty,
            "a network provider with no endpoint to name still has to say the text leaves")
    }

    /// **A rung that cannot be configured is refused in words that say what is missing.**
    ///
    /// A disabled radio with nothing beside it teaches a user the app is broken — the argument
    /// `SettingsCopy.hotkeyNotRebindable` already makes. Each refusal names the field.
    func testARefusalNamesTheMissingField() {
        XCTAssertTrue(CleanupTabCopy.missingFields(.ollama).lowercased().contains("model"))
        XCTAssertTrue(CleanupTabCopy.missingFields(.byok).lowercased().contains("endpoint"))
    }
}
