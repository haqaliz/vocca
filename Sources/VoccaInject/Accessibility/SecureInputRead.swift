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

/// **The shipped Secure Input read — one Carbon call, in the one file permitted to make it.**
///
/// `IsSecureEventInputEnabled()` returns whether *any* process in this login session currently
/// holds Secure Input — the same fact ``SystemSecureInputState`` reads for the tap-health poll
/// (`VoccaHotkey/SecureInput.swift`), read here at injection time instead, as the seam aspect
/// decided: ``TargetResolution`` reads it freshly at resolution time (PRD R2) and carries the
/// answer in ``TargetContext/isSecureInput``, where the decision's rung-0 refusal finds it. The
/// decision never reads this call directly; the value crosses the seam once, as a `Bool`.
///
/// ## The honest limit, stated like its sibling's
///
/// This file is executed by nothing in CI, and the reason is the unusual one
/// ``SystemSecureInputState`` documents in full: the call *works* without a grant — what cannot
/// be written is a **test worth having**. The value is a fact about every other application on
/// the machine, so asserting it is `false` fails on a developer who happens to have a password
/// field focused, and asserting it is *a `Bool`* asserts nothing the compiler did not. Only the
/// *decision* over it is tested — exhaustively, over ``SecureInputReading``.
///
/// ## Isolation
///
/// No assertion, and none belongs: unlike ``SystemSecureInputState`` (which asserts the main
/// actor because its reader is the ~1 s main-run-loop poll), this read happens at injection time
/// on whatever thread the resolver's actor runs, and the call needs no grant, no entitlement and
/// no run loop. The object holds no state, so `Sendable` is checked, not asserted — the
/// resolver actor holds it across the resolution boundary.
///
/// Public because the composition root constructs it: `VoccaBootstrap` builds
/// ``TargetResolution`` with this adapter and ``AXSource``, and the root imports `VoccaInject`
/// like any consumer. The public surface is the constructor and the one protocol witness — the
/// same raw read ``TargetResolution`` already consumed when the type was module-internal.
public final class SystemSecureInputRead: SecureInputReading, Sendable {

    /// The composition root's construction — a plain adapter, no arguments and no grants.
    public init() {}

    public func isSecureInputActive() async -> Bool {
        IsSecureEventInputEnabled()
    }
}
