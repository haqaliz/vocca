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

/// The onboarding window's copy — the first-run flow's strings, pinned byte-for-byte against
/// `PRODUCT_SPEC.md:211-244` (§6 First run), the `BadgeCopy`/`EnginePickerCopy` rule: the
/// product's own wording, not a paraphrase (G3). If the spec's wording changes, this test fails
/// until the copy changes with it.
///
/// Character fidelity: the spec's `⌥` (U+2325 OPTION KEY) and `≈` (U+2248 ALMOST EQUAL TO) are
/// held as-is, exactly as the spec spells them — no normalization, no lookalike substitution.
///
/// Two strings are **NEW-COPY**, not spec-verbatim: the M5c three-state Accessibility line and
/// the M7 model-unavailable surface (`PRODUCT_SPEC.md:244` names the restart button but not the
/// status line; the TRY IT step's model-unavailable surface is prd.md M7's, not §6's). Each is
/// pinned here to its own documented source, the `EnginePickerCopy` rule for copy the spec does
/// not render verbatim.
final class OnboardingCopyTests: XCTestCase {

    // MARK: - WELCOME (`PRODUCT_SPEC.md:212-215`)

    /// The WELCOME title, `PRODUCT_SPEC.md:212` verbatim.
    func testWelcomeTitleMatchesTheSpec() {
        XCTAssertEqual(OnboardingCopy.welcomeTitle, "Vocca types what you say, into any app.")
    }

    /// The WELCOME body, `PRODUCT_SPEC.md:213` verbatim — the privacy promise made in the first
    /// sentence the user reads.
    func testWelcomeBodyMatchesTheSpec() {
        XCTAssertEqual(OnboardingCopy.welcomeBody, "Everything runs on your Mac.")
    }

    /// The WELCOME affordance, `PRODUCT_SPEC.md:215` verbatim — brackets included, they are part
    /// of the spec's mock (`EnginePickerCopyTests`' `[ installed ]` rule).
    func testGetStartedMatchesTheSpec() {
        XCTAssertEqual(OnboardingCopy.getStarted, "[ Get started ]")
    }

    // MARK: - PERMISSIONS (`PRODUCT_SPEC.md:217-230`)

    /// The Accessibility reason, `PRODUCT_SPEC.md:219-220` verbatim — the spec's mock splits it
    /// across two lines ("so ⌥Space works everywhere, and so / Vocca can type into other
    /// apps"); the rendered string is the flat sentence the two lines spell.
    func testAccessibilityReasonMatchesTheSpec() {
        XCTAssertEqual(
            OnboardingCopy.accessibilityReason,
            "so ⌥Space works everywhere, and so Vocca can type into other apps")
    }

    /// The Microphone reason, `PRODUCT_SPEC.md:221` verbatim — "Audio never leaves this Mac."
    /// is the local-first promise at the moment it matters most.
    func testMicrophoneReasonMatchesTheSpec() {
        XCTAssertEqual(OnboardingCopy.microphoneReason, "to hear you. Audio never leaves this Mac.")
    }

    // MARK: - MODEL (`PRODUCT_SPEC.md:232-236`)

    /// The MODEL title, `PRODUCT_SPEC.md:232` verbatim — the `≈` (U+2248) is the spec's own
    /// character, held as-is.
    func testModelTitleMatchesTheSpec() {
        XCTAssertEqual(OnboardingCopy.modelTitle, "Downloading the speech model (≈600 MB, one time)")
    }

    /// The skip affordance, `PRODUCT_SPEC.md:233-235` verbatim — "Skip for now" is the line
    /// that keeps a stalled download from blocking the whole product.
    func testSkipForNowMatchesTheSpec() {
        XCTAssertEqual(OnboardingCopy.skipForNow, "Skip for now")
    }

    // MARK: - TRY IT and DONE (`PRODUCT_SPEC.md:237-242`)

    /// The TRY IT prompt, `PRODUCT_SPEC.md:239` verbatim.
    func testTryItPromptMatchesTheSpec() {
        XCTAssertEqual(OnboardingCopy.tryItPrompt, "Hold ⌥Space and say something.")
    }

    /// The DONE copy, `PRODUCT_SPEC.md:242` verbatim.
    func testDoneCopyMatchesTheSpec() {
        XCTAssertEqual(OnboardingCopy.doneCopy, "Vocca lives in your menu bar. Hold ⌥Space anywhere.")
    }

    // MARK: - The M5c three-state Accessibility copy (NEW-COPY, `PRODUCT_SPEC.md:244`)

    /// The granted-but-not-armed status line — NEW-COPY (M5c): §6 does not render the three
    /// states, it only states the doctrine ("Granting it afterwards requires a restart, so
    /// that screen offers a [Restart Vocca] button instead of leaving the user to wonder why
    /// the hotkey still does nothing", `PRODUCT_SPEC.md:244`). The line says plainly that the
    /// grant is present and the tap is still dead — a ✓ that hides a dead tap is the silent
    /// gate this capability exists to kill.
    func testTheGrantedNotArmedLineIsNewCopyAndSaysTheTapNeedsARestart() {
        XCTAssertEqual(OnboardingCopy.accessibilityGrantedNotArmed, "granted, restart to arm")
    }

    /// The restart affordance, `PRODUCT_SPEC.md:244`'s own wording — "[Restart Vocca]" is the
    /// button the spec names for the middle state.
    func testTheRestartAffordanceIsTheSpecsRestartButton() {
        XCTAssertEqual(OnboardingCopy.restartVocca, "[ Restart Vocca ]")
    }

    // MARK: - The M7 model-unavailable surface (NEW-COPY, prd.md M7)

    /// The TRY IT step's model-unavailable reason — NEW-COPY (M7): the MODEL step was skipped
    /// and no model is installed, so the surface states the cause plainly (G2 — no silent
    /// gate) instead of the pipeline notice's "try again in a moment", which would be a lie
    /// here: nothing is momentary, the model must be downloaded. The opener cites the
    /// readiness-refusal wording the pipeline already ships (`SMOKE_CHECKLIST.md` step 66:
    /// "Voice processing isn't ready yet — try again in a moment.").
    func testTheModelUnavailableLineIsNewCopyAndCitesTheReadinessRefusal() {
        XCTAssertEqual(
            OnboardingCopy.tryItModelUnavailable,
            "Voice processing isn't ready yet — the speech model isn't downloaded.")
    }

    /// The way forward, prd.md M7's own wording — "[Download now]" re-enters the MODEL step's
    /// download; never a dead end, never an auto-download.
    func testTheDownloadNowAffordanceIsTheM7WayForward() {
        XCTAssertEqual(OnboardingCopy.downloadNow, "[ Download now ]")
    }
}