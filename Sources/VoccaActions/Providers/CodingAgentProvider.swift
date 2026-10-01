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

/// A configured coding agent behind the action seam — **the fifth real ``ActionProvider``**
/// (`agent-provider`, the `coding-agent-handoff` unit): a registry row becomes a
/// voice-reachable, gate-governed, auditable one-shot agent run. The ``ShellProvider`` shape
/// exactly — actor, injected engine closure, describe and invoke sharing one argv-derived
/// sentence, refusal never a trap, confirmation never minted.
///
/// | Agent | Blast radius | What it does |
/// |---|---|---|
/// | *anything in `coding-agents.json`* | outwardFacing, always | Runs the row's fixed argv in the row's project directory |
///
/// ## The sentence is derived from the argv, never authored prose (founder decision)
///
/// ``describe(_:)`` renders the agent id, the fixed argv verbatim, the project directory and
/// the author's optional clause appended last. A planted argv appears verbatim and a
/// misleading clause cannot hide it — the card confirms what actually runs, not what the
/// author wrote about it. The clause is untrusted prose rendered into a safety dialog, so it
/// is sanitised exactly like a value: a control character inside it must not be able to forge
/// a new line of the dialog it appears in. The rendering lives in ``CodingAgentSentences``,
/// one place, shared with the invoke path so the sentence and the argv that runs cannot drift.
///
/// ## An agent is never read-only
///
/// The registry row has **no `readOnly` field** (the `agent-registry` byte-pin refuses the
/// key), so the blast radius is ``BlastRadius/outwardFacing`` for every resolved row by
/// construction. The gate's escalate-only policy can only raise this claim, never lower it —
/// and there is no read-only claim to lower, so the outward-facing radius is the floor the
/// confirmation surface builds on.
///
/// ## The gap-1 pin: an agent row declares no parameters
///
/// The invocation's argument text is read only for presence, never parsed: this unit ships no
/// `$N` slots and no `{{utterance}}` seeding (PRD N1/N2 deferrals), so an invocation that
/// carries arguments at all is a call this provider cannot honestly serve — *any* supplied
/// arguments are refused, the shell undeclared-key rule. `describe` renders the refusal at
/// ``BlastRadius/outwardFacing`` — never de-escalated to read-only, which would be a
/// de-escalation however it was arrived at — and `invoke` answers
/// ``ActionOutcome/failed(reasonKey:)`` with the bounded `agent.unexpectedArguments` key.
///
/// ## Refusals keep the radius
///
/// An unknown row describes as a refusal at ``BlastRadius/readOnly`` — nothing will happen, so
/// nothing needs confirming. Everything else describes at ``BlastRadius/outwardFacing``,
/// whatever the arguments look like.
///
/// ## What the engine is, and what it is not
///
/// The engine is injected as an ``ShellExecutor/Configuration``-shaped run closure, so a test
/// records what was asked without spawning anything and the shipped composition hands over the
/// real ``ShellExecutor`` — the same engine the shell slice uses, inherited for the agent
/// child (the `agent-execution` decision: no new engine ships, the transport-permit lint keeps
/// its permitted set at exactly the stdio transport and the executor). This file names no
/// transport family: the row's timeout flows into the configuration's timeout, the row's
/// environment map into the configuration's environment — exactly those variables and nothing
/// else (the executor scrubs) — and the row's `projectDirectory` into the configuration's
/// `currentDirectoryURL`, so the child starts where the sentence says it will.
///
/// ## What it is not
///
/// Nothing here is wired into the composition root — this aspect ships an implementation, not
/// a surface. The registry is read **once**, at construction: ``toolIDs`` is fixed for the
/// provider's lifetime, so a tool list can never disagree with the sentence a user was shown.
/// `invoke` never constructs an ``ActionConfirmation`` — Family B confines that to
/// ``ActionGate`` across `Sources/` and `Tests/` alike, and this file names the token only
/// in the signature the seam forces.
public actor CodingAgentProvider: ActionProvider {

    /// The identifier a caller names this provider by when building an invocation.
    ///
    /// Exposed as a constant because an invocation is plain data built by the caller: a call
    /// site that spelled the string itself would drift from the one the audit log attributes
    /// entries to. **The real id of this unit** — the registry's own documentation carries it
    /// too, so the enablement store, the phrase store and the surface all name one value.
    public static let providerID = "vocca.agent"

    /// A row the registry never declared. Bounded key, never a message — the audit entry is
    /// byte-pinned and free-form text would smuggle unbounded bytes onto disk.
    static let unknownAgentReasonKey = "agent.unknownTool"

    /// Argument text an agent row cannot accept — an agent declares no parameters, so any
    /// supplied arguments are refused (the gap-1 pin).
    static let unexpectedArgumentsReasonKey = "agent.unexpectedArguments"

    // MARK: - State

    /// The tools this provider serves, by agent id, in the registry's order.
    ///
    /// `nonisolated` because the requirement is synchronous and the value is fixed at
    /// construction — there is no state here to protect, which is the point of reading the
    /// registry once.
    public nonisolated let toolIDs: [String]

    /// The configured agents, by id. First declaration wins: a caller that listed one id
    /// twice has contradicted itself, and taking the later one would let a second row
    /// quietly replace the argv the first was read with.
    private let agentsByID: [String: CodingAgentDefinition]

    /// The engine: one run of one resolved row. Injected so a test records the call without
    /// spawning anything; the shipped composition hands over the real ``ShellExecutor``.
    private let run: @Sendable (ShellExecutor.Configuration) async -> ShellExecutionResult

    /// - Parameters:
    ///   - agents: The configured agent definitions — the file the registry holds, or
    ///     whatever a test seeds. The tool list is fixed from this at construction.
    ///   - run: The engine, as a run closure over one configuration. The provider resolves
    ///     the row and hands it over; it never touches a transport itself.
    public init(
        agents: [CodingAgentDefinition],
        run: @escaping @Sendable (ShellExecutor.Configuration) async -> ShellExecutionResult
    ) {
        self.toolIDs = agents.map(\.id)
        var byID: [String: CodingAgentDefinition] = [:]
        for agent in agents where byID[agent.id] == nil { byID[agent.id] = agent }
        self.agentsByID = byID
        self.run = run
    }

    /// Loads the registry and builds a provider over it — the registry-shaped construction,
    /// the ``MCPProvider/discover(session:providerID:)`` analogue.
    ///
    /// Reads the file once, so a provider that exists is a provider whose tool list is fixed
    /// for its lifetime; an agent added to the file is a new provider, never a silent re-list.
    /// The engine is injected — the wiring composes the handoff to the real ``ShellExecutor``;
    /// nothing runs until an invocation is invoked.
    public static func load(
        registry: CodingAgentRegistry,
        run: @escaping @Sendable (ShellExecutor.Configuration) async -> ShellExecutionResult
    ) async -> CodingAgentProvider {
        let file = await registry.load()
        return CodingAgentProvider(agents: file.agents, run: run)
    }

    // MARK: - describe

    /// Renders what the agent *would* do, concretely, without running any part of it.
    ///
    /// Pure: nothing here spawns, and a dry-run that stops after this call has changed
    /// nothing. The sentence comes from ``CodingAgentSentences``, so the argv a person
    /// approves is the argv ``invoke(_:confirmation:)`` would run — one rendering shared by
    /// both halves, never two spellings that can drift.
    ///
    /// An unserved row is refused at ``BlastRadius/readOnly`` before anything else is read.
    /// A resolved row — and the refusal for an invocation that carried arguments — claims
    /// ``BlastRadius/outwardFacing``: an agent is never read-only, and a refusal that
    /// de-escalated the claim would be a de-escalation however it was arrived at.
    public func describe(_ invocation: ActionInvocation) async -> ActionSummary {
        guard let agent = agentsByID[invocation.toolID] else {
            return ActionSummary(
                sentence: CodingAgentSentences.unknownAgentSentence(
                    toolID: invocation.toolID),
                blastRadius: .readOnly)
        }

        guard invocation.arguments == nil else {
            return ActionSummary(
                sentence: CodingAgentSentences.unexpectedArgumentsSentence(
                    id: agent.id, executablePath: agent.executablePath,
                    arguments: agent.arguments, projectDirectory: agent.projectDirectory),
                blastRadius: .outwardFacing)
        }

        return ActionSummary(
            sentence: CodingAgentSentences.sentence(
                id: agent.id, executablePath: agent.executablePath,
                arguments: agent.arguments, projectDirectory: agent.projectDirectory,
                clause: agent.clause),
            blastRadius: .outwardFacing)
    }

    // MARK: - invoke

    /// Runs the resolved row through the engine. **The only operation that acts**, and
    /// reachable only with a token the gate alone can mint.
    ///
    /// The row is re-resolved here on the invocation's own arguments — the same object the
    /// gate described — so the argv that runs is the argv the sentence showed. Every failure
    /// is a returned ``ActionOutcome``, never a trap and never a thrown error: an unknown row
    /// and an invocation carrying arguments are refused before the engine is asked at all.
    ///
    /// An unknown row is ``ActionOutcome/failed(reasonKey:)`` with a bounded key, never
    /// a trap and never a silent success. It is a failure rather than
    /// ``ActionOutcome/notInvoked`` because the gate reached this provider and this provider
    /// could not do what it was asked; `.notInvoked` is reserved for the case where nothing
    /// was attempted at all.
    public func invoke(_ invocation: ActionInvocation, confirmation: ActionConfirmation) async
        -> ActionOutcome
    {
        guard let agent = agentsByID[invocation.toolID] else {
            return .failed(reasonKey: Self.unknownAgentReasonKey)
        }

        guard invocation.arguments == nil else {
            return .failed(reasonKey: Self.unexpectedArgumentsReasonKey)
        }

        let configuration = ShellExecutor.Configuration(
            executablePath: agent.executablePath,
            arguments: agent.arguments,
            environment: agent.environment ?? [:],
            currentDirectoryURL: URL(fileURLWithPath: agent.projectDirectory),
            timeout: .seconds(agent.timeoutSeconds))
        let result = await run(configuration)
        return Self.outcome(from: result)
    }

    /// The engine's result as an ``ActionOutcome`` — the fold that lives with the provider.
    ///
    /// The engine's bounded failure keys are carried **unchanged** — never translated,
    /// abbreviated or re-spelled — so ``ShellExecutionResult/boundedFailureKeys`` is exactly
    /// the vocabulary the audit seam can ever see from an agent run. Success carries no key
    /// at all.
    private static func outcome(from result: ShellExecutionResult) -> ActionOutcome {
        switch result.status {
        case .succeeded:
            return .succeeded
        case .failed(let reasonKey):
            return .failed(reasonKey: reasonKey)
        }
    }
}