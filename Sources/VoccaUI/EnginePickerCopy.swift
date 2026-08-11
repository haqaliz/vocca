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

/// The Speech-tab picker's copy — every user-visible string, lifted from
/// `PRODUCT_SPEC.md:189-196` verbatim (`FailsafeCopy`'s shape: pure constants and pure functions,
/// no AppKit, so the contract test runs every string against the spec headlessly).
///
/// **The honest-tradeoff surface.** The two rows are the product's own wording of what each
/// engine is good at — "Fastest. 25 European languages." against "Slower, broader language
/// coverage." — and the test (`EnginePickerCopyTests`) pins each constant to its spec line. No
/// latency or accuracy number is invented anywhere in this file (S1 posture).
///
/// Character fidelity: the radio glyphs are the spec's own `◉` (U+25C9) and `○` (U+25CB), plain
/// BMP code points held as-is — no normalization, no lookalike substitution.
public enum EnginePickerCopy {

    /// The selected row's radio glyph, `PRODUCT_SPEC.md:192` verbatim.
    public static let radioSelected = "◉"

    /// The unselected row's radio glyph, `PRODUCT_SPEC.md:193` verbatim.
    public static let radioUnselected = "○"

    /// The Parakeet row's name, `PRODUCT_SPEC.md:192` verbatim — also
    /// `EngineCandidate.parakeetV3.displayName`.
    public static let parakeetName = "Parakeet v3"

    /// The Parakeet row's tagline, `PRODUCT_SPEC.md:192` verbatim.
    public static let parakeetTagline = "Fastest. 25 European languages."

    /// The Whisper row's name, `PRODUCT_SPEC.md:193` verbatim — also
    /// `EngineCandidate.whisperTurbo.displayName`.
    public static let whisperName = "Whisper turbo"

    /// The Whisper row's tagline, `PRODUCT_SPEC.md:193` verbatim.
    public static let whisperTagline = "Slower, broader language coverage."

    /// The installed row's affordance label, `PRODUCT_SPEC.md:192` verbatim — brackets included,
    /// they are part of the spec's mock.
    public static let installedAffordance = "[ installed ]"

    /// The downloadable row's affordance label, `PRODUCT_SPEC.md:193` verbatim.
    public static let downloadAffordance = "[ download ]"

    /// The model-management line, `PRODUCT_SPEC.md:195` verbatim. The registry surface it promises
    /// is C14; the label ships now so the promise stays visible.
    public static let modelManagementLine = "Model management: disk used, remove, re-download."

    /// The tier menu's label for a tier — the engine's own quantisation name. Not a
    /// `PRODUCT_SPEC.md:189-196` string (the spec does not render the tier menu); pinned to
    /// `spec.md:26` / `plan_20260810.md:78` by `EnginePickerCopyTests`.
    public static func tierLabel(for tier: EngineTier) -> String {
        switch tier {
        case .parakeetV3: return "Parakeet v3"
        case .whisperTurbo: return "turbo"
        case .whisperTurboQ5: return "q5_0"
        }
    }
}
