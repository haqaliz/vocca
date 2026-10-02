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
import VoccaUI
import XCTest
@testable import VoccaActions

/// The `invocation-carrier` aspect of `active-project-detection` (PRD R2) — the **additive
/// carrier** that makes one arm-time resolution survive the whole confirmation path:
/// `ActionInvocation.resolvedDirectory: String?` (default nil), the
/// `WidgetConfirmationSignal` counterpart, the agent provider's consumption
/// (`invocation.resolvedDirectory ?? agent.projectDirectory`), and the nil-tolerant
/// sentence (no directory → no `in` clause).
///
/// ## The exact-shape check passed (the critique gap, STEP 1 of the plan)
///
/// Grep `ActionInvocation(` across Tests/: **40 construction sites**, every one a
/// failable-init named-parameter call. No test enumerates the invocation's member set — no
/// `Mirror` over it, no reflection, no allCases, no memberwise round-trip; the vocabulary
/// suite in `ActionSeamTests` pins the blast-radius closed set, the two identifiers, and the
/// `arguments` field **additively** (`testAnInvocationCarriesOptionalArgumentTextAndCarriesNoneByDefault`),
/// and its equality pins are value comparisons between same-shape constructions that stay
/// meaningful under an additive default-nil field (both sides default the same way). **No
/// exact-shape pin exists** — the additive-with-default is safe, exactly as the `arguments`
/// precedent was.
///
/// ## The contract, acceptance by acceptance
///
/// 1. An invocation **without** `resolvedDirectory` behaves byte-identically to today: the
///    sentence renders the row's directory and invoke runs in it.
/// 2. An invocation **with** it renders it verbatim in the sentence and invoke runs in it —
///    describe and invoke share **one resolution** (`invocation.resolvedDirectory ??
///    agent.projectDirectory`), witnessed by the recording runner receiving the
///    configuration's `currentDirectoryURL`.
/// 3. A nil resolution renders the **clause-less** sentence (S1 — the child runs in Vocca's
///    cwd, the pre-fix behavior, visible in the sentence, never hidden), and the
///    configuration a nil resolution builds on carries **no** `currentDirectoryURL` (the
///    executor field's own default). The nil leg is the shipped shape's now — a row without
///    a `projectDirectory` (the editor's empty field, absent or blank in the file) resolves
///    to nil on the real path — and the render is exercised directly on the shared sentence.
/// 4. The **gap-1 pin** holds: `arguments` on an agent invocation is still refused — the
///    resolved directory is a separate field, never a payload that buys arguments past the
///    refusal.
/// 5. The signal carries the field; the confirm path can rebuild the identical invocation.
/// 6. The vocabulary stays additive: nil default, equality includes the field, and empty is
///    refused so absence has one spelling.
final class InvocationCarrierTests: XCTestCase {

    // MARK: - Fixtures

    /// The PRD's data-model agent — a fixed argv, a raised per-row timeout, an explicit
    /// environment and a clause; the byte-identity fixture.
    private static let commitHelper = CodingAgentDefinition(
        id: "commit-helper",
        executablePath: "/usr/bin/true",
        arguments: [],
        projectDirectory: "/Users/aliz/dev/at/vocca",
        timeoutSeconds: 120,
        environment: ["VOCCA_TEST_KEY": "1"],
        clause: "Runs the commit helper.")!

    /// The planted argv — a config whose fixed argv is destructive and whose clause pretends
    /// otherwise. The sentence must show the argv verbatim and the clause must not hide it.
    private static let planted = CodingAgentDefinition(
        id: "planted",
        executablePath: "/usr/bin/rm",
        arguments: ["-rf", "/tmp/evil"],
        projectDirectory: "/tmp",
        clause: "safely tidies temporary files")!

    private func makeInvocation(
        toolID: String, arguments: String? = nil, resolvedDirectory: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(
                providerID: CodingAgentProvider.providerID, toolID: toolID,
                arguments: arguments, resolvedDirectory: resolvedDirectory),
            "the invocation under test must construct", file: file, line: line)
    }

    /// A provider over the given agent rows whose engine records every call and answers
    /// `result`. The runner is returned so a test can assert what was — and was not — asked.
    private func makeProvider(
        agents: [CodingAgentDefinition], result: ShellExecutionResult
    ) -> (CodingAgentProvider, RecordingCarrierRunner) {
        let runner = RecordingCarrierRunner(result: result)
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

    /// The reducer fold, the `WidgetConfirmationStateTests` shape.
    private func fold(
        _ steps: [(action: WidgetAction, now: Duration)],
        from state: WidgetReducerState = WidgetReducerState()
    ) -> WidgetReducerState {
        steps.reduce(state) { WidgetStateReducer.reduce($0, action: $1.action, now: $1.now) }
    }

    // MARK: - Acceptance 1: without resolvedDirectory, byte-identical to today

    /// **An invocation without `resolvedDirectory` is byte-identical to today: the row's
    /// directory renders in the sentence and invoke runs in it.**
    ///
    /// The sentence is asserted **byte-for-byte** — the exact pre-carrier render, `in
    /// <row-directory>` included — and the engine configuration carries the row's directory
    /// as its `currentDirectoryURL`, so the child starts where the sentence says it will.
    func testWithoutResolvedDirectoryTheSentenceAndRunAreByteIdenticalToToday() async throws {
        let (provider, runner) = makeProvider(agents: [Self.commitHelper], result: success())
        let invocation = try makeInvocation(toolID: "commit-helper")

        let summary = await provider.describe(invocation)
        XCTAssertEqual(
            summary.sentence,
            "Run the coding agent 'commit-helper': /usr/bin/true in /Users/aliz/dev/at/vocca. "
                + "Runs the commit helper.",
            "byte-identical to the pre-carrier render — the additive field must not move the "
                + "sentence for a call that does not use it")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)
        XCTAssertEqual(decision.outcome, .succeeded)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls[0].currentDirectoryURL,
            URL(fileURLWithPath: try XCTUnwrap(Self.commitHelper.projectDirectory)),
            "the row's projectDirectory flows into the configuration's currentDirectoryURL — "
                + "byte-identical to today's run")
    }

    // MARK: - Acceptance 2: with resolvedDirectory, verbatim in both halves

    /// **An invocation WITH `resolvedDirectory` renders it verbatim and invoke runs in it —
    /// describe and invoke share one resolution.**
    ///
    /// The resolved value wins over the row's directory in **both** halves: the sentence
    /// shows `in /tmp/resolved` (never the row's directory), and the engine receives
    /// `currentDirectoryURL == /tmp/resolved` — one resolution source feeding the sentence
    /// and the run, the argv-that-runs doctrine extended to the directory.
    func testWithResolvedDirectoryTheSentenceShowsItVerbatimAndInvokeRunsInIt() async throws {
        let (provider, runner) = makeProvider(agents: [Self.commitHelper], result: success())
        let invocation = try makeInvocation(
            toolID: "commit-helper", resolvedDirectory: "/tmp/resolved")

        let summary = await provider.describe(invocation)
        XCTAssertEqual(
            summary.sentence,
            "Run the coding agent 'commit-helper': /usr/bin/true in /tmp/resolved. "
                + "Runs the commit helper.",
            "the resolved directory appears VERBATIM in the sentence — the card confirms the "
                + "directory the child will actually start in")
        XCTAssertFalse(
            summary.sentence.contains("/Users/aliz/dev/at/vocca"),
            "the invocation's resolved directory wins over the row's — a sentence that fell "
                + "back to the row would show a directory nobody confirmed: \(summary.sentence)")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)
        XCTAssertEqual(decision.outcome, .succeeded)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls[0].currentDirectoryURL, URL(fileURLWithPath: "/tmp/resolved"),
            "invoke runs in the resolved directory — the configuration's currentDirectoryURL "
                + "is the same value the sentence showed, so what ran is what was confirmed")
        XCTAssertNotEqual(
            calls[0].currentDirectoryURL,
            URL(fileURLWithPath: try XCTUnwrap(Self.commitHelper.projectDirectory)),
            "invoke does not re-resolve from the row — one resolution, shared by both halves")
    }

    // MARK: - Acceptance 3: both nil → the clause-less sentence, no current directory

    /// **A nil resolution renders the clause-less sentence (S1) — the child runs in Vocca's
    /// cwd, and the sentence says so by saying nothing about a directory.**
    ///
    /// Driven directly on the shared render — the nil leg is the shipped shape's now: a row
    /// without a `projectDirectory` (the editor's empty field, absent or blank in the file)
    /// resolves to nil on the real path, so this render is the one describe and invoke share
    /// for the nil-directory row.
    func testABothNilResolutionRendersTheClauseLessSentence() {
        XCTAssertEqual(
            CodingAgentSentences.sentence(
                id: "commit-helper", executablePath: "/usr/bin/true", arguments: [],
                projectDirectory: nil, clause: nil),
            "Run the coding agent 'commit-helper': /usr/bin/true.",
            "no directory → no `in` clause — the bare sentence is the honest render of a run "
                + "that will happen in Vocca's own cwd")
        XCTAssertFalse(
            CodingAgentSentences.sentence(
                id: "commit-helper", executablePath: "/usr/bin/true", arguments: [],
                projectDirectory: nil, clause: nil).contains(" in "),
            "the clause-less shape never renders a dangling `in`")

        XCTAssertEqual(
            CodingAgentSentences.sentence(
                id: "commit-helper", executablePath: "/usr/bin/true", arguments: [],
                projectDirectory: nil, clause: "Runs the commit helper."),
            "Run the coding agent 'commit-helper': /usr/bin/true. Runs the commit helper.",
            "the clause appends after the sentence, exactly as it does with a directory")

        XCTAssertEqual(
            CodingAgentSentences.sentence(
                id: "planted", executablePath: "/usr/bin/rm", arguments: ["-rf", "/tmp/evil"],
                projectDirectory: nil, clause: nil),
            "Run the coding agent 'planted': /usr/bin/rm -rf /tmp/evil.",
            "an argv still renders verbatim with no dangling space before the full stop")
    }

    /// **The configuration a nil resolution builds on carries NO `currentDirectoryURL` — the
    /// executor field's own default, the pre-fix behavior.**
    ///
    /// The provider's nil leg (written for the resolution's contract) omits the field
    /// entirely; this pins what that omission means: `currentDirectoryURL` defaults to nil,
    /// which is the executor's run-in-Vocca's-cwd fallback. The child is not told a directory
    /// it was never shown a sentence for.
    func testANilResolutionLeavesTheConfigurationWithoutACurrentDirectoryURL() {
        let configuration = ShellExecutor.Configuration(executablePath: "/usr/bin/true")
        XCTAssertNil(
            configuration.currentDirectoryURL,
            "the pre-fix fallback: no currentDirectoryURL means Foundation's default — the "
                + "child runs in Vocca's own cwd, which is exactly what the clause-less "
                + "sentence now says, honestly")
    }

    // MARK: - Acceptance 4: the gap-1 pin holds

    /// **The gap-1 pin holds: an invocation carrying `arguments` is still refused — a
    /// resolved directory is a separate field, never a payload that buys arguments past the
    /// refusal.**
    ///
    /// The refusal renders at the outward-facing radius and invoke answers
    /// `.failed("agent.unexpectedArguments")` with the engine never reached — unchanged with
    /// `resolvedDirectory` in the picture.
    func testAnInvocationWithArgumentsIsStillRefusedWhenItAlsoCarriesAResolvedDirectory()
        async throws
    {
        let (provider, runner) = makeProvider(agents: [Self.commitHelper], result: success())
        let invocation = try makeInvocation(
            toolID: "commit-helper", arguments: ##"{"Sneaky": "x"}"##,
            resolvedDirectory: "/tmp/resolved")

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
            "nothing is run on a payload an agent row cannot accept — the resolved directory "
                + "must not become a back door for arguments")
    }

    // MARK: - Acceptance 5: the signal carries the field

    /// **The signal carries `resolvedDirectory` through a reducer round trip, and the
    /// confirm path can rebuild the identical invocation from it.**
    ///
    /// The wiring's shape: describe the invocation, fold the card with the rendered sentence
    /// and the invocation's own fields, read the card back off the reducer state, and
    /// rebuild the invocation the confirm path would submit — the rebuilt invocation equals
    /// the one that was described, so one resolution survives the whole confirmation path.
    func testTheSignalCarriesTheResolvedDirectoryThroughAReducerRoundTrip() async throws {
        let (provider, _) = makeProvider(agents: [Self.commitHelper], result: success())
        let invocation = try makeInvocation(
            toolID: "commit-helper", resolvedDirectory: "/tmp/resolved")
        let summary = await provider.describe(invocation)

        let signal = WidgetConfirmationSignal(
            sentence: summary.sentence, providerID: invocation.providerID,
            toolID: invocation.toolID, generation: 1, resolvedDirectory: invocation.resolvedDirectory)
        let after = fold([(.confirmation(signal), .zero)])

        XCTAssertEqual(
            after.confirmation?.signal, signal,
            "the card carries the signal whole — sentence, identity and resolved directory")
        XCTAssertEqual(
            after.confirmation?.signal.resolvedDirectory, "/tmp/resolved",
            "the resolved directory survives the reducer fold")

        let rebuilt = try XCTUnwrap(
            ActionInvocation(
                providerID: after.confirmation!.signal.providerID,
                toolID: after.confirmation!.signal.toolID,
                resolvedDirectory: after.confirmation!.signal.resolvedDirectory))
        XCTAssertEqual(
            rebuilt, invocation,
            "the confirm path rebuilds the identical invocation from the card — the directory "
                + "shown on the card is the directory the child runs in, under the binding")
    }

    /// **The signal's field is additive: a signal constructed without it carries `nil` —
    /// every pre-carrier construction site compiles and means exactly what it meant.**
    func testTheSignalCarriesNoResolvedDirectoryByDefault() {
        let signal = WidgetConfirmationSignal(
            sentence: "Permanently delete 12 entries.", providerID: "audit",
            toolID: "clear", generation: 1)
        XCTAssertNil(
            signal.resolvedDirectory,
            "absent is the default — a signal built before this field existed has no resolved "
                + "directory to carry")
    }

    // MARK: - Acceptance 6: the vocabulary stays additive

    /// **The field is additive with a nil default, equality includes it, and empty is
    /// refused — absence has one spelling, exactly as the `arguments` precedent.**
    ///
    /// The equality leg is load-bearing: enablement membership and the gate's per-invocation
    /// reasoning are by whole `ActionInvocation`, so an equality that ignored the resolved
    /// directory could let one confirmed directory authorise a run in another.
    func testResolvedDirectoryIsAdditiveWithNilDefaultAndEqualityIncludesIt() throws {
        let plain = try makeInvocation(toolID: "commit-helper")
        XCTAssertNil(
            plain.resolvedDirectory,
            "absent is the default — every construction site written before this field existed "
                + "keeps compiling and keeps meaning exactly what it meant")

        let resolved = try makeInvocation(toolID: "commit-helper", resolvedDirectory: "/tmp/a")
        let other = try makeInvocation(toolID: "commit-helper", resolvedDirectory: "/tmp/b")
        XCTAssertNotEqual(
            resolved, other,
            "same tool, different resolved directory, different invocation — an equality blind "
                + "to the directory would let a run in one directory authorise a run in another")
        XCTAssertNotEqual(
            resolved, plain,
            "carrying a resolved directory is not the same invocation as carrying none")
        XCTAssertEqual(
            plain, try makeInvocation(toolID: "commit-helper"),
            "equality is by value throughout — two invocations that both carry none are equal")
    }

    /// **Empty resolved-directory text is refused at construction, so absence has one
    /// spelling** — the `arguments` rule exactly: `nil` means "no resolved directory"; `""`
    /// would be a second way to say the same thing, and would render a dishonest `in .` on
    /// the card.
    func testEmptyResolvedDirectoryIsRefusedSoAbsenceHasOneSpelling() {
        XCTAssertNil(
            ActionInvocation(
                providerID: CodingAgentProvider.providerID, toolID: "commit-helper",
                resolvedDirectory: ""),
            "empty resolved-directory text is not 'no directory' spelled a second way — it is "
                + "refused, so `nil` is the only way to say an invocation carries none")
    }
}

// MARK: - The call-logged engine

/// The provider's engine seam, recorded — the `RecordingAgentRunner` shape of
/// `CodingAgentProviderTests`, local to this suite.
private actor RecordingCarrierRunner {

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