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
import XCTest
@testable import VoccaActions

/// The `task-carrier` aspect of `spoken-task-seeding` (PRD R1/R2/S1) — the **additive
/// carrier** that carries the spoken task to the provider: `ActionInvocation.taskText:
/// String?` (default nil), the provider's **one-render substitution** (every literal
/// `KnownAgentPresets.taskPlaceholder` occurrence in the row's argv replaced with the task
/// text — describe and invoke resolve it from the same helper, so the argv that runs is the
/// argv the sentence showed), and the three loud refusal paths — task text with no
/// placeholder in the argv (the task has nowhere to go), a placeholder with no task text
/// (reachable only by a hand-built invocation — the surface refuses earlier), and task text
/// over the 4096-UTF-8-byte bound (refused, never truncated — the arguments precedent).
///
/// ## The exact-shape check passed (STEP 1 of the plan, re-run for the second field)
///
/// Grep `ActionInvocation(` across Tests/: **40 construction sites** outside
/// `InvocationCarrierTests` itself, every one a failable-init named-parameter call — the
/// `resolvedDirectory` precedent's count, re-verified for this aspect. No test enumerates
/// the invocation's member set: the harness's three `Mirror` uses (`AccessibilityRungTests`,
/// `CleanupTabReducerTests`, `NetworkInterposer`) are over other types, there is no
/// reflection, no `allCases`, no memberwise round-trip; `ActionSeamTests` pins the
/// vocabulary **additively** — nil-default fields and value equality between same-shape
/// constructions that stay meaningful under a default-nil field. **No exact-shape pin
/// exists** — the second additive-with-default field is safe, exactly as the
/// `resolvedDirectory` precedent was.
///
/// ## The contract, acceptance by acceptance
///
/// 1. An invocation **without** `taskText` behaves byte-identically to today: the row's
///    argv renders and runs unchanged, and the `resolvedDirectory` machinery is untouched —
///    the full round trip through the counting engine.
/// 2. With `taskText` and a **single placeholder**: the sentence shows the substituted argv
///    verbatim, and invoke's configuration runs the substituted argv — one render shared by
///    describe and invoke, witnessed by the sentence binding.
/// 3. **Two placeholders → both substituted** — the deterministic rule, pinned by an
///    adjacent pair (`<task><task>`) that a split dropping empty subsequences would
///    collapse into one substitution.
/// 4. `taskText` **without** a placeholder → the loud refusal (`agent.taskHasNowhereToGo`),
///    invoke never reached (engine count 0).
/// 5. A placeholder **without** `taskText` → the loud refusal (`agent.taskTextMissing`),
///    invoke never reached (engine count 0).
/// 6. Over-bound `taskText` → refused, never truncated (`agent.taskTextTooLarge`), engine
///    count 0 — and exactly at the bound the substitution still runs.
/// 7. The **gap-1 pin** holds: `arguments` on an agent invocation is still refused beside
///    `taskText` — the task is a separate field, never a payload that buys arguments past
///    the refusal.
/// 8. The exact-shape check passes (recorded above).
final class TaskCarrierTests: XCTestCase {

    // MARK: - Fixtures

    /// The row with the `<task>` placeholder in its argv — the substitution's subject. The
    /// sentence and the engine's argv are asserted byte-for-byte against it.
    private static let taskAgent = CodingAgentDefinition(
        id: "claude",
        executablePath: "/opt/homebrew/bin/claude",
        arguments: ["-p", "<task>"],
        projectDirectory: "/Users/aliz/dev/at/vocca",
        timeoutSeconds: 30,
        environment: nil,
        clause: nil)!

    /// A row whose argv has **no** placeholder — the task-has-nowhere-to-go subject, and the
    /// no-`taskText` byte-identity fixture.
    private static let plainAgent = CodingAgentDefinition(
        id: "commit-helper",
        executablePath: "/usr/bin/true",
        arguments: ["--commit"],
        projectDirectory: "/Users/aliz/dev/at/vocca",
        timeoutSeconds: 120,
        environment: ["VOCCA_TEST_KEY": "1"],
        clause: "Runs the commit helper.")!

    /// Two placeholders, one adjacent pair in a single argv element — the deterministic
    /// rule's pin (a split/join that dropped empty subsequences would collapse
    /// `<task><task>` into one substitution) plus a second element proving cross-element
    /// substitution.
    private static let twoPlaceholderAgent = CodingAgentDefinition(
        id: "two-placeholders",
        executablePath: "/opt/homebrew/bin/claude",
        arguments: ["--prompt", "<task><task>", "--label", "<task>"],
        projectDirectory: "/Users/aliz/dev/at/vocca",
        timeoutSeconds: 30,
        environment: nil,
        clause: nil)!

    private func makeInvocation(
        toolID: String, arguments: String? = nil, resolvedDirectory: String? = nil,
        taskText: String? = nil, file: StaticString = #filePath, line: UInt = #line
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(
                providerID: CodingAgentProvider.providerID, toolID: toolID,
                arguments: arguments, resolvedDirectory: resolvedDirectory, taskText: taskText),
            "the invocation under test must construct", file: file, line: line)
    }

    /// A provider over the given agent rows whose engine records every call and answers
    /// `result`. The runner is returned so a test can assert what was — and was not — asked.
    private func makeProvider(
        agents: [CodingAgentDefinition], result: ShellExecutionResult
    ) -> (CodingAgentProvider, RecordingTaskRunner) {
        let runner = RecordingTaskRunner(result: result)
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

    // MARK: - Acceptance 1: without taskText, byte-identical to today

    /// **An invocation without `taskText` is byte-identical to today: the row's argv
    /// renders and runs unchanged, and the `resolvedDirectory` machinery is untouched.**
    ///
    /// The sentence is asserted **byte-for-byte** — the exact pre-carrier render with the
    /// carried directory's `in <dir>` clause — and the full round trip goes through the
    /// counting engine: the gate binds to the described sentence, invoke runs, and the
    /// engine received the row's argv and the resolved directory unchanged.
    func testWithoutTaskTextTheSentenceAndRunAreByteIdenticalToToday() async throws {
        let (provider, runner) = makeProvider(agents: [Self.plainAgent], result: success())
        let invocation = try makeInvocation(
            toolID: "commit-helper", resolvedDirectory: "/tmp/resolved")

        let summary = await provider.describe(invocation)
        XCTAssertEqual(
            summary.sentence,
            "Run the coding agent 'commit-helper': /usr/bin/true --commit in /tmp/resolved. "
                + "Runs the commit helper.",
            "byte-identical to the pre-carrier render — the additive taskText field must not "
                + "move the sentence for a call that does not use it")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, approvedSentence: summary.sentence, mode: .live)
        XCTAssertEqual(decision.outcome, .succeeded)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls[0].arguments, ["--commit"],
            "the engine receives the row's argv untouched — no substitution without taskText")
        XCTAssertEqual(
            calls[0].currentDirectoryURL, URL(fileURLWithPath: "/tmp/resolved"),
            "the resolvedDirectory machinery is untouched by the task carrier — the child "
                + "starts where the sentence says")
    }

    // MARK: - Acceptance 2: taskText with a single placeholder, verbatim in both halves

    /// **With `taskText` and a single placeholder, the sentence shows the substituted argv
    /// verbatim and invoke runs it — describe and invoke share the one substitution.**
    ///
    /// The sentence is asserted **byte-for-byte** (the placeholder gone, the spoken words in
    /// place), and the invoke leg goes through the gate **with the described sentence
    /// bound** — a drift between what the card showed and what invoke would run would
    /// decline with ``ActionDeclineReason/approvedSentenceMismatch`` instead of running. The
    /// counting engine then witnesses the substituted argv.
    func testWithTaskTextAndASinglePlaceholderTheSentenceShowsTheSubstitutedArgvVerbatimAndInvokeRunsIt()
        async throws
    {
        let (provider, runner) = makeProvider(agents: [Self.taskAgent], result: success())
        let invocation = try makeInvocation(toolID: "claude", taskText: "add tests for the ledger")

        let summary = await provider.describe(invocation)
        XCTAssertEqual(
            summary.sentence,
            "Run the coding agent 'claude': /opt/homebrew/bin/claude -p add tests for the "
                + "ledger in /Users/aliz/dev/at/vocca.",
            "the substituted argv renders VERBATIM in the sentence — the card confirms the "
                + "argv that will actually run, spoken words in place")
        XCTAssertFalse(
            summary.sentence.contains("<task>"),
            "the placeholder never survives into the sentence a person is asked to approve: "
                + "\(summary.sentence)")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, approvedSentence: summary.sentence, mode: .live)
        XCTAssertEqual(
            decision.outcome, .succeeded,
            "the approval bound to the substituted sentence must survive the gate's own "
                + "render — describe and invoke resolve the substitution from the same helper, "
                + "so the sentence cannot drift")
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls[0].arguments, ["-p", "add tests for the ledger"],
            "the engine receives the substituted argv — the argv that runs is the argv the "
                + "sentence showed")
    }

    // MARK: - Acceptance 3: two placeholders, both substituted

    /// **Two placeholders → both substituted — the deterministic rule.**
    ///
    /// The adjacent pair `<task><task>` is the pin: a substitution built on split/join that
    /// dropped empty subsequences would collapse it into one replacement, silently changing
    /// the argv. The second element proves the rule is not one-per-element but
    /// every-occurrence.
    func testTwoPlaceholdersAreBothSubstituted() async throws {
        let (provider, runner) = makeProvider(agents: [Self.twoPlaceholderAgent], result: success())
        let invocation = try makeInvocation(toolID: "two-placeholders", taskText: "fix the ledger")

        let summary = await provider.describe(invocation)
        XCTAssertEqual(
            summary.sentence,
            "Run the coding agent 'two-placeholders': /opt/homebrew/bin/claude --prompt fix "
                + "the ledgerfix the ledger --label fix the ledger in "
                + "/Users/aliz/dev/at/vocca.",
            "every occurrence is replaced — the adjacent pair renders as taskText+taskText, "
                + "never one collapsed substitution")
        XCTAssertFalse(summary.sentence.contains("<task>"))

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, approvedSentence: summary.sentence, mode: .live)
        XCTAssertEqual(decision.outcome, .succeeded)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls[0].arguments,
            ["--prompt", "fix the ledgerfix the ledger", "--label", "fix the ledger"],
            "both placeholders are substituted — a helper that dropped one occurrence would "
                + "run a different argv from the one confirmed")
    }

    // MARK: - Acceptance 4: taskText without a placeholder, the loud refusal

    /// **`taskText` without a placeholder is the loud refusal — the task has nowhere to
    /// go, invoke is never reached.**
    ///
    /// The refusal renders at the outward-facing radius (an agent is never read-only, and a
    /// refusal that de-escalated the claim would be a de-escalation however it was arrived
    /// at), still shows the row's argv, and is a returned
    /// ``ActionOutcome/failed(reasonKey:)`` with the bounded `agent.taskHasNowhereToGo` key
    /// on the invoke side — with the engine's call log empty.
    func testTaskTextWithoutAPlaceholderIsRefusedAndInvokeNeverRuns() async throws {
        let (provider, runner) = makeProvider(agents: [Self.plainAgent], result: success())
        let invocation = try makeInvocation(toolID: "commit-helper", taskText: "do the thing")

        let summary = await provider.describe(invocation)
        XCTAssertEqual(
            summary.blastRadius, .outwardFacing,
            "the refusal keeps the agent's radius — outwardFacing is the only radius a row "
                + "can claim: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("refused"),
            "the sentence says the call will be refused: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("/usr/bin/true --commit"),
            "even the refusal renders what would have run — the person still sees the argv: "
                + "\(summary.sentence)")
        XCTAssertFalse(
            summary.sentence.contains("do the thing"),
            "the refused task text is not rendered into the dialog — nothing runs, so "
                + "nothing substitutes, and the dialog stays bounded")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)
        guard case .failed(let reasonKey)? = decision.outcome else {
            return XCTFail(
                "a task with nowhere to go is a returned failure, never a trap and never a "
                    + "silent run with the task dropped: \(String(describing: decision.outcome))")
        }
        XCTAssertEqual(
            reasonKey, "agent.taskHasNowhereToGo",
            "the bounded, vocabulary-pinned key names the refusal")
        let calls = await runner.calls
        XCTAssertTrue(
            calls.isEmpty,
            "invoke is never reached — a run with the task silently dropped would be a "
                + "different action from the one refused")
    }

    // MARK: - Acceptance 5: placeholder without taskText, the loud refusal

    /// **A placeholder without `taskText` is the loud refusal — reachable only by a
    /// hand-built invocation (the surface refuses earlier), invoke never reached.**
    ///
    /// The refusal still renders the row's argv verbatim — the unsubstituted placeholder is
    /// visible, which is the honest account of a call that cannot run.
    func testAPlaceholderWithoutTaskTextIsRefusedAndInvokeNeverRuns() async throws {
        let (provider, runner) = makeProvider(agents: [Self.taskAgent], result: success())
        let invocation = try makeInvocation(toolID: "claude")

        let summary = await provider.describe(invocation)
        XCTAssertEqual(
            summary.blastRadius, .outwardFacing,
            "the refusal keeps the agent's radius: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("refused"),
            "the sentence says the call will be refused: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("/opt/homebrew/bin/claude -p <task>"),
            "the refusal renders the row's argv verbatim — the unsubstituted placeholder is "
                + "visible, which is the honest account of a call that cannot run: "
                + "\(summary.sentence)")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)
        guard case .failed(let reasonKey)? = decision.outcome else {
            return XCTFail(
                "a placeholder with no task text is a returned failure: "
                    + "\(String(describing: decision.outcome))")
        }
        XCTAssertEqual(
            reasonKey, "agent.taskTextMissing",
            "the bounded, vocabulary-pinned key names the refusal")
        let calls = await runner.calls
        XCTAssertTrue(
            calls.isEmpty,
            "invoke is never reached — substituting nothing would run a placeholder the "
                + "sentence never showed")
    }

    // MARK: - Acceptance 6: over-bound taskText, refused never truncated

    /// **Over-bound `taskText` is refused, never truncated — and exactly at the bound the
    /// substitution still runs.**
    ///
    /// The refusal is the arguments precedent's: a truncated *task* is a different task,
    /// silently, so the oversized text is refused loudly with the bounded
    /// `agent.taskTextTooLarge` key and never rendered into the dialog — and the engine is
    /// never asked. The boundary is asserted in both directions: one byte over the bound
    /// refuses, exactly at the bound substitutes and runs the full text.
    func testOverBoundTaskTextIsRefusedNeverTruncated() async throws {
        let (provider, runner) = makeProvider(agents: [Self.taskAgent], result: success())
        let over = String(
            repeating: "a", count: ActionInvocation.maximumArgumentsUTF8Bytes + 1)
        let invocation = try makeInvocation(toolID: "claude", taskText: over)

        let summary = await provider.describe(invocation)
        XCTAssertEqual(
            summary.blastRadius, .outwardFacing,
            "the refusal keeps the agent's radius: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("refused"),
            "an oversized task is refused loudly, never truncated into a silent different "
                + "action: \(summary.sentence)")
        XCTAssertFalse(
            summary.sentence.contains(over),
            "the oversized text is not rendered into the dialog — the refusal stays bounded")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)
        guard case .failed(let reasonKey)? = decision.outcome else {
            return XCTFail(
                "the oversized task is a returned failure, never a truncated run: "
                    + "\(String(describing: decision.outcome))")
        }
        XCTAssertEqual(
            reasonKey, "agent.taskTextTooLarge",
            "the bounded, vocabulary-pinned key names the refusal")
        let calls = await runner.calls
        XCTAssertTrue(
            calls.isEmpty,
            "nothing runs with a truncated task — the refusal happens before the engine is "
                + "asked at all")

        let atBound = String(
            repeating: "b", count: ActionInvocation.maximumArgumentsUTF8Bytes)
        let (boundProvider, boundRunner) = makeProvider(agents: [Self.taskAgent], result: success())
        let boundInvocation = try makeInvocation(toolID: "claude", taskText: atBound)
        let boundSummary = await boundProvider.describe(boundInvocation)
        XCTAssertTrue(
            boundSummary.sentence.contains(atBound),
            "exactly at the bound the substitution still renders the full text")
        let boundDecision = await ActionGate.submit(
            boundInvocation, to: boundProvider,
            enablement: ActionEnablement([boundInvocation]),
            policy: .none, approval: .granted, approvedSentence: boundSummary.sentence,
            mode: .live)
        XCTAssertEqual(
            boundDecision.outcome, .succeeded,
            "the refusal begins one byte past the bound — at the bound, the task runs whole")
        let boundCalls = await boundRunner.calls
        XCTAssertEqual(boundCalls.count, 1)
        XCTAssertEqual(
            boundCalls[0].arguments, ["-p", atBound],
            "at the bound the engine receives the full, untruncated task")
    }

    // MARK: - Acceptance 7: the gap-1 pin holds

    /// **The gap-1 pin holds: an invocation carrying `arguments` is still refused beside
    /// `taskText` — the task is a separate field, never a payload that buys arguments past
    /// the refusal.**
    ///
    /// The arguments refusal fires before any substitution is considered — the task text is
    /// not rendered and nothing is run — and invoke answers the bounded
    /// `agent.unexpectedArguments` key with the engine never reached.
    func testTheGapOnePinHoldsArgumentsAreStillRefusedBesideTaskText() async throws {
        let (provider, runner) = makeProvider(agents: [Self.taskAgent], result: success())
        let invocation = try makeInvocation(
            toolID: "claude", arguments: ##"{"Sneaky": "x"}"##, taskText: "fix the ledger")

        let summary = await provider.describe(invocation)
        XCTAssertEqual(
            summary.blastRadius, .outwardFacing,
            "the refusal keeps the agent's radius: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("refused"),
            "the sentence says the call will be refused: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("/opt/homebrew/bin/claude"),
            "even the refusal renders what would have run: \(summary.sentence)")
        XCTAssertFalse(
            summary.sentence.contains("fix the ledger"),
            "the arguments refusal fires before any substitution — task text must not buy a "
                + "payload past the pin")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)
        guard case .failed(let reasonKey)? = decision.outcome else {
            return XCTFail(
                "unexpected arguments are a returned failure beside taskText too: "
                    + "\(String(describing: decision.outcome))")
        }
        XCTAssertEqual(
            reasonKey, "agent.unexpectedArguments",
            "the gap-1 pin is untouched — arguments are still refused, taskText or not")
        let calls = await runner.calls
        XCTAssertTrue(
            calls.isEmpty,
            "nothing is run on a payload an agent row cannot accept — the task field must "
                + "not become a back door for arguments")
    }

    // MARK: - Acceptance 8 companion: the vocabulary stays additive

    /// **The field is additive with a nil default and equality includes it — absence has
    /// one spelling, exactly as the `arguments` and `resolvedDirectory` precedents.**
    ///
    /// The equality leg is load-bearing: enablement membership and the gate's
    /// per-invocation reasoning are by whole `ActionInvocation`, so an equality that ignored
    /// the task text could let one confirmed task authorise a run of another.
    func testTaskTextIsAdditiveWithNilDefaultAndEqualityIncludesIt() throws {
        let plain = try makeInvocation(toolID: "claude")
        XCTAssertNil(
            plain.taskText,
            "absent is the default — every construction site written before this field "
                + "existed keeps compiling and keeps meaning exactly what it meant")

        let seeded = try makeInvocation(toolID: "claude", taskText: "one")
        let other = try makeInvocation(toolID: "claude", taskText: "two")
        XCTAssertNotEqual(
            seeded, other,
            "same tool, different task text, different invocation — an equality blind to the "
                + "task text would let one confirmed task authorise a run of another")
        XCTAssertNotEqual(
            seeded, plain,
            "carrying task text is not the same invocation as carrying none")
        XCTAssertEqual(
            plain, try makeInvocation(toolID: "claude"),
            "equality is by value throughout — two invocations that both carry none are equal")
    }

    /// **Empty task text is refused at construction, so absence has one spelling** — the
    /// `arguments` rule exactly: `nil` means "no task"; `""` would be a second way to say
    /// the same thing, and a substitution with an empty task would silently delete the
    /// placeholder from the argv.
    func testEmptyTaskTextIsRefusedSoAbsenceHasOneSpelling() {
        XCTAssertNil(
            ActionInvocation(
                providerID: CodingAgentProvider.providerID, toolID: "claude", taskText: ""),
            "empty task text is not 'no task' spelled a second way — it is refused, so `nil` "
                + "is the only way to say an invocation carries none")
    }
}

// MARK: - The call-logged engine

/// The provider's engine seam, recorded — the `RecordingCarrierRunner` shape of
/// `InvocationCarrierTests`, local to this suite.
private actor RecordingTaskRunner {

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