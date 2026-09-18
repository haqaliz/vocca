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

/// Proof that a human said yes — the token ``ActionProvider/invoke(_:confirmation:)`` demands
/// and that only the confirmation gate can mint (`action-safety-spine` PRD M4).
///
/// ## Why the type is `public` and the initializer is not
///
/// The type must be `public`: `invoke`'s signature names it, every provider conforming to the
/// seam from another module writes that signature, and a type they cannot name is a seam they
/// cannot implement.
///
/// The **initializer is `internal`**, and that asymmetry is the whole mechanism. A value of
/// this type can be created only by code compiled into `VoccaCore` — which, once
/// `confirmation-gate` lands, means the gate and nothing else. Outside the module the type can
/// be named, passed along and stored, but never *made*. So "an unconfirmed destructive action
/// cannot reach invocation" is not a rule anyone has to remember and not a check anyone can
/// forget to write: a caller who wants to bypass the gate has nothing to hand `invoke`, and
/// the attempt does not compile. R8's "Fatal (trust)" failure is closed by the type system
/// rather than by discipline.
///
/// ## What this deliberately does not do
///
/// **It does not close the `@testable` route by itself.** A test that wrote
/// `@testable import VoccaCore` would see this initializer and could mint a token, which would
/// make a bypass compile in exactly the place a bypass must never compile — the tests that are
/// supposed to prove it cannot. Access control cannot reach that case, so it is closed the
/// other way: the `action-seam` family lint confines *construction of this type* to this one
/// file, scanning `Sources/` **and** `Tests/` alike. A forging test fails the lint even though
/// it compiles. The two mechanisms are complementary and neither is sufficient alone.
///
/// **It carries no state yet.** Confirmation is per-invocation (M4a: no "don't ask me again",
/// no per-tool or per-session carry-over), so binding a token to the exact ``ActionInvocation``
/// and ``ActionSummary`` the user saw is the natural next step — and it belongs to
/// `confirmation-gate`, which is the aspect that mints, the aspect that can test the binding,
/// and therefore the aspect that should own the fields. Adding them here now would be a
/// contract invented ahead of its only caller. The token as it stands proves *that* the gate
/// was passed, not *what* it was passed for; the later addition is purely additive and does
/// not weaken what is written above.
public struct ActionConfirmation: Sendable, Equatable {

    /// Mints a confirmation. **Internal by design — see the type's documentation.** Only
    /// `VoccaCore` can call this, and within `VoccaCore` only the confirmation gate's own file
    /// may, which the family lint enforces across `Sources/` and `Tests/`.
    init() {}
}
