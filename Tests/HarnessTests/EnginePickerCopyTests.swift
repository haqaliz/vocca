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
import VoccaUI
import XCTest

/// The Speech-tab picker's copy — the **honest-tradeoff surface** (`engine-picker` Phase 3).
///
/// `PRODUCT_SPEC.md:189-196` is the product's own wording of what each engine is good at; the
/// whole point of the picker is to show that tradeoff, so the strings the user sees must be the
/// spec's strings, not a paraphrase. Every constant in ``EnginePickerCopy`` is pinned here to its
/// spec line. If the spec's wording changes, this test fails until the copy changes with it —
/// editing the copy to dodge the test is exactly the failure mode the plan forbids
/// (`plan_20260810.md:128-130`: do not "fix" the test by editing copy without flagging it).
///
/// Character fidelity: the spec's radio glyphs are `◉` (U+25C9 FISHEYE) and `○` (U+25CB WHITE
/// CIRCLE) — both plain BMP code points, representable in a Swift string literal as-is, so the
/// assertion is byte-for-byte verbatim with no normalization and no documented equivalent.
final class EnginePickerCopyTests: XCTestCase {

    // MARK: - The engine rows (`PRODUCT_SPEC.md:192-193`)

    /// The two names, exactly as the spec's mock rows spell them.
    func testEngineNamesMatchTheSpec() {
        XCTAssertEqual(EnginePickerCopy.parakeetName, "Parakeet v3")
        XCTAssertEqual(EnginePickerCopy.whisperName, "Whisper turbo")
    }

    /// The two taglines — the honest tradeoff, word for word. No invented numbers, no weasel
    /// words: "Fastest." and "Slower" are the spec's own claims (S1 posture: no latency/accuracy
    /// figures invented anywhere in the copy).
    func testTaglinesMatchTheSpec() {
        XCTAssertEqual(EnginePickerCopy.parakeetTagline, "Fastest. 25 European languages.")
        XCTAssertEqual(EnginePickerCopy.whisperTagline, "Slower, broader language coverage.")
    }

    /// The radio glyphs: `◉` for the selected row, `○` for the unselected one — the spec's exact
    /// characters (U+25C9, U+25CB; no normalization needed, see the type doc comment).
    func testRadioGlyphsMatchTheSpec() {
        XCTAssertEqual(EnginePickerCopy.radioSelected, "◉")
        XCTAssertEqual(EnginePickerCopy.radioUnselected, "○")
        XCTAssertNotEqual(
            EnginePickerCopy.radioSelected, EnginePickerCopy.radioUnselected,
            "The two states must be visually distinct.")
    }

    /// The per-row affordance labels, verbatim — including their brackets, which are part of the
    /// spec's mock. "[ installed ]" says what is true; "[ download ]" is the action offered.
    func testAffordanceLabelsMatchTheSpec() {
        XCTAssertEqual(EnginePickerCopy.installedAffordance, "[ installed ]")
        XCTAssertEqual(EnginePickerCopy.downloadAffordance, "[ download ]")
    }

    /// The model-management line (`PRODUCT_SPEC.md:195`) — the spec promises the registry surface;
    /// the label is shipped now so the promise stays visible. The registry itself is C14.
    func testModelManagementLineMatchesTheSpec() {
        XCTAssertEqual(
            EnginePickerCopy.modelManagementLine,
            "Model management: disk used, remove, re-download.")
    }

    /// The names must also agree with the Core's own `displayName` (`EngineCandidate`): the row
    /// label and the transcript attribution are the same engine, and a drift between them would
    /// make the picker show one name while transcripts are signed with another.
    func testCopyNamesAgreeWithTheCoreDisplayNames() {
        XCTAssertEqual(EnginePickerCopy.parakeetName, EngineCandidate.parakeetV3.displayName)
        XCTAssertEqual(EnginePickerCopy.whisperName, EngineCandidate.whisperTurbo.displayName)
    }

    // MARK: - The whisper tier menu (spec.md:26, plan_20260810.md:78)

    /// The tier menu's labels. `PRODUCT_SPEC.md:189-196` does not render the tier menu, so these
    /// are **not** a spec-verbatim contract; they are pinned to the engine-picker spec
    /// (`spec.md:26` — "Whisper-tier menu (S2): turbo full / q5_0") and the plan's shorthand
    /// (`plan_20260810.md:78` — "(turbo / q5_0)"), where the "full" qualifier describes the tier
    /// rather than naming the menu item. The labels are the engine's own quantisation names, and
    /// each tier's menu label must agree with the tier it tags.
    func testTierMenuLabelsMatchThePlan() {
        XCTAssertEqual(EnginePickerCopy.tierLabel(for: .parakeetV3), "Parakeet v3")
        XCTAssertEqual(EnginePickerCopy.tierLabel(for: .whisperTurbo), "turbo")
        XCTAssertEqual(EnginePickerCopy.tierLabel(for: .whisperTurboQ5), "q5_0")
    }
}
