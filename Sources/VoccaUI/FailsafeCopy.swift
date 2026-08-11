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

/// The FAILSAFE pill's copy — every user-visible string, rendered from the structured cause.
///
/// The reducer carries ``FailsafeReason`` and the target app name as **data**; rendering those
/// into the `PRODUCT_SPEC.md:111-114` sentences is the view's job, and this file is that job made
/// testable — a pure function of the structured state with no AppKit anywhere near it (the
/// ``DownloadState`` shape: Foundation + `VoccaCore` only, so `FailsafePanelContractTests` runs
/// every string against the spec headlessly).
///
/// The one deviation from the spec is stated rather than hidden: the reserved
/// ``FailsafeReason/accessibilityRevoked`` copy renders without the "[Open Settings]" affordance
/// (`PRODUCT_SPEC.md:114`). Opening Settings is an action this surface does not offer yet, so
/// printing a label with no action behind it would be a lie — the honest refusal stays, and the
/// affordance arrives with the settings unit. Everything else is verbatim.
public enum FailsafeCopy {

    /// The cause-specific reason line, `PRODUCT_SPEC.md:111-113` verbatim, plus the reserved
    /// revocation fallback (`:114`, minus the not-yet-real `[Open Settings]` affordance).
    ///
    /// ``FailsafeReason/exhausted`` interpolates the target app name — "Couldn't type into
    /// Notion." — and falls back to a name-less phrasing when the name could not be resolved
    /// (``HeldTranscript/targetAppName`` is `nil`): the sentence must never read "Couldn't type
    /// into .", and must never invent a name.
    public static func reasonText(for reason: FailsafeReason, targetAppName: String?) -> String {
        switch reason {
        case .secureInput:
            return "This looks like a password field. Vocca won't type into it — press ⌘C to paste it yourself."
        case .exhausted:
            let target = targetAppName ?? "the focused app"
            return "Couldn't type into \(target). Press ⌘C to paste it manually, or ⏎ to try again."
        case .noFocusedField:
            return "Nothing was focused. Click where you want this, then press ⏎."
        case .accessibilityRevoked:
            return "Vocca's permission to type was turned off. Press ⌘C to paste it manually."
        }
    }

    /// The affordances legend, `PRODUCT_SPEC.md:54` verbatim: what ⌘C, ⏎ and ✕ do.
    public static func affordancesLine() -> String {
        "⌘C to copy    ⏎ retry   ✕"
    }
}
