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

/// The onboarding window's copy — every user-visible string, lifted from
/// `PRODUCT_SPEC.md:211-244` (§6 First run) verbatim (`EnginePickerCopy`'s shape: pure
/// constants, no AppKit, so the contract test runs every string against the spec headlessly).
///
/// Character fidelity: the spec's `⌥` (U+2325 OPTION KEY) and `≈` (U+2248 ALMOST EQUAL TO) are
/// the product's own characters, held as-is — no normalization, no lookalike substitution
/// (`EnginePickerCopyTests`' glyph rule).
///
/// Two surfaces are **NEW-COPY**, not §6-verbatim, and each says so in its doc comment with its
/// own source: the M5c three-state Accessibility line and the M7 model-unavailable surface.
/// `PRODUCT_SPEC.md:244` names the [ Restart Vocca ] button but never renders the three states
/// as copy; prd.md M7 names the TRY IT surface but §6 does not print its line. The `EnginePickerCopy`
/// rule applies: new copy is marked NEW-COPY and justified against the nearest spec line.
public enum OnboardingCopy {

    // MARK: - WELCOME (`PRODUCT_SPEC.md:212-215`)

    /// The WELCOME title, `PRODUCT_SPEC.md:212` verbatim.
    public static let welcomeTitle = "Vocca types what you say, into any app."

    /// The WELCOME body, `PRODUCT_SPEC.md:213` verbatim — the privacy promise in the first
    /// sentence the user reads.
    public static let welcomeBody = "Everything runs on your Mac."

    /// The WELCOME affordance, `PRODUCT_SPEC.md:215` verbatim — brackets included, they are part
    /// of the spec's mock (`EnginePickerCopy.installedAffordance`'s rule).
    public static let getStarted = "[ Get started ]"

    // MARK: - PERMISSIONS (`PRODUCT_SPEC.md:217-230`)

    /// The Accessibility reason, `PRODUCT_SPEC.md:219-220` verbatim — the spec's mock splits it
    /// across two lines ("so ⌥Space works everywhere, and so / Vocca can type into other
    /// apps"); the rendered string is the flat sentence the two lines spell.
    public static let accessibilityReason =
        "so ⌥Space works everywhere, and so Vocca can type into other apps"

    /// The Microphone reason, `PRODUCT_SPEC.md:221` verbatim — "Audio never leaves this Mac."
    /// is the local-first promise at the moment it matters most.
    public static let microphoneReason = "to hear you. Audio never leaves this Mac."

    // MARK: - MODEL (`PRODUCT_SPEC.md:232-236`)

    /// The MODEL title, `PRODUCT_SPEC.md:232` verbatim — the `≈` is the spec's own character.
    public static let modelTitle = "Downloading the speech model (≈600 MB, one time)"

    /// The skip affordance, `PRODUCT_SPEC.md:233-235` verbatim — the line that keeps a stalled
    /// download from blocking the whole product.
    public static let skipForNow = "Skip for now"

    // MARK: - TRY IT and DONE (`PRODUCT_SPEC.md:237-242`)

    /// The TRY IT prompt, `PRODUCT_SPEC.md:239` verbatim.
    public static let tryItPrompt = "Hold ⌥Space and say something."

    /// The DONE copy, `PRODUCT_SPEC.md:242` verbatim.
    public static let doneCopy = "Vocca lives in your menu bar. Hold ⌥Space anywhere."

    // MARK: - The M5c three-state Accessibility copy (NEW-COPY, `PRODUCT_SPEC.md:244`)

    /// The granted-but-not-armed status line. **NEW-COPY (M5c)**: §6 does not render the three
    /// states, it only states the doctrine — "Granting it afterwards requires a restart, so
    /// that screen offers a [Restart Vocca] button instead of leaving the user to wonder why
    /// the hotkey still does nothing" (`PRODUCT_SPEC.md:244`). The line says plainly that the
    /// grant is present and the tap is still dead: a ✓ that hides a dead tap is the silent
    /// gate this capability exists to kill (prd.md M5c, R10).
    public static let accessibilityGrantedNotArmed = "granted, restart to arm"

    /// The restart affordance, `PRODUCT_SPEC.md:244`'s own wording — the button the spec names
    /// for the middle state, brackets per the spec's mock style.
    public static let restartVocca = "[ Restart Vocca ]"

    // MARK: - The M7 model-unavailable surface (NEW-COPY, prd.md M7)

    /// The TRY IT step's model-unavailable reason. **NEW-COPY (M7)**: the MODEL step was
    /// skipped and no model is installed, and the surface states the cause plainly (G2 — no
    /// silent gate) instead of the pipeline notice's "try again in a moment", which would be a
    /// lie here: nothing is momentary, the model must be downloaded. The opener cites the
    /// readiness-refusal wording the pipeline already ships (`SMOKE_CHECKLIST.md` step 66's
    /// `.modelUnavailable` notice: "Voice processing isn't ready yet — try again in a
    /// moment."), adapted to the cause the onboarding surface can actually see.
    public static let tryItModelUnavailable =
        "Voice processing isn't ready yet — the speech model isn't downloaded."

    /// The way forward, prd.md M7's own wording: re-enters the MODEL step's download — never a
    /// dead end, never an auto-download ("Skip for now … never blocks the whole product",
    /// `PRODUCT_SPEC.md:233-235`).
    public static let downloadNow = "[ Download now ]"
}