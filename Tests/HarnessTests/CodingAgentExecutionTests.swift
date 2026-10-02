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

/// The `agent-execution` aspect of `coding-agent-handoff` — **no new engine ships**.
///
/// The agent engine is the shipped ``ShellExecutor``, reused behind an injected closure; the
/// transport-permit lint therefore stays at exactly two files — an agent child is a
/// ``ShellExecutor`` child, covered by the existing reviewed entry, and the D2 answer is
/// inherited ("a shell child" → "a coding-agent child": the same blind hop, the same narrowed
/// claim). What this suite pins is the executor's contract for the **agent configuration
/// shape**: an absolute executable, a fixed argv, a configured environment, and a per-row
/// timeout that flows from the registry's `timeoutSeconds` into ``ShellExecutor/Configuration``.
///
/// ## The child is hostile, and the four failure modes are the executor's existing answers
///
/// A child can exit early, never exit, write forever, and outlive the call that started it.
/// Each acceptance drives the **real** executor over real platform binaries — never a shell —
/// and asserts the shipped contract holds for the agent shape: completion with the exit code
/// read back, a raised per-row timeout honored over the injected clock (the run must not die at
/// the 30 s default when configured otherwise), the terminate → poll → SIGKILL → poll reaping
/// with the no-orphan acceptance asserted against the kernel (`kill(pid, 0) == -1 && errno ==
/// ESRCH` on the real child, via ``ShellExecutor/lastProcessIdentifier``), exactly the
/// configured environment and nothing else, and bounded capture that truncates, reports and
/// never fatals.
///
/// ## No test here may leave a child behind
///
/// The engine's whole contract is that a timed-out child is terminated **and reaped**; the
/// timeouts below are driven by the injected clock so the suite never waits, and the no-orphan
/// acceptance verifies the reaping against the kernel rather than against a flag of ours.
final class CodingAgentExecutionTests: XCTestCase {

    // MARK: - Fixtures

    /// A child that writes its arguments and exits 0 — a benign agent run.
    private static let completionAgent = "/bin/echo"

    /// A child that produces nothing and exits on nobody's schedule but its own — the hung
    /// agent, and the fixture the injected-clock ceilings are driven against.
    private static let silentAgent = "/bin/sleep"

    /// A child that prints its environment — the scrubbed-environment fixture.
    private static let environmentAgent = "/usr/bin/env"

    /// A child that writes unbounded output **and then exits** — a flood that still terminates
    /// normally, which is what separates "bounded capture" from "the timeout did the bounding".
    private static let floodingAgent = "/usr/bin/seq"

    /// The physical path a child's `getcwd` prints for a given URL.
    ///
    /// The kernel resolves symlinked components on `chdir`, so `/bin/pwd` prints the physical
    /// path — `/private/var/...` for a directory under `/var/folders/...`. Foundation's
    /// `resolvingSymlinksInPath()` leaves `/var` unresolved on this macOS (measured
    /// 2026-10-01), so the ground truth both sides agree on is `realpath`.
    private static func physicalPath(of url: URL) -> String {
        guard let resolved = url.path.withCString({ realpath($0, nil) }) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Acceptance 1: an agent-shaped configuration runs to completion

    /// An agent-shaped configuration — absolute executable, fixed argv, a configured environment
    /// entry, and no timeout of its own (the shipped 30 s default) — runs to completion through
    /// the real executor, with the exit code read back and the child's stdout captured.
    func testAnAgentShapedConfigurationRunsToCompletionWithTheExitCodeReadBack() async {
        let executor = ShellExecutor(
            configuration: .init(
                executablePath: Self.completionAgent,
                arguments: ["agent-ready"],
                environment: ["VOCCA_AGENT": "1"]),
            clock: ContinuousStdioClock(),
            sleeper: TaskStdioPollSleeper())
        let result = await executor.run()
        XCTAssertEqual(
            result.status, .succeeded(exitCode: 0),
            "an agent-shaped argv must complete successfully — '/bin/echo agent-ready' exits 0")
        XCTAssertEqual(
            String(decoding: result.standardOutput, as: UTF8.self), "agent-ready\n",
            "the child's stdout must be captured and read back — the agent's own output")
    }

    // MARK: - Acceptance 2: a raised per-row timeout is honored

    /// A row's raised timeout (120 s) is honored: the executor does **not** die at the 30 s
    /// default when configured otherwise.
    ///
    /// The deadline is the configured ceiling over the injected clock. The stepping clock
    /// advances 5 s per reading, so a run that silently applied the default would be terminated
    /// around the 35 s reading; the assertion that the clock had crossed **120 s** when the run
    /// resolved is the proof the child was still running past the 30 s mark — it was only
    /// terminated when the configured ceiling was reached. The wait is counted (`waits > 0`),
    /// and the counterfactual — the same child over the same clock shape with the default
    /// timeout — resolves near its own 35 s deadline, which is what makes "the configuration,
    /// not the harness, let the run pass 30 s" an observed fact rather than a hope.
    func testARaisedPerRowTimeoutIsHonoredPastTheThirtySecondMark() async {
        let clock = SteppingAgentClock(step: .seconds(5))
        let sleeper = InstantAgentPollSleeper()

        let executor = ShellExecutor(
            configuration: .init(
                executablePath: Self.silentAgent,
                arguments: ["300"],
                timeout: .seconds(120)),
            clock: clock,
            sleeper: sleeper)
        let result = await executor.run()

        XCTAssertEqual(
            result.status, .failed(reasonKey: ShellExecutionResult.timedOutReasonKey),
            """
            the run must end at the configured ceiling — `/bin/sleep 300` is still alive at \
            120 s of injected time, so the outcome is the timeout, never a hang.
            """)
        let reading = clock.now
        XCTAssertGreaterThanOrEqual(
            reading, .seconds(120),
            """
            the run resolved with the injected clock at \(reading) — it must have kept polling \
            until the configured 120 s ceiling. If the executor had applied the 30 s default, \
            the clock would have stopped around the 35 s reading and the child would have been \
            terminated at the wrong mark.
            """)
        let waits = await sleeper.waits
        XCTAssertGreaterThan(
            waits, 0,
            "the wait must actually have polled — a timeout reached by a spin loop is a bound "
                + "that costs a core, and a raised ceiling must still be a counted wait")

        let defaultClock = SteppingAgentClock(step: .seconds(5))
        let defaultExecutor = ShellExecutor(
            configuration: .init(executablePath: Self.silentAgent, arguments: ["300"]),
            clock: defaultClock,
            sleeper: InstantAgentPollSleeper())
        _ = await defaultExecutor.run()
        XCTAssertLessThan(
            defaultClock.now, .seconds(60),
            """
            the counterfactual — the same child, the same clock shape, the default 30 s timeout \
            — must resolve near its own deadline (~35 s of injected time). That the raised \
            configuration reached 120 s while the default stopped at ~35 s is what attributes \
            the longer run to the configuration and not to the harness.
            """)
    }

    // MARK: - Acceptance 3: a hung child is reaped, no orphan survives

    /// A hung child (`/bin/sleep 60`) is still alive at the injected-clock ceiling, so the
    /// engine must take the terminate → poll → SIGKILL → poll path; the no-orphan acceptance is
    /// asserted against the **real pid** read off ``ShellExecutor/lastProcessIdentifier`` —
    /// `kill(pid, 0) == -1 && errno == ESRCH`, `ESRCH` specifically because a zombie answers
    /// `kill(pid, 0)` successfully: the child must be terminated *and reaped*.
    ///
    /// The real sleeper (not the instant one) is deliberate, exactly as the executor's own suite
    /// records: the reap is a poll for the kernel to release the slot, and giving the OS time is
    /// part of the assertion.
    func testAHungChildIsTerminatedAndNoOrphanSurvivesTheRun() async throws {
        let executor = ShellExecutor(
            configuration: .init(executablePath: Self.silentAgent, arguments: ["60"]),
            clock: SteppingAgentClock(step: .seconds(30)),
            sleeper: TaskStdioPollSleeper())
        let result = await executor.run()
        XCTAssertEqual(
            result.status, .failed(reasonKey: ShellExecutionResult.timedOutReasonKey),
            """
            the run must time out — that is the staging that makes the no-orphan assertion real: \
            only a child the engine had to terminate stages anything about termination.
            """)

        let identifier = await executor.lastProcessIdentifier
        let pid = try XCTUnwrap(
            identifier, "a run that launched must have recorded the child's pid")
        let killed = kill(pid, 0)
        let error = errno
        XCTAssertEqual(
            killed, -1,
            """
            pid \(pid) still exists after the timed-out run returned. `kill(pid, 0)` asks the \
            kernel, which is the point: an internal flag reads correctly in every way this can \
            fail.
            """)
        XCTAssertEqual(
            error, ESRCH,
            """
            the child must be gone *and reaped* — a zombie answers kill(pid, 0) successfully, \
            so ESRCH is the assertion and not merely a non-zero return.
            """)
    }

    // MARK: - Acceptance 4: exactly the configured environment, nothing else

    /// The child receives **exactly** the configured environment entries, and nothing else.
    ///
    /// `/usr/bin/env` prints every variable it received. Two configured entries must print as
    /// the exact set of two lines — no `PATH`, no `HOME`, no residue of the caller's
    /// environment: the scrubbed-environment rule (N2) holds for the agent shape.
    func testTheChildReceivesExactlyTheConfiguredEnvironmentAndNothingElse() async {
        let executor = ShellExecutor(
            configuration: .init(
                executablePath: Self.environmentAgent,
                environment: ["ANTHROPIC_API_KEY": "sk-test", "VOCCA_AGENT": "1"]),
            clock: ContinuousStdioClock(),
            sleeper: TaskStdioPollSleeper())
        let result = await executor.run()
        XCTAssertEqual(
            result.status, .succeeded(exitCode: 0),
            "'/usr/bin/env' with a scrubbed environment must still run to completion")

        let lines = String(decoding: result.standardOutput, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(
            Set(lines),
            ["ANTHROPIC_API_KEY=sk-test", "VOCCA_AGENT=1"],
            """
            the child's environment must be exactly the configured entries and nothing else — \
            an agent row's environment is a trust the user extends to the agent's author, and \
            a stray `PATH` or `HOME` reaching the child would be the caller's environment \
            leaking into that trust. Got: \(lines.sorted())
            """)
    }

    // MARK: - Acceptance 4b: the baseline-environment merge (`executor-baseline`)

    /// The default baseline is the empty dictionary — byte-identical to today.
    ///
    /// ``ShellExecutor/Configuration/baselineEnvironment`` defaults to `[:]`, so a configuration
    /// that names no baseline runs exactly as the shipped scrub did: the child receives the
    /// configured entries and nothing else — no `PATH`, no `HOME`, no residue of the caller's
    /// session (N2). The baseline is **declared per configuration**, never inherited.
    func testTheDefaultBaselineIsTheEmptyDictionaryAndTheScrubHolds() async {
        let configuration = ShellExecutor.Configuration(
            executablePath: Self.environmentAgent,
            environment: ["VOCCA_AGENT": "1"])
        XCTAssertEqual(
            configuration.baselineEnvironment, [:],
            "the default baseline must be the empty dictionary — byte-identical to today's scrub")

        let executor = ShellExecutor(
            configuration: configuration,
            clock: ContinuousStdioClock(),
            sleeper: TaskStdioPollSleeper())
        let result = await executor.run()
        let lines = String(decoding: result.standardOutput, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(
            Set(lines), ["VOCCA_AGENT=1"],
            """
            a real run with the default baseline must still show the caller's `PATH` and `HOME` \
            absent — the default is byte-identical to the shipped scrub. Got: \(lines.sorted())
            """)
    }

    /// Baseline ∪ configured, configured wins — and nothing beyond the union reaches the child.
    ///
    /// The declared baseline (`PATH`, `HOME`) supplies what the row does not name; a configured
    /// entry (`PATH`) overrides the baseline's; and the exact printed set is the union — no
    /// `TMPDIR`, no `SHELL`, no residue of the caller's session.
    func testBaselineAndConfiguredEnvironmentMergeWithConfiguredWinningAndNothingElse() async {
        let executor = ShellExecutor(
            configuration: .init(
                executablePath: Self.environmentAgent,
                baselineEnvironment: ["PATH": "/baseline/bin", "HOME": "/baseline/home"],
                environment: ["PATH": "/configured/bin", "VOCCA_AGENT": "1"]),
            clock: ContinuousStdioClock(),
            sleeper: TaskStdioPollSleeper())
        let result = await executor.run()
        XCTAssertEqual(
            result.status, .succeeded(exitCode: 0),
            "'/usr/bin/env' over the merged environment must run to completion")
        let lines = String(decoding: result.standardOutput, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(
            Set(lines),
            ["PATH=/configured/bin", "HOME=/baseline/home", "VOCCA_AGENT=1"],
            """
            the child's environment must be exactly baseline ∪ configured with the configured \
            value winning — `PATH` from the row, `HOME` from the baseline, and nothing beyond \
            the union. Got: \(lines.sorted())
            """)
    }

    /// An explicitly empty configured entry beats a real baseline value — the intent rule.
    ///
    /// `"HOME": ""` in the row's own environment is a decision to unset, not an accident: the
    /// merge is `baseline.merging(environment) { _, new in new }`, so an empty configured value
    /// wins over a real baseline `HOME`, and the child prints `HOME=` — the empty entry is
    /// present, never the baseline's.
    func testAnExplicitlyEmptyConfiguredEntryBeatsABaselineValue() async {
        let executor = ShellExecutor(
            configuration: .init(
                executablePath: Self.environmentAgent,
                baselineEnvironment: ["HOME": "/real/home", "PATH": "/baseline/bin"],
                environment: ["HOME": ""]),
            clock: ContinuousStdioClock(),
            sleeper: TaskStdioPollSleeper())
        let result = await executor.run()
        XCTAssertEqual(
            result.status, .succeeded(exitCode: 0),
            "'/usr/bin/env' with the empty entry must still run to completion")
        let lines = String(decoding: result.standardOutput, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(
            Set(lines), ["HOME=", "PATH=/baseline/bin"],
            """
            an explicitly empty configured `HOME` must beat the baseline's real `/real/home` — \
            the row's intent wins even when the value is empty. Got: \(lines.sorted())
            """)
    }

    /// The N2 record is the honest rewrite — a comment pin, because comments are not executed.
    ///
    /// The scrub wording that promised "never the caller's environment" is gone from
    /// ``ShellExecutor``'s source; in its place is the declared rule — the child receives the
    /// baseline and the row's own entries, never beyond. The pin is a deterministic scan of the
    /// shipped source (the ``PackageRootLocator`` pattern); the wording itself is the reviewer's
    /// line.
    func testTheN2ScrubWordingIsTheHonestRewrite() throws {
        let source = try String(
            contentsOf: PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Sources/VoccaActions/Execution/ShellExecutor.swift"),
            encoding: .utf8)
        XCTAssertFalse(
            source.contains("never the caller's environment"),
            "the old scrub promise must be gone — the child's environment is no longer 'never "
                + "the caller's', it is the declared baseline plus the row's own entries")
        XCTAssertTrue(
            source.contains("never beyond the declared baseline and the row's own entries"),
            "the honest rule must be written in the source: the child receives the declared "
                + "baseline and the row's own entries, never beyond")
    }

    // MARK: - Acceptance 5: bounded capture — truncated, reported, never fatal

    /// An agent that floods stdout is capped at the 4 KB bound and still terminates normally —
    /// truncation, never a hang and never a failure.
    ///
    /// `/usr/bin/seq 1 100000` writes roughly 590 KB and then exits 0: a flood that ends. The
    /// retained stdout lands exactly on the bound, with ``ShellExecutionResult/outputWasTruncated``
    /// carrying the fact — an agent's long output is not a result channel this slice, and the
    /// loss is loud rather than silent.
    func testAnAgentFloodingStdoutIsTruncatedReportedAndNeverFatal() async {
        let executor = ShellExecutor(
            configuration: .init(
                executablePath: Self.floodingAgent, arguments: ["1", "100000"]),
            clock: ContinuousStdioClock(),
            sleeper: TaskStdioPollSleeper())
        let result = await executor.run()
        XCTAssertEqual(
            result.status, .succeeded(exitCode: 0),
            "the flood fixture must terminate on its own — seq writes then exits, so the run is "
                + "a normal completion, not a timeout")
        XCTAssertLessThanOrEqual(
            result.standardOutput.count,
            ShellExecutor.Configuration.defaultMaximumOutputBytes,
            "the captured stdout must be capped at the bound, never chosen by how fast the "
                + "child can write")
        XCTAssertTrue(
            result.outputWasTruncated,
            "a child that wrote 100000 lines must have hit the cap — a cap that is claimed "
                + "rather than measured is not a cap")
        XCTAssertEqual(
            result.standardOutput.count,
            ShellExecutor.Configuration.defaultMaximumOutputBytes,
            "a flood must fill the cap exactly — truncation lands on the bound, not short of it")
    }

    // MARK: - Acceptance 6: the child runs in the configured working directory

    /// The child starts in the configured working directory — `/bin/pwd` prints the directory
    /// the configuration named.
    ///
    /// This is the project-directory contract of the agent shape: a row's `projectDirectory`
    /// must reach the child as its working directory, or the sentence "in <directory>" is a
    /// lie. The directory is a **real** temp directory (created, never assumed), and the
    /// captured stdout is compared against its `realpath` — the physical path, which is what
    /// a child's `getcwd` prints after the kernel resolves the `/var` symlink.
    func testTheChildRunsInTheConfiguredWorkingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-coding-agent-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executor = ShellExecutor(
            configuration: .init(
                executablePath: "/bin/pwd",
                currentDirectoryURL: directory),
            clock: ContinuousStdioClock(),
            sleeper: TaskStdioPollSleeper())
        let result = await executor.run()
        XCTAssertEqual(
            result.status, .succeeded(exitCode: 0),
            "'/bin/pwd' in a real directory must run to completion")
        XCTAssertEqual(
            String(decoding: result.standardOutput, as: UTF8.self),
            Self.physicalPath(of: directory) + "\n",
            """
            the child must print the configured directory — the row's projectDirectory is \
            where the agent actually runs, never the caller's working directory. Got: \
            \(String(decoding: result.standardOutput, as: UTF8.self))
            """)
    }

    // MARK: - The seam row: the registry shape flows into the executor configuration

    /// The registry-shaped timeout and environment flow into the executor's configuration.
    ///
    /// The provider aspect builds a ``ShellExecutor/Configuration`` from a row of
    /// `coding-agents.json`; this pins the flow at the seam: a definition's `timeoutSeconds`
    /// (`Int`) becomes the configuration's `timeout` (`.seconds(...)`), its optional
    /// `environment` becomes the configuration's exact environment, and the resulting
    /// configuration drives the real executor end to end. The absent-timeout row (30) flows as
    /// `.seconds(30)`, which is the executor's own pinned default — the two defaults are the
    /// same fact.
    func testTheRegistryShapedRowFlowsIntoTheExecutorConfiguration() async {
        let definition = CodingAgentDefinition(
            id: "planner",
            executablePath: "/bin/echo",
            arguments: ["agent-seam"],
            projectDirectory: "/Users/alice/Projects/work",
            timeoutSeconds: 120,
            environment: ["VOCCA_AGENT": "seam"])!
        let configuration = ShellExecutor.Configuration(
            executablePath: definition.executablePath,
            arguments: definition.arguments,
            environment: definition.environment ?? [:],
            timeout: .seconds(definition.timeoutSeconds))

        XCTAssertEqual(
            configuration.timeout, .seconds(120),
            "the row's timeoutSeconds (Int) must flow into the configuration's timeout (Duration)")
        XCTAssertEqual(
            configuration.environment, ["VOCCA_AGENT": "seam"],
            "the row's optional environment must flow as the configuration's exact environment")
        XCTAssertEqual(
            configuration.arguments, ["agent-seam"],
            "the fixed argv flows through untouched")

        let executor = ShellExecutor(
            configuration: configuration,
            clock: ContinuousStdioClock(),
            sleeper: TaskStdioPollSleeper())
        let result = await executor.run()
        XCTAssertEqual(
            result.status, .succeeded(exitCode: 0),
            "the registry-shaped configuration must drive the real executor to completion")
        XCTAssertEqual(
            String(decoding: result.standardOutput, as: UTF8.self), "agent-seam\n",
            "and the child's output must be captured and read back")

        let minimal = CodingAgentDefinition(
            id: "minimal", executablePath: "/bin/echo", projectDirectory: "/tmp")!
        XCTAssertEqual(
            ShellExecutor.Configuration(executablePath: minimal.executablePath).timeout,
            .seconds(minimal.timeoutSeconds),
            "the absent-timeout row (30) flows as .seconds(30) — the same fact as the "
                + "executor's own default")
    }
}

// MARK: - Injected time

/// A clock that advances by a fixed step on every reading.
///
/// The shape the executor's own suite uses: one property — time passes *because the engine
/// looked at it*, so a ceiling of any size is reached in a bounded number of polls and the
/// suite never waits.
private final class SteppingAgentClock: MonotonicClock, @unchecked Sendable {
    private let step: Duration
    private var reading: Duration = .zero
    private let lock = NSLock()

    init(step: Duration) {
        self.step = step
    }

    var now: Duration {
        lock.lock()
        defer { lock.unlock() }
        reading += step
        return reading
    }
}

/// A poll wait that does not wait, and counts how often it was asked to.
///
/// The count is what keeps the timeout tests from passing for the wrong reason: an engine that
/// spun without ever yielding would also finish in milliseconds.
private actor InstantAgentPollSleeper: StdioPollSleeper {
    private(set) var waits = 0

    func wait(_ duration: Duration) async {
        waits += 1
        await Task.yield()
    }
}