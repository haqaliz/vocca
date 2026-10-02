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

/// The provider half of the agent-auth baseline (`provider-baseline`, the
/// `agent-auth-baseline` unit): **both providers carry the injected baseline into every
/// configuration they build.**
///
/// ``CodingAgentProvider`` and ``ShellProvider`` gain an additive `baselineEnvironment`
/// init parameter (default `[:]` — the doctrine), and every
/// ``ShellExecutor/Configuration`` they build passes it on. The composition wires **one**
/// value; every child the providers spawn receives it — the executor's merge rule does the
/// union, the row's own entries winning, never beyond the declared baseline and the row's
/// entries (N2).
///
/// ## The named consequence (`critique gap 2`)
///
/// Shell rows carry no environment of their own, so a wired baseline is the **whole** of a
/// shell child's environment: the day the composition wires HOME (and SHELL), a shell row's
/// child sees it too. That consequence is deliberately recorded here — in the provider's
/// configuration *and* in the child's actual environment, driven over a real
/// ``ShellExecutor`` and a real `/usr/bin/env` child. The unwired default reaches nothing:
/// a provider constructed without a baseline asks the engine for exactly the configuration
/// today's providers asked for — `baselineEnvironment` absent reads as `[:]`.
///
/// ## Every engine call below is recorded, never real — except the consequence rows
///
/// The counting-engine rows assert **what** was asked: the configuration's
/// `baselineEnvironment`, alongside the row's own entries. The two consequence rows are
/// deliberately real — a real ``ShellExecutor`` over a real `/usr/bin/env` child, the
/// `CodingAgentExecutionTests` shape — because the acceptance is about what a spawned
/// child *receives*, which a recorded call can only promise. No test here constructs an
/// ``ActionConfirmation`` — Family B confines that to ``ActionGate`` across `Sources/` and
/// `Tests/` alike, so every invocation below travels through the gate.
final class ProviderBaselineTests: XCTestCase {

    // MARK: - Fixtures

    /// An agent row with its own environment — the configuration must carry the row's
    /// entries AND the injected baseline, side by side (the executor's merge does the
    /// union; the provider decides nothing).
    private static let commitHelper = CodingAgentDefinition(
        id: "commit-helper",
        executablePath: "/usr/bin/true",
        arguments: [],
        projectDirectory: "/Users/aliz/dev/at/vocca",
        timeoutSeconds: 30,
        environment: ["VOCCA_TEST_KEY": "1"],
        clause: nil)!

    /// A shell row that prints its environment — the wired consequence's witness.
    private static let printEnvironment = ShellCommandDefinition(
        id: "print-env",
        command: ["/usr/bin/env"])

    /// The baseline the composition will wire — HOME and PATH, the named consequence's own
    /// vocabulary.
    private static let baseline = ["HOME": "/baseline/home", "PATH": "/baseline/bin"]

    private func makeAgentInvocation(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(
                providerID: CodingAgentProvider.providerID, toolID: "commit-helper",
                arguments: nil),
            "the agent invocation under test must construct", file: file, line: line)
    }

    private func makeShellInvocation(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(
                providerID: ShellProvider.providerID, toolID: "print-env", arguments: nil),
            "the shell invocation under test must construct", file: file, line: line)
    }

    /// A provider over the agent row whose engine records every call and answers `result`.
    ///
    /// `baselineEnvironment` is passed **only** when the test names one — the nil leg is the
    /// default-posture construction, byte-identical to today's call sites.
    private func makeAgentProvider(
        baselineEnvironment: [String: String]? = nil, result: ShellExecutionResult
    ) -> (CodingAgentProvider, RecordingBaselineRunner) {
        let runner = RecordingBaselineRunner(result: result)
        if let baselineEnvironment {
            return (
                CodingAgentProvider(
                    agents: [Self.commitHelper],
                    run: { configuration in await runner.run(configuration) },
                    baselineEnvironment: baselineEnvironment),
                runner)
        }
        return (
            CodingAgentProvider(agents: [Self.commitHelper]) { configuration in
                await runner.run(configuration)
            },
            runner)
    }

    /// A provider over the env-printing shell row whose engine records every call and
    /// answers `result` — the configuration-level shell rows.
    private func makeShellProvider(
        baselineEnvironment: [String: String]? = nil, result: ShellExecutionResult
    ) -> (ShellProvider, RecordingBaselineRunner) {
        let runner = RecordingBaselineRunner(result: result)
        if let baselineEnvironment {
            return (
                ShellProvider(
                    commands: [Self.printEnvironment],
                    run: { configuration in await runner.run(configuration) },
                    baselineEnvironment: baselineEnvironment),
                runner)
        }
        return (
            ShellProvider(commands: [Self.printEnvironment]) { configuration in
                await runner.run(configuration)
            },
            runner)
    }

    /// A provider over the env-printing shell row whose engine is the **real**
    /// ``ShellExecutor`` — the consequence rows' witness, recording the child's actual
    /// result alongside running it.
    private func makeRealShellProvider(
        baselineEnvironment: [String: String]? = nil
    ) -> (ShellProvider, RecordingRealRunner) {
        let runner = RecordingRealRunner()
        if let baselineEnvironment {
            return (
                ShellProvider(
                    commands: [Self.printEnvironment],
                    run: { configuration in await runner.run(configuration) },
                    baselineEnvironment: baselineEnvironment),
                runner)
        }
        return (
            ShellProvider(commands: [Self.printEnvironment]) { configuration in
                await runner.run(configuration)
            },
            runner)
    }

    /// A successful engine answer.
    private func success() -> ShellExecutionResult {
        ShellExecutionResult(
            status: .succeeded(exitCode: 0),
            standardOutput: Data(), standardError: Data(), outputWasTruncated: false)
    }

    // MARK: - Acceptance 1: the configurations carry the injected baseline

    /// **The agent configuration carries the injected baseline alongside the row's own
    /// environment.**
    ///
    /// The counting engine asserts the ``ShellExecutor/Configuration/baselineEnvironment``
    /// value — and that the row's entries still flow in their own field, never merged,
    /// never dropped: the provider passes both and the executor's merge rule does the
    /// union (the row winning). One value wired at composition; every agent child starts
    /// from it.
    func testCodingAgentConfigurationCarriesTheInjectedBaselineAlongsideTheRowsEnvironment()
        async throws
    {
        let (provider, runner) = makeAgentProvider(
            baselineEnvironment: Self.baseline, result: success())
        let invocation = try makeAgentInvocation()

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)

        XCTAssertEqual(decision.outcome, .succeeded)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls[0].baselineEnvironment, Self.baseline,
            "the injected baseline is carried into the configuration the engine receives")
        XCTAssertEqual(
            calls[0].environment, ["VOCCA_TEST_KEY": "1"],
            "the row's own entries flow alongside, in their own field — the provider carries "
                + "both and decides nothing about the union")
    }

    /// **The shell configuration carries the injected baseline.**
    ///
    /// Shell rows declare no environment of their own, so the baseline is the whole of what
    /// a shell child receives when wired — and it travels in its own field, never smuggled
    /// into the row's.
    func testShellConfigurationCarriesTheInjectedBaseline() async throws {
        let (provider, runner) = makeShellProvider(
            baselineEnvironment: Self.baseline, result: success())
        let invocation = try makeShellInvocation()

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)

        XCTAssertEqual(decision.outcome, .succeeded)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls[0].baselineEnvironment, Self.baseline,
            "a shell row's configuration carries the injected baseline — the provider's own "
                + "field, exactly as wired")
        XCTAssertEqual(
            calls[0].environment, [:],
            "the shell configuration still carries no row environment — the baseline is "
                + "carried beside it, never in it")
    }

    // MARK: - Acceptance 2: the default `[:]` is byte-identical

    /// **A provider constructed without a baseline asks the engine for the empty
    /// baseline** — the default posture, byte-identical to today's configuration.
    func testTheCodingAgentDefaultBaselineIsTheEmptyDictionary() async throws {
        let (provider, runner) = makeAgentProvider(result: success())
        let invocation = try makeAgentInvocation()

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)

        XCTAssertEqual(decision.outcome, .succeeded)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls[0].baselineEnvironment, [:],
            "the default baseline is the empty dictionary — a construction that names no "
                + "baseline is byte-identical to today's")
        XCTAssertEqual(
            calls[0].environment, ["VOCCA_TEST_KEY": "1"],
            "the row's environment is untouched by the new default")
    }

    /// **The shell default is the empty dictionary too** — a shell row built as every
    /// shipped construction site builds it today carries no baseline.
    func testTheShellDefaultBaselineIsTheEmptyDictionary() async throws {
        let (provider, runner) = makeShellProvider(result: success())
        let invocation = try makeShellInvocation()

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)

        XCTAssertEqual(decision.outcome, .succeeded)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls[0].baselineEnvironment, [:],
            "the default baseline is the empty dictionary — the doctrine holds for both "
                + "providers")
    }

    // MARK: - Acceptance 3: the shell consequence

    /// **A wired baseline reaches a shell child — the named consequence, measured.**
    ///
    /// Once the composition wires HOME and PATH, a shell row's child receives them: this
    /// row drives the provider with a wired baseline through the **real** ``ShellExecutor``
    /// and a real `/usr/bin/env` child, and the child's printed environment is exactly the
    /// baseline — nothing beyond it (the scrub holds over the baseline), nothing missing.
    func testAWiredBaselineReachesAShellChild() async throws {
        let (provider, runner) = makeRealShellProvider(baselineEnvironment: Self.baseline)
        let invocation = try makeShellInvocation()

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)

        XCTAssertEqual(
            decision.outcome, .succeeded,
            "a shell row over a real engine must run to completion")
        let results = await runner.results
        XCTAssertEqual(results.count, 1)
        let lines = String(decoding: results[0].standardOutput, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(
            Set(lines), Set(Self.baseline.map { "\($0.key)=\($0.value)" }),
            """
            the wired baseline is exactly what the shell child sees — HOME and PATH from the \
            composition, and nothing else: a shell row declares no environment of its own, so \
            the baseline is the whole of the child's environment (the N2 scrub holds over it). \
            Got: \(lines.sorted())
            """)
    }

    /// **The unwired default reaches nothing — a shell child with no environment.**
    ///
    /// A shell provider constructed as every shipped construction site constructs it today
    /// wires no baseline, and a shell row declares no environment of its own: the real
    /// child's printed environment is empty. The consequence's other half, measured.
    func testTheUnwiredDefaultReachesNothing() async throws {
        let (provider, runner) = makeRealShellProvider()
        let invocation = try makeShellInvocation()

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)

        XCTAssertEqual(
            decision.outcome, .succeeded,
            "a shell row with no wired baseline must still run to completion")
        let results = await runner.results
        XCTAssertEqual(results.count, 1)
        let lines = String(decoding: results[0].standardOutput, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(
            Set(lines), [],
            """
            with no wired baseline a shell row's child receives an empty environment — no \
            HOME, no PATH, no residue of the caller's session (N2), and no baseline to carry. \
            Got: \(lines.sorted())
            """)
    }
}

// MARK: - The call-logged engines

/// The providers' engine seam, recorded: every configuration it is asked to run is logged,
/// and the answer is the scripted one.
///
/// An actor because the providers' run closures are `async` and the log is read from the
/// assertions afterwards — the ``RecordingActionProvider`` shape, for the engine instead of
/// the seam. No counting row here spawns a child; the real engine's rows live below.
private actor RecordingBaselineRunner {

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

/// The real engine's recorder: every result of a genuinely spawned run, kept for the
/// assertions that measure what a child received.
private actor RecordingRealRunner {

    private var log: [ShellExecutionResult] = []

    func run(_ configuration: ShellExecutor.Configuration) async -> ShellExecutionResult {
        let result = await ShellExecutor(
            configuration: configuration,
            clock: ContinuousStdioClock(),
            sleeper: TaskStdioPollSleeper()).run()
        log.append(result)
        return result
    }

    /// Every result this runner's real runs produced, in order.
    var results: [ShellExecutionResult] { log }
}