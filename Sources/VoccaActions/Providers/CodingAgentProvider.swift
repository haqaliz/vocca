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
/// ``describe(_:)`` renders the agent id, the fixed argv verbatim, the resolved project
/// directory and the author's optional clause appended last. A planted argv appears verbatim
/// and a misleading clause cannot hide it — the card confirms what actually runs, not what the
/// author wrote about it. The clause is untrusted prose rendered into a safety dialog, so it
/// is sanitised exactly like a value: a control character inside it must not be able to forge
/// a new line of the dialog it appears in. The rendering lives in ``CodingAgentSentences``,
/// one place, shared with the invoke path so the sentence and the argv that runs cannot drift.
///
/// ## One resolution, both halves (`invocation-carrier`, PRD R2)
///
/// The directory is resolved exactly once, per invocation, at arm time and carried on the
/// invocation itself: both halves read `invocation.resolvedDirectory ?? agent.projectDirectory`
/// — the invocation's resolved value wins, else the row's. Describe feeds that one value to
/// the sentence's `in <dir>` clause; invoke feeds the same value to the configuration's
/// `currentDirectoryURL`, so the child starts where the sentence says it will. When the
/// resolution is nil the sentence renders clause-less (S1 — the child runs in Vocca's cwd,
/// visible in the sentence, never hidden) and the configuration is built without a
/// `currentDirectoryURL`. The nil leg is the shipped shape's own: a row without a
/// `projectDirectory` — the editor's empty field, absent or blank in the file (the decoder
/// normalizes blank to nil) — is the valid nil-directory row, resolved once at arm by the
/// injected `activeProjectDirectory` closure, and a nil-directory row without detection runs
/// in Vocca's cwd, visible in the sentence, never hidden.
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
    /// ## The spoken task substitutes into the argv, one render (`task-carrier`)
    ///
    /// An invocation may carry `taskText` — the spoken words that fill the row's `<task>`
    /// placeholder (the preset templates' ``KnownAgentPresets/taskPlaceholder``). Both halves
    /// resolve the substituted argv from the same helper
    /// (``CodingAgentSentences/substitutedArguments(arguments:taskText:)``), so the argv that
    /// runs is the argv the sentence showed, with the spoken words in place. Three refusals
    /// are loud, bounded (`agent.taskHasNowhereToGo`, `agent.taskTextMissing`,
    /// `agent.taskTextTooLarge`) and shared by both halves — a task with no placeholder to
    /// fill, a placeholder with no task (reachable only by a hand-built invocation — the
    /// surface refuses earlier), and a task over the 4096-UTF-8-byte bound (refused, never
    /// truncated — the arguments precedent). The refusals describe at
    /// ``BlastRadius/outwardFacing`` like the arguments refusal does: the call would have
    /// run, and the radius keeps the agent's claim.
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
/// environment map into the configuration's environment, the injected baseline into its
/// `baselineEnvironment` — exactly those variables and nothing else (the executor scrubs) —
/// and the **resolved** directory
/// (`invocation.resolvedDirectory ?? agent.projectDirectory`) into the configuration's
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

    /// A spoken task with no placeholder in the row's argv — the task has nowhere to go
    /// (`task-carrier`).
    static let taskHasNowhereToGoReasonKey = "agent.taskHasNowhereToGo"

    /// A placeholder in the row's argv with no spoken task supplied — reachable only by a
    /// hand-built invocation, since the surface refuses earlier (`task-carrier`).
    static let taskTextMissingReasonKey = "agent.taskTextMissing"

    /// A spoken task over the 4096-UTF-8-byte bound — refused, never truncated (the
    /// ``ActionInvocation/maximumArgumentsUTF8Bytes`` precedent, `task-carrier`).
    static let taskTextTooLargeReasonKey = "agent.taskTextTooLarge"

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

    /// The declared baseline environment — the entries every configuration carries, merged
    /// under the row's own environment by the executor (the row winning, never beyond
    /// (N2)). **Empty by default**: a provider constructed without a baseline asks the
    /// engine for exactly what today's did — the doctrine, byte-identical (`provider-baseline`).
    /// The composition wires one value; every agent child starts from it.
    private let baselineEnvironment: [String: String]

    /// - Parameters:
    ///   - agents: The configured agent definitions — the file the registry holds, or
    ///     whatever a test seeds. The tool list is fixed from this at construction.
    ///   - run: The engine, as a run closure over one configuration. The provider resolves
    ///     the row and hands it over; it never touches a transport itself.
    ///   - baselineEnvironment: The declared baseline environment every configuration
    ///     carries (`provider-baseline`): the entries the composition wires once, merged
    ///     under the row's own environment by the executor (the row winning). Empty by
    ///     default — the additive doctrine, byte-identical to today.
    public init(
        agents: [CodingAgentDefinition],
        run: @escaping @Sendable (ShellExecutor.Configuration) async -> ShellExecutionResult,
        baselineEnvironment: [String: String] = [:]
    ) {
        self.toolIDs = agents.map(\.id)
        var byID: [String: CodingAgentDefinition] = [:]
        for agent in agents where byID[agent.id] == nil { byID[agent.id] = agent }
        self.agentsByID = byID
        self.run = run
        self.baselineEnvironment = baselineEnvironment
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
    /// A resolved row — and the refusals for an invocation that carried arguments or a spoken
    /// task the row cannot take — claims ``BlastRadius/outwardFacing``: an agent is never
    /// read-only, and a refusal that de-escalated the claim would be a de-escalation however
    /// it was arrived at.
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

        let resolvedDirectory = Self.resolvedDirectory(
            carried: invocation.resolvedDirectory, rowDirectory: agent.projectDirectory)
        switch Self.resolveTaskSubstitution(
            rowArguments: agent.arguments, taskText: invocation.taskText)
        {
        case .unsubstituted(let argv), .substituted(let argv):
            return ActionSummary(
                sentence: CodingAgentSentences.sentence(
                    id: agent.id, executablePath: agent.executablePath,
                    arguments: argv, projectDirectory: resolvedDirectory,
                    clause: agent.clause),
                blastRadius: .outwardFacing)
        case .taskHasNowhereToGo:
            return ActionSummary(
                sentence: CodingAgentSentences.taskHasNowhereToGoSentence(
                    id: agent.id, executablePath: agent.executablePath,
                    arguments: agent.arguments, projectDirectory: resolvedDirectory),
                blastRadius: .outwardFacing)
        case .taskTextMissing:
            return ActionSummary(
                sentence: CodingAgentSentences.taskTextMissingSentence(
                    id: agent.id, executablePath: agent.executablePath,
                    arguments: agent.arguments, projectDirectory: resolvedDirectory),
                blastRadius: .outwardFacing)
        case .taskTextTooLarge:
            return ActionSummary(
                sentence: CodingAgentSentences.taskTextTooLargeSentence(
                    id: agent.id, executablePath: agent.executablePath,
                    arguments: agent.arguments, projectDirectory: resolvedDirectory),
                blastRadius: .outwardFacing)
        }
    }

    // MARK: - invoke

    /// Runs the resolved row through the engine. **The only operation that acts**, and
    /// reachable only with a token the gate alone can mint.
    ///
    /// The row is re-resolved here on the invocation's own arguments — the same object the
    /// gate described — so the argv that runs is the argv the sentence showed, spoken task
    /// substituted in place. Every failure is a returned ``ActionOutcome``, never a trap and
    /// never a thrown error: an unknown row, an invocation carrying arguments, and an
    /// invocation whose spoken task the row cannot take are all refused before the engine is
    /// asked at all.
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

        let resolvedDirectory = Self.resolvedDirectory(
            carried: invocation.resolvedDirectory, rowDirectory: agent.projectDirectory)
        switch Self.resolveTaskSubstitution(
            rowArguments: agent.arguments, taskText: invocation.taskText)
        {
        case .unsubstituted(let argv), .substituted(let argv):
            let configuration: ShellExecutor.Configuration
            if let resolvedDirectory {
                configuration = ShellExecutor.Configuration(
                    executablePath: agent.executablePath,
                    arguments: argv,
                    environment: agent.environment ?? [:],
                    baselineEnvironment: baselineEnvironment,
                    currentDirectoryURL: URL(fileURLWithPath: resolvedDirectory),
                    timeout: .seconds(agent.timeoutSeconds))
            } else {
                configuration = ShellExecutor.Configuration(
                    executablePath: agent.executablePath,
                    arguments: argv,
                    environment: agent.environment ?? [:],
                    baselineEnvironment: baselineEnvironment,
                    timeout: .seconds(agent.timeoutSeconds))
            }
            let result = await run(configuration)
            return Self.outcome(from: result)
        case .taskHasNowhereToGo:
            return .failed(reasonKey: Self.taskHasNowhereToGoReasonKey)
        case .taskTextMissing:
            return .failed(reasonKey: Self.taskTextMissingReasonKey)
        case .taskTextTooLarge:
            return .failed(reasonKey: Self.taskTextTooLargeReasonKey)
        }
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

    /// **The one resolution, both halves share** (`invocation-carrier` R2 + `agent-wiring-cwd`
    /// R3): the invocation's carried arm-time value wins; else the row's own directory — which
    /// the type guarantees is nil or a non-blank absolute path, so a nil-directory row resolves
    /// to nil: the clause-less sentence and the no-`currentDirectoryURL` configuration are one
    /// resolution (S1). A non-nil row resolves byte-identically to the pre-carrier shape.
    private static func resolvedDirectory(
        carried: String?, rowDirectory: String?
    ) -> String? {
        carried ?? rowDirectory
    }

    // MARK: - The task substitution (one render, both halves)

    /// The resolution of an invocation's spoken task against the row's argv
    /// (`task-carrier`): either the argv to run — raw when there is no task text, substituted
    /// when there is — or the refusal the combination demands.
    private enum TaskSubstitution {
        /// No task text and no placeholder: the row's argv runs unchanged.
        case unsubstituted([String])

        /// Task text present and the placeholder present: every occurrence substituted.
        case substituted([String])

        /// Task text present, no placeholder in the argv — the task has nowhere to go.
        case taskHasNowhereToGo

        /// Placeholder present, no task text — reachable only by a hand-built invocation.
        case taskTextMissing

        /// Task text over the 4096-UTF-8-byte bound — refused, never truncated.
        case taskTextTooLarge
    }

    /// **The one substitution resolution, both halves share** — describe and invoke resolve
    /// the substituted argv from the same helper, so the argv that runs is the argv the
    /// sentence showed, and a refusal is the same refusal in both halves.
    ///
    /// The rules, in the order they are judged: a task text with no placeholder in the argv
    /// has nowhere to go (refused — a run with the task silently dropped would be a different
    /// action); a task text over ``ActionInvocation/maximumArgumentsUTF8Bytes`` is refused,
    /// never truncated (the arguments precedent); a placeholder with no task text is refused
    /// (substituting nothing would run a placeholder the sentence never showed); otherwise
    /// the substitution is ``CodingAgentSentences/substitutedArguments(arguments:taskText:)``,
    /// every literal occurrence, both halves.
    private static func resolveTaskSubstitution(
        rowArguments: [String], taskText: String?
    ) -> TaskSubstitution {
        if let taskText {
            guard CodingAgentSentences.argumentsContainPlaceholder(rowArguments) else {
                return .taskHasNowhereToGo
            }
            guard taskText.utf8.count <= ActionInvocation.maximumArgumentsUTF8Bytes else {
                return .taskTextTooLarge
            }
            return .substituted(
                CodingAgentSentences.substitutedArguments(
                    arguments: rowArguments, taskText: taskText))
        }
        guard !CodingAgentSentences.argumentsContainPlaceholder(rowArguments) else {
            return .taskTextMissing
        }
        return .unsubstituted(rowArguments)
    }
}