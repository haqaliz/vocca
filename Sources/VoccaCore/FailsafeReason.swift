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

/// Why a transcript ended up in the failsafe instead of in the field — the key the FAILSAFE
/// window's copy table and the recovery journal's persisted schema both speak.
///
/// Three reasons the ladder can produce today, each with its own `PRODUCT_SPEC.md` copy
/// (`:111-113`). The fourth case, ``FailsafeReason/accessibilityRevoked``, is *reserved*: the
/// mid-session revocation of the Accessibility grant (PRD N1) is a real eventuality, but its
/// detection is a later unit. The case exists now so that the window's copy table and the
/// journal's persisted schema are stable when detection lands — and so no later unit has to
/// invent a string, or quietly drop an already-persisted transcript it cannot render.
///
/// No code produces ``FailsafeReason/accessibilityRevoked`` yet. It must not be produced
/// speculatively either: a reason that lies about the cause is worse than one that says
/// `.exhausted`.
public enum FailsafeReason: String, Sendable, Equatable {
    /// Secure Input was in force: the honest rung-0 refusal — "This looks like a password
    /// field. Vocca won't type into it — press ⌘C to paste it yourself."
    case secureInput
    /// Every rung was attempted and failed — "Couldn't type into {app}. Press ⌘C to paste it
    /// manually, or ⏎ to try again."
    case exhausted
    /// Nothing was focused (`TargetContext.bundleID == nil`) — "Nothing was focused. Click
    /// where you want this, then press ⏎."
    case noFocusedField
    /// Reserved (N1): the Accessibility grant was revoked mid-session. Detection is a later
    /// unit; no code produces this case yet.
    case accessibilityRevoked
}
