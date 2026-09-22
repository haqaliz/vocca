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

/// The subprocess engine of the `shell-provider` slice: runs a configured argv on the user's
/// machine and returns a bounded ``ShellExecutionResult``.
///
/// This is the **second** file under `Sources/VoccaActions/` permitted to name the `Process`
/// family, by a reviewed entry in `ActionTransportProhibitionTests`. The confinement is the D2
/// answer in writing: a shell child is one blind hop more than the stdio child, so nothing about
/// it is observable from inside this process — and the claim the lint keeps true is that the
/// **default configuration cannot create one**; this file is machinery nothing is wired to.
///
/// ## Fixed argv, no shell
///
/// The configured argv is executed directly (`executableURL` + `arguments`), never through
/// `/bin/sh -c`. A shell is where expansion, metacharacters and a user-typed command line get
/// in; the registry's `command` array is a fixed, reviewed argv and nothing about it is typed at
/// call time. The engine is registry-agnostic — it takes a path and arguments, full stop.
///
/// ## The child is hostile, and the four failure modes are the same ones the stdio peer has
///
/// A child can exit early, never exit, write forever, and outlive the call that started it.
/// Every wait in this type is bounded and every read is bounded, following
/// `StdioMCPTransport` exactly:
///
/// - **The timeout is a hard ceiling over an injected clock.** ``Configuration/defaultTimeout``
///   (30 s) is the ceiling; the clock and the poll wait are both injected, so a test moves time
///   by hand and a ten-minute bound is exercised in milliseconds rather than by waiting for it.
/// - **The wait is counted, so a spin loop cannot pass.** The poll loop runs against a budget —
///   ``Configuration/maximumPolls`` — and yields to the sleeper on every turn. The count is what
///   keeps a *frozen* clock from making the wait infinite: whether the clock passes the deadline
///   or the budget runs out, a child that is still alive after the bound is terminated. The
///   stdio transport bounds its termination wait this way (`terminationPolls`); this engine
///   extends the same count to the whole run.
/// - **Termination reaps, and the no-orphan acceptance is measured, not asserted.** A timed-out
///   child is `SIGTERM`'d, polled to exit within a counted bound, `SIGKILL`'d if it ignores that,
///   and polled again. `waitUntilExit()` is **never** called — it deadlocks here, spinning the
///   calling thread's run loop from the concurrency pool (the measured stdio lesson). The reap is
///   polled against the operating system (`kill(pid, 0)`), so a child that answered a polite
///   `SIGTERM` and a child that needed killing are both gone from the process table before the
///   engine returns — and a zombie, which answers `kill(pid, 0)` successfully, is not "gone".
/// - **Output is bounded per stream.** stdout and stderr are read in bounded chunks into a
///   bounded buffer (``Configuration/maximumOutputBytes``); overflow is truncated, never fatal,
///   and reported in ``ShellExecutionResult/outputWasTruncated``.
/// - **The environment is scrubbed.** The child receives exactly the configured variables — the
///   empty dictionary by default — never the caller's environment (N2). A shell command that
///   expected `PATH` or `HOME` to be inherited gets nothing it was not configured with.
///
/// ## Failure is a returned value
///
/// ``run()`` is `async`, never `async throws`. A launch that failed is a `.failed` outcome a
/// caller cannot drop by omitting a `catch` — the seam posture the provider maps into
/// ``ActionOutcome``.
public actor ShellExecutor {

    // MARK: - Configuration

    /// What to launch, and the bounds that keep an untrusted child from deciding how much time
    /// and memory this process spends on it.
    public struct Configuration: Sendable {

        /// The hard ceiling on one run, over the injected clock.
        ///
        /// **The one place the bound is pinned.** A second bound beside it would not be wrong so
        /// much as ambiguous, which is the failure mode timeouts actually have. The value is a
        /// seed, recorded as such in the spec.
        public static let defaultTimeout: Duration = .seconds(30)

        /// How long the engine waits between polls of a child that has not finished yet.
        public static let defaultPollInterval: Duration = .milliseconds(5)

        /// The cap on each captured stream. 4 KB: plenty for a diagnostic tail, far below a
        /// number that matters to this process.
        public static let defaultMaximumOutputBytes = 4096

        /// The executable to run. An absolute path — nothing here consults a `PATH`, because
        /// resolving a name against an environment variable is a second decision about *which*
        /// program runs, and it is not this seam's to make.
        public let executablePath: String

        /// The arguments, passed through untouched. Never a command line, never a shell.
        public let arguments: [String]

        /// The child's environment — exactly these variables and nothing else. **Empty by
        /// default**: the child gets a scrubbed environment, never the caller's (N2).
        public let environment: [String: String]

        /// How long one run may take before the child is terminated.
        public let timeout: Duration

        /// How long the engine waits between polls.
        public let pollInterval: Duration

        /// The cap on each captured stream, in bytes.
        public let maximumOutputBytes: Int

        public init(
            executablePath: String,
            arguments: [String] = [],
            environment: [String: String] = [:],
            timeout: Duration = Configuration.defaultTimeout,
            pollInterval: Duration = Configuration.defaultPollInterval,
            maximumOutputBytes: Int = Configuration.defaultMaximumOutputBytes
        ) {
            self.executablePath = executablePath
            self.arguments = arguments
            self.environment = environment
            self.timeout = timeout
            self.pollInterval = pollInterval
            self.maximumOutputBytes = maximumOutputBytes
        }

        /// The wait-count: how many polls one run may take before the bound must have been
        /// reached.
        ///
        /// Computed from the timeout and the poll interval so a legitimate run can reach its
        /// deadline, and clamped so an absurd configuration cannot divide by zero. This is the
        /// number a *frozen* clock is up against — the counted half of the timeout contract.
        public var maximumPolls: Int {
            let timeoutSeconds = Self.seconds(in: timeout)
            let intervalSeconds = max(Self.seconds(in: pollInterval), 0.001)
            let polls = Int(timeoutSeconds / intervalSeconds) + 1
            return max(polls, 1)
        }

        private static func seconds(in duration: Duration) -> Double {
            Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        }
    }

    // MARK: - State

    private let configuration: Configuration
    private let clock: any MonotonicClock & Sendable
    private let sleeper: any StdioPollSleeper

    /// The pid of the most recently launched child, or `nil` when nothing has been spawned.
    ///
    /// Exposed so "no orphan survives a run" can be asserted against the **operating system** —
    /// `kill(pid, 0)` — rather than against a flag of ours. Every way reaping can go wrong leaves
    /// an internal flag reading correctly; the process table does not lie.
    public private(set) var lastProcessIdentifier: pid_t?

    public init(
        configuration: Configuration,
        clock: any MonotonicClock & Sendable,
        sleeper: any StdioPollSleeper
    ) {
        self.configuration = configuration
        self.clock = clock
        self.sleeper = sleeper
    }

    // MARK: - Run

    /// Runs the configured argv to completion, or until the ceiling, and returns the outcome.
    ///
    /// Never throws. Launch failure, a non-zero exit, a signal death and a timeout are all
    /// returned as ``ShellExecutionResult`` values — the `async, never async throws` discipline
    /// the ``ActionProvider`` seam and the audit record depend on.
    ///
    /// Every exit path that has launched a child leaves it **reaped**: a timed-out child is
    /// terminated and polled out of the process table before this returns, and a normally-exited
    /// child is reaped the same way. The no-orphan acceptance asserts exactly that with
    /// `kill(pid, 0) == -1 && errno == ESRCH`.
    public func run() async -> ShellExecutionResult {
        guard access(configuration.executablePath, X_OK) == 0 else {
            return Self.failed(ShellExecutionResult.launchFailedReasonKey)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.arguments = configuration.arguments
        // The scrubbed environment: exactly the configured variables, never the caller's.
        process.environment = configuration.environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        // No stdin: the spec's boundary is no interactive commands, so the child reads /dev/null.
        process.standardInput = FileHandle.nullDevice

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        guard Self.setNonBlocking(outputHandle), Self.setNonBlocking(errorHandle) else {
            return Self.failed(ShellExecutionResult.launchFailedReasonKey)
        }

        do {
            try process.run()
        } catch {
            return Self.failed(ShellExecutionResult.launchFailedReasonKey)
        }
        lastProcessIdentifier = process.processIdentifier

        // The parent's copies of the write ends must close, or the child's stdout never reads
        // end-of-file. This engine sends nothing.
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        let deadline = clock.now + configuration.timeout
        var standardOutput = Data()
        var standardError = Data()
        var stdoutTruncated = false
        var stderrTruncated = false
        var remainingPolls = configuration.maximumPolls

        // The counted wait: bounded polls, each yielding to the sleeper, decided by the clock.
        // Either the child finishes, or the clock passes the deadline, or the count runs out —
        // and whichever of the last two happens with the child still alive, it is a timeout.
        while remainingPolls > 0 {
            remainingPolls -= 1
            Self.appendAvailable(
                outputHandle, into: &standardOutput,
                cap: configuration.maximumOutputBytes, truncated: &stdoutTruncated)
            Self.appendAvailable(
                errorHandle, into: &standardError,
                cap: configuration.maximumOutputBytes, truncated: &stderrTruncated)
            if !process.isRunning { break }
            if clock.now >= deadline { break }
            await sleeper.wait(configuration.pollInterval)
        }

        if process.isRunning {
            // The bound was reached with the child still alive. Terminate it, and keep polling
            // until the process table has no slot for it: polite, then SIGKILL, then reaped.
            await terminateAndReap(process)
            return Self.failed(
                ShellExecutionResult.timedOutReasonKey,
                stdout: standardOutput, stderr: standardError,
                truncated: stdoutTruncated || stderrTruncated)
        }

        // The child has exited. Reap it — a child Foundation has observed is not necessarily a
        // slot the process table has released — then drain whatever it still had buffered.
        await reap(process)
        Self.appendAvailable(
            outputHandle, into: &standardOutput,
            cap: configuration.maximumOutputBytes, truncated: &stdoutTruncated)
        Self.appendAvailable(
            errorHandle, into: &standardError,
            cap: configuration.maximumOutputBytes, truncated: &stderrTruncated)
        try? outputHandle.close()
        try? errorHandle.close()

        return ShellExecutionResult(
            status: Self.status(
                terminationReason: process.terminationReason,
                terminationStatus: process.terminationStatus),
            standardOutput: standardOutput,
            standardError: standardError,
            outputWasTruncated: stdoutTruncated || stderrTruncated)
    }

    // MARK: - Exit-code mapping

    /// Maps Foundation's termination vocabulary to the bounded outcome vocabulary.
    ///
    /// Pure and public so the mapping is executed by a test even though no benign fixture can
    /// stage a signal death without a shell or a scripting dependency.
    public static func status(
        terminationReason: Process.TerminationReason,
        terminationStatus: Int32
    ) -> ShellExecutionResult.Status {
        switch (terminationReason, terminationStatus) {
        case (.exit, 0):
            return .succeeded(exitCode: 0)
        case (.exit, _):
            return .failed(reasonKey: ShellExecutionResult.exitCodeReasonKey)
        case (.uncaughtSignal, _):
            return .failed(reasonKey: ShellExecutionResult.signalReasonKey)
        case (_, _):
            // An unknown termination reason is not an exit: the child did not run to a status.
            // Fold it under the signal key — the bounded "did not exit normally" vocabulary —
            // rather than inventing a key the audit seam has not seen.
            return .failed(reasonKey: ShellExecutionResult.signalReasonKey)
        }
    }

    // MARK: - Teardown

    /// How many polls a child gets to honour `SIGTERM` — and how many polls a run gets to leave
    /// the process table — before the engine gives up waiting and kills it outright.
    private static let terminationPolls = 100

    /// Terminates a running child and reaps it: `SIGTERM`, a counted wait, `SIGKILL` if it is
    /// still there, then another counted wait. The no-orphan acceptance is this function.
    private func terminateAndReap(_ process: Process) async {
        let pid = process.processIdentifier
        process.terminate()
        await waitForExit(of: pid)
        if isAlive(pid) {
            kill(pid, SIGKILL)
            await waitForExit(of: pid)
        }
    }

    /// Reaps an already-exited child: waits, bounded, for the process table to release it.
    private func reap(_ process: Process) async {
        await waitForExit(of: process.processIdentifier)
    }

    /// Whether `pid` still occupies a slot in the process table.
    ///
    /// Signal 0 performs the permission and existence checks and delivers nothing. It answers
    /// `0` for a **zombie** too, which is the point: a reaped child and an exited-but-unreaped
    /// one are different states, and only the first is "no orphan".
    private nonisolated func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// Waits, bounded, for `pid` to leave the process table entirely.
    ///
    /// Polls rather than calling `Process.waitUntilExit()`, and the reason is measured rather
    /// than stylistic: `waitUntilExit()` spins the calling thread's run loop waiting for a source
    /// signalled against the run loop that was current when the child was launched — which here
    /// is the concurrency pool, where run loops do not run, so the call blocks a cooperative
    /// thread forever and takes the suite with it. That is not a hypothetical; it is the stdio
    /// transport's recorded lesson. Bounded by ``terminationPolls``, so an unkillable child costs
    /// a bounded wait and not a hang.
    private func waitForExit(of pid: pid_t) async {
        var remainingPolls = Self.terminationPolls
        while remainingPolls > 0, isAlive(pid) {
            remainingPolls -= 1
            await sleeper.wait(configuration.pollInterval)
        }
    }

    // MARK: - The bounded capture

    /// The most that is taken from a pipe in a single read — the bound on a *flooding* child.
    private static let readChunkBytes = 16 * 1024

    /// Reads whatever is available from `handle` and appends it to `buffer`, **bounded**.
    ///
    /// Never reads "until the child is done": the run loop is what decides when a run is over,
    /// and a child that never stops writing must cost at most ``Configuration/maximumOutputBytes``
    /// of retained memory. A read that would pass the cap is truncated, and `truncated` records
    /// the fact — overflow is never fatal. Non-blocking: a descriptor that would block would
    /// park the wait with no bound, which is exactly the timeout this type exists to impose.
    private static func appendAvailable(
        _ handle: FileHandle,
        into buffer: inout Data,
        cap: Int,
        truncated: inout Bool
    ) {
        let descriptor = handle.fileDescriptor
        var scratch = [UInt8](repeating: 0, count: Self.readChunkBytes)
        let count: Int = scratch.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            return read(descriptor, base, raw.count)
        }
        guard count > 0 else { return }
        guard buffer.count < cap else {
            truncated = true
            return
        }
        let room = cap - buffer.count
        if count <= room {
            buffer.append(Data(scratch[0..<count]))
        } else {
            buffer.append(Data(scratch[0..<room]))
            truncated = true
        }
    }

    /// Marks a `FileHandle`'s descriptor non-blocking, so reads never park the wait.
    ///
    /// Set **before** the spawn: if it cannot be set there is nothing to clean up.
    private static func setNonBlocking(_ handle: FileHandle) -> Bool {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            return false
        }
        return true
    }

    // MARK: - Result construction

    private static func failed(
        _ reasonKey: String,
        stdout: Data = Data(),
        stderr: Data = Data(),
        truncated: Bool = false
    ) -> ShellExecutionResult {
        ShellExecutionResult(
            status: .failed(reasonKey: reasonKey),
            standardOutput: stdout,
            standardError: stderr,
            outputWasTruncated: truncated)
    }
}