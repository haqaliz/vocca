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

/// `ShellExecutor` — the subprocess engine of the `shell-provider` slice (`execution` aspect).
///
/// ## The child is hostile in the same four ways the stdio peer is
///
/// A child can exit early, never exit, write forever, and outlive the call that started it. The
/// stdio transport's suite is the precedent this battery follows: real children, an injected
/// clock, a counted wait, and a no-orphan acceptance asserted against the operating system
/// (`kill(pid, 0) == -1 && errno == ESRCH`) rather than against a flag of ours.
///
/// ## No shell, on purpose
///
/// Every fixture below is a real binary run directly. A shell would add a hop and make a quoting
/// rule part of what the test asserts — the same reason the stdio suite refuses it.
///
/// ## No test here may leave a child behind
///
/// The engine's whole contract is that a timed-out child is terminated **and reaped**. The
/// timeouts below are driven by the injected clock so the suite never waits; the no-orphan
/// acceptance is what verifies the reaping actually happened.
final class ShellExecutorTests: XCTestCase {

    // MARK: - Fixtures

    /// A child that writes its arguments and exits 0. The benign case.
    private static let benignChild = "/bin/echo"

    /// A child that exits 1. `/usr/bin/false` rather than `/bin/false`: on this SDK the latter
    /// does not exist — the fixture is a real platform binary either way.
    private static let failingChild = "/usr/bin/false"

    /// A child that produces nothing and exits on nobody's schedule but its own.
    private static let silentChild = "/bin/sleep"

    /// A child that writes unbounded output **and then exits** — a flood that still terminates
    /// normally, which is what separates "bounded capture" from "the timeout did the bounding".
    private static let floodingChild = "/usr/bin/seq"

    /// A child that prints its environment. Used to verify the scrubbed-environment contract.
    private static let environmentChild = "/usr/bin/env"

    /// A path that cannot be an executable — the launch-failure fixture.
    private static let missingChild = "/nonexistent/definitely-not-a-vocca-binary"

    // MARK: - Acceptance 1: a benign argv runs to completion

    /// A benign argv runs to completion; the outcome is success and the exit code is read back.
    func testABenignEchoRunsToCompletionAndTheExitCodeIsReadBack() async {
        let executor = ShellExecutor(
            configuration: .init(executablePath: Self.benignChild, arguments: ["hello"]),
            clock: ContinuousStdioClock(),
            sleeper: TaskStdioPollSleeper())
        let result = await executor.run()
        XCTAssertEqual(
            result.status, .succeeded(exitCode: 0),
            "a benign argv must complete successfully — '/bin/echo hello' exits 0")
        XCTAssertEqual(
            String(decoding: result.standardOutput, as: UTF8.self), "hello\n",
            "the child's stdout must be captured and read back")
    }

    // MARK: - Acceptance 2: a non-zero exit

    /// A non-zero exit is a failure with the bounded `shell.exitCode` key — never a throw.
    func testANonZeroExitYieldsTheBoundedExitCodeKey() async {
        let executor = ShellExecutor(
            configuration: .init(executablePath: Self.failingChild),
            clock: ContinuousStdioClock(),
            sleeper: TaskStdioPollSleeper())
        let result = await executor.run()
        XCTAssertEqual(
            result.status, .failed(reasonKey: ShellExecutionResult.exitCodeReasonKey),
            "a non-zero exit is a returned failure carrying the bounded exit-code key")
    }

    // MARK: - Acceptance 3: the bounded timeout, injected, never a hang

    /// A seeded sleeping child reaches the 30 s ceiling and is terminated — over the injected
    /// clock, so the suite does **not** sleep to find out.
    ///
    /// The wall-clock gap is the assertion: a 30 s bound resolved in milliseconds, and the
    /// wait-count (`waits > 0`) says the engine yielded to its poll rather than spinning.
    func testASeepingChildHitsTheCeilingAndTimesOutWithoutTheSuiteSleeping() async {
        let clock = SteppingShellClock(step: .seconds(5))
        let sleeper = InstantShellPollSleeper()
        let started = ContinuousClock.now

        let executor = ShellExecutor(
            configuration: .init(executablePath: Self.silentChild, arguments: ["300"]),
            clock: clock,
            sleeper: sleeper)
        let result = await executor.run()

        XCTAssertEqual(
            result.status, .failed(reasonKey: ShellExecutionResult.timedOutReasonKey),
            """
            a sleeping child must exhaust the ceiling and be terminated. The timeout is \
            `failed`, never a hang.
            """)
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(
            elapsed, .seconds(5),
            """
            a 30 s bound resolved in \(elapsed) — the wait must come from the injected clock, \
            not from the wall. If this ever fails, the bound has been hardcoded somewhere the \
            injection does not reach.
            """)
        let waits = await sleeper.waits
        XCTAssertGreaterThan(
            waits, 0,
            "the wait must actually have polled — a timeout reached by a spin loop is a bound "
                + "that costs a core")
    }

    /// A clock that never advances cannot make the wait infinite: the wait is **counted**.
    ///
    /// The stdio transport's timeout loop is bounded by the clock alone; this engine's contract
    /// is stronger — a broken or frozen clock must still resolve the bound in a bounded number of
    /// polls, or a release build could hang on a clock conformance that never moves. That is the
    /// "wait-count so a spin loop cannot pass" clause, pinned here against a frozen clock.
    func testAFrozenClockCannotPassTheCountedWait() async {
        let configuration = ShellExecutor.Configuration(
            executablePath: Self.silentChild, arguments: ["300"])
        let sleeper = InstantShellPollSleeper()
        let started = ContinuousClock.now

        let executor = ShellExecutor(
            configuration: configuration,
            clock: FrozenShellClock(),
            sleeper: sleeper)
        let result = await executor.run()

        XCTAssertEqual(
            result.status, .failed(reasonKey: ShellExecutionResult.timedOutReasonKey),
            """
            a frozen clock must still resolve the bound: the counted wait, not the clock, is \
            what guarantees a run terminates. A clock that never advances must cost a bounded \
            wait, never a hang.
            """)
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(
            elapsed, .seconds(5),
            "a counted wait over a frozen clock resolved in \(elapsed) — the count, not the "
                + "wall, must be what ended it")
        let waits = await sleeper.waits
        XCTAssertLessThanOrEqual(
            waits, configuration.maximumPolls + 101,
            """
            the counted wait performed \(waits) polls against a budget of \
            \(configuration.maximumPolls) plus the termination polls. A spin loop — or a wait \
            not bounded by a count — would exceed this; the count is what terminated the run.
            """)
    }

    // MARK: - Acceptance 4: no orphan survives termination

    /// After a timed-out run the **real pid** is gone: `kill(pid, 0) == -1 && errno == ESRCH`.
    ///
    /// Asserted against the operating system, never against an internal flag — every way this
    /// can go wrong leaves our flag reading correctly. `ESRCH` specifically, because a zombie
    /// answers `kill(pid, 0)` successfully: the child must be terminated **and reaped**.
    ///
    /// The real sleeper (not the instant one) is deliberate here: the reap is a poll for the
    /// kernel to say the slot is gone, and giving the OS time is part of the assertion.
    func testNoOrphanSurvivesTimeoutTermination() async throws {
        let executor = ShellExecutor(
            configuration: .init(executablePath: Self.silentChild, arguments: ["300"]),
            clock: SteppingShellClock(step: .seconds(30)),
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
        XCTAssertEqual(
            kill(pid, 0), -1,
            """
            pid \(pid) still exists after the timed-out run returned. `kill(pid, 0)` asks the \
            kernel, which is the point: an internal `isRunning` flag reads correctly in every \
            way this can fail.
            """)
        XCTAssertEqual(
            errno, ESRCH,
            """
            the child must be gone *and reaped* — a zombie answers kill(pid, 0) successfully, \
            so ESRCH is the assertion and not merely a non-zero return.
            """)
    }

    // MARK: - Acceptance 5: a flooding child is capped

    /// A child that writes unbounded output is capped at the 4 KB bound and still terminates
    /// normally — truncation, never a hang and never a failure.
    ///
    /// `/usr/bin/seq 1 100000` writes roughly 590 KB and then exits 0: a flood that ends. The
    /// cap is on what we retain, never on how fast the child can write.
    func testAFloodingChildIsCappedAtTheOutputBoundAndStillTerminatesNormally() async {
        let executor = ShellExecutor(
            configuration: .init(
                executablePath: Self.floodingChild, arguments: ["1", "100000"]),
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

    // MARK: - Acceptance 6: failure is a returned value, never a throw

    /// An unlaunchable argv is a returned failure — the engine never throws.
    ///
    /// This is the seam discipline the provider depends on: an outcome that must be returned is
    /// an outcome that cannot be dropped by omitting a `catch`, and the audit record must be
    /// written either way.
    func testALaunchFailureIsAReturnedValueNotAThrow() async {
        let executor = ShellExecutor(
            configuration: .init(executablePath: Self.missingChild),
            clock: ContinuousStdioClock(),
            sleeper: TaskStdioPollSleeper())
        let result = await executor.run()
        XCTAssertEqual(
            result.status, .failed(reasonKey: ShellExecutionResult.launchFailedReasonKey),
            "an unlaunchable argv is a failed outcome with the launch key, never a thrown error")
        let identifier = await executor.lastProcessIdentifier
        XCTAssertNil(
            identifier,
            "a failed launch must record no pid — nothing was spawned, so there is nothing to "
                + "terminate or reap")
    }

    // MARK: - The scrubbed environment (N2)

    /// The child receives the configured variables, and never the caller's environment.
    ///
    /// `/usr/bin/env` with no arguments prints every variable it received. `PATH` and `HOME`
    /// are present in every real caller environment, so their absence is the proof of scrubbing;
    /// the configured variable's presence proves the configured vars are exactly what is passed.
    func testTheChildReceivesAScrubbedEnvironmentNeverTheCallers() async {
        let executor = ShellExecutor(
            configuration: .init(
                executablePath: Self.environmentChild,
                environment: ["VOCCA_FIXTURE": "present"]),
            clock: ContinuousStdioClock(),
            sleeper: TaskStdioPollSleeper())
        let result = await executor.run()
        XCTAssertEqual(
            result.status, .succeeded(exitCode: 0),
            "'/usr/bin/env' with a scrubbed environment must still run to completion")

        let output = String(decoding: result.standardOutput, as: UTF8.self)
        XCTAssertTrue(
            output.contains("VOCCA_FIXTURE=present"),
            "the configured variable must reach the child")
        XCTAssertFalse(
            output.contains("PATH="),
            "the caller's environment must never reach the child — PATH is present in every "
                + "real environment, so its absence proves scrubbing")
        XCTAssertFalse(
            output.contains("HOME="),
            "likewise HOME — scrubbing is per-variable, not a keep-list that forgets one")
    }

    // MARK: - A child killed by a signal

    /// A child terminated by an uncaught signal maps to the distinct `shell.signal` key.
    ///
    /// The mapping is pure — no fixture can stage a self-signal without a shell or a scripting
    /// dependency, so the branch is pinned by handing the mapping its two inputs directly. The
    /// exit half of the same table is pinned here too, because it is the same decision.
    func testAChildKilledByASignalYieldsTheSignalKey() {
        XCTAssertEqual(
            ShellExecutor.status(terminationReason: .uncaughtSignal, terminationStatus: 9),
            .failed(reasonKey: ShellExecutionResult.signalReasonKey),
            "a signal death is a failure with its own bounded key, distinct from the exit-code "
                + "and timeout keys")
        XCTAssertEqual(
            ShellExecutor.status(terminationReason: .exit, terminationStatus: 0),
            .succeeded(exitCode: 0),
            "an exit 0 is success")
        XCTAssertEqual(
            ShellExecutor.status(terminationReason: .exit, terminationStatus: 3),
            .failed(reasonKey: ShellExecutionResult.exitCodeReasonKey),
            "a non-zero exit is the exit-code key, whatever the code")
    }

    // MARK: - The bounds are pinned in one place

    /// The timeout ceiling and the output bound are pinned as the shipped defaults, and a
    /// configuration that declares neither takes them rather than a literal of its own.
    ///
    /// Named so that a second, disagreeing bound cannot appear quietly beside it: the failure
    /// mode of a timeout is not that it is wrong but that there are two of them.
    func testTheTimeoutAndOutputBoundsArePinnedInOnePlace() {
        XCTAssertEqual(
            ShellExecutor.Configuration.defaultTimeout, .seconds(30),
            "the hard ceiling is 30 s — the seeded bound, recorded as such")
        XCTAssertEqual(
            ShellExecutor.Configuration.defaultMaximumOutputBytes, 4096,
            "the output capture bound is 4 KB")
        let config = ShellExecutor.Configuration(executablePath: Self.benignChild)
        XCTAssertEqual(
            config.timeout, ShellExecutor.Configuration.defaultTimeout,
            "a configuration that declares no timeout must take the pinned one, not a literal "
                + "of its own")
        XCTAssertEqual(
            config.maximumOutputBytes, ShellExecutor.Configuration.defaultMaximumOutputBytes,
            "likewise the output bound")
        XCTAssertTrue(
            config.environment.isEmpty,
            "the shipped default is a scrubbed environment — no configured variables means an "
                + "empty child environment, never the caller's")
    }
}

// MARK: - Injected time

/// A clock that advances by a fixed step on every reading.
///
/// The `StepAdvancingClock` shape from `InjectionTestDoubles`, kept local for the same reason
/// the stdio suite keeps its own: one property — time passes *because the engine looked at it*,
/// so a bound of any size is reached in a bounded number of polls and the suite never waits.
private final class SteppingShellClock: MonotonicClock, @unchecked Sendable {
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

/// A clock that never advances — the conformance the counted wait exists to survive.
private final class FrozenShellClock: MonotonicClock, @unchecked Sendable {
    var now: Duration { .zero }
}

/// A poll wait that does not wait, and counts how often it was asked to.
///
/// The count is what keeps the timeout tests from passing for the wrong reason: an engine that
/// spun without ever yielding would also finish in milliseconds.
private actor InstantShellPollSleeper: StdioPollSleeper {
    private(set) var waits = 0

    func wait(_ duration: Duration) async {
        waits += 1
        await Task.yield()
    }
}