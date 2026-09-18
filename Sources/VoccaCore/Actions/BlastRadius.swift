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

/// How far an action reaches — the one thing the confirmation gate branches on
/// (`action-safety-spine` PRD M3).
///
/// The enum is **closed at three cases on purpose**. Every classification an action layer
/// eventually wants — reversible, idempotent, rate-limited, cheap — is a refinement of a
/// question the gate does not ask. The gate asks exactly one: *may this run without a human
/// saying yes?* Three cases is the smallest set that answers it honestly, because "reaches
/// outward" and "destroys locally" are different harms a user weighs differently even though
/// the gate treats them identically today.
///
/// Adding a fourth case is a reviewed change to the gate, not an addition here alone:
/// ``requiresConfirmation`` switches exhaustively and `ActionSeamTests` sweeps `allCases`, so a
/// new case fails both places before it can inherit whichever side a `default` branch fell on.
/// That is deliberate — a silently-permissive default is precisely the failure this type
/// exists to prevent.
public enum BlastRadius: Sendable, CaseIterable {
    /// Observes and reports; changes nothing and sends nothing anywhere.
    case readOnly

    /// Changes or removes something on this machine.
    case destructive

    /// Leaves the machine — a message sent, a request made, a file shared.
    case outwardFacing

    /// Whether the gate must obtain a confirmation before this action may be invoked.
    ///
    /// **The single documented branch point.** The gate reads this and nothing else about the
    /// radius; no caller is expected to re-derive the rule by matching cases, and no second
    /// place may encode it. Read-only is the one case that may run directly — and even then
    /// "may run directly" is a statement about *permission*, never a promise that a provider
    /// will serve the call (``NullActionProvider`` refuses every tool at every radius).
    ///
    /// The switch is exhaustive rather than `default`-terminated so that a fourth case is a
    /// compile error here, where the decision belongs, instead of an implicit `true` or `false`
    /// chosen by whoever wrote the default.
    public var requiresConfirmation: Bool {
        switch self {
        case .readOnly:
            return false
        case .destructive, .outwardFacing:
            return true
        }
    }
}
