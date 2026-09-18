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

import Carbon.HIToolbox

/// **The context adapter's Secure Input read — the one file in `VoccaContext` permitted to make
/// the Carbon call** (the Secure Input family's third seam row, `"contextRead"`, beside the
/// tap-health poll's and the injection-time read's).
///
/// `IsSecureEventInputEnabled()` returns whether *any* process in this login session currently
/// holds Secure Input — the same fact ``SystemSecureInputState`` reads for the tap-health poll
/// (`VoccaHotkey/SecureInput.swift`) and ``SystemSecureInputRead`` reads at injection time
/// (`VoccaInject/Accessibility/SecureInputRead.swift`), read here at context-resolution time
/// instead, as the `accessibility-context` aspect decided (PRD M5b): ``AccessibilityContext``
/// consults it **before** any AX call, so a password field is never even asked. The decision
/// never reads this call directly; the value crosses the seam once, as a `Bool`.
///
/// ## The honest limit, stated like its siblings'
///
/// This file is executed by nothing in CI, and the reason is the unusual one its siblings
/// document in full: the call *works* without a grant — what cannot be written is a **test worth
/// having**. The value is a fact about every other application on the machine, so asserting it
/// is `false` fails on a developer who happens to have a password field focused, and asserting
/// it is *a `Bool`* asserts nothing the compiler did not. Only the *decision* over it is tested
/// — exhaustively, over ``ContextSecureInputReading``. (Unlike ``SystemSecureInputState``, this
/// read makes no main-actor assertion: it happens on whatever thread the caller resolves on,
/// and the call needs no grant, no entitlement and no run loop.)
///
/// ## Isolation
///
/// Synchronous, for the reason ``ContextAXReading`` is: the consumer's conformance witness is
/// synchronous. The object holds no state, so `Sendable` is checked, not asserted.
///
/// Public because the composition root constructs it (`bootstrap-wiring` builds
/// ``AccessibilityContext`` with this adapter and ``AXContextSource``).
public final class ContextSecureInputRead: ContextSecureInputReading, Sendable {

    /// The composition root's construction — a plain adapter, no arguments and no grants.
    public init() {}

    /// `true` when some application is holding Secure Input and no event tap is receiving key
    /// events.
    public func isSecureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }
}