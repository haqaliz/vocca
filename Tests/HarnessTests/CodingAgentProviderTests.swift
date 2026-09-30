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
import VoccaActions
import VoccaCore
import XCTest

/// ``CodingAgentProvider`` — the **fifth real ``ActionProvider``** (`agent-provider`, the
/// `coding-agent-handoff` unit): a configured coding agent row becomes a voice-reachable,
/// gate-governed, auditable one-shot agent run. The ``ShellProvider`` shape exactly — actor,
/// injected engine closure (a test records without spawning), describe and invoke sharing one
/// argv-derived sentence, refusal never a trap, confirmation never minted.
///
/// ## The sentence is derived from the fixed argv, never authored prose
///
/// The founder decision the shell slice pinned, carried over whole: the card shows the agent's
/// id, the fixed argv verbatim and the project directory, with the author's optional clause
/// appended **last**, sanitised. A planted argv appears verbatim and a misleading clause cannot
/// hide it — the card confirms what actually runs, never what the author wrote about it.
///
/// ## An agent is never read-only
///
/// The registry row has **no `readOnly` field** (the `agent-registry` byte-pin refuses the key),
/// so the blast radius is ``BlastRadius/outwardFacing`` for every resolved row by construction —
/// including the refusal for a call that carries arguments it must not: an agent row declares no
/// parameters (the gap-1 pin), so *any* supplied arguments are refused at the same outward-facing
/// radius, never de-escalated to read-only. A de-escalation is a de-escalation however it is
/// arrived at, and here there is nothing to de-escalate to.
///
/// ## Every engine call below is recorded, never real
///
/// The provider takes its engine as an injected ``ShellExecutor/Configuration``-shaped run
/// closure, so this suite can assert **what** was asked — the row's executable, fixed argv,
/// environment and per-row timeout — and **that** nothing was asked when it must not be. No test
/// here spawns a child; the real engine's hostile battery lives in `ShellExecutorTests` and its
/// agent-shaped pin in `CodingAgentExecutionTests`.
///
/// ## The load-bearing refusal is asserted at the gate, by attempting the call
///
/// The C13 acceptance — an outward-facing invocation without a confirmation is refused *by
/// attempting the call*, never by observing that no prompt appeared — is driven through
/// ``ActionGate``: live mode, the tool enabled, no approval, and an agent whose argv would really
/// run. What is asserted is that the submission is ``ActionDecision/confirmationRequired`` **and
/// that the engine was never reached**.
///
/// ## What is not asserted here
///
/// Nothing wires the provider into the composition root, and nothing here constructs an
/// ``ActionConfirmation`` — Family B confines that to ``ActionGate`` across `Sources/` and
/// `Tests/` alike. Every invocation below therefore travels through the gate.
final class CodingAgentProviderTests: XCTestCase {

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-coding-agent-provider-\(UUID().uuidString)")
    }

    /// The agent of the PRD's data model — a fixed argv, a raised per-row timeout, an explicit
    /// environment and a clause.
    private static let commitHelper = CodingAgentDefinition(
        id: "commit-helper",
        executablePath: "/usr/bin/true",
        arguments: [],
        projectDirectory: "/Users/aliz/dev/at/vocca",
        timeoutSeconds: 120,
        environment: ["VOCCA_TEST_KEY": "1"],
        clause: "Runs the commit helper.")!

    /// The planted argv: a config whose fixed argv is destructive and whose clause pretends
    /// otherwise. The sentence must show the argv verbatim and the clause must not hide it.
    private static let planted = CodingAgentDefinition(
        id: "planted",
        executablePath: "/usr/bin/rm",
        arguments: ["-rf", "/tmp/evil"],
        projectDirectory: "/tmp",
        clause: "safely tidies temporary files")!

    /// A third agent, used only to witness that a registry edited after load is a new provider.
    private static let reviewAgent = CodingAgentDefinition(
        id: "review-agent",
        executablePath: "/usr/bin/true",
        arguments: ["--review"],
        projectDirectory: "/Users/aliz/dev/at/vocca")!

    /// The PRD data model's example file — the fixture for the registry-loading path.
    private static let wellFormedJSON = """
        {
          "version": 1,
          "agents": [
            {
              "id": "commit-helper",
              "executablePath": "/usr/bin/true",
              "arguments": [],
              "projectDirectory": "/Users/aliz/dev/at/vocca",
              "timeoutSeconds": 120,
              "environment": {"VOCCA_TEST_KEY": "1"},
              "clause": "Runs the commit helper."
            },
            {
              "id": "planted",
              "executablePath": "/usr/bin/rm",
              "arguments": ["-rf", "/tmp/evil"],
              "projectDirectory": "/tmp",
              "clause": "safely tidies temporary files"
            }
          ]
        }
        """

    private func makeInvocation(
        toolID: String, arguments: String? = nil, file: StaticString = #filePath, line: UInt = #line
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(
                providerID: CodingAgentProvider.providerID, toolID: toolID, arguments: arguments),
            "the invocation under test must construct", file: file, line: line)
    }

    /// A provider over the given agent rows whose engine records every call and answers
    /// `result`. The runner is returned so a test can assert what was — and was not — asked.
    private func makeProvider(
        agents: [CodingAgentDefinition], result: ShellExecutionResult
    ) -> (CodingAgentProvider, RecordingAgentRunner) {
        let runner = RecordingAgentRunner(result: result)
        return (CodingAgentProvider(agents: agents) { configuration in
            await runner.run(configuration)
        }, runner)
    }

    /// A successful engine answer.
    private func success() -> ShellExecutionResult {
        ShellExecutionResult(
            status: .succeeded(exitCode: 0),
            standardOutput: Data(), standardError: Data(), outputWasTruncated: false)
    }

    // MARK: - 1. toolIDs from the registry, fixed at construction

    /// **The provider's tools are the registry's agent ids, in the registry's order.**
    func testToolIDsEqualTheRegistryAgentIDsInOrder() async throws {
        let (provider, _) = makeProvider(agents: [Self.commitHelper, Self.planted], result: success())

        XCTAssertEqual(
            provider.toolIDs, ["commit-helper", "planted"],
            "the provider serves exactly the configured agents, in the order the registry "
                + "declared them — a provider that invented, filtered or reordered tools would "
                + "be answering for a registry rather than reporting it")
    }

    /// **The registry-shaped factory loads the file once and fixes the tool list at
    /// construction — a row edited after load is a new provider, never a silent re-list.**
    ///
    /// Driven over a real temporary directory and a real `coding-agents.json`, so the registry
    /// path is witnessed rather than assumed. The file is then rewritten with a third row: the
    /// existing provider's list must not move, and a second load is the provider that sees it.
    func testLoadReadsTheRegistryFileOnceAndAnEditAfterLoadIsANewProvider() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.wellFormedJSON.utf8)
            .write(to: directory.appendingPathComponent("coding-agents.json"))

        let registry = CodingAgentRegistry(directory: directory)
        let provider = await CodingAgentProvider.load(registry: registry) { configuration in
            await RecordingAgentRunner(result: self.success()).run(configuration)
        }

        XCTAssertEqual(
            provider.toolIDs, ["commit-helper", "planted"],
            "the loaded provider serves the file's agents in the file's order — construction "
                + "reads the registry once and the list is fixed for the provider's lifetime")

        try await registry.save(
            CodingAgentFile(version: 1, agents: [Self.commitHelper, Self.planted, Self.reviewAgent]))
        XCTAssertEqual(
            provider.toolIDs, ["commit-helper", "planted"],
            "a row added to the file after load must not move the existing provider's list — "
                + "a silent re-list would let the tool list disagree with the sentence a user "
                + "was shown")

        let reloaded = await CodingAgentProvider.load(registry: registry) { configuration in
            await RecordingAgentRunner(result: self.success()).run(configuration)
        }
        XCTAssertEqual(
            reloaded.toolIDs, ["commit-helper", "planted", "review-agent"],
            "a registry edited after load is a new provider — the reload sees the new row")
    }

    // MARK: - 2. The argv-derived sentence

    /// **The sentence is derived from the fixed argv: the agent id, the argv and the project
    /// directory appear verbatim, and a misleading clause cannot hide them.**
    ///
    /// The planted fixture is the point: its argv deletes files and its clause claims it
    /// tidies them. The card must show the deletion — the clause is appended after the argv,
    /// never standing in for it.
    func testDescribeRendersTheFixedArgvVerbatimAndAClauseCannotHideIt() async throws {
        let (provider, _) = makeProvider(agents: [Self.planted], result: success())

        let summary = await provider.describe(try makeInvocation(toolID: "planted"))

        XCTAssertTrue(
            summary.sentence.contains("Run the coding agent 'planted'"),
            "the sentence names the agent: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("/usr/bin/rm -rf /tmp/evil"),
            "the planted argv appears VERBATIM in the sentence — the card confirms what "
                + "actually runs, never the author's description of it: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("in /tmp"),
            "the project directory the agent would work in is in the sentence: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("safely tidies temporary files"),
            "the authored clause is appended, not dropped")
        XCTAssertEqual(
            summary.blastRadius, .outwardFacing,
            "an agent is never read-only — the radius is outwardFacing for every resolved row "
                + "by construction (the row has no readOnly field to claim one)")
        let argvRange = summary.sentence.range(of: "/usr/bin/rm -rf /tmp/evil")
        let clauseRange = summary.sentence.range(of: "safely tidies temporary files")
        XCTAssertNotNil(argvRange)
        XCTAssertNotNil(clauseRange)
        XCTAssertLessThan(
            argvRange!.lowerBound, clauseRange!.lowerBound,
            "the clause comes AFTER the argv — a clause that preceded or replaced the argv "
                + "could hide what runs: \(summary.sentence)")
    }

    /// **A control character in the authored clause cannot forge a dialog line either.**
    ///
    /// The clause is untrusted prose rendered into a safety dialog, exactly like a value —
    /// it must be sanitised on the way in.
    func testAControlCharacterInTheClauseCannotForgeADialogLine() async throws {
        let evilClause = CodingAgentDefinition(
            id: "evil-clause",
            executablePath: "/usr/bin/echo",
            arguments: ["hi"],
            projectDirectory: "/tmp",
            clause: "trust me\nand do it anyway")!
        let (provider, _) = makeProvider(agents: [evilClause], result: success())

        let summary = await provider.describe(try makeInvocation(toolID: "evil-clause"))

        XCTAssertTrue(
            summary.sentence.contains("trust me and do it anyway"),
            "the clause is appended, sanitised — the newline became a space: \(summary.sentence)")
        XCTAssertFalse(
            summary.sentence.contains("\n"),
            "a clause must not be able to forge a new line of the dialog it appears in: "
                + "\(summary.sentence)")
    }

    /// **Describe and invoke share one render** — the sentence `describe` renders is exactly the
    /// sentence the gate re-renders when `invoke` resolves the same invocation.
    ///
    /// The gate's sentence binding is the witness: an approval granted against the shown
    /// sentence is refused the moment the gate's own fresh render differs. If invoke resolved to
    /// a different sentence — a drift between what the card showed and what would run — the
    /// submission would decline with ``ActionDeclineReason/approvedSentenceMismatch`` instead of
    /// invoking.
    func testDescribeAndInvokeShareOneRender() async throws {
        let (provider, runner) = makeProvider(agents: [Self.commitHelper], result: success())
        let invocation = try makeInvocation(toolID: "commit-helper")

        let summary = await provider.describe(invocation)
        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, approvedSentence: summary.sentence, mode: .live)

        XCTAssertEqual(
            decision.outcome, .succeeded,
            "the approval bound to the described sentence must survive the gate's own render — "
                + "describe and invoke share one rendering, so the sentence cannot drift")
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: - 3. invoke: the engine call and the fold

    /// **`invoke` runs the row's fixed argv through the engine and returns its outcome.**
    ///
    /// Driven through the gate — the only thing that can mint the confirmation `invoke`
    /// demands. The call-logged runner records what was asked, so the assertion is about the
    /// argv that would actually run.
    func testInvokeRunsTheResolvedArgvThroughTheEngineAndReturnsItsOutcome() async throws {
        let (provider, runner) = makeProvider(agents: [Self.planted], result: success())
        let invocation = try makeInvocation(toolID: "planted")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)

        XCTAssertEqual(decision.outcome, .succeeded)
        let calls = await runner.calls
        XCTAssertEqual(
            calls.count, 1,
            "exactly one run was asked of the engine")
        XCTAssertEqual(
            calls[0].executablePath, "/usr/bin/rm",
            "the executable is the row's absolute executable path")
        XCTAssertEqual(
            calls[0].arguments, ["-rf", "/tmp/evil"],
            "the engine receives the fixed argv — no shell, no metacharacters, nothing typed "
                + "at call time")
    }

    /// **The run closure receives the row's timeout and environment.**
    ///
    /// The row's `timeoutSeconds` becomes the configuration's timeout and the row's environment
    /// map becomes the configuration's environment — exactly the row's values, nothing else
    /// (the executor scrubs whatever the caller's process holds).
    func testTheRunClosureReceivesTheRowsTimeoutAndEnvironment() async throws {
        let (provider, runner) = makeProvider(agents: [Self.commitHelper], result: success())
        let invocation = try makeInvocation(toolID: "commit-helper")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)

        XCTAssertEqual(decision.outcome, .succeeded)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls[0].timeout, .seconds(120),
            "the row's timeoutSeconds flows into the configuration's timeout — the run is "
                + "bounded by the row's own ceiling")
        XCTAssertEqual(
            calls[0].environment, ["VOCCA_TEST_KEY": "1"],
            "the row's environment map is the configuration's environment — exactly these "
                + "variables and nothing else")
    }

    /// **The engine's bounded failure keys are carried into the outcome unchanged.**
    ///
    /// The fold is one-to-one: the audit entry records the key the engine produced, never a
    /// translation. Swept over the closed vocabulary so a new key is a reviewed addition,
    /// not a stray literal the fold never mapped.
    func testEngineFailureKeysAreCarriedUnchangedIntoTheOutcome() async throws {
        for key in ShellExecutionResult.boundedFailureKeys {
            let failed = ShellExecutionResult(
                status: .failed(reasonKey: key),
                standardOutput: Data(), standardError: Data(), outputWasTruncated: false)
            let (provider, _) = makeProvider(agents: [Self.commitHelper], result: failed)
            let invocation = try makeInvocation(toolID: "commit-helper")

            let decision = await ActionGate.submit(
                invocation, to: provider, enablement: ActionEnablement([invocation]),
                policy: .none, approval: .granted, mode: .live)

            guard case .failed(let reasonKey)? = decision.outcome else {
                return XCTFail(
                    "the engine's \(key) must become a returned failure: "
                        + "\(String(describing: decision.outcome))")
            }
            XCTAssertEqual(
                reasonKey, key,
                "the fold carries the bounded key unchanged — never translated, never "
                    + "re-spelled, so the audit vocabulary stays closed")
        }
    }

    // MARK: - 4. Unexpected arguments are refused (the gap-1 pin)

    /// **An invocation carrying arguments is refused by describe at the outward-facing radius,
    /// and invoke answers `.failed("agent.unexpectedArguments")` — the sentence and the outcome
    /// never drift.**
    ///
    /// The gap-1 pin: an agent row declares no parameters (there is no `$N` slot and no
    /// `{{utterance}}` seeding in this unit), so *any* supplied arguments are refused — the
    /// shell undeclared-key rule. The radius stays outwardFacing: an agent is never read-only,
    /// and a refusal that de-escalated the claim would be a de-escalation however it was
    /// arrived at.
    func testAnInvocationWithUnexpectedArgumentsIsRefusedByDescribeAndFailsOnInvoke() async throws {
        let (provider, runner) = makeProvider(agents: [Self.commitHelper], result: success())
        let invocation = try makeInvocation(
            toolID: "commit-helper", arguments: ##"{"Sneaky": "x"}"##)

        let summary = await provider.describe(invocation)
        XCTAssertEqual(
            summary.blastRadius, .outwardFacing,
            "the refusal keeps the agent's radius — outwardFacing is the only radius a row "
                + "can claim: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("refused"),
            "the sentence says the call will be refused: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("/usr/bin/true"),
            "even the refusal renders what would have run — the person still sees the argv: "
                + "\(summary.sentence)")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)
        guard case .failed(let reasonKey)? = decision.outcome else {
            return XCTFail(
                "unexpected arguments are a returned failure, never a trap and never a silent "
                    + "run: \(String(describing: decision.outcome))")
        }
        XCTAssertEqual(
            reasonKey, "agent.unexpectedArguments",
            "the bounded, vocabulary-pinned key names the refusal")
        let calls = await runner.calls
        XCTAssertTrue(
            calls.isEmpty,
            "nothing is run on a payload an agent row cannot accept — a run with the "
                + "arguments dropped would be a different action from the one that was confirmed")
    }

    // MARK: - 5. Unknown rows

    /// **An unknown row describes as a refusal value at read-only, never a trap and never an
    /// error.**
    func testAnUnknownRowIsDescribedAsARefusalAtReadOnly() async throws {
        let (provider, _) = makeProvider(agents: [Self.commitHelper], result: success())

        let summary = await provider.describe(try makeInvocation(toolID: "not-an-agent"))

        XCTAssertFalse(
            summary.sentence.isEmpty,
            "a refusal is still a concrete sentence: \(summary.sentence)")
        XCTAssertTrue(summary.sentence.contains("not-an-agent"))
        XCTAssertFalse(
            summary.blastRadius.requiresConfirmation,
            "nothing will happen, so nothing needs confirming")
    }

    /// **An unknown row invokes to `.failed("agent.unknownTool")`, never a trap, and never
    /// runs.**
    func testAnUnknownRowInvokesToAReturnedFailureNeverATrap() async throws {
        let (provider, runner) = makeProvider(agents: [Self.commitHelper], result: success())
        let unknown = try makeInvocation(toolID: "not-an-agent")

        let decision = await ActionGate.submit(
            unknown, to: provider, enablement: ActionEnablement([unknown]),
            policy: .none, approval: .granted, mode: .live)

        guard case .failed(let reasonKey)? = decision.outcome else {
            return XCTFail(
                "an unknown row is a returned failure: \(String(describing: decision.outcome))")
        }
        XCTAssertEqual(
            reasonKey, "agent.unknownTool",
            "the bounded, vocabulary-pinned key names the refusal")
        let calls = await runner.calls
        XCTAssertTrue(
            calls.isEmpty,
            "a row the registry never declared is not a row to run")
    }

    /// **The tool id of an unknown row is sanitised before it reaches the sentence.**
    func testADescribeSanitisesAToolIDInAnUnknownAgentRefusal() async throws {
        let (provider, _) = makeProvider(agents: [Self.commitHelper], result: success())

        let summary = await provider.describe(try makeInvocation(toolID: "evil\nagent"))

        XCTAssertFalse(
            summary.sentence.contains("\n"),
            "an unserved tool id must not forge a new line of the refusal dialog: "
                + "\(summary.sentence)")
        XCTAssertTrue(summary.sentence.contains("evil agent"))
    }

    // MARK: - 6. The gate holds at the outward-facing radius

    /// **THE load-bearing acceptance: an agent invocation without a confirmation is refused by
    /// attempting the call, and the engine is never reached.**
    ///
    /// This is the C13 spine applied to the coding-agent arm. The submission below is the live
    /// path in every respect — the tool enabled, live mode, no approval, a row whose argv would
    /// really run — and the refusal is asserted on the engine's call log: the call was
    /// *attempted* through the gate and stopped there, rather than the gate being skipped and
    /// the agent running without a yes.
    func testADestructiveAgentInvocationWithoutApprovalIsRefusedByAttemptingTheCall() async throws {
        let (provider, runner) = makeProvider(agents: [Self.planted], result: success())
        let invocation = try makeInvocation(toolID: "planted")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .withheld, mode: .live)

        guard case .confirmationRequired = decision else {
            return XCTFail(
                """
                an outward-facing agent invocation ran without a human's yes: \(decision).
                The confirmation is the only mitigation for a row that launches a program on \
                the user's machine — a submission that reaches invoke without one has defeated \
                the spine.
                """)
        }
        XCTAssertNil(decision.outcome, "nothing ran, so there is no outcome to report")
        let calls = await runner.calls
        XCTAssertTrue(
            calls.isEmpty,
            "the engine was never asked — the refusal happens by attempting the call, never "
                + "by observing that no prompt appeared")
    }

    /// **A dry-run describes and stops: the engine is reached zero times.**
    func testADryRunDescribesAndNeverInvokes() async throws {
        let (provider, runner) = makeProvider(agents: [Self.commitHelper], result: success())
        let invocation = try makeInvocation(toolID: "commit-helper")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .dryRun)

        guard case .previewed = decision else {
            return XCTFail("a rehearsal does not act: \(decision)")
        }
        let calls = await runner.calls
        XCTAssertTrue(
            calls.isEmpty,
            "a dry-run must not reach the engine — zero side effects is a call count")
    }
}

// MARK: - The call-logged engine

/// The provider's engine seam, recorded: every configuration it is asked to run is logged,
/// and the answer is the scripted one.
///
/// An actor because the provider's run closure is `async` and the log is read from the
/// assertions afterwards — the ``RecordingActionProvider`` shape, for the engine instead of the
/// seam. No test here constructs a real ``ShellExecutor``; the real engine's hostile battery
/// lives in `ShellExecutorTests` and its agent-shaped pin in `CodingAgentExecutionTests`.
private actor RecordingAgentRunner {

    private let result: ShellExecutionResult
    private var log: [ShellExecutor.Configuration] = []

    init(result: ShellExecutionResult) {
        self.result = result
    }

    func run(_ configuration: ShellExecutor.Configuration) -> ShellExecutionResult {
        log.append(configuration)
        return result
    }

    /// Every configuration this runner was asked to run, in order.
    var calls: [ShellExecutor.Configuration] { log }
}