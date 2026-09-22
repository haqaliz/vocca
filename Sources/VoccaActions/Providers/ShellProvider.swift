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

import VoccaCore

/// A configured shell command behind the action seam — **the third real ``ActionProvider``**
/// and the one with the highest blast radius in the roadmap (`shell-provider` PRD R3): a
/// shell command can do anything the user can do, and the confirmation surface is the only
/// mitigation.
///
/// | Command | Blast radius | What it does |
/// |---|---|---|
/// | *anything in `shell-commands.json`* | destructive unless the file declares `readOnly: true` | Runs the fixed argv on the user's machine |
///
/// ## The sentence is derived from the argv, never authored prose (founder decision)
///
/// ``describe(_:)`` renders the command name, the argv with supplied parameter values
/// substituted in place, the `key = value` value renderings (keys sorted, values sanitised)
/// and the author's optional clause appended last. A planted argv appears verbatim and a
/// misleading clause cannot hide it — the card confirms what actually runs, not what the
/// author wrote about it. The clause is untrusted prose rendered into a safety dialog, so it
/// is sanitised exactly like a value: a control character inside it must not be able to
/// forge a new line of the dialog it appears in. The rendering lives in
/// ``ShellProviderSentences``, one place, shared with the invoke path so the sentence and
/// the argv that runs cannot drift.
///
/// ## Destructive by default
///
/// A command whose file does not declare `readOnly: true` claims ``BlastRadius/destructive``
/// — the founder decision, and the MCP "absent means unsafe" precedent. The gate's
/// escalate-only policy can only raise this claim, never lower it, so the file is the floor
/// the confirmation surface builds on.
///
/// ## Refusals keep the radius
///
/// An unknown command describes as a refusal at ``BlastRadius/readOnly`` — nothing will
/// happen, so nothing needs confirming. Unreadable or missing parameter values render a
/// refusal that **keeps the command's own radius**: answering "nothing will happen,
/// read-only" for a destructive command with an unreadable payload would hand the gate a
/// read-only classification for a command that is not one, and leave the refusal resting on
/// ``invoke(_:confirmation:)`` remembering to check again. A de-escalation is a
/// de-escalation however it is arrived at.
///
/// ## What the engine is, and what it is not
///
/// The engine is injected as an ``ShellExecutor/Configuration``-shaped run closure, so a
/// test records what was asked without spawning anything and the shipped composition hands
/// over the real ``ShellExecutor`` — the engine that runs a fixed argv directly, never
/// through a shell, with the bounded injected-clock timeout and the no-orphan contract. This
/// file names no transport: the module's prohibition lint keeps its permitted set at exactly
/// the stdio transport and the executor, and this conformance is not a third entry.
///
/// ## What it is not
///
/// Nothing here is wired into the composition root — this aspect ships an implementation,
/// not a surface. The registry is read **once**, at construction: ``toolIDs`` is fixed for
/// the provider's lifetime, so a tool list can never disagree with the sentence a user was
/// shown. `invoke` never constructs an ``ActionConfirmation`` — Family B confines that to
/// ``ActionGate`` across `Sources/` and `Tests/` alike, and this file names the token only
/// in the signature the seam forces.
public actor ShellProvider: ActionProvider {

    /// The identifier a caller names this provider by when building an invocation.
    ///
    /// Exposed as a constant because an invocation is plain data built by the caller: a call
    /// site that spelled the string itself would drift from the one the audit log attributes
    /// entries to.
    public static let providerID = "dev.vocca.shell"

    /// A command the registry never declared. Bounded key, never a message — the audit entry
    /// is byte-pinned and free-form text would smuggle unbounded bytes onto disk.
    static let unknownCommandReasonKey = "provider.unknownTool"

    /// Argument text the provider cannot resolve against the command's declared parameters.
    static let unreadableArgumentsReasonKey = "shell.unreadableArguments"

    // MARK: - State

    /// The tools this provider serves, by command id, in the registry's order.
    ///
    /// `nonisolated` because the requirement is synchronous and the value is fixed at
    /// construction — there is no state here to protect, which is the point of reading the
    /// registry once.
    public nonisolated let toolIDs: [String]

    /// The configured commands, by id. First declaration wins: a caller that listed one id
    /// twice has contradicted itself, and taking the later one would let a second row
    /// quietly replace the argv the first was read with.
    private let commandsByID: [String: ShellCommandDefinition]

    /// The engine: one run of one resolved argv. Injected so a test records the call without
    /// spawning anything; the shipped composition hands over the real ``ShellExecutor``.
    private let run: @Sendable (ShellExecutor.Configuration) async -> ShellExecutionResult

    /// - Parameters:
    ///   - commands: The configured command definitions — the file the registry holds, or
    ///     whatever a test seeds. The tool list is fixed from this at construction.
    ///   - run: The engine, as a run closure over one configuration. The provider resolves
    ///     the argv and hands it over; it never touches a transport itself.
    public init(
        commands: [ShellCommandDefinition],
        run: @escaping @Sendable (ShellExecutor.Configuration) async -> ShellExecutionResult
    ) {
        self.toolIDs = commands.map(\.id)
        var byID: [String: ShellCommandDefinition] = [:]
        for command in commands where byID[command.id] == nil { byID[command.id] = command }
        self.commandsByID = byID
        self.run = run
    }

    /// Loads the registry and builds a provider over it — the registry-shaped construction,
    /// the ``MCPProvider/discover(session:providerID:)`` analogue.
    ///
    /// Reads the file once, so a provider that exists is a provider whose tool list is fixed
    /// for its lifetime; a command added to the file is a new provider, never a silent
    /// re-list. The engine is the real ``ShellExecutor`` with the shipped clock and poll
    /// sleeper; nothing runs until an invocation is invoked.
    public static func load(
        registry: ShellCommandRegistry,
        clock: any MonotonicClock & Sendable = ContinuousStdioClock(),
        sleeper: any StdioPollSleeper = TaskStdioPollSleeper()
    ) async -> ShellProvider {
        let file = await registry.load()
        return ShellProvider(commands: file.commands) { configuration in
            await ShellExecutor(configuration: configuration, clock: clock, sleeper: sleeper)
                .run()
        }
    }

    // MARK: - describe

    /// Renders what the command *would* do, concretely, without running any part of it.
    ///
    /// Pure: nothing here spawns, and a dry-run that stops after this call has changed
    /// nothing. The sentence comes from ``ShellProviderSentences``, so the argv a person
    /// approves is the argv ``invoke(_:confirmation:)`` would run — one rendering shared by
    /// both halves, never two spellings that can drift.
    ///
    /// An unserved command is refused before anything else is read. The radius on a refusal
    /// for unreadable parameters is the command's own — destructive unless the file declared
    /// `readOnly: true` — because the gate's escalate-only policy may only raise a claim,
    /// and a refusal that de-escalated it would be a de-escalation dressed as a courtesy.
    public func describe(_ invocation: ActionInvocation) async -> ActionSummary {
        guard let command = commandsByID[invocation.toolID] else {
            return ActionSummary(
                sentence: ShellProviderSentences.unknownCommandSentence(
                    toolID: invocation.toolID),
                blastRadius: .readOnly)
        }

        switch ShellProviderSentences.resolve(
            arguments: invocation.arguments, parameters: command.parameters)
        {
        case .unreadable:
            return ActionSummary(
                sentence: ShellProviderSentences.refusalSentence(
                    id: command.id, argv: command.command),
                blastRadius: command.readOnly ? .readOnly : .destructive)

        case .resolved(let values):
            guard ShellProviderSentences.substitutedArgv(command, values: values) != nil else {
                return ActionSummary(
                    sentence: ShellProviderSentences.refusalSentence(
                        id: command.id, argv: command.command),
                    blastRadius: command.readOnly ? .readOnly : .destructive)
            }
            return ActionSummary(
                sentence: ShellProviderSentences.sentence(
                    id: command.id, argv: command.command, parameters: command.parameters,
                    values: values, clause: command.clause),
                blastRadius: command.readOnly ? .readOnly : .destructive)
        }
    }

    // MARK: - invoke

    /// Runs the resolved argv through the engine. **The only operation that acts**, and
    /// reachable only with a token the gate alone can mint.
    ///
    /// The resolution is re-run here on the invocation's own arguments — the same object the
    /// gate described — so the argv that runs is the argv the sentence showed. Every failure
    /// is a returned ``ActionOutcome``, never a trap and never a thrown error: the engine
    /// maps its bounded keys through unchanged, and an unreadable payload is refused before
    /// the engine is asked at all.
    ///
    /// An unknown command is ``ActionOutcome/failed(reasonKey:)`` with a bounded key, never
    /// a trap and never a silent success. It is a failure rather than
    /// ``ActionOutcome/notInvoked`` because the gate reached this provider and this provider
    /// could not do what it was asked; `.notInvoked` is reserved for the case where nothing
    /// was attempted at all.
    public func invoke(_ invocation: ActionInvocation, confirmation: ActionConfirmation) async
        -> ActionOutcome
    {
        guard let command = commandsByID[invocation.toolID] else {
            return .failed(reasonKey: Self.unknownCommandReasonKey)
        }

        switch ShellProviderSentences.resolve(
            arguments: invocation.arguments, parameters: command.parameters)
        {
        case .unreadable:
            return .failed(reasonKey: Self.unreadableArgumentsReasonKey)

        case .resolved(let values):
            guard let argv = ShellProviderSentences.substitutedArgv(command, values: values)
            else {
                return .failed(reasonKey: Self.unreadableArgumentsReasonKey)
            }
            let configuration = ShellExecutor.Configuration(
                executablePath: argv[0], arguments: Array(argv.dropFirst()))
            let result = await run(configuration)
            return Self.outcome(from: result)
        }
    }

    /// The engine's result as an ``ActionOutcome`` — the fold that lives with the provider.
    ///
    /// The engine's bounded failure keys are carried **unchanged** — never translated,
    /// abbreviated or re-spelled — so ``ShellExecutionResult/boundedFailureKeys`` is exactly
    /// the vocabulary the audit seam can ever see from a shell run. Success carries no key
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