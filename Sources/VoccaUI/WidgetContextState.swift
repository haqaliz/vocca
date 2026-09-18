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

/// Whether the pill shows that Vocca reads the focused app's content — the context badge's
/// reducer state (`context-provider` M8, the egress badge's persistent shape).
///
/// The badge is **per-fold non-dismissable**, exactly as ``WidgetEgressState`` is: the wiring
/// folds one `WidgetAction/contextChanged(_:)` per context resolution, and no timer and no
/// session effect can clear a `.reading` state — `adopting(_:)` and the notice branch carry it
/// forward (`WidgetStateReducerTests` pins the carry). The badge clears in the same fold that
/// stops the reads: the kill (M9) lands as the wiring folding a `consentActive: false` signal,
/// and Secure Input (M5b/M8) is a reducer row — a signal with `secureInputActive: true` never
/// lights the badge, whatever the app consented to.
///
/// ``reading(appName:)`` carries the focused app's name for the hover copy (`BadgeCopy`), never
/// any selection or content — `nil` when the name did not resolve, which renders the honest
/// fallback copy rather than a dangling name.
public enum WidgetContextState: Equatable, Sendable {
    /// Nothing is being read — the default, and every non-consented or Secure Input state.
    case off
    /// Consent is active for the focused app and Secure Input is not holding the keyboard;
    /// `appName` is the focused app's display name for the hover copy, `nil` when unresolved.
    case reading(appName: String?)
}

/// The raw facts the wiring folds into the badge — the signal `WidgetAction/contextChanged(_:)`
/// carries, so the two rules this badge owns live in the reducer, not the wiring (D2).
///
/// `consentActive` and `appName` are folded by the wiring from the consent store × the context
/// resolution; `secureInputActive` comes from the wiring's own `SecureInputReading` at
/// context-resolution time — never from the snapshot, which carries no secure-input field
/// (`context-seam` D2/D3) — because `VoccaUI` may not name the reader (`ModuleBoundaryTests`).
public struct WidgetContextSignal: Equatable, Sendable {
    /// Whether consent is active for the focused app — the wiring's composition of per-app
    /// consent ∧ focused-app-is-consented ∧ ¬killed.
    public let consentActive: Bool
    /// Whether another application holds the keyboard (`IsSecureEventInputEnabled`), so a
    /// password field is focused and the badge must not light (M5b/M8).
    public let secureInputActive: Bool
    /// The focused app's display name for the hover copy — `nil` when it did not resolve.
    public let appName: String?

    public init(consentActive: Bool, secureInputActive: Bool, appName: String?) {
        self.consentActive = consentActive
        self.secureInputActive = secureInputActive
        self.appName = appName
    }
}