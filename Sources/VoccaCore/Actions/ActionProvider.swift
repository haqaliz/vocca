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

/// The pluggable action boundary (C13, `action-safety-spine` PRD M1): a source of tools Vocca
/// can be asked to run, and the only route by which anything Vocca says gets *done*.
///
/// ## The describe / invoke split (PRD M5a)
///
/// The seam has two operations and the split between them is the design, not an ergonomics
/// choice. Two requirements looked compatible and were not: dry-run must touch nothing (M5),
/// and the confirmation must state concretely what will happen (M2, M4). Only the provider
/// knows what `delete-downloads` concretely means — so as long as "find out what it does" and
/// "do it" are the same call, one of the two requirements has to give.
///
/// - ``describe(_:)`` is **pure**: it renders the sentence and the blast radius and changes
///   nothing. Dry-run calls it freely.
/// - ``invoke(_:confirmation:)`` is the **only operation that acts**, and it cannot be called
///   without an ``ActionConfirmation`` — a token whose initializer is `internal` to
///   `VoccaCore`, so outside the gate there is nothing to hand it. The structural refusal
///   (M4) is that signature, not a check inside an implementation.
///
/// "Zero side effects" is therefore scoped precisely: it means `invoke` is called zero times,
/// which is a thing a test can assert by counting.
///
/// ## `async`, and deliberately **not** `async throws`
///
/// Both operations are `async` (`async-seam`, 2026-09-19). They were synchronous, on the C12 D1
/// posture — an adapter whose work was asynchronous would become an `actor` and conform through a
/// `nonisolated` witness. That route works only where the underlying work is *synchronous*, as
/// the Accessibility C API is. **A `nonisolated` synchronous witness cannot await an actor**, so
/// for a provider backed by the audit store — an actor with `async throws` methods — or by MCP
/// over stdio, file I/O or a subprocess, there was no conformance to write at all. The first
/// honest attempt at a second provider failed against the contract rather than against its own
/// design, which is what changed the shape here.
///
/// Both operations, not only the acting one: a confirmation has to say what will happen **in
/// concrete terms** — "clear the audit log, 12 entries, permanently" — and a count like that is a
/// read. A synchronous ``describe(_:)`` forces vague copy, which is the specific failure C13
/// names.
///
/// **Not `async throws`, and that is load-bearing.** Failure stays a *returned value*:
/// `describe` cannot fail — an unknown tool is described as a refusal, never as an error (see
/// ``NullActionProvider``) — and `invoke` returns its failure as an ``ActionOutcome`` the audit
/// log must record either way. An error is droppable by omitting a `catch`; an audit record must
/// not be. Adding `throws` here would destroy that property, so it is a reviewed decision about
/// every provider at once rather than a convenience at one call site.
///
/// ## What ships behind it
///
/// ``NullActionProvider`` — zero tools, refuses everything — is the shipped default and the
/// only implementation in the tree. Nothing in this unit transports anything anywhere: there
/// is no MCP client, no `Process`, no network, and `VoccaCore` imports nothing that could
/// provide one.
public protocol ActionProvider: Sendable {

    /// The tools this provider serves, by identifier.
    ///
    /// Empty is a legitimate and meaningful answer: it is what the shipped default returns, and
    /// it means there is nothing for an intent layer to resolve an utterance against.
    var toolIDs: [String] { get }

    /// Renders what the invocation *would* do, without doing any part of it.
    ///
    /// Pure and side-effect-free — this is the call dry-run is allowed to make. It always
    /// returns a summary: an unknown or unserved tool is described as a refusal (a sentence
    /// saying nothing will happen, at ``BlastRadius/readOnly``), never a trap and never an
    /// error, so the default is safe to call with anything.
    ///
    /// - Parameter invocation: The provider and tool being asked about.
    /// - Returns: The concrete sentence and the blast radius the gate branches on.
    func describe(_ invocation: ActionInvocation) async -> ActionSummary

    /// Performs the action. **The only operation that acts.**
    ///
    /// - Parameters:
    ///   - invocation: The provider and tool to run.
    ///   - confirmation: Proof the gate was passed. Unforgeable outside `VoccaCore` by
    ///     construction — see ``ActionConfirmation``.
    /// - Returns: ``ActionOutcome/succeeded``, ``ActionOutcome/failed(reasonKey:)`` when the
    ///   attempt was made and failed, or ``ActionOutcome/notInvoked`` when the provider never
    ///   acted at all. A provider that declines must return `.notInvoked` rather than a
    ///   failure: the audit log distinguishes "tried and failed" from "never ran".
    func invoke(_ invocation: ActionInvocation, confirmation: ActionConfirmation) async
        -> ActionOutcome
}
